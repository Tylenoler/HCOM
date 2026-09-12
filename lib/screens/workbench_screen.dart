import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:bitsdojo_window/bitsdojo_window.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app_info.dart';
import '../core/backend_bridge.dart';
import '../models/log_copy.dart';
import '../models/log_export.dart';
import '../models/receive_framer.dart';
import '../models/serial_entry.dart';
import '../models/time_zone.dart';
import '../theme/hcom_theme.dart';

enum SendMode { sequence, loop, trigger, periodic }

enum SendInputFormat { hex, plainText }

enum PacketSuffix { none, cr, crlf, lf }

extension PacketSuffixDetails on PacketSuffix {
  String get label => switch (this) {
        PacketSuffix.none => '无',
        PacketSuffix.cr => r'+ \r',
        PacketSuffix.crlf => r'+ \r\n',
        PacketSuffix.lf => r'+ \n',
      };

  String get hex => switch (this) {
        PacketSuffix.none => '',
        PacketSuffix.cr => '0D',
        PacketSuffix.crlf => '0D 0A',
        PacketSuffix.lf => '0A',
      };
}

const _queueDeleteDoubleClickWindow = Duration(milliseconds: 450);
const _minimumAppWidthForQueueEditor = 600.0;
const _sendFormatSyncWindow = Duration(milliseconds: 1500);

class _QueuedCommand {
  _QueuedCommand({
    required this.name,
    required this.hex,
    this.packetSuffix = PacketSuffix.none,
  });

  String name;
  String hex;
  bool enabled = true;
  int delayMilliseconds = 0;
  PacketSuffix packetSuffix;

  String get wireHex => _appendPacketSuffix(hex, packetSuffix);
}

String _appendPacketSuffix(String bytes, PacketSuffix suffix) {
  final base = bytes.trim();
  if (base.isEmpty) return suffix.hex;
  return suffix.hex.isEmpty ? base : '$base ${suffix.hex}';
}

class _StartupSettings {
  const _StartupSettings({
    required this.timeZoneOffsetMinutes,
    required this.leftDockExpanded,
    required this.rightDockExpanded,
    required this.queueExpanded,
    required this.isDark,
  });

  final int timeZoneOffsetMinutes;
  final bool leftDockExpanded;
  final bool rightDockExpanded;
  final bool queueExpanded;
  final bool isDark;
}

class WorkbenchScreen extends StatefulWidget {
  const WorkbenchScreen({
    super.key,
    required this.isDark,
    required this.onThemeChanged,
    required this.onStartupThemeChanged,
  });

  final bool isDark;
  final VoidCallback onThemeChanged;
  final ValueChanged<bool> onStartupThemeChanged;

  @override
  State<WorkbenchScreen> createState() => _WorkbenchScreenState();
}

