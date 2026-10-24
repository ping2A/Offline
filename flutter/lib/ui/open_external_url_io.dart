import 'dart:io' show Platform, Process;

/// Opens [url] in the system browser on desktop; returns false on mobile
/// (caller should fall back to clipboard).
Future<bool> openExternalUrl(String url) async {
  try {
    if (Platform.isMacOS) {
      final r = await Process.run('open', [url]);
      return r.exitCode == 0;
    }
    if (Platform.isLinux) {
      final r = await Process.run('xdg-open', [url]);
      return r.exitCode == 0;
    }
    if (Platform.isWindows) {
      final r = await Process.run('cmd', ['/c', 'start', '', url]);
      return r.exitCode == 0;
    }
  } catch (_) {
    return false;
  }
  return false;
}
