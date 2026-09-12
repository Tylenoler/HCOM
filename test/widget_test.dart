import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hcom/main.dart';
import 'package:hcom/models/log_copy.dart';
import 'package:hcom/models/log_export.dart';
import 'package:hcom/models/receive_framer.dart';
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
    expect(find.text('手动保存'), findsOneWidget);
    expect(find.text('实时保存'), findsOneWidget);
    expect(find.text('可拖选复制'), findsOneWidget);
    expect(find.byType(SelectionArea), findsOneWidget);
    expect(find.text('周期'), findsOneWidget);
    expect(find.byIcon(Icons.timer), findsOneWidget);
    expect(find.byIcon(Icons.chevron_left), findsOneWidget);
    expect(find.byIcon(Icons.chevron_right), findsOneWidget);
    expect(find.byKey(const ValueKey('queue-editor-panel')), findsNothing);
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

    final leftBefore = tester.getCenter(find.byTooltip('收起左侧 Dock')).dy;
    final leftBodyBefore =
        tester.getCenter(find.byKey(const ValueKey('left-dock-body'))).dy;
    expect((leftBodyBefore - leftBefore).abs(), lessThanOrEqualTo(1));
    await tester.tap(find.byTooltip('收起左侧 Dock'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('展开左侧 Dock'), findsOneWidget);
    final leftAfter = tester.getCenter(find.byTooltip('展开左侧 Dock')).dy;
    expect((leftAfter - leftBefore).abs(), lessThanOrEqualTo(1));
    final leftBodyAfter =
        tester.getCenter(find.byKey(const ValueKey('left-dock-body'))).dy;
    expect((leftBodyAfter - leftAfter).abs(), lessThanOrEqualTo(1));

    final rightBefore = tester.getCenter(find.byTooltip('收起右侧 Dock')).dy;
    final rightBodyBefore =
        tester.getCenter(find.byKey(const ValueKey('right-dock-body'))).dy;
    expect((rightBodyBefore - rightBefore).abs(), lessThanOrEqualTo(1));
    await tester.tap(find.byTooltip('收起右侧 Dock'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('展开右侧 Dock'), findsOneWidget);
    final rightAfter = tester.getCenter(find.byTooltip('展开右侧 Dock')).dy;
    expect((rightAfter - rightBefore).abs(), lessThanOrEqualTo(1));
    final rightBodyAfter =
        tester.getCenter(find.byKey(const ValueKey('right-dock-body'))).dy;
    expect((rightBodyAfter - rightAfter).abs(), lessThanOrEqualTo(1));
  });

  testWidgets('uses an explicit start icon for periodic sending',
      (tester) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const HcomApp());

    await tester.tap(find.text('周期'));
    await tester.pumpAndSettle();
    expect(find.text('开始周期'), findsOneWidget);
    expect(find.byIcon(Icons.play_arrow), findsOneWidget);
    expect(find.byKey(const ValueKey('queue-editor-panel')), findsNothing);
  });

  testWidgets('opens the queue editor in the right half of a wide workspace',
      (tester) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const HcomApp());

    await tester.tap(find.text('循环'));
    await tester.pumpAndSettle();

    final panel = find.byKey(const ValueKey('queue-editor-panel'));
    expect(panel, findsOneWidget);
    expect(tester.getTopLeft(panel).dx, greaterThan(960));
    expect(find.byType(Checkbox), findsNWidgets(2));
  });

  testWidgets('splits receive and queue panels evenly in a half-screen window',
      (tester) async {
    tester.view.physicalSize = const Size(960, 768);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const HcomApp());
    await tester.tap(find.text('顺序'));
    await tester.pumpAndSettle();

    final queue = find.byKey(const ValueKey('queue-editor-panel'));
    final receive = find.byKey(const ValueKey('receive-stream'));
    expect(queue, findsOneWidget);
    expect(
      (tester.getSize(queue).width - tester.getSize(receive).width).abs(),
      lessThanOrEqualTo(16),
    );
  });

  testWidgets('rejects queue expansion below 600 px without selecting a mode',
      (tester) async {
    tester.view.physicalSize = const Size(599, 768);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const HcomApp());

    await tester.tap(find.text('顺序'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('queue-editor-panel')), findsNothing);
    expect(find.text('当前界面小于 600px，无法展开队列编辑。'), findsOneWidget);
    expect(find.text('发送已选'), findsNothing);
  });

  testWidgets(
      'links receive format after three send toggles and keeps it synchronized',
      (tester) async {
    await tester.pumpWidget(const HcomApp());

    await tester.tap(find.text('普通'));
    await tester.pumpAndSettle();
    expect(find.text('HEX 原始'), findsOneWidget);
    expect(find.text('HEX 实时数据'), findsOneWidget);
    expect(find.text('输入普通文本，将以 UTF-8 编码发送'), findsOneWidget);

    await tester.tap(find.text('HEX'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('普通'));
    await tester.pumpAndSettle();
    expect(find.text('文本 原始'), findsOneWidget);
    expect(find.text('发送与接收格式已开启联动；以后切换发送格式会立即同步接收格式'), findsOneWidget);

    // Once linked, every send-format change immediately updates reception.
    await tester.tap(find.text('HEX'));
    await tester.pumpAndSettle();
    expect(find.text('HEX 原始'), findsOneWidget);
    expect(find.text('HEX 实时数据'), findsOneWidget);

    // Choosing a receive format directly makes it independent again.
    await tester.tap(find.text('HEX 原始'));
    await tester.pumpAndSettle();
    expect(find.text('文本 原始'), findsOneWidget);
    expect(find.text('文本 实时数据'), findsOneWidget);

    await tester.tap(find.text('HEX'));
    await tester.pumpAndSettle();
    expect(find.text('文本 原始'), findsOneWidget);
  });

  testWidgets('protects queue deletion with a second click or confirmation',
      (tester) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const HcomApp());
    await tester.tap(find.text('顺序'));
    await tester.pumpAndSettle();

    final delete = find.byTooltip('删除命令：单击确认，450 ms 内再点直接删除');
    expect(delete, findsNWidgets(2));
    await tester.tap(delete.first);
    await tester.pump(const Duration(milliseconds: 300));
    final armed = find.byTooltip('再点一次立即删除');
    expect(armed, findsOneWidget);
    await tester.tap(armed);
    await tester.pumpAndSettle();
    expect(find.byTooltip('删除命令：单击确认，450 ms 内再点直接删除'), findsOneWidget);

    await tester.tap(find.byTooltip('删除命令：单击确认，450 ms 内再点直接删除'));
    await tester.pump(const Duration(milliseconds: 450));
    await tester.pumpAndSettle();
    expect(find.text('删除队列命令？'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
  });

  testWidgets(
      'moves the full queue row instead of retaining its old input state',
      (tester) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const HcomApp());
    await tester.tap(find.text('顺序'));
    await tester.pumpAndSettle();

    final heartbeat = find.text('心跳');
    final before = tester.getTopLeft(heartbeat).dy;
    await tester.tap(find.byTooltip('下移命令').first);
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(heartbeat).dy, greaterThan(before));
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
    expect(find.text('启动默认值'), findsOneWidget);
    expect(find.text('左侧 Dock'), findsOneWidget);
    expect(find.text('右侧 Dock'), findsOneWidget);
    expect(find.text('队列编辑面板'), findsOneWidget);

    await tester.tap(find.text('修改时区'));
    await tester.pumpAndSettle();
    expect(find.text('选择时区'), findsOneWidget);
    expect(find.text('UTC-12:00'), findsOneWidget);
  });

  testWidgets('uses rounded hover states for menu options', (tester) async {
    await tester.pumpWidget(const HcomApp());

    await tester.tap(find.text('分包 · 自动识别'));
    await tester.pumpAndSettle();
    final field = find.text('自动识别');
    final anchor = tester.widget<MenuAnchor>(
      find.ancestor(of: field, matching: find.byType(MenuAnchor)).first,
    );
    final surfaceShape = anchor.style!.shape!.resolve({});
    expect(surfaceShape, isA<RoundedRectangleBorder>());
    expect(
      (surfaceShape! as RoundedRectangleBorder).borderRadius,
      BorderRadius.circular(16),
    );

    await tester.tap(field);
    await tester.pumpAndSettle();
    final menuItem =
        tester.widget<MenuItemButton>(find.byType(MenuItemButton).first);
    final itemShape = menuItem.style!.shape!.resolve({WidgetState.hovered});
    expect(itemShape, isA<RoundedRectangleBorder>());
    expect(
      (itemShape! as RoundedRectangleBorder).borderRadius,
      BorderRadius.circular(10),
    );
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

  test('exports logs as CSV and TXT records', () {
    final entries = [
      SerialEntry(
        direction: SerialDirection.rx,
        timestamp: DateTime.utc(2026, 9, 11, 12, 38, 53, 175),
        hex: 'AA 55 A0 00',
        label: 'Core',
      ),
    ];

    final csv = serializeLogEntries(
      entries,
      LogFileFormat.csv,
      defaultTimeZoneOffsetMinutes,
    );
    expect(csv, contains('timestamp,direction,format,byte_count,data'));
    expect(csv, contains('26-09-11 20:38:53.175,RX,HEX,4,"AA 55 A0 00"'));

    final txt = serializeLogEntries(
      entries,
      LogFileFormat.txt,
      defaultTimeZoneOffsetMinutes,
    );
    expect(txt, '26-09-11 20:38:53.175 RX(HEX)\nAA 55 A0 00\n');
  });

  test('automatically splits a transport batch by the learned packet length',
      () {
    final framer = ReceiveFramer();
    final time = DateTime.utc(2026, 9, 12, 8, 38, 41);
    for (var index = 0; index < 3; index++) {
      expect(framer.addHex('01 02 03 04', time), hasLength(1));
    }

    final frames = framer.addHex('AA 55 55 AA 10 20 30 40', time);
    expect(frames.map((frame) => frame.hex), ['AA 55 55 AA', '10 20 30 40']);
  });

  test('fixed-length framing spans arbitrary transport reads', () {
    final framer = ReceiveFramer(const ReceiveFramingConfig(
        mode: ReceiveFramingMode.fixedLength, fixedLength: 4));
    final time = DateTime.utc(2026, 9, 12, 8, 38, 41);

    expect(framer.addHex('AA 55', time), isEmpty);
    final frames = framer.addHex('55 AA 11 22 33 44', time);
    expect(frames.map((frame) => frame.hex), ['AA 55 55 AA', '11 22 33 44']);
  });

  test('delimiter framing supports protocol-specific heads and tails', () {
    final framer = ReceiveFramer(const ReceiveFramingConfig(
      mode: ReceiveFramingMode.delimiters,
      headerHex: '7E 01',
      trailerHex: '0D 0A',
    ));
    final time = DateTime.utc(2026, 9, 12, 8, 38, 41);

    expect(framer.addHex('7E 01 10', time), isEmpty);
    final frames = framer.addHex('20 0D 0A 7E 01 30 0D 0A', time);
    expect(frames.map((frame) => frame.hex),
        ['7E 01 10 20 0D 0A', '7E 01 30 0D 0A']);
  });
}
