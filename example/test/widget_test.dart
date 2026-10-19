import 'package:flutter_test/flutter_test.dart';
import 'package:openlv_example/main.dart';

void main() {
  testWidgets('renders the role tabs', (tester) async {
    await tester.pumpWidget(const OpenLvExampleApp());

    expect(find.text('dApp (host)'), findsOneWidget);
    expect(find.text('Wallet (client)'), findsOneWidget);
  });
}
