import 'package:flutter/material.dart';
import 'package:offline/src/rust/frb_generated.dart';
import 'package:offline/ui/app_theme.dart';
import 'package:offline/ui/home_page.dart';
import 'package:offline/ui/identity_store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init();
  final identity = await IdentityStore.loadOrCreate();
  runApp(OfflineApp(identity: identity));
}

class OfflineApp extends StatelessWidget {
  const OfflineApp({super.key, required this.identity});

  final StoredIdentity identity;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Offline',
      debugShowCheckedModeBanner: false,
      theme: buildOfflineTheme(),
      themeMode: ThemeMode.dark,
      home: HomePage(identity: identity),
    );
  }
}