class _WorkbenchScreenState extends State<WorkbenchScreen>
    with TickerProviderStateMixin {
  final _bridge = BackendBridge();
  final _commandController = TextEditingController();
  final _periodicIntervalController = TextEditingController(text: '1000');
  final _queueNameController = TextEditingController(text: '默认队列');
  final _streamController = ScrollController();
  late final StreamSubscription<Map<String, dynamic>> _eventSubscription;
  late final AnimationController _connectionPulseController;
  late final AnimationController _sendPanelFadeController;
  late List<SerialEntry> _entries;
  List<_SerialPort> _ports = const [];
  SendMode? _sendMode;
  SendInputFormat _sendInputFormat = SendInputFormat.hex;
  SendInputFormat _receiveInputFormat = SendInputFormat.hex;
  ReceiveFramingConfig _receiveFramingConfig = const ReceiveFramingConfig();
  final ReceiveFramer _receiveFramer = ReceiveFramer();
  PacketSuffix _sendPacketSuffix = PacketSuffix.none;
  DateTime? _lastSendFormatToggleAt;
  int _sendFormatToggleCount = 0;
  bool _formatsLinked = false;
  final List<_QueuedCommand> _queue = [
    _QueuedCommand(
      name: '心跳',
      hex: 'AA 55 A0 00 00 00 00 00 00 00 00 00',
    ),
    _QueuedCommand(
      name: '查询状态',
      hex: 'AA 55 01 01 04 00 41 42 20 1A',
    ),
  ];
  bool _connected = false;
  bool _connecting = false;
  bool _portConfigurationExpanded = true;
  bool _sendPanelExpanded = true;
  bool _periodicSending = false;
  bool _queueSending = false;
  int _queueRunToken = 0;
  Timer? _notificationTimer;
  Timer? _queueDeleteTimer;
  _QueuedCommand? _armedQueueDelete;
  String? _notificationMessage;
  bool _notificationHovered = false;
  String? _selectedLogText;
  bool _showLineNumbers = false;
  LogFileFormat? _realtimeLogFormat;
  String? _realtimeLogPath;
  Future<void> _realtimeWriteChain = Future.value();
  int _timeZoneOffsetMinutes = defaultTimeZoneOffsetMinutes;
  _SerialPort? _selectedPort;
  String _baudRate = '115200';
  String _dataBits = '8';
  String _stopBits = '1';
  String _parity = '无 None';
  String _flowControl = '无';
  int _leftRailIndex = 0;
  int _rightRailIndex = 0;
  bool _leftRailExpanded = true;
  bool _rightRailExpanded = true;
  bool _queuePanelExpanded = false;
  int _selectedTab = 0;

  @override
  void initState() {
    super.initState();
    _entries = [];
    _connectionPulseController = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 200));
    _sendPanelFadeController = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 200), value: 1);
    _eventSubscription = _bridge.events.listen(_consumeCoreEvent);
    unawaited(_bridge.start());
    unawaited(_loadStartupPreferences());
  }

  @override
  void dispose() {
    if (_periodicSending) _bridge.send('stop_periodic');
    _queueRunToken++;
    _notificationTimer?.cancel();
    _queueDeleteTimer?.cancel();
    _eventSubscription.cancel();
    _connectionPulseController.dispose();
    _sendPanelFadeController.dispose();
    _commandController.dispose();
    _periodicIntervalController.dispose();
    _queueNameController.dispose();
    _streamController.dispose();
    unawaited(_bridge.dispose());
    super.dispose();
  }

  void _consumeCoreEvent(Map<String, dynamic> event) {
    final payload = event['payload'];
    if (payload is! Map) return;
    switch (event['event']) {
      case 'ports':
        final rawPorts = payload['ports'];
        if (rawPorts is! List) return;
        final ports = rawPorts
            .whereType<Map>()
            .map(_SerialPort.fromCore)
            .whereType<_SerialPort>()
            .toList();
        final retained =
            ports.where((port) => port.port == _selectedPort?.port);
        setState(() {
          _ports = ports;
          _selectedPort = retained.isNotEmpty
              ? retained.first
              : (ports.isEmpty ? null : ports.first);
        });
      case 'connection_state':
        final state = payload['state'];
        if (state is! String) return;
        final wasConnected = _connected;
        setState(() {
          _connecting = state == 'connecting';
          _connected = state == 'connected';
        });
        if (!_connected && wasConnected) _stopPeriodicSend();
        if (_connected && !wasConnected) {
          _connectionPulseController.forward(from: 0);
          _showMessage('已连接 ${payload['port'] ?? _selectedPort?.port ?? '串口'}');
        }
      case 'periodic_state':
        final active = payload['active'];
        if (active is bool && active != _periodicSending && mounted) {
          setState(() => _periodicSending = active);
        }
      case 'serial_data':
        final bytes = payload['bytes'];
        if (bytes is! String) return;
        final direction = payload['direction'] == 'tx'
            ? SerialDirection.tx
            : SerialDirection.rx;
        final receivedAt =
            DateTime.tryParse(payload['timestamp']?.toString() ?? '') ??
                DateTime.now();
        final entries = direction == SerialDirection.tx
            ? [
                SerialEntry(
                    direction: direction,
                    timestamp: receivedAt,
                    hex: bytes,
                    label: 'Core')
              ]
            : _receiveFramer
                .addHex(bytes, receivedAt)
                .map((frame) => SerialEntry(
                      direction: direction,
                      timestamp: frame.timestamp,
                      hex: frame.hex,
                      label: 'Core',
                    ))
                .toList();
        if (entries.isEmpty) return;
        final followLatest = !_streamController.hasClients ||
            _streamController.position.maxScrollExtent -
                    _streamController.position.pixels <
                48;
        setState(() {
          _entries.addAll(entries);
          if (_entries.length > 5000) {
            _entries.removeRange(0, _entries.length - 5000);
          }
        });
        for (final entry in entries) {
          _appendRealtimeLog(entry);
        }
        if (followLatest) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (_streamController.hasClients) {
              _streamController.jumpTo(
                _streamController.position.maxScrollExtent,
              );
            }
          });
        }
      case 'error':
        final message = payload['message'];
        if (message is String && message.isNotEmpty) _showMessage(message);
    }
  }

  void _showMessage(String message) {
    _notificationTimer?.cancel();
    if (!mounted) return;
    setState(() {
      _notificationMessage = message;
      _notificationHovered = false;
    });
    _notificationTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => _notificationMessage = null);
    });
  }

  Future<void> _loadStartupPreferences() async {
    final preferences = await SharedPreferences.getInstance();
    final offset = preferences.getInt('displayTimeZoneOffsetMinutes');
    if (!mounted) return;
    setState(() {
      if (offset != null && availableTimeZoneOffsets.contains(offset)) {
        _timeZoneOffsetMinutes = offset;
      }
      _leftRailExpanded =
          preferences.getBool('startupLeftDockExpanded') ?? true;
      _rightRailExpanded =
          preferences.getBool('startupRightDockExpanded') ?? true;
      _queuePanelExpanded =
          preferences.getBool('startupQueueExpanded') ?? false;
    });
  }

  Future<void> _showSettings() async {
    final settings = await showDialog<_StartupSettings>(
      context: context,
      builder: (context) {
        var draftOffset = _timeZoneOffsetMinutes;
        var draftLeftDockExpanded = _leftRailExpanded;
        var draftRightDockExpanded = _rightRailExpanded;
        var draftQueueExpanded = _queuePanelExpanded;
        var draftIsDark = widget.isDark;
        return StatefulBuilder(builder: (context, setDialogState) {
          return AlertDialog(
            title: const Text('设置'),
            content: SizedBox(
              width: 440,
              child: SingleChildScrollView(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.schedule_rounded),
                    title: const Text('日志时间时区'),
                    subtitle: Text(timeZoneLabel(draftOffset)),
                  ),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: FilledButton.tonalIcon(
                      onPressed: () async {
                        final offset =
                            await _chooseTimeZone(context, draftOffset);
                        if (offset != null) {
                          setDialogState(() => draftOffset = offset);
                        }
                      },
                      icon: const Icon(Icons.edit_outlined),
                      label: const Text('修改时区'),
                    ),
                  ),
                  const Divider(height: 28),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text('启动默认值',
                        style: Theme.of(context).textTheme.titleSmall),
                  ),
                  const SizedBox(height: 6),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(draftIsDark
                        ? Icons.dark_mode_outlined
                        : Icons.light_mode_outlined),
                    title: const Text('主题'),
                    subtitle: Text(draftIsDark ? '深色' : '浅色'),
                    trailing: SegmentedButton<bool>(
                      segments: const [
                        ButtonSegment(
                            value: false,
                            icon: Icon(Icons.light_mode_outlined, size: 16),
                            label: Text('浅色')),
                        ButtonSegment(
                            value: true,
                            icon: Icon(Icons.dark_mode_outlined, size: 16),
                            label: Text('深色')),
                      ],
                      selected: {draftIsDark},
                      showSelectedIcon: false,
                      onSelectionChanged: (value) =>
                          setDialogState(() => draftIsDark = value.first),
                    ),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    secondary: const Icon(Icons.vertical_split_rounded),
                    title: const Text('左侧 Dock'),
                    subtitle: Text(draftLeftDockExpanded ? '启动时展开' : '启动时隐藏'),
                    value: draftLeftDockExpanded,
                    onChanged: (value) =>
                        setDialogState(() => draftLeftDockExpanded = value),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    secondary: const Icon(Icons.vertical_split_rounded),
                    title: const Text('右侧 Dock'),
                    subtitle: Text(draftRightDockExpanded ? '启动时展开' : '启动时隐藏'),
                    value: draftRightDockExpanded,
                    onChanged: (value) =>
                        setDialogState(() => draftRightDockExpanded = value),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    secondary: const Icon(Icons.playlist_play_rounded),
                    title: const Text('队列编辑面板'),
                    subtitle: Text(draftQueueExpanded ? '启动时展开' : '启动时隐藏'),
                    value: draftQueueExpanded,
                    onChanged: (value) =>
                        setDialogState(() => draftQueueExpanded = value),
                  ),
                ]),
              ),
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('取消')),
              FilledButton(
                  onPressed: () => Navigator.pop(
                        context,
                        _StartupSettings(
                          timeZoneOffsetMinutes: draftOffset,
                          leftDockExpanded: draftLeftDockExpanded,
                          rightDockExpanded: draftRightDockExpanded,
                          queueExpanded: draftQueueExpanded,
                          isDark: draftIsDark,
                        ),
                      ),
                  child: const Text('保存')),
            ],
          );
        });
      },
    );
    if (settings == null) return;
    setState(() {
      _timeZoneOffsetMinutes = settings.timeZoneOffsetMinutes;
      _leftRailExpanded = settings.leftDockExpanded;
      _rightRailExpanded = settings.rightDockExpanded;
      _queuePanelExpanded = settings.queueExpanded;
    });
    widget.onStartupThemeChanged(settings.isDark);
    final preferences = await SharedPreferences.getInstance();
    await Future.wait([
      preferences.setInt(
          'displayTimeZoneOffsetMinutes', settings.timeZoneOffsetMinutes),
      preferences.setBool('startupLeftDockExpanded', settings.leftDockExpanded),
      preferences.setBool(
          'startupRightDockExpanded', settings.rightDockExpanded),
      preferences.setBool('startupQueueExpanded', settings.queueExpanded),
    ]);
    if (mounted) _showMessage('启动默认值已保存');
  }

  Future<int?> _chooseTimeZone(BuildContext context, int selectedOffset) =>
      showDialog<int>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('选择时区'),
          content: SizedBox(
            width: 360,
            height: 420,
            child: ListView(
              children: availableTimeZoneOffsets
                  .map((offset) => ListTile(
                        dense: true,
                        leading: Icon(offset == selectedOffset
                            ? Icons.check_rounded
                            : Icons.schedule_outlined),
                        title: Text(timeZoneLabel(offset)),
                        onTap: () => Navigator.pop(context, offset),
                      ))
                  .toList(),
            ),
          ),
        ),
      );

  void _toggleConnection() {
    if (_connected) {
      _stopPeriodicSend();
      _bridge.send('close_port');
      return;
    }
    final port = _selectedPort;
    if (port == null) {
      _showMessage('未发现可用串口，请连接设备后刷新。');
      _bridge.send('scan_ports');
      return;
    }
    _bridge.send('open_port', {
      'port': port.port,
      'baudRate': int.parse(_baudRate),
      'dataBits': int.parse(_dataBits),
      'stopBits': int.parse(_stopBits),
      'parity': switch (_parity) {
        '奇 Odd' => 'odd',
        '偶 Even' => 'even',
        _ => 'none',
      },
      'flowControl': switch (_flowControl) {
        'RTS/CTS' => 'rts_cts',
        'XON/XOFF' => 'xon_xoff',
        _ => 'none',
      },
    });
  }

  Future<void> _showReceiveFramingSettings() async {
    var mode = _receiveFramingConfig.mode;
    var errorText = '';
    final lengthController = TextEditingController(
        text: _receiveFramingConfig.fixedLength.toString());
    final headerController =
        TextEditingController(text: _receiveFramingConfig.headerHex);
    final trailerController =
        TextEditingController(text: _receiveFramingConfig.trailerHex);
    final config = await showDialog<ReceiveFramingConfig>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Row(children: [
            Icon(Icons.call_split_rounded),
            SizedBox(width: 10),
            Text('接收分包'),
          ]),
          content: SizedBox(
            width: 460,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              _HcomPopupField<ReceiveFramingMode>(
                width: 460,
                label: '边界识别方式',
                value: mode,
                options: ReceiveFramingMode.values,
                textOf: (value) => value.label,
                onChanged: (value) => setDialogState(() => mode = value),
              ),
              const SizedBox(height: 12),
              Text(
                switch (mode) {
                  ReceiveFramingMode.automatic =>
                    '根据最近稳定出现的包长度自动学习；较大的整倍数批次会按已学习长度拆分。',
                  ReceiveFramingMode.idle => '仅按串口空闲间隔分批，适合长度变化且发送间隔明确的数据。',
                  ReceiveFramingMode.fixedLength =>
                    '持续缓存数据并严格按指定字节数切分，适合固定长度协议。',
                  ReceiveFramingMode.delimiters =>
                    '跨越多次系统读取寻找帧头和帧尾，输出包含帧头、帧尾的完整帧。',
                },
                style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    fontSize: 12),
              ),
              if (mode == ReceiveFramingMode.fixedLength) ...[
                const SizedBox(height: 16),
                TextField(
                  controller: lengthController,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: const InputDecoration(
                    labelText: '每包字节数',
                    suffixText: 'B',
                    isDense: true,
                  ),
                ),
              ],
              if (mode == ReceiveFramingMode.delimiters) ...[
                const SizedBox(height: 16),
                TextField(
                  controller: headerController,
                  decoration: const InputDecoration(
                    labelText: '帧头 HEX',
                    hintText: '例如 AA 55',
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: trailerController,
                  decoration: const InputDecoration(
                    labelText: '帧尾 HEX',
                    hintText: '例如 55 AA',
                    isDense: true,
                  ),
                ),
              ],
              if (errorText.isNotEmpty) ...[
                const SizedBox(height: 10),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(errorText,
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                          fontSize: 12)),
                ),
              ],
            ]),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('取消')),
            FilledButton(
              onPressed: () {
                final fixedLength = int.tryParse(lengthController.text) ?? 0;
                if (mode == ReceiveFramingMode.fixedLength &&
                    (fixedLength < 1 || fixedLength > 65536)) {
                  setDialogState(() => errorText = '固定长度必须在 1–65536 字节之间。');
                  return;
                }
                if (mode == ReceiveFramingMode.delimiters &&
                    (parseHexBytes(headerController.text).isEmpty ||
                        parseHexBytes(trailerController.text).isEmpty)) {
                  setDialogState(() => errorText = '帧头和帧尾必须是完整的 HEX 字节。');
                  return;
                }
                Navigator.pop(
                  dialogContext,
                  ReceiveFramingConfig(
                    mode: mode,
                    fixedLength: fixedLength == 0 ? 4 : fixedLength,
                    headerHex: headerController.text.trim().toUpperCase(),
                    trailerHex: trailerController.text.trim().toUpperCase(),
                  ),
                );
              },
              child: const Text('应用'),
            ),
          ],
        ),
      ),
    );
    lengthController.dispose();
    headerController.dispose();
    trailerController.dispose();
    if (config == null || !mounted) return;

    final unfinished = _receiveFramer.flush().map((frame) => SerialEntry(
          direction: SerialDirection.rx,
          timestamp: frame.timestamp,
          hex: frame.hex,
          label: 'Core',
        ));
    setState(() {
      _entries.addAll(unfinished);
      _receiveFramingConfig = config;
      _receiveFramer.configure(config);
    });
    _showMessage('接收分包已切换为 ${config.mode.label}');
  }

  void _toggleSendPanel() {
    if (_sendPanelExpanded && _periodicSending) _stopPeriodicSend();
    setState(() => _sendPanelExpanded = !_sendPanelExpanded);
    _sendPanelExpanded
        ? _sendPanelFadeController.forward()
        : _sendPanelFadeController.reverse();
  }

  void _togglePortConfiguration() {
    if (_portConfigurationExpanded) {
      _connectionPulseController.forward(from: 0);
    }
    setState(() => _portConfigurationExpanded = !_portConfigurationExpanded);
  }

  void _selectSendMode(Set<SendMode> selection) {
    final mode = selection.isEmpty ? null : selection.first;
    if (mode != null &&
        MediaQuery.sizeOf(context).width < _minimumAppWidthForQueueEditor) {
      _showMessage('当前界面小于 600px，无法展开队列编辑。');
      return;
    }
    if (_periodicSending && mode != SendMode.periodic) _stopPeriodicSend();
    if (_queueSending && mode != SendMode.loop && mode != SendMode.sequence) {
      _stopQueueSend();
    }
    setState(() {
      _sendMode = mode;
      _queuePanelExpanded = mode != null && mode != SendMode.periodic;
    });
  }

  void _queueCommand() {
    final bytes = _commandBaseBytes;
    if (bytes == null) {
      _showMessage(_sendInputFormat == SendInputFormat.hex
          ? '请输入 HEX 命令后再加入队列。'
          : '请输入普通文本后再加入队列。');
      return;
    }
    setState(() => _queue.add(_QueuedCommand(
          name: '命令 ${_queue.length + 1}',
          hex: bytes,
          packetSuffix: _sendPacketSuffix,
        )));
    _showMessage(
        '已加入 ${_queueNameController.text.trim().isEmpty ? '默认队列' : _queueNameController.text.trim()}');
    _commandController.clear();
  }

  List<_QueuedCommand> get _enabledQueue =>
      _queue.where((command) => command.enabled).toList(growable: false);

  void _toggleQueueItem(int index, bool? enabled) =>
      setState(() => _queue[index].enabled = enabled ?? false);

  void _moveQueueItem(int index, int direction) {
    final target = index + direction;
    if (target < 0 || target >= _queue.length) return;
    setState(() {
      final item = _queue.removeAt(index);
      _queue.insert(target, item);
    });
  }

  void _requestQueueDelete(_QueuedCommand command) {
    if (identical(_armedQueueDelete, command)) {
      _queueDeleteTimer?.cancel();
      setState(() => _armedQueueDelete = null);
      _deleteQueueItem(command);
      return;
    }
    _queueDeleteTimer?.cancel();
    setState(() => _armedQueueDelete = command);
    _queueDeleteTimer = Timer(_queueDeleteDoubleClickWindow, () {
      if (!mounted || !identical(_armedQueueDelete, command)) return;
      setState(() => _armedQueueDelete = null);
      unawaited(_confirmQueueDelete(command));
    });
  }

  Future<void> _confirmQueueDelete(_QueuedCommand command) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除队列命令？'),
        content: Text(
            '确认从“${_queueNameController.text.trim().isEmpty ? '默认队列' : _queueNameController.text.trim()}”中删除“${command.name}”？'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error,
                foregroundColor: Theme.of(context).colorScheme.onError),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) _deleteQueueItem(command);
  }

  void _deleteQueueItem(_QueuedCommand command) {
    final index = _queue.indexOf(command);
    if (index < 0) return;
    setState(() => _queue.removeAt(index));
    _showMessage('已删除命令“${command.name}”');
  }

  Future<void> _startQueueSend({required bool repeat}) async {
    if (!_connected) {
      _showMessage('请先打开串口。');
      return;
    }
    final commands = _enabledQueue;
    if (commands.isEmpty) {
      _showMessage('请在右侧队列中至少勾选一条命令。');
      return;
    }
    final runToken = ++_queueRunToken;
    setState(() => _queueSending = true);
    do {
      for (var index = 0; index < commands.length; index++) {
        if (!_connected || runToken != _queueRunToken) break;
        final command = commands[index];
        _sendBytes(command.wireHex);
        final isLast = index == commands.length - 1;
        final delay = isLast && !repeat ? 0 : command.delayMilliseconds;
        if (delay > 0) {
          await Future<void>.delayed(Duration(milliseconds: delay));
        }
      }
    } while (repeat && _connected && runToken == _queueRunToken);

    if (mounted && runToken == _queueRunToken) {
      setState(() => _queueSending = false);
      _showMessage(repeat ? '循环发送已停止' : '顺序发送完成');
    }
  }

  void _stopQueueSend() {
    if (!_queueSending) return;
    _queueRunToken++;
    if (mounted) setState(() => _queueSending = false);
    _showMessage('队列发送已停止');
  }

  void _sendToPort() {
    if (!_connected) {
      _showMessage('请先打开串口。');
      return;
    }
    final bytes = _commandBytes;
    if (bytes == null) {
      _showMessage(_sendInputFormat == SendInputFormat.hex
          ? '请输入 HEX 命令后再发送。'
          : '请输入普通文本后再发送。');
      return;
    }
    _sendBytes(bytes);
  }

  String? get _commandBaseBytes {
    final input = _commandController.text;
    if (input.trim().isEmpty) return null;
    if (_sendInputFormat == SendInputFormat.hex) {
      return input.trim().toUpperCase();
    }
    return utf8
        .encode(input)
        .map((byte) => byte.toRadixString(16).padLeft(2, '0').toUpperCase())
        .join(' ');
  }

  String? get _commandBytes {
    final bytes = _commandBaseBytes;
    return bytes == null ? null : _appendPacketSuffix(bytes, _sendPacketSuffix);
  }

  void _selectSendInputFormat(Set<SendInputFormat> formats) {
    if (formats.isEmpty) return;
    final format = formats.first;
    if (format == _sendInputFormat) return;
    final now = DateTime.now();
    final consecutive = _lastSendFormatToggleAt != null &&
        now.difference(_lastSendFormatToggleAt!) <= _sendFormatSyncWindow;
    _lastSendFormatToggleAt = now;
    _sendFormatToggleCount = consecutive ? _sendFormatToggleCount + 1 : 1;
    var linkJustEnabled = false;
    setState(() {
      _sendInputFormat = format;
      if (!_formatsLinked && _sendFormatToggleCount >= 3) {
        _formatsLinked = true;
        _receiveInputFormat = format;
        _sendFormatToggleCount = 0;
        linkJustEnabled = true;
      } else if (_formatsLinked) {
        _receiveInputFormat = format;
      }
    });
    if (linkJustEnabled) {
      _showMessage('发送与接收格式已开启联动；以后切换发送格式会立即同步接收格式');
    }
  }

  void _toggleReceiveInputFormat() {
    setState(() {
      _receiveInputFormat = _receiveInputFormat == SendInputFormat.hex
          ? SendInputFormat.plainText
          : SendInputFormat.hex;
      _formatsLinked = false;
      _sendFormatToggleCount = 0;
    });
    _showMessage('已解除发送与接收格式联动');
  }

  void _sendBytes(String bytes) => _bridge.send('write_data', {'bytes': bytes});

  void _togglePeriodicSend() {
    if (_periodicSending) {
      _stopPeriodicSend();
      return;
    }
    if (!_connected) {
      _showMessage('请先打开串口。');
      return;
    }
    final intervalMilliseconds = int.tryParse(_periodicIntervalController.text);
    if (intervalMilliseconds == null ||
        intervalMilliseconds < 10 ||
        intervalMilliseconds > 3600000) {
      _showMessage('周期请输入 10–3600000 ms。');
      return;
    }
    final bytes = _commandBytes;
    if (bytes == null) {
      _showMessage(_sendInputFormat == SendInputFormat.hex
          ? '请输入 HEX 命令后再开始周期。'
          : '请输入普通文本后再开始周期。');
      return;
    }
    _bridge.send('start_periodic', {
      'intervalMs': intervalMilliseconds,
      'commands': [bytes],
    });
    setState(() => _periodicSending = true);
    _showMessage('已开始周期发送：每 $intervalMilliseconds ms 发送当前消息');
  }

  void _stopPeriodicSend() {
    if (!_periodicSending) return;
    _bridge.send('stop_periodic');
    if (mounted) setState(() => _periodicSending = false);
    _showMessage('周期发送已停止');
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final content = Stack(children: [
      Scaffold(
        body: Column(children: [
          _windowTitleBar(scheme),
          SizedBox(
            height: 64,
            child: AppBar(
              primary: false,
              toolbarHeight: 64,
              titleSpacing: 16,
              title: Row(children: [
                SizedBox(
                  width: 36,
                  height: 36,
                  child: Image.asset('Image/LOGO.png', fit: BoxFit.contain),
                ),
                const SizedBox(width: 12),
                const Text('HCOM 调试助手'),
              ]),
              actions: [
                _appAction(Icons.folder_open_rounded, '打开日志'),
                _appAction(Icons.upload_file_rounded, '导入帧配置'),
                _appAction(Icons.download_rounded, '导出帧配置'),
                const Spacer(),
                _connectionChip(scheme),
                const SizedBox(width: 4),
                IconButton(
                  tooltip: '切换${widget.isDark ? '浅色' : '深色'}主题',
                  onPressed: widget.onThemeChanged,
                  icon: Icon(widget.isDark
                      ? Icons.light_mode_outlined
                      : Icons.dark_mode_outlined),
                ),
                _appAction(Icons.settings_outlined, '设置', _showSettings),
                const SizedBox(width: 4),
              ],
            ),
          ),
          Expanded(
            child: Column(children: [
              Expanded(
                child: Row(children: [
                  _protocolRail(scheme),
                  Expanded(child: _workspace(scheme)),
                  _extensionRail(scheme),
                ]),
              ),
              _statusBar(scheme),
            ]),
          ),
        ]),
      ),
      if (_notificationMessage case final message?)
        _transientNotification(message, scheme),
    ]);
    return _usesNativeWindowFrame
        ? WindowBorder(
            color: scheme.outlineVariant.withValues(alpha: .7),
            width: 1,
            child: content,
          )
        : content;
  }

  bool get _usesNativeWindowFrame =>
      Platform.isWindows && !Platform.environment.containsKey('FLUTTER_TEST');

  Widget _windowTitleBar(ColorScheme scheme) {
    final buttonColors = WindowButtonColors(
      iconNormal: scheme.onSurfaceVariant,
      mouseOver: scheme.surfaceContainerHighest,
      mouseDown: scheme.surfaceContainerHigh,
      iconMouseOver: scheme.onSurface,
      iconMouseDown: scheme.onSurface,
    );
    final closeButtonColors = WindowButtonColors(
      iconNormal: scheme.onSurfaceVariant,
      mouseOver: scheme.error,
      mouseDown: scheme.errorContainer,
      iconMouseOver: scheme.onError,
      iconMouseDown: scheme.onErrorContainer,
    );
    final title = Container(
      height: 36,
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        border: Border(bottom: BorderSide(color: scheme.outlineVariant)),
      ),
      child: Row(children: [
        Expanded(
          child: _usesNativeWindowFrame
              ? MoveWindow(
                  child: _windowTitleContent(scheme),
                )
              : _windowTitleContent(scheme),
        ),
        if (_usesNativeWindowFrame)
          Tooltip(
            message: '最小化窗口',
            child: MinimizeWindowButton(colors: buttonColors),
          ),
        if (_usesNativeWindowFrame)
          Tooltip(
            message: '最大化或还原窗口',
            child: MaximizeWindowButton(colors: buttonColors),
          ),
        if (_usesNativeWindowFrame)
          Tooltip(
            message: '关闭窗口',
            child: CloseWindowButton(colors: closeButtonColors),
          ),
      ]),
    );
    return _usesNativeWindowFrame ? WindowTitleBarBox(child: title) : title;
  }

  Widget _windowTitleContent(ColorScheme scheme) => Padding(
        padding: const EdgeInsets.only(left: 14, right: 8),
        child: Row(children: [
          Image.asset('Image/LOGO.png', width: 18, height: 18),
          const SizedBox(width: 8),
          Text('HCOM',
              style: TextStyle(
                  color: scheme.onSurface,
                  fontFamily: HcomTheme.latinFontFamily,
                  fontWeight: FontWeight.w600,
                  letterSpacing: .5,
                  fontSize: 13)),
          const SizedBox(width: 10),
          Text('UART WORKBENCH',
              style: TextStyle(
                  color: scheme.onSurfaceVariant,
                  fontFamily: HcomTheme.latinFontFamily,
                  letterSpacing: .8,
                  fontSize: 10)),
        ]),
      );

  Widget _transientNotification(String message, ColorScheme scheme) =>
      Positioned(
        left: 0,
        right: 0,
        bottom: 42,
        child: Center(
          child: MouseRegion(
            opaque: false,
            onEnter: (_) => setState(() => _notificationHovered = true),
            child: IgnorePointer(
              ignoring: _notificationHovered,
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 140),
                opacity: _notificationHovered ? .16 : 1,
                child: Material(
                  color: scheme.surfaceContainerHighest,
                  elevation: 6,
                  borderRadius: BorderRadius.circular(8),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 10),
                    child: Text(message,
                        style: TextStyle(color: scheme.onSurface)),
                  ),
                ),
              ),
            ),
          ),
        ),
      );

  /// Leaves a deliberate M3 gap between independent toolbar actions so their
  /// circular containers do not visually merge into one control.
  Widget _appAction(IconData icon, String tooltip, [VoidCallback? action]) =>
      Padding(
        padding: const EdgeInsets.only(right: 8),
        child: IconButton.filledTonal(
          tooltip: tooltip,
          onPressed: action ?? () => _showMessage('$tooltip将在后续阶段接入'),
          icon: Icon(icon, size: 20),
        ),
      );

  Widget _connectionChip(ColorScheme scheme) {
    final accent = widget.isDark ? HcomTheme.txDark : HcomTheme.txLight;
    return ScaleTransition(
      scale: TweenSequence<double>([
        TweenSequenceItem(tween: Tween(begin: 1, end: 1.055), weight: 55),
        TweenSequenceItem(tween: Tween(begin: 1.055, end: 1), weight: 45),
      ]).animate(CurvedAnimation(
          parent: _connectionPulseController,
          curve: Easing.emphasizedDecelerate)),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Easing.standard,
        height: 32,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color:
              _connected ? accent.withValues(alpha: .15) : Colors.transparent,
          border: Border.all(
              color: _connected
                  ? accent.withValues(alpha: .55)
                  : scheme.outlineVariant),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 180),
            switchInCurve: Easing.standard,
            child: Icon(
                _connected ? Icons.link_rounded : Icons.link_off_rounded,
                key: ValueKey(_connected),
                size: 16,
                color: _connected ? accent : scheme.onSurfaceVariant),
          ),
          const SizedBox(width: 8),
          Text(
              _connected
                  ? '${_selectedPort?.port ?? 'COM'} · $_baudRate · $_dataBits-$_parityCode-$_stopBits'
                  : (_connecting ? '连接中…' : '未连接'),
              style: const TextStyle(
                  fontFamily: HcomTheme.latinFontFamily, fontSize: 12)),
          if (!_portConfigurationExpanded) ...[
            const SizedBox(width: 4),
            Tooltip(
              message: '展开串口配置',
              child: InkWell(
                borderRadius: BorderRadius.circular(99),
                onTap: _togglePortConfiguration,
                child: Padding(
                  padding: const EdgeInsets.all(2),
                  child: Icon(Icons.keyboard_arrow_down_rounded,
                      size: 18,
                      color: _connected ? accent : scheme.onSurfaceVariant),
                ),
              ),
            ),
          ],
        ]),
      ),
    );
  }

  Widget _protocolRail(ColorScheme scheme) => _AnimatedRail(
        destinations: const [
          _RailDestination(Icons.usb_rounded, 'UART'),
          _RailDestination(Icons.route_rounded, 'CAN'),
          _RailDestination(Icons.bolt_rounded, 'CAN-FD'),
          _RailDestination(Icons.hub_rounded, 'I2C'),
          _RailDestination(Icons.lan_rounded, 'TCP'),
          _RailDestination(Icons.memory_rounded, '虚拟串口'),
          _RailDestination(Icons.settings_outlined, '设置'),
        ],
        selectedIndex: _leftRailIndex,
        onSelected: (value) {
          if (value == 6) {
            unawaited(_showSettings());
            return;
          }
          if (value != 0) _showMessage('仅 UART/COM 在 v1 范围内');
          setState(() => _leftRailIndex = value);
        },
        scheme: scheme,
        side: _RailSide.left,
        expanded: _leftRailExpanded,
        onToggle: () => setState(() => _leftRailExpanded = !_leftRailExpanded),
      );

  Widget _extensionRail(ColorScheme scheme) => _AnimatedRail(
        destinations: const [
          _RailDestination(Icons.calculate_rounded, 'CRC'),
          _RailDestination(Icons.visibility_rounded, '帧监听'),
          _RailDestination(Icons.show_chart_rounded, '时序'),
          _RailDestination(Icons.science_outlined, '信号'),
          _RailDestination(Icons.link_rounded, '抓包'),
          _RailDestination(Icons.extension_rounded, '插件'),
        ],
        selectedIndex: _rightRailIndex,
        onSelected: (value) => setState(() => _rightRailIndex = value),
        scheme: scheme,
        side: _RailSide.right,
        expanded: _rightRailExpanded,
        onToggle: () =>
            setState(() => _rightRailExpanded = !_rightRailExpanded),
      );

  Widget _workspace(ColorScheme scheme) => LayoutBuilder(
        builder: (context, constraints) {
          final appWidth = MediaQuery.sizeOf(context).width;
          final availableWorkspaceWidth = constraints.maxWidth - 32;
          final queueWidth = availableWorkspaceWidth >= 1000
              ? 500.0
              : availableWorkspaceWidth / 2;
          final shouldCloseQueueForWindow =
              _queuePanelExpanded && appWidth < _minimumAppWidthForQueueEditor;
          if (shouldCloseQueueForWindow) {
            // Defer the state change until after layout so a window resize is
            // safe. Above 600 px the two panels share the workspace equally.
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted && _queuePanelExpanded) {
                setState(() => _queuePanelExpanded = false);
              }
            });
          }
          final showQueuePanel =
              _queuePanelExpanded && !shouldCloseQueueForWindow;
          final content = Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _portConfiguration(scheme),
              AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                curve: Easing.standard,
                height: _portConfigurationExpanded ? 14 : 0,
              ),
              _AnimatedTabStrip(
                selectedIndex: _selectedTab,
                frameCount: _entries.length,
                scheme: scheme,
                streamLabel: _receiveInputFormat == SendInputFormat.hex
                    ? 'HEX 原始'
                    : '文本 原始',
                formatsLinked: _formatsLinked,
                onSelected: (value) => setState(() => _selectedTab = value),
                onStreamFormatToggle: _toggleReceiveInputFormat,
              ),
              const SizedBox(height: 8),
              Expanded(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 200),
                  switchInCurve: Easing.standard,
                  switchOutCurve: Easing.standard,
                  child: KeyedSubtree(
                    key: ValueKey(_selectedTab),
                    child: [
                      _hexStream(scheme),
                      _emptyPanel(
                          Icons.data_object_rounded, '字段解析将在 Phase 3 接入'),
                      _emptyPanel(Icons.timeline_rounded, '时间轴将在 Phase 6 接入'),
                      _statistics(scheme),
                    ][_selectedTab],
                  ),
                ),
              ),
              const SizedBox(height: 14),
              _sendPanel(scheme),
            ],
          );

          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: Row(children: [
              Expanded(child: content),
              AnimatedContainer(
                duration: const Duration(milliseconds: 220),
                curve: Easing.emphasizedDecelerate,
                width: showQueuePanel ? 14 : 0,
              ),
              AnimatedSize(
                duration: const Duration(milliseconds: 220),
                curve: Easing.emphasizedDecelerate,
                alignment: Alignment.centerRight,
                child: showQueuePanel
                    ? SizedBox(
                        width: queueWidth,
                        child: _queueEditorPanel(scheme),
                      )
                    : const SizedBox.shrink(),
              ),
            ]),
          );
        },
      );

  Widget _portConfiguration(ColorScheme scheme) => LayoutBuilder(
        builder: (context, constraints) {
          final portWidth = constraints.maxWidth >= 1100
              ? 300.0
              : constraints.maxWidth >= 760
                  ? 250.0
                  : 220.0;
          // With both docks expanded, a half-screen workspace can become too
          // narrow for a useful configuration form.  Keep the receive stream
          // usable by temporarily showing the compact state; the user's
          // explicit expand/collapse preference is left untouched.
          final compactWorkspace = constraints.maxWidth < 420;
          final showIdentity = MediaQuery.sizeOf(context).height >= 700;
          return AnimatedSize(
            duration: const Duration(milliseconds: 220),
            curve: Easing.emphasizedDecelerate,
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 180),
              switchInCurve: Easing.standard,
              switchOutCurve: Easing.standard,
              transitionBuilder: (child, animation) => FadeTransition(
                opacity: animation,
                child: SizeTransition(
                    sizeFactor: animation,
                    alignment: Alignment.topCenter,
                    child: child),
              ),
              child: _portConfigurationExpanded && !compactWorkspace
                  ? Card(
                      key: const ValueKey('port-configuration'),
                      child: Padding(
                        padding: const EdgeInsets.all(14),
                        child: Wrap(
                          crossAxisAlignment: WrapCrossAlignment.center,
                          spacing: 12,
                          runSpacing: 12,
                          children: [
                            _portField(portWidth),
                            if (showIdentity && _selectedPort != null)
                              _deviceIdentity(portWidth, scheme),
                            _selectField(
                                '波特率',
                                _baudRate,
                                const [
                                  '9600',
                                  '38400',
                                  '57600',
                                  '115200',
                                  '921600'
                                ],
                                (value) => setState(() => _baudRate = value)),
                            _selectField(
                                '数据位',
                                _dataBits,
                                const ['5', '6', '7', '8'],
                                (value) => setState(() => _dataBits = value)),
                            _selectField('停止位', _stopBits, const ['1', '2'],
                                (value) => setState(() => _stopBits = value)),
                            _selectField(
                                '校验',
                                _parity,
                                const ['无 None', '奇 Odd', '偶 Even'],
                                (value) => setState(() => _parity = value)),
                            _selectField(
                                '流控',
                                _flowControl,
                                const ['无', 'RTS/CTS', 'XON/XOFF'],
                                (value) =>
                                    setState(() => _flowControl = value)),
                            Tooltip(
                              message: _connected ? '关闭当前串口' : '按当前配置打开串口',
                              child: FilledButton.icon(
                                style: _connected
                                    ? FilledButton.styleFrom(
                                        backgroundColor: scheme.error,
                                        foregroundColor: scheme.onError)
                                    : null,
                                onPressed:
                                    _connecting ? null : _toggleConnection,
                                icon: Icon(_connected
                                    ? Icons.link_off_rounded
                                    : Icons.link_rounded),
                                label: Text(_connected
                                    ? '关闭端口'
                                    : (_connecting ? '连接中…' : '打开端口')),
                              ),
                            ),
                            IconButton(
                              tooltip: '收起串口配置',
                              onPressed: _togglePortConfiguration,
                              icon: const Icon(Icons.keyboard_arrow_up_rounded),
                            ),
                          ],
                        ),
                      ),
                    )
                  : const SizedBox(key: ValueKey('port-configuration-hidden')),
            ),
          );
        },
      );

  Widget _portField(double width) {
    final selected = _selectedPort;
    if (selected == null) {
      return SizedBox(
        width: width,
        child: InkWell(
          borderRadius: BorderRadius.circular(4),
          onTap: _connecting ? null : () => _bridge.send('scan_ports'),
          child: const InputDecorator(
            isEmpty: false,
            decoration: InputDecoration(labelText: '串口', isDense: true),
            child: Row(children: [
              Expanded(child: Text('未发现串口，点击刷新')),
              Icon(Icons.refresh_rounded),
            ]),
          ),
        ),
      );
    }
    return SizedBox(
      width: width,
      child: _HcomPopupField<_SerialPort>(
        width: width,
        label: '串口',
        value: selected,
        options: _ports,
        textOf: (port) => '${port.port} · ${port.description}',
        iconOf: (port) => port.icon,
        onChanged: _connected || _connecting
            ? null
            : (port) => setState(() => _selectedPort = port),
      ),
    );
  }

  Widget _deviceIdentity(double width, ColorScheme scheme) => SizedBox(
        width: width,
        child: Tooltip(
          message: '硬件 ID: ${_selectedPort!.hardwareId}',
          child: Container(
            height: 52,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
                border: Border.all(color: scheme.outlineVariant),
                borderRadius: BorderRadius.circular(8)),
            child: Row(children: [
              Icon(_selectedPort!.icon, color: scheme.primary),
              const SizedBox(width: 10),
              Expanded(
                  child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    Text(_selectedPort!.description,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w500)),
                    Text(_selectedPort!.hardwareId,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: scheme.onSurfaceVariant,
                            fontFamily: HcomTheme.latinFontFamily,
                            fontSize: 11)),
                  ])),
            ]),
          ),
        ),
      );

  String get _parityCode => switch (_parity) {
        '奇 Odd' => 'O',
        '偶 Even' => 'E',
        _ => 'N',
      };

  Widget _selectField(String label, String selected, List<String> options,
          ValueChanged<String> onChanged) =>
      SizedBox(
        width: 132,
        child: _HcomPopupField<String>(
          width: 132,
          label: label,
          value: selected,
          options: options,
          textOf: (option) => option,
          useMono: true,
          onChanged: _connected || _connecting ? null : onChanged,
        ),
      );

  void _clearLog() {
    if (_entries.isEmpty) return;
    setState(_entries.clear);
    _showMessage('已清除当前日志');
  }

  Future<void> _saveLogManually(LogFileFormat format) async {
    if (_entries.isEmpty) {
      _showMessage('当前没有可保存的日志。');
      return;
    }
    final location = await _chooseLogSaveLocation(format, 'HCOM_日志');
    if (location == null) return;
    try {
      await File(location.path).writeAsString(
        serializeLogEntries(_entries, format, _timeZoneOffsetMinutes),
        flush: true,
      );
      if (mounted) _showMessage('日志已保存为 ${format.label}');
    } on FileSystemException catch (error) {
      if (mounted) _showMessage('保存失败：${error.message}');
    }
  }

  Future<void> _startRealtimeLog(LogFileFormat format) async {
    final location = await _chooseLogSaveLocation(format, 'HCOM_实时日志');
    if (location == null) return;
    try {
      await File(location.path).writeAsString(
        serializeLogEntries(_entries, format, _timeZoneOffsetMinutes),
        flush: true,
      );
      if (!mounted) return;
      setState(() {
        _realtimeLogFormat = format;
        _realtimeLogPath = location.path;
      });
      _showMessage('已开始实时保存 ${format.label}');
    } on FileSystemException catch (error) {
      if (mounted) _showMessage('无法开始实时保存：${error.message}');
    }
  }

  void _stopRealtimeLog() {
    if (_realtimeLogPath == null) return;
    setState(() {
      _realtimeLogFormat = null;
      _realtimeLogPath = null;
    });
    _showMessage('实时保存已停止');
  }

  void _appendRealtimeLog(SerialEntry entry) {
    final path = _realtimeLogPath;
    final format = _realtimeLogFormat;
    if (path == null || format == null) return;
    _realtimeWriteChain = _realtimeWriteChain.then((_) async {
      await File(path).writeAsString(
        serializeLogEntries(
          [entry],
          format,
          _timeZoneOffsetMinutes,
          includeCsvHeader: false,
        ),
        mode: FileMode.append,
        flush: true,
      );
    }).catchError((Object error) {
      if (!mounted) return;
      setState(() {
        _realtimeLogFormat = null;
        _realtimeLogPath = null;
      });
      _showMessage('实时保存已停止：写入文件失败');
    });
  }

  Future<FileSaveLocation?> _chooseLogSaveLocation(
    LogFileFormat format,
    String prefix,
  ) {
    final now = DateTime.now();
    final stamp = '${now.year}'
        '${now.month.toString().padLeft(2, '0')}'
        '${now.day.toString().padLeft(2, '0')}_'
        '${now.hour.toString().padLeft(2, '0')}'
        '${now.minute.toString().padLeft(2, '0')}'
        '${now.second.toString().padLeft(2, '0')}';
    return getSaveLocation(
      suggestedName: '${prefix}_$stamp.${format.extension}',
      acceptedTypeGroups: [
        XTypeGroup(
          label: '${format.label} 日志',
          extensions: [format.extension],
        ),
      ],
    );
  }

  Future<void> _copySelectedLog() async {
    final selectedText = _selectedLogText;
    if (selectedText == null || selectedText.isEmpty) return;
    final text = formatSelectedLogCopy(
      _entries,
      selectedText,
      _timeZoneOffsetMinutes,
    );
    await Clipboard.setData(ClipboardData(text: text));
  }

  Widget _logContextMenu(
    BuildContext context,
    SelectableRegionState selectableRegionState,
  ) {
    final items = selectableRegionState.contextMenuButtonItems
        .map(
          (item) => item.type == ContextMenuButtonType.copy
              ? ContextMenuButtonItem(
                  type: ContextMenuButtonType.copy,
                  onPressed: () {
                    unawaited(_copySelectedLog());
                    selectableRegionState.hideToolbar();
                  },
                )
              : item,
        )
        .toList();
    return AdaptiveTextSelectionToolbar.buttonItems(
      anchors: selectableRegionState.contextMenuAnchors,
      buttonItems: items,
    );
  }

  Widget _hexStream(ColorScheme scheme) => LayoutBuilder(
        builder: (context, constraints) {
          // At very short heights keep all receive actions reachable while
          // giving the stream its last few pixels instead of overflowing.
          final compactToolbar = constraints.maxHeight < 120;
          return Container(
            key: const ValueKey('receive-stream'),
            decoration: BoxDecoration(
                color: scheme.surfaceContainerLowest,
                borderRadius: BorderRadius.circular(16)),
            child: Column(children: [
              Padding(
                padding: compactToolbar
                    ? const EdgeInsets.fromLTRB(12, 0, 8, 0)
                    : const EdgeInsets.fromLTRB(12, 6, 8, 2),
                child: _receiveToolbar(scheme),
              ),
              Expanded(
                child: Actions(
                  actions: {
                    CopySelectionTextIntent:
                        CallbackAction<CopySelectionTextIntent>(
                      onInvoke: (_) {
                        unawaited(_copySelectedLog());
                        return null;
                      },
                    ),
                  },
                  child: SelectionArea(
                    onSelectionChanged: (content) =>
                        _selectedLogText = content?.plainText,
                    contextMenuBuilder: _logContextMenu,
                    child: _entries.isEmpty
                        ? Center(
                            child: Text('打开串口后，实时 RX/TX 数据将在此显示',
                                style:
                                    TextStyle(color: scheme.onSurfaceVariant)))
                        : ListView.builder(
                            controller: _streamController,
                            padding: const EdgeInsets.all(8),
                            itemCount: _entries.length,
                            itemBuilder: (_, index) =>
                                _entryRow(_entries[index], scheme, index),
                          ),
                  ),
                ),
              ),
            ]),
          );
        },
      );

  Widget _receiveToolbar(ColorScheme scheme) {
    final title = Row(mainAxisSize: MainAxisSize.min, children: [
      Text(
        _receiveInputFormat == SendInputFormat.hex ? 'HEX 实时数据' : '文本 实时数据',
        style: TextStyle(
          color: scheme.onSurfaceVariant,
          fontSize: 12,
          fontWeight: FontWeight.w500,
        ),
      ),
      const SizedBox(width: 8),
      Text(
        '可拖选复制',
        style: TextStyle(
          color: scheme.onSurfaceVariant.withValues(alpha: .72),
          fontSize: 11,
        ),
      ),
    ]);
    final actions = <Widget>[
      Tooltip(
        message: _showLineNumbers ? '隐藏接收区行号' : '显示接收区行号',
        child: FilledButton.tonalIcon(
          style: _receiveToolbarButtonStyle(),
          onPressed: () => setState(() => _showLineNumbers = !_showLineNumbers),
          icon: Icon(
            _showLineNumbers
                ? Icons.format_list_numbered_rtl_rounded
                : Icons.format_list_numbered_rounded,
            size: 18,
          ),
          label: Text(_showLineNumbers ? '隐藏行号' : '显示行号'),
        ),
      ),
      const SizedBox(width: 8),
      Tooltip(
        message: '设置接收数据的自动、定长或帧头帧尾边界识别',
        child: FilledButton.tonalIcon(
          style: _receiveToolbarButtonStyle(),
          onPressed: _showReceiveFramingSettings,
          icon: const Icon(Icons.call_split_rounded, size: 18),
          label: Text('分包 · ${_receiveFramingConfig.mode.label}'),
        ),
      ),
      const SizedBox(width: 8),
      MenuAnchor(
        style: _hcomMenuSurfaceStyle(scheme),
        menuChildren: [
          for (final format in LogFileFormat.values)
            MenuItemButton(
              style: _hcomMenuItemStyle(scheme),
              clipBehavior: Clip.antiAlias,
              onPressed: () => unawaited(_saveLogManually(format)),
              leadingIcon: const Icon(Icons.save_as_rounded),
              child: Text('手动保存 ${format.label}'),
            ),
        ],
        builder: (context, controller, child) => Tooltip(
          message: '将当前全部日志另存为 CSV 或 TXT',
          child: FilledButton.tonalIcon(
            style: _receiveToolbarButtonStyle(),
            onPressed: _entries.isEmpty
                ? null
                : () =>
                    controller.isOpen ? controller.close() : controller.open(),
            icon: const Icon(Icons.save_as_rounded, size: 18),
            label: const Text('手动保存'),
          ),
        ),
      ),
      const SizedBox(width: 8),
      MenuAnchor(
        style: _hcomMenuSurfaceStyle(scheme),
        menuChildren: [
          MenuItemButton(
            style: _hcomMenuItemStyle(
              scheme,
              selected: _realtimeLogPath != null &&
                  _realtimeLogFormat == LogFileFormat.csv,
            ),
            clipBehavior: Clip.antiAlias,
            onPressed: () => unawaited(_startRealtimeLog(LogFileFormat.csv)),
            leadingIcon: const Icon(Icons.table_rows_rounded),
            child: const Text('实时保存 CSV'),
          ),
          MenuItemButton(
            style: _hcomMenuItemStyle(
              scheme,
              selected: _realtimeLogPath != null &&
                  _realtimeLogFormat == LogFileFormat.txt,
            ),
            clipBehavior: Clip.antiAlias,
            onPressed: () => unawaited(_startRealtimeLog(LogFileFormat.txt)),
            leadingIcon: const Icon(Icons.description_outlined),
            child: const Text('实时保存 TXT'),
          ),
          if (_realtimeLogPath != null) ...[
            const Divider(),
            MenuItemButton(
              style: _hcomMenuItemStyle(scheme),
              clipBehavior: Clip.antiAlias,
              onPressed: _stopRealtimeLog,
              leadingIcon: const Icon(Icons.stop_circle_outlined),
              child: const Text('停止实时保存'),
            ),
          ],
        ],
        builder: (context, controller, child) => Tooltip(
          message: '设置 CSV/TXT 实时日志保存，或停止实时保存',
          child: FilledButton.tonalIcon(
            style: _receiveToolbarButtonStyle(
              selected: _realtimeLogPath != null,
              scheme: scheme,
            ),
            onPressed: () =>
                controller.isOpen ? controller.close() : controller.open(),
            icon: Icon(
              _realtimeLogPath == null
                  ? Icons.sync_rounded
                  : Icons.sync_lock_rounded,
              size: 18,
            ),
            label: Text(
              _realtimeLogFormat == null
                  ? '实时保存'
                  : '实时保存中 · ${_realtimeLogFormat!.label}',
            ),
          ),
        ),
      ),
      const SizedBox(width: 8),
      Tooltip(
        message: '清除当前 RX/TX 日志',
        child: FilledButton.tonalIcon(
          style: _receiveToolbarButtonStyle(),
          onPressed: _entries.isEmpty ? null : _clearLog,
          icon: const Icon(Icons.delete_sweep_rounded, size: 18),
          label: const Text('清除日志'),
        ),
      ),
    ];
    return LayoutBuilder(builder: (context, constraints) {
      final actionRow = Row(mainAxisSize: MainAxisSize.min, children: actions);
      if (constraints.maxWidth >= 900) {
        return Row(children: [title, const Spacer(), actionRow]);
      }
      return SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(children: [title, const SizedBox(width: 14), actionRow]),
      );
    });
  }

  ButtonStyle _receiveToolbarButtonStyle({
    bool selected = false,
    ColorScheme? scheme,
  }) =>
      FilledButton.styleFrom(
        minimumSize: const Size(0, 30),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 0),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        visualDensity: VisualDensity.compact,
        backgroundColor: selected ? scheme?.primaryContainer : null,
        foregroundColor: selected ? scheme?.onPrimaryContainer : null,
      );

  Widget _entryRow(SerialEntry entry, ColorScheme scheme, int index) {
    final isRx = entry.direction == SerialDirection.rx;
    final directionLabel = _receiveInputFormat == SendInputFormat.hex
        ? hexDirectionLabel(entry.direction)
        : (isRx ? 'RX(TEXT)' : 'TX(TEXT)');
    final payload = _receiveInputFormat == SendInputFormat.hex
        ? entry.hex
        : _decodeHexText(entry.hex);
    final accent = isRx
        ? (widget.isDark ? HcomTheme.rxDark : HcomTheme.rxLight)
        : (widget.isDark ? HcomTheme.txDark : HcomTheme.txLight);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          child: Row(children: [
            if (_showLineNumbers) ...[
              SelectionContainer.disabled(
                child: SizedBox(
                  width: 36,
                  child: Text('${index + 1}',
                      textAlign: TextAlign.right,
                      style: TextStyle(
                          color: scheme.onSurfaceVariant,
                          fontSize: 11.5,
                          fontFamily: HcomTheme.latinFontFamily)),
                ),
              ),
              const SizedBox(width: 12),
            ],
            Container(
                width: 68,
                height: 22,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                    color: accent.withValues(alpha: .20),
                    borderRadius: BorderRadius.circular(99)),
                child: Text(directionLabel,
                    style: TextStyle(
                        color: accent,
                        fontWeight: FontWeight.w700,
                        fontSize: 11))),
            const SizedBox(width: 12),
            SizedBox(
                width: 92,
                child: Text(_formatTime(entry.timestamp),
                    style: TextStyle(
                        color: scheme.onSurfaceVariant,
                        fontSize: 11.5,
                        fontFamily: HcomTheme.latinFontFamily))),
            const SizedBox(width: 12),
            Expanded(
                child: Text(payload,
                    style: TextStyle(
                        color: scheme.onSurface,
                        fontFamily: _receiveInputFormat == SendInputFormat.hex
                            ? HcomTheme.latinFontFamily
                            : null,
                        fontSize: 12.5))),
            const SizedBox(width: 12),
            SelectionContainer.disabled(
              child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                  decoration: BoxDecoration(
                      color: scheme.surfaceContainerHigh,
                      borderRadius: BorderRadius.circular(8)),
                  child: Text('${entry.byteCount} B',
                      style: TextStyle(
                          fontSize: 11, color: scheme.onSurfaceVariant))),
            ),
          ]),
        ),
      ),
    );
  }

  String _decodeHexText(String hex) {
    final bytes = hex
        .split(RegExp(r'\s+'))
        .where((value) => value.isNotEmpty)
        .map((value) => int.tryParse(value, radix: 16))
        .whereType<int>()
        .toList();
    return utf8.decode(bytes, allowMalformed: true);
  }

  Widget _emptyPanel(IconData icon, String text) => Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 44),
        const SizedBox(height: 12),
        Text(text)
      ]));

  Widget _statistics(ColorScheme scheme) => Center(
        child: Wrap(
            spacing: 12,
            runSpacing: 12,
            alignment: WrapAlignment.center,
            children: [
              _statCard(
                  'RX',
                  '${_entries.where((entry) => entry.direction == SerialDirection.rx).fold(0, (sum, entry) => sum + entry.byteCount)} B',
                  HcomTheme.rxDark,
                  scheme),
              _statCard(
                  'TX',
                  '${_entries.where((entry) => entry.direction == SerialDirection.tx).fold(0, (sum, entry) => sum + entry.byteCount)} B',
                  HcomTheme.txDark,
                  scheme),
              _statCard('帧', '${_entries.length}', scheme.primary, scheme),
            ]),
      );

  Widget _statCard(
          String label, String value, Color color, ColorScheme scheme) =>
      Card(
          child: SizedBox(
              width: 160,
              height: 110,
              child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(label, style: TextStyle(color: color)),
                        const Spacer(),
                        Text(value,
                            style: TextStyle(
                                fontSize: 22,
                                color: scheme.onSurface,
                                fontFamily: HcomTheme.latinFontFamily))
                      ]))));

  Widget _sendPanel(ColorScheme scheme) => Card(
        margin: EdgeInsets.zero,
        shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
        child: Padding(
          padding: EdgeInsets.fromLTRB(
              16, _sendPanelExpanded ? 10 : 0, 16, _sendPanelExpanded ? 12 : 0),
          child: AnimatedSize(
            duration: const Duration(milliseconds: 200),
            curve: Easing.standard,
            child: _sendPanelExpanded
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _sendPanelHeader(),
                      FadeTransition(
                        opacity: CurvedAnimation(
                            parent: _sendPanelFadeController,
                            curve: Easing.standard),
                        child: Column(children: [
                          const SizedBox(height: 8),
                          _sendCommandBar(scheme),
                        ]),
                      ),
                    ],
                  )
                : _sendCommandBar(scheme, collapsed: true),
          ),
        ),
      );

  Widget _sendPanelHeader() => LayoutBuilder(builder: (context, constraints) {
        final formatSelector = SegmentedButton<SendInputFormat>(
          segments: const [
            ButtonSegment(
                value: SendInputFormat.hex,
                icon: Icon(Icons.data_object_rounded, size: 17),
                label: Text('HEX'),
                tooltip: '以十六进制字节发送'),
            ButtonSegment(
                value: SendInputFormat.plainText,
                icon: Icon(Icons.text_fields_rounded, size: 17),
                label: Text('普通'),
                tooltip: '以 UTF-8 文本编码发送'),
          ],
          selected: {_sendInputFormat},
          showSelectedIcon: false,
          onSelectionChanged: _selectSendInputFormat,
        );
        final modeSelector = SegmentedButton<SendMode>(
          segments: const [
            ButtonSegment(
                value: SendMode.sequence,
                icon: Icon(Icons.playlist_play_rounded, size: 17),
                label: Text('顺序'),
                tooltip: '按队列顺序发送一轮；每条遵循发送后延时'),
            ButtonSegment(
                value: SendMode.loop,
                icon: Icon(Icons.repeat_rounded, size: 17),
                label: Text('循环'),
                tooltip: '重复执行勾选队列，直到点击停止循环'),
            ButtonSegment(
                value: SendMode.trigger,
                icon: Icon(Icons.bolt_rounded, size: 17),
                label: Text('触发'),
                tooltip: '手动触发一轮已选队列；接收条件将在后续提供'),
            ButtonSegment(
                value: SendMode.periodic,
                icon: Icon(Icons.timer, size: 17),
                label: Text('周期'),
                tooltip: '按设定间隔重复发送发送框当前消息，不使用队列'),
          ],
          selected: _sendMode == null ? {} : {_sendMode!},
          emptySelectionAllowed: true,
          onSelectionChanged: _selectSendMode,
        );
        final collapseButton = IconButton(
          tooltip: '收起发送面板',
          onPressed: _toggleSendPanel,
          icon: const Icon(Icons.keyboard_arrow_down_rounded),
        );
        const title = Text('发送面板',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500));
        // Keep the complete header on one visual line.  On a compact window a
        // second line here would consume the receive stream's last usable
        // height; scale the controls down instead of pushing that stream away.
        return Row(children: [
          title,
          const SizedBox(width: 8),
          Expanded(
            child: FittedBox(
              alignment: Alignment.centerRight,
              fit: BoxFit.scaleDown,
              child: Row(children: [
                formatSelector,
                const SizedBox(width: 10),
                modeSelector,
                collapseButton,
              ]),
            ),
          ),
        ]);
      });

  Widget _sendCommandBar(ColorScheme scheme, {bool collapsed = false}) {
    final periodicMode = _sendMode == SendMode.periodic;
    final queueMode = _sendMode == SendMode.sequence ||
        _sendMode == SendMode.loop ||
        _sendMode == SendMode.trigger;
    final queueRunMode =
        _sendMode == SendMode.sequence || _sendMode == SendMode.loop;
    final queueIsRunning = queueRunMode && _queueSending;
    Widget commandInput({bool expand = false}) => TextField(
          controller: _commandController,
          decoration: InputDecoration(
            hintText: _sendInputFormat == SendInputFormat.hex
                ? '输入 HEX 命令，例如 AA 55 01 01 04 00 41 42 20 1A'
                : '输入普通文本，将以 UTF-8 编码发送',
            isDense: true,
          ),
        );

    Widget periodicField() => Tooltip(
          message: '周期范围：10 ms–1 h',
          child: SizedBox(
            width: 108,
            child: TextField(
              controller: _periodicIntervalController,
              enabled: !_periodicSending,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              style: const TextStyle(
                  fontFamily: HcomTheme.latinFontFamily, fontSize: 13),
              decoration: const InputDecoration(
                labelText: '周期',
                suffixText: 'ms',
                isDense: true,
              ),
            ),
          ),
        );

    Widget packetButton() => MenuAnchor(
          style: _hcomMenuSurfaceStyle(scheme),
          menuChildren: [
            for (final suffix in PacketSuffix.values)
              MenuItemButton(
                style: _hcomMenuItemStyle(
                  scheme,
                  selected: _sendPacketSuffix == suffix,
                ),
                clipBehavior: Clip.antiAlias,
                onPressed: () => setState(() => _sendPacketSuffix = suffix),
                child: Text(suffix.label),
              ),
          ],
          builder: (context, controller, child) => Tooltip(
            message: '发送当前消息后追加 ${_sendPacketSuffix.label}',
            child: FilledButton.tonalIcon(
              style: FilledButton.styleFrom(
                minimumSize: const Size(0, 40),
                padding: const EdgeInsets.symmetric(horizontal: 10),
              ),
              onPressed: () =>
                  controller.isOpen ? controller.close() : controller.open(),
              icon: const Icon(Icons.call_split_rounded, size: 18),
              label: Text('组包 ${_sendPacketSuffix.label}'),
            ),
          ),
        );

    Widget queueButton() => Tooltip(
          message: '将发送框当前消息加入队列',
          child: FilledButton.tonalIcon(
              onPressed: _queueCommand,
              icon: const Icon(Icons.add_rounded),
              label: const Text('加入队列')),
        );

    Widget sendButton() => Tooltip(
          message: periodicMode
              ? '按设定间隔重复发送发送框当前消息'
              : queueRunMode
                  ? '开始或停止当前队列发送'
                  : queueMode
                      ? '发送队列中已勾选的消息'
                      : '发送当前消息',
          child: FilledButton.icon(
            style: (periodicMode && _periodicSending) || queueIsRunning
                ? FilledButton.styleFrom(
                    backgroundColor: scheme.errorContainer,
                    foregroundColor: scheme.onErrorContainer)
                : null,
            onPressed: _connected
                ? (periodicMode
                    ? _togglePeriodicSend
                    : (queueIsRunning
                        ? _stopQueueSend
                        : (queueMode
                            ? () => unawaited(_startQueueSend(
                                  repeat: _sendMode == SendMode.loop,
                                ))
                            : _sendToPort)))
                : null,
            icon: Icon(periodicMode
                ? (_periodicSending ? Icons.stop : Icons.play_arrow)
                : (queueIsRunning ? Icons.stop : Icons.send_rounded)),
            label: Text(periodicMode
                ? (_periodicSending ? '停止周期' : '开始周期')
                : (queueIsRunning
                    ? '停止${_sendMode == SendMode.loop ? '循环' : '顺序'}'
                    : (queueMode ? '发送已选' : '发送'))),
          ),
        );

    Widget expandButton() => IconButton.filledTonal(
          tooltip: '展开完整发送面板',
          onPressed: _toggleSendPanel,
          icon: const Icon(Icons.keyboard_arrow_up_rounded),
        );

    // A compact window must never let controls squeeze the message input or
    // overflow into the receive stream.  Stack the action row only when the
    // available width cannot safely fit the desktop layout.
    return LayoutBuilder(builder: (context, constraints) {
      final compact = constraints.maxWidth < 420;
      if (!compact) {
        return Row(children: [
          Expanded(child: commandInput()),
          if (periodicMode) ...[const SizedBox(width: 10), periodicField()],
          const SizedBox(width: 10),
          packetButton(),
          const SizedBox(width: 10),
          queueButton(),
          const SizedBox(width: 10),
          sendButton(),
          if (collapsed) ...[const SizedBox(width: 6), expandButton()],
        ]);
      }
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        commandInput(),
        const SizedBox(height: 8),
        Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (periodicMode) periodicField(),
              packetButton(),
              queueButton(),
              sendButton(),
              if (collapsed) expandButton(),
            ]),
      ]);
    });
  }

  Widget _queueEditorPanel(ColorScheme scheme) => Card(
        key: const ValueKey('queue-editor-panel'),
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              const Icon(Icons.playlist_play_rounded),
              const SizedBox(width: 8),
              const Text('队列编辑',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              const Spacer(),
              Text('${_enabledQueue.length}/${_queue.length} 已选',
                  style:
                      TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
              IconButton(
                tooltip: '收起队列编辑',
                onPressed: () => setState(() {
                  _queuePanelExpanded = false;
                  _sendMode = null;
                }),
                icon: const Icon(Icons.close_rounded),
              ),
            ]),
            const SizedBox(height: 14),
            TextField(
              controller: _queueNameController,
              decoration: const InputDecoration(
                labelText: '队列名称',
                hintText: '例如：设备初始化',
                prefixIcon: Icon(Icons.drive_file_rename_outline),
                isDense: true,
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 14),
            Text(
              '勾选本次 ${_sendModeLabel()} 要发送的命令',
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: _queue.isEmpty
                  ? Center(
                      child: Text('队列为空，使用左侧“加入队列”添加命令。',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: scheme.onSurfaceVariant)),
                    )
                  : ListView.separated(
                      itemCount: _queue.length,
                      separatorBuilder: (_, index) => const SizedBox(height: 8),
                      itemBuilder: (context, index) =>
                          _queueEditorRow(index, scheme),
                    ),
            ),
          ]),
        ),
      );

  String _sendModeLabel() => switch (_sendMode) {
        SendMode.sequence => '顺序发送',
        SendMode.loop => '循环发送',
        SendMode.trigger => '触发发送',
        SendMode.periodic => '周期发送',
        null => '发送',
      };

  Widget _queueEditorRow(int index, ColorScheme scheme) {
    final command = _queue[index];
    return Container(
      key: ObjectKey(command),
      padding: const EdgeInsets.fromLTRB(6, 8, 6, 8),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLowest,
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Tooltip(
          message: command.enabled ? '本次发送此命令' : '不发送此命令',
          child: Checkbox(
            value: command.enabled,
            onChanged: (value) => _toggleQueueItem(index, value),
          ),
        ),
        Expanded(
          child: Column(children: [
            Row(children: [
              Expanded(
                child: TextFormField(
                  initialValue: command.name,
                  enabled: command.enabled,
                  onChanged: (value) => command.name = value,
                  decoration: const InputDecoration(
                    hintText: '命令名称',
                    isDense: true,
                  ),
                  style: const TextStyle(fontSize: 13),
                ),
              ),
              const SizedBox(width: 6),
              Tooltip(
                message: identical(_armedQueueDelete, command)
                    ? '再点一次立即删除'
                    : '删除命令：单击确认，450 ms 内再点直接删除',
                child: IconButton.filledTonal(
                  onPressed: () => _requestQueueDelete(command),
                  icon: Icon(identical(_armedQueueDelete, command)
                      ? Icons.delete_forever_rounded
                      : Icons.delete_outline_rounded),
                ),
              ),
            ]),
            const SizedBox(height: 6),
            TextFormField(
              initialValue: command.hex,
              enabled: command.enabled,
              onChanged: (value) => command.hex = value.toUpperCase(),
              decoration: const InputDecoration(
                hintText: 'HEX 命令',
                isDense: true,
              ),
              style: const TextStyle(
                  fontFamily: HcomTheme.latinFontFamily, fontSize: 12),
            ),
            const SizedBox(height: 6),
            Wrap(spacing: 8, runSpacing: 6, children: [
              Tooltip(
                message: '设置发送该条后等待下一条的时间',
                child: SizedBox(
                  width: 112,
                  child: TextFormField(
                    initialValue: '${command.delayMilliseconds}',
                    enabled: command.enabled,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    onChanged: (value) =>
                        command.delayMilliseconds = int.tryParse(value) ?? 0,
                    decoration: const InputDecoration(
                      labelText: '发送后延时',
                      suffixText: 'ms',
                      isDense: true,
                    ),
                    style: const TextStyle(
                        fontFamily: HcomTheme.latinFontFamily, fontSize: 12),
                  ),
                ),
              ),
              MenuAnchor(
                style: _hcomMenuSurfaceStyle(scheme),
                menuChildren: [
                  for (final suffix in PacketSuffix.values)
                    MenuItemButton(
                      style: _hcomMenuItemStyle(
                        scheme,
                        selected: command.packetSuffix == suffix,
                      ),
                      clipBehavior: Clip.antiAlias,
                      onPressed: command.enabled
                          ? () => setState(() => command.packetSuffix = suffix)
                          : null,
                      child: Text(suffix.label),
                    ),
                ],
                builder: (context, controller, child) => Tooltip(
                  message: '发送此条消息后追加 ${command.packetSuffix.label}',
                  child: FilledButton.tonalIcon(
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(0, 40),
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                    ),
                    onPressed: command.enabled
                        ? () => controller.isOpen
                            ? controller.close()
                            : controller.open()
                        : null,
                    icon: const Icon(Icons.call_split_rounded, size: 18),
                    label: Text('组包 ${command.packetSuffix.label}'),
                  ),
                ),
              ),
            ]),
          ]),
        ),
        Column(children: [
          IconButton(
            tooltip: '上移命令',
            iconSize: 18,
            onPressed: index == 0 ? null : () => _moveQueueItem(index, -1),
            icon: const Icon(Icons.arrow_upward_rounded),
          ),
          IconButton(
            tooltip: '下移命令',
            iconSize: 18,
            onPressed: index == _queue.length - 1
                ? null
                : () => _moveQueueItem(index, 1),
            icon: const Icon(Icons.arrow_downward_rounded),
          ),
        ]),
      ]),
    );
  }

  Widget _statusBar(ColorScheme scheme) {
    final rx = _entries
        .where((entry) => entry.direction == SerialDirection.rx)
        .fold(0, (sum, entry) => sum + entry.byteCount);
    final tx = _entries
        .where((entry) => entry.direction == SerialDirection.tx)
        .fold(0, (sum, entry) => sum + entry.byteCount);
    Text item(String label, String value) => Text.rich(
          TextSpan(
            text: '$label ',
            children: [
              TextSpan(
                text: value,
                style: TextStyle(
                    color: scheme.onSurface,
                    fontFamily: HcomTheme.latinFontFamily,
                    fontWeight: FontWeight.w500),
              ),
            ],
          ),
          style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
        );
    return Container(
        height: 30,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        color: scheme.surfaceContainerLow,
        child: Row(children: [
          item('RX', '$rx B'),
          const SizedBox(width: 20),
          item('TX', '$tx B'),
          const SizedBox(width: 20),
          item('速率', '—'),
          const Spacer(),
          item('帧', '${_entries.length}'),
          const SizedBox(width: 20),
          item('校验通过率', '—'),
          const SizedBox(width: 20),
          item('版本', applicationVersion),
        ]));
  }

  String _formatTime(DateTime value) =>
      formatDisplayTimestamp(value, _timeZoneOffsetMinutes);
}

