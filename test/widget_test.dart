import 'package:flutter_test/flutter_test.dart';

import 'package:noise_map_collector/main.dart';

void main() {
  testWidgets('Noise collector home screen renders', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const MyApp());
    await tester.pump();

    expect(find.text('Noise Map Collector'), findsWidgets);
    expect(find.text('Start'), findsOneWidget);
    expect(find.text('Stop & Save'), findsOneWidget);
    expect(find.text('CSV Tools'), findsWidgets);
    expect(find.text('Collector'), findsOneWidget);
    expect(find.textContaining('Altitude'), findsWidgets);

    await tester.tap(find.text('CSV Tools').last);
    await tester.pumpAndSettle();

    expect(find.text('CSV Tools'), findsWidgets);
    expect(find.text('Merge All CSV'), findsOneWidget);
  });
}
