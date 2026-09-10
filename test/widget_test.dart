import 'package:flutter_test/flutter_test.dart';
import 'package:hcom/main.dart';

void main() {
  testWidgets('renders the Phase 1 UART workbench', (tester) async {
    await tester.pumpWidget(const HcomApp());

    expect(find.text('HCOM 调试助手'), findsOneWidget);
    expect(find.text('HEX 原始'), findsOneWidget);
    expect(find.text('发送面板'), findsOneWidget);
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
}