/// Shared menu treatment: a generous surface radius with small inset around
/// each menu item, so hover and selected states remain rounded rather than
/// filling the whole menu as a hard-edged rectangle.
MenuStyle _hcomMenuSurfaceStyle(ColorScheme scheme, {double? width}) =>
    MenuStyle(
      backgroundColor:
          WidgetStatePropertyAll<Color?>(scheme.surfaceContainerHigh),
      elevation: const WidgetStatePropertyAll<double?>(4),
      padding: const WidgetStatePropertyAll<EdgeInsetsGeometry>(
        EdgeInsets.all(6),
      ),
      fixedSize: width == null
          ? null
          : WidgetStatePropertyAll<Size?>(Size.fromWidth(width)),
      shape: WidgetStatePropertyAll<OutlinedBorder>(
        RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
    );

ButtonStyle _hcomMenuItemStyle(
  ColorScheme scheme, {
  bool selected = false,
}) =>
    MenuItemButton.styleFrom(
      backgroundColor:
          selected ? scheme.secondaryContainer : Colors.transparent,
      overlayColor: scheme.onSurface.withValues(alpha: .10),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      minimumSize: const Size(0, 42),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      animationDuration: const Duration(milliseconds: 150),
    );

/// A compact M3 menu field whose rounded option states match the rest of the
/// workbench. Flutter's legacy dropdown renders rectangular item highlights.
class _HcomPopupField<T> extends StatelessWidget {
  const _HcomPopupField({
    required this.width,
    required this.label,
    required this.value,
    required this.options,
    required this.textOf,
    required this.onChanged,
    this.iconOf,
    this.useMono = false,
  });

  final double width;
  final String label;
  final T value;
  final List<T> options;
  final String Function(T value) textOf;
  final IconData? Function(T value)? iconOf;
  final ValueChanged<T>? onChanged;
  final bool useMono;

  Widget? _leadingIcon(T option) {
    final icon = iconOf?.call(option);
    return icon == null ? null : Icon(icon, size: 18);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final enabled = onChanged != null;
    final textStyle = TextStyle(
      color: enabled ? scheme.onSurface : scheme.onSurfaceVariant,
      fontFamily: useMono ? HcomTheme.latinFontFamily : null,
      fontSize: 13,
    );
    return MenuAnchor(
      style: _hcomMenuSurfaceStyle(scheme, width: width),
      crossAxisUnconstrained: false,
      menuChildren: [
        for (final option in options)
          MenuItemButton(
            style: _hcomMenuItemStyle(
              scheme,
              selected: option == value,
            ),
            clipBehavior: Clip.antiAlias,
            onPressed: enabled ? () => onChanged!(option) : null,
            leadingIcon: _leadingIcon(option),
            child: Text(textOf(option),
                maxLines: 1, overflow: TextOverflow.ellipsis, style: textStyle),
          ),
      ],
      builder: (context, controller, child) => SizedBox(
        width: width,
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: enabled
              ? () => controller.isOpen ? controller.close() : controller.open()
              : null,
          child: InputDecorator(
            isEmpty: false,
            decoration: InputDecoration(labelText: label, isDense: true),
            child: Row(children: [
              Expanded(
                  child: Text(textOf(value),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: textStyle)),
              Icon(Icons.arrow_drop_down_rounded,
                  color: enabled ? scheme.onSurfaceVariant : scheme.outline),
            ]),
          ),
        ),
      ),
    );
  }
}

