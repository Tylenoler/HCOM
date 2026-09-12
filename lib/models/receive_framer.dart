enum ReceiveFramingMode { automatic, idle, fixedLength, delimiters }

extension ReceiveFramingModeDetails on ReceiveFramingMode {
  String get label => switch (this) {
        ReceiveFramingMode.automatic => '自动识别',
        ReceiveFramingMode.idle => '空闲间隔',
        ReceiveFramingMode.fixedLength => '固定长度',
        ReceiveFramingMode.delimiters => '帧头 + 帧尾',
      };
}

class ReceiveFramingConfig {
  const ReceiveFramingConfig({
    this.mode = ReceiveFramingMode.automatic,
    this.fixedLength = 4,
    this.headerHex = 'AA 55',
    this.trailerHex = '55 AA',
  });

  final ReceiveFramingMode mode;
  final int fixedLength;
  final String headerHex;
  final String trailerHex;
}

class FramedReceiveData {
  const FramedReceiveData(this.bytes, this.timestamp);

  final List<int> bytes;
  final DateTime timestamp;

  String get hex => bytes
      .map((byte) => byte.toRadixString(16).padLeft(2, '0').toUpperCase())
      .join(' ');
}

/// Turns arbitrary UART transport reads into display frames.
///
/// Automatic mode learns the dominant recent message length and only splits a
/// larger batch when it is an exact multiple of that well-established length.
/// Protocol-specific modes retain incomplete data across transport reads.
class ReceiveFramer {
  ReceiveFramer([this.config = const ReceiveFramingConfig()]);

  static const _learningWindow = 24;
  static const _minimumSamples = 3;
  static const _maximumPendingBytes = 64 * 1024;

  ReceiveFramingConfig config;
  final List<int> _pending = [];
  DateTime? _pendingTimestamp;
  final List<int> _recentLengths = [];

  void configure(ReceiveFramingConfig value) {
    config = value;
    reset();
  }

  void reset() {
    _pending.clear();
    _pendingTimestamp = null;
    _recentLengths.clear();
  }

  List<FramedReceiveData> addHex(String hex, DateTime timestamp) {
    final bytes = parseHexBytes(hex);
    if (bytes.isEmpty) return const [];
    return add(bytes, timestamp);
  }

  List<FramedReceiveData> add(List<int> bytes, DateTime timestamp) {
    return switch (config.mode) {
      ReceiveFramingMode.automatic => _addAutomatic(bytes, timestamp),
      ReceiveFramingMode.idle => [FramedReceiveData(List.of(bytes), timestamp)],
      ReceiveFramingMode.fixedLength => _addFixed(bytes, timestamp),
      ReceiveFramingMode.delimiters => _addDelimited(bytes, timestamp),
    };
  }

  List<FramedReceiveData> flush() {
    if (_pending.isEmpty) return const [];
    final frame = FramedReceiveData(
      List<int>.from(_pending),
      _pendingTimestamp ?? DateTime.now().toUtc(),
    );
    _pending.clear();
    _pendingTimestamp = null;
    return [frame];
  }

  List<FramedReceiveData> _addAutomatic(List<int> bytes, DateTime timestamp) {
    final learnedLength = _dominantLength();
    if (learnedLength != null &&
        bytes.length > learnedLength &&
        bytes.length % learnedLength == 0) {
      final frames = <FramedReceiveData>[];
      for (var offset = 0; offset < bytes.length; offset += learnedLength) {
        frames.add(FramedReceiveData(
          List<int>.from(bytes.sublist(offset, offset + learnedLength)),
          timestamp,
        ));
        _recordLength(learnedLength);
      }
      return frames;
    }
    _recordLength(bytes.length);
    return [FramedReceiveData(List<int>.from(bytes), timestamp)];
  }

  List<FramedReceiveData> _addFixed(List<int> bytes, DateTime timestamp) {
    final length = config.fixedLength.clamp(1, _maximumPendingBytes);
    _append(bytes, timestamp);
    final frames = <FramedReceiveData>[];
    while (_pending.length >= length) {
      frames.add(_takePrefix(length));
    }
    _limitPending(frames);
    return frames;
  }

  List<FramedReceiveData> _addDelimited(List<int> bytes, DateTime timestamp) {
    final header = parseHexBytes(config.headerHex);
    final trailer = parseHexBytes(config.trailerHex);
    if (header.isEmpty || trailer.isEmpty) {
      return [FramedReceiveData(List<int>.from(bytes), timestamp)];
    }

    _append(bytes, timestamp);
    final frames = <FramedReceiveData>[];
    while (_pending.isNotEmpty) {
      final headerAt = _indexOf(_pending, header);
      if (headerAt < 0) break;
      if (headerAt > 0) {
        // Preserve unexpected bytes instead of silently discarding them.
        frames.add(_takePrefix(headerAt));
        continue;
      }
      final trailerAt = _indexOf(_pending, trailer, header.length);
      if (trailerAt < 0) break;
      frames.add(_takePrefix(trailerAt + trailer.length));
    }
    _limitPending(frames);
    return frames;
  }

  void _append(List<int> bytes, DateTime timestamp) {
    if (_pending.isEmpty) _pendingTimestamp = timestamp;
    _pending.addAll(bytes);
  }

  FramedReceiveData _takePrefix(int count) {
    final timestamp = _pendingTimestamp ?? DateTime.now().toUtc();
    final bytes = List<int>.from(_pending.take(count));
    _pending.removeRange(0, count);
    if (_pending.isEmpty) _pendingTimestamp = null;
    return FramedReceiveData(bytes, timestamp);
  }

  void _limitPending(List<FramedReceiveData> frames) {
    if (_pending.length <= _maximumPendingBytes) return;
    frames.add(_takePrefix(_pending.length - _maximumPendingBytes));
  }

  int? _dominantLength() {
    if (_recentLengths.length < _minimumSamples) return null;
    final counts = <int, int>{};
    for (final length in _recentLengths) {
      counts[length] = (counts[length] ?? 0) + 1;
    }
    final candidates =
        counts.entries.where((entry) => entry.value >= _minimumSamples).toList()
          ..sort((a, b) {
            final byCount = b.value.compareTo(a.value);
            return byCount != 0 ? byCount : a.key.compareTo(b.key);
          });
    return candidates.isEmpty ? null : candidates.first.key;
  }

  void _recordLength(int length) {
    if (length <= 0) return;
    _recentLengths.add(length);
    if (_recentLengths.length > _learningWindow) {
      _recentLengths.removeAt(0);
    }
  }
}

List<int> parseHexBytes(String hex) {
  final compact = hex.replaceAll(RegExp(r'\s+'), '');
  if (compact.isEmpty || compact.length.isOdd) return const [];
  final bytes = <int>[];
  for (var index = 0; index < compact.length; index += 2) {
    final byte = int.tryParse(compact.substring(index, index + 2), radix: 16);
    if (byte == null) return const [];
    bytes.add(byte);
  }
  return bytes;
}

int _indexOf(List<int> source, List<int> pattern, [int start = 0]) {
  if (pattern.isEmpty || source.length < pattern.length) return -1;
  for (var index = start; index <= source.length - pattern.length; index++) {
    var matches = true;
    for (var offset = 0; offset < pattern.length; offset++) {
      if (source[index + offset] != pattern[offset]) {
        matches = false;
        break;
      }
    }
    if (matches) return index;
  }
  return -1;
}
