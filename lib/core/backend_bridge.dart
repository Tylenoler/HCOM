import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Phase 1 IPC boundary: newline-delimited JSON over a Rust child process.
/// An environment override supports development; packaged Windows builds use
/// a sibling `hcom-core.exe`. See protocol/stdio-ndjson.md.
class BackendBridge {
  Process? _process;
  StreamSubscription<String>? _stdoutSubscription;
  final _events = StreamController<Map<String, dynamic>>.broadcast();

  Stream<Map<String, dynamic>> get events => _events.stream;
  bool get isRunning => _process != null;

  Future<bool> start() async {
    final executable = _findExecutable();
    if (executable == null) return false;

    try {
      _process = await Process.start(executable, const []);
      _stdoutSubscription = _process!.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(_handleLine);
      unawaited(_process!.exitCode.then((_) => stop()));
      send('hello', {'client': 'flutter', 'protocolVersion': 1});
      return true;
    } on ProcessException {
      _process = null;
      return false;
    }
  }

  String? _findExecutable() {
    final override = Platform.environment['HCOM_CORE_PATH'];
    if (override != null && override.isNotEmpty) return override;

    final bundled = File(
        '${File(Platform.resolvedExecutable).parent.path}${Platform.pathSeparator}hcom-core.exe');
    return bundled.existsSync() ? bundled.path : null;
  }

  void send(String command, [Map<String, dynamic> payload = const {}]) {
    final process = _process;
    if (process == null) return;
    process.stdin.writeln(jsonEncode({'command': command, 'payload': payload}));
  }

  void _handleLine(String line) {
    try {
      final decoded = jsonDecode(line);
      if (decoded is Map<String, dynamic>) _events.add(decoded);
    } on FormatException {
      // Stdio is a machine protocol. Ignore malformed diagnostics on stdout.
    }
  }

  Future<void> stop() async {
    await _stdoutSubscription?.cancel();
    _stdoutSubscription = null;
    final process = _process;
    _process = null;
    process?.kill();
  }

  Future<void> dispose() async {
    await stop();
    await _events.close();
  }
}