class _SerialPort {
  const _SerialPort({
    required this.port,
    required this.description,
    required this.hardwareId,
    required this.kind,
  });

  static _SerialPort? fromCore(Map<dynamic, dynamic> value) {
    final port = value['port'];
    if (port is! String || port.isEmpty) return null;
    return _SerialPort(
      port: port,
      description: value['description']?.toString() ?? 'Serial Port',
      hardwareId: value['hardwareId']?.toString() ?? 'Unknown',
      kind: value['kind']?.toString() ?? 'serial',
    );
  }

  final String port;
  final String description;
  final String hardwareId;
  final String kind;

  IconData get icon => switch (kind) {
        'bluetooth' => Icons.bluetooth_rounded,
        'usb' => Icons.usb_rounded,
        _ => Icons.settings_input_component_rounded,
      };
}

class _RailDestination {
  const _RailDestination(this.icon, this.label);

  final IconData icon;
  final String label;
}

enum _RailSide { left, right }

/// M3 rail with an explicitly timed, shared selection pill.
class _AnimatedRail extends StatefulWidget {
  const _AnimatedRail({
    required this.destinations,
    required this.selectedIndex,
    required this.onSelected,
    required this.scheme,
    required this.side,
    required this.expanded,
    required this.onToggle,
  });

  final List<_RailDestination> destinations;
  final int selectedIndex;
  final ValueChanged<int> onSelected;
  final ColorScheme scheme;
  final _RailSide side;
  final bool expanded;
  final VoidCallback onToggle;

