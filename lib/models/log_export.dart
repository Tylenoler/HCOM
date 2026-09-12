import 'serial_entry.dart';
import 'time_zone.dart';

enum LogFileFormat { csv, txt }

extension LogFileFormatLabel on LogFileFormat {
  String get extension => name;
  String get label => name.toUpperCase();
}

String serializeLogEntries(
  Iterable<SerialEntry> entries,
  LogFileFormat format,
  int offsetMinutes, {
  bool includeCsvHeader = true,
}) {
  if (format == LogFileFormat.txt) {
    final records = entries.map((entry) {
      final direction = entry.direction == SerialDirection.rx ? 'RX' : 'TX';
      return '${formatDisplayLogTimestamp(entry.timestamp, offsetMinutes)} $direction(HEX)\n${entry.hex}';
    }).join('\n');
    return records.isEmpty ? '' : '$records\n';
  }

  final buffer = StringBuffer();
  if (includeCsvHeader) {
    buffer.writeln('timestamp,direction,format,byte_count,data');
  }
  for (final entry in entries) {
    final direction = entry.direction == SerialDirection.rx ? 'RX' : 'TX';
    buffer.writeln([
      formatDisplayLogTimestamp(entry.timestamp, offsetMinutes),
      direction,
      'HEX',
      entry.byteCount,
      _csvCell(entry.hex),
    ].join(','));
  }
  return buffer.toString();
}

String _csvCell(String value) => '"${value.replaceAll('"', '""')}"';
