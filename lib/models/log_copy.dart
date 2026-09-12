import 'serial_entry.dart';
import 'time_zone.dart';

String hexDirectionLabel(SerialDirection direction) =>
    direction == SerialDirection.rx ? 'RX(HEX)' : 'TX(HEX)';

/// The text sequence produced by the on-screen selectable fields. It is kept
/// separate from the exported representation so a compact visual row can still
/// copy as a readable two-line record.
String selectableLogEntryText(SerialEntry entry, int offsetMinutes) =>
    '${hexDirectionLabel(entry.direction)}${formatDisplayTimestamp(entry.timestamp, offsetMinutes)}${entry.hex}';

String formatLogCopyEntry(SerialEntry entry, int offsetMinutes) =>
    '${formatDisplayLogTimestamp(entry.timestamp, offsetMinutes)} ${hexDirectionLabel(entry.direction)}\n${entry.hex}';

/// Converts complete selected visual rows into one two-line record per event.
/// A partial character selection remains untouched, so copying a fragment of
/// a HEX payload still behaves like normal text selection.
String formatSelectedLogCopy(
  List<SerialEntry> entries,
  String selectedText,
  int offsetMinutes,
) {
  final records = <String>[];
  var searchFrom = 0;
  for (final entry in entries) {
    final visible = selectableLogEntryText(entry, offsetMinutes);
    final match = selectedText.indexOf(visible, searchFrom);
    if (match == -1) continue;
    records.add(formatLogCopyEntry(entry, offsetMinutes));
    searchFrom = match + visible.length;
  }
  return records.isEmpty ? selectedText : records.join('\n');
}
