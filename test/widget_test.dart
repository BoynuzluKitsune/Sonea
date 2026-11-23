import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  testWidgets('library surface renders', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: Center(child: Text('Library')))));
    expect(find.text('Library'), findsOneWidget);
  });
}