  @override
  State<_AnimatedRail> createState() => _AnimatedRailState();
}

class _AnimatedRailState extends State<_AnimatedRail> {
  bool _hovering = false;

  static const _itemHeight = 66.0;

  @override
  Widget build(BuildContext context) {
    final controlOnLeft = widget.side == _RailSide.right;
    final collapseIcon = widget.side == _RailSide.left
        ? Icons.chevron_left
        : Icons.chevron_right;
    final expandIcon = widget.side == _RailSide.left
        ? Icons.chevron_right
        : Icons.chevron_left;
    final tooltip = widget.expanded
        ? '收起${widget.side == _RailSide.left ? '左侧' : '右侧'} Dock'
        : '展开${widget.side == _RailSide.left ? '左侧' : '右侧'} Dock';
    final control = AnimatedOpacity(
      duration: const Duration(milliseconds: 180),
      opacity: _hovering ? 1 : .62,
      child: Tooltip(
        message: tooltip,
        child: Material(
          color: widget.scheme.surfaceContainerHighest.withValues(alpha: .96),
          shape: StadiumBorder(
              side: BorderSide(color: widget.scheme.outlineVariant)),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: widget.onToggle,
            child: SizedBox(
              width: 34,
              height: 42,
              child: Icon(widget.expanded ? collapseIcon : expandIcon,
                  size: 22, color: widget.scheme.primary),
            ),
          ),
        ),
      ),
    );

