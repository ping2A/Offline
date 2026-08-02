import 'package:flutter_test/flutter_test.dart';
import 'package:offline/src/rust/api/simple.dart';
import 'package:offline/src/rust/frb_generated.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await RustLib.init();
  });

  test('Rust greet is reachable', () {
    expect(greet(name: 'Offline'), contains('Offline'));
  });
}
