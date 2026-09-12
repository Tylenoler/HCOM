import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hcom/main.dart';
import 'package:hcom/models/log_copy.dart';
import 'package:hcom/models/serial_entry.dart';
import 'package:hcom/models/time_zone.dart';
import 'package:hcom/theme/hcom_theme.dart';

void main() {
  testWidgets('renders the UART workbench and its in-stream clear action',
      (tester) async {
    await tester.pumpWidget(const HcomApp());

    expect(find.text('HCOM 调试助手'), findsOneWidget);
    expect(find.text('HEX 原始'), findsOneWidget);
    expect(find.text('发送面板'), findsOneWidget);
    expect(find.text('清除日志'), findsOneWidget);
    expect(find.text('显示行号'), findsOneWidget);
    expect(find.text('可拖选复制'), findsOneWidget);
    expect(find.byType(SelectionArea), findsOneWidget);
    expect(find.text('周期'), findsOneWidget);
    expect(find.byIcon(Icons.timer), findsOneWidget);
    expect(find.byIcon(Icons.chevron_left), findsOneWidget);
    expect(find.byIcon(Icons.chevron_right), findsOneWidget);
  });

  testWidgets('updates the selected baud rate while disconnected',
      (tester) async {
    await tester.pumpWidget(const HcomApp());

    await tester.tap(find.text('115200'));
    await tester.pumpAndSettle();
    expect(find.text('9600'), findsOneWidget);

    await tester.tap(find.text('9600'));
    await tester.pumpAndSettle();
    expect(find.text('9600'), findsOneWidget);
  });

  testWidgets('collapses port configuration and keeps a compact send bar',
      (tester) async {
    await tester.pumpWidget(const HcomApp());

    await tester.tap(find.byTooltip('收起串口配置'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('展开串口配置'), findsOneWidget);

    await tester.tap(find.byTooltip('收起发送面板'));
    await tester.pumpAndSettle();
    expect(find.text('发送面板'), findsNothing);
    expect(find.byTooltip('展开完整发送面板'), findsOneWidget);
    expect(find.text('发送'), findsOneWidget);
  });

  testWidgets('collapses either vertical dock from its center control',
      (tester) async {
    await tester.pumpWidget(const HcomApp());

    await tester.tap(find.byTooltip('收起左侧 Dock'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('展开左侧 Dock'), findsOneWidget);

    await tester.tap(find.byTooltip('收起右侧 Dock'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('展开右侧 Dock'), findsOneWidget);
  });

  testWidgets('uses an explicit start icon for periodic sending',
      (tester) async {
    await tester.pumpWidget(const HcomApp());

    await tester.tap(find.text('周期'));
    await tester.pumpAndSettle();
    expect(find.text('开始周期'), findsOneWidget);
    expect(find.byIcon(Icons.play_arrow), findsOneWidget);
  });

  testWidgets('uses packaged Noto Sans SC as the Chinese fallback',
      (tester) async {
    await tester.pumpWidget(const HcomApp());

    final context = tester.element(find.text('HCOM 调试助手'));
    expect(Theme.of(context).textTheme.bodyMedium!.fontFamilyFallback,
        contains(HcomTheme.chineseFontFamily));
    expect(Theme.of(context).textTheme.bodyMedium!.fontFamily,
        HcomTheme.latinFontFamily);
  });

  testWidgets('opens the persisted log time-zone setting', (tester) async {
    await tester.pumpWidget(const HcomApp());

    await tester.tap(find.byTooltip('设置'));
    await tester.pumpAndSettle();
    expect(find.text('日志时间时区'), findsOneWidget);
    expect(find.text('UTC+08:00（中国标准时间）'), findsOneWidget);

    await tester.tap(find.text('修改时区'));
    await tester.pumpAndSettle();
    expect(find.text('选择时区'), findsOneWidget);
    expect(find.text('UTC-12:00'), findsOneWidget);
  });

  test('defaults log timestamps to China Standard Time', () {
    final timestamp = DateTime.utc(2026, 9, 11, 12, 17, 19, 450);

    expect(defaultTimeZoneOffsetMinutes, 480);
    expect(formatDisplayTimestamp(timestamp, defaultTimeZoneOffsetMinutes),
        '20:17:19.450');
    expect(formatDisplayTimestamp(timestamp, 0), '12:17:19.450');
  });

  test('copies selected HEX log rows as readable two-line records', () {
    final entries = [
      SerialEntry(
        direction: SerialDirection.rx,
        timestamp: DateTime.utc(2026, 9, 11, 12, 38, 53, 175),
        hex: 'AA 55 A0 00',
        label: 'Core',
      ),
      SerialEntry(
        direction: SerialDirection.tx,
        timestamp: DateTime.utc(2026, 9, 11, 12, 38, 53, 345),
        hex: '11 22 33 44',
        label: 'Core',
      ),
    ];
    final selectedText =
        entries.map((entry) => selectableLogEntryText(entry, 480)).join();

    expect(hexDirectionLabel(SerialDirection.rx), 'RX(HEX)');
    expect(hexDirectionLabel(SerialDirection.tx), 'TX(HEX)');
    expect(
      formatSelectedLogCopy(entries, selectedText, 480),
      '26-09-11 20:38:53.175 RX(HEX)\n'
      'AA 55 A0 00\n'
      '26-09-11 20:38:53.345 TX(HEX)\n'
      '11 22 33 44',
    );
  });
}