    return LayoutBuilder(builder: (context, constraints) {
      const verticalInset = 16.0;
      final usableHeight = (constraints.maxHeight - verticalInset * 2)
          .clamp(0.0, double.infinity);
      final naturalHeight = widget.destinations.length * _itemHeight;
      final railHeight = usableHeight < naturalHeight
          ? usableHeight
          : naturalHeight.toDouble();
      final itemHeight = widget.destinations.isEmpty
          ? _itemHeight
          : railHeight / widget.destinations.length;
      final selectionInset = itemHeight < 12 ? 0.0 : 4.0;

      final expandedRail = Material(
        color: widget.scheme.surfaceContainerLow,
        elevation: 1,
        shadowColor: Colors.black.withValues(alpha: .18),
        shape: const StadiumBorder(),
        clipBehavior: Clip.antiAlias,
        child: Stack(children: [
          AnimatedPositioned(
            duration: const Duration(milliseconds: 250),
            curve: Easing.emphasizedDecelerate,
            left: 4,
            right: 4,
            top: selectionInset + widget.selectedIndex * itemHeight,
            height:
                (itemHeight - selectionInset * 2).clamp(0.0, double.infinity),
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                    color: widget.scheme.secondaryContainer,
                    borderRadius: BorderRadius.circular(100)),
              ),
            ),
          ),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: List.generate(widget.destinations.length, (index) {
              final destination = widget.destinations[index];
              final selected = index == widget.selectedIndex;
              return SizedBox(
                height: itemHeight,
                width: double.infinity,
                child: Tooltip(
                  message: '打开${destination.label}模块',
                  child: InkWell(
                    borderRadius: BorderRadius.circular(100),
                    onTap: () => widget.onSelected(index),
                    child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(destination.icon,
                              size: itemHeight < 52 ? 18 : 20,
                              color: selected
                                  ? widget.scheme.onSecondaryContainer
                                  : widget.scheme.onSurfaceVariant),
                          if (itemHeight >= 42) ...[
                            const SizedBox(height: 3),
                            Text(destination.label,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    fontSize: itemHeight < 54 ? 10 : 11,
                                    fontWeight: FontWeight.w500,
                                    color: selected
                                        ? widget.scheme.onSurface
                                        : widget.scheme.onSurfaceVariant)),
                          ],
                        ]),
                  ),
                ),
              );
            }),
          ),
        ]),
      );
      final collapsedRail = Container(
        width: 8,
        decoration: BoxDecoration(
            color: widget.scheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(99)),
      );

      return MouseRegion(
        onEnter: (_) => setState(() => _hovering = true),
        onExit: (_) => setState(() => _hovering = false),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          curve: Easing.standard,
          width: widget.expanded ? 112 : 44,
          child: Stack(clipBehavior: Clip.none, children: [
            Positioned(
              top: verticalInset,
              bottom: verticalInset,
              left: controlOnLeft ? 24 : 0,
              right: controlOnLeft ? 0 : 24,
              child: Align(
                // Keep the rail body on the very same vertical center line as
                // its external expand/collapse control.  The previous top
                // alignment left the capsule visually pinned to the window top.
                alignment: Alignment.center,
                child: SizedBox(
                  key: ValueKey(widget.side == _RailSide.left
                      ? 'left-dock-body'
                      : 'right-dock-body'),
                  width: widget.expanded ? 96 : 8,
                  height: railHeight,
                  child: widget.expanded ? expandedRail : collapsedRail,
                ),
              ),
            ),
            Positioned.fill(
              child: Align(
                alignment: controlOnLeft
                    ? Alignment.centerLeft
                    : Alignment.centerRight,
                child: control,
              ),
            ),
          ]),
        ),
      );
    });
  }
}

