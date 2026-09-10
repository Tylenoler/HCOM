enum SerialDirection { rx, tx }

class SerialEntry {
  const SerialEntry({
    required this.direction,
    required this.timestamp,
    required this.hex,
    required this.label,
  });

  final SerialDirection direction;
  final DateTime timestamp;
  final String hex;
  final String label;

  int get byteCount =>
      hex.split(RegExp(r'\s+')).where((byte) => byte.isNotEmpty).length;
}
