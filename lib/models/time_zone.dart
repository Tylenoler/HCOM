const defaultTimeZoneOffsetMinutes = 8 * 60;

/// Common fixed UTC offsets. Daylight-saving changes remain an explicit user
/// choice instead of being guessed from the computer's locale.
final availableTimeZoneOffsets = List<int>.unmodifiable([
  for (var hour = -12; hour <= 14; hour++) hour * 60,
  330, // UTC+05:30
  345, // UTC+05:45
  570, // UTC+09:30
]..sort());

String timeZoneLabel(int offsetMinutes) {
  final sign = offsetMinutes < 0 ? '-' : '+';
  final absolute = offsetMinutes.abs();
  final hours = absolute ~/ 60;
  final minutes = absolute % 60;
  final base =
      'UTC$sign${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}';
  return offsetMinutes == defaultTimeZoneOffsetMinutes ? '$base（中国标准时间）' : base;
}

String formatDisplayTimestamp(DateTime timestamp, int offsetMinutes) {
  final displayTime = timestamp.toUtc().add(Duration(minutes: offsetMinutes));
  return '${displayTime.hour.toString().padLeft(2, '0')}:${displayTime.minute.toString().padLeft(2, '0')}:${displayTime.second.toString().padLeft(2, '0')}.${displayTime.millisecond.toString().padLeft(3, '0')}';
}

String formatDisplayLogTimestamp(DateTime timestamp, int offsetMinutes) {
  final displayTime = timestamp.toUtc().add(Duration(minutes: offsetMinutes));
  final year = (displayTime.year % 100).toString().padLeft(2, '0');
  final month = displayTime.month.toString().padLeft(2, '0');
  final day = displayTime.day.toString().padLeft(2, '0');
  return '$year-$month-$day ${formatDisplayTimestamp(timestamp, offsetMinutes)}';
}