/// Four equal M3 primary tabs with a 200ms standard-motion indicator.
class _AnimatedTabStrip extends StatelessWidget {
  const _AnimatedTabStrip({
    required this.selectedIndex,
    required this.frameCount,
    required this.scheme,
    required this.streamLabel,
    required this.formatsLinked,
    required this.onSelected,
    required this.onStreamFormatToggle,
  });

  final int selectedIndex;
  final int frameCount;
  final ColorScheme scheme;
  final String streamLabel;
  final bool formatsLinked;
  final ValueChanged<int> onSelected;
  final VoidCallback onStreamFormatToggle;

  @override
  Widget build(BuildContext context) {
    final labels = [streamLabel, '字段解析', '时间轴', '统计'];
    return SizedBox(
      height: 48,
      child: LayoutBuilder(builder: (context, constraints) {
        final tabWidth = constraints.maxWidth / labels.length;
        return Stack(children: [
          Positioned.fill(
            child: Row(
              children: List.generate(labels.length, (index) {
                final selected = index == selectedIndex;
                return Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 3),
                    child: Material(
                      color: selected
                          ? scheme.surfaceContainerHighest
                          : scheme.surfaceContainerLow,
                      shape: const RoundedRectangleBorder(
                          borderRadius:
                              BorderRadius.vertical(top: Radius.circular(12))),
                      clipBehavior: Clip.antiAlias,
                      child: Tooltip(
                        message: index == 0
                            ? (formatsLinked
                                ? '已与发送格式联动；再次点击可切换接收格式并解除联动'
                                : '再次点击可切换接收 HEX / 文本显示')
                            : labels[index],
                        child: InkWell(
                          onTap: () {
                            if (index == 0 && selected) {
                              onStreamFormatToggle();
                            } else {
                              onSelected(index);
                            }
                          },
                          child: Center(
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(labels[index],
                                        style: TextStyle(
                                            fontSize: 14,
                                            fontWeight: FontWeight.w500,
                                            color: selected
                                                ? scheme.primary
                                                : scheme.onSurfaceVariant)),
                                    if (index == 0) ...[
                                      const SizedBox(width: 5),
                                      Icon(Icons.swap_horiz_rounded,
                                          size: 16,
                                          color: selected
                                              ? scheme.primary
                                              : scheme.onSurfaceVariant),
                                      if (formatsLinked) ...[
                                        const SizedBox(width: 4),
                                        Icon(Icons.link_rounded,
                                            size: 14,
                                            color: selected
                                                ? scheme.primary
                                                : scheme.onSurfaceVariant),
                                      ],
                                      const SizedBox(width: 8),
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 7, vertical: 1),
                                        decoration: BoxDecoration(
                                            color: scheme.primaryContainer,
                                            borderRadius:
                                                BorderRadius.circular(8)),
                                        child: Text('$frameCount',
                                            style: TextStyle(
                                                color:
                                                    scheme.onPrimaryContainer,
                                                fontSize: 11,
                                                fontFamily:
                                                    HcomTheme.latinFontFamily)),
                                      ),
                                    ],
                                  ]),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              }),
            ),
          ),
          Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Divider(height: 1, color: scheme.outlineVariant)),
          AnimatedPositioned(
            duration: const Duration(milliseconds: 200),
            curve: Easing.standard,
            left: selectedIndex * tabWidth + (tabWidth - 48) / 2,
            bottom: 0,
            width: 48,
            height: 3,
            child: DecoratedBox(
                decoration: BoxDecoration(
                    color: scheme.primary,
                    borderRadius:
                        const BorderRadius.vertical(top: Radius.circular(8)))),
          ),
        ]);
      }),
    );
  }
}
