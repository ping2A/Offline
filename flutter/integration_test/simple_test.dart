import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:offline/src/rust/api/simple.dart';
import 'package:offline/src/rust/frb_generated.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await RustLib.init();
  });

  testWidgets('Rust FFI works', (tester) async {
    expect(greet(name: 'Tom'), contains('Tom'));
  });
}
