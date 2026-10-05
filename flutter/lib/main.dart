import 'package:flutter/material.dart';
import 'package:offline/src/rust/frb_generated.dart';
import 'package:offline/ui/app_theme.dart';
import 'package:offline/ui/home_page.dart';
import 'package:offline/ui/identity_store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init();
  await OfflineThemeController.instance.load();
  final identity = await IdentityStore.loadOrCreate();
  runApp(OfflineApp(identity: identity));
}

class OfflineApp extends StatefulWidget {
  const OfflineApp({super.key, required this.identity});

  final StoredIdentity identity;

  @override
  State<OfflineApp> createState() => _OfflineAppState();
}

class _OfflineAppState extends State<OfflineApp> {
  late final Widget _home = HomePage(identity: widget.identity);

  @override
  void initState() {
    super.initState();
    OfflineThemeController.instance.addListener(_onTheme);
  }

  @override
  void dispose() {
    OfflineThemeController.instance.removeListener(_onTheme);
    super.dispose();
  }

  void _onTheme() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final palette = OfflineThemeController.instance.palette;
    return MaterialApp(
      title: 'Offline',
      debugShowCheckedModeBanner: false,
      theme: buildOfflineTheme(palette),
      themeMode: palette.brightness == Brightness.dark
          ? ThemeMode.dark
          : ThemeMode.light,
      home: _home,
    );
  }
}
