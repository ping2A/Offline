import 'package:flutter/material.dart';
import 'package:offline/ui/app_theme.dart';

/// BitChat reserves orange for the local user.
const Color kMeshSelfColor = Color(0xFFFF9F0A);

/// Stable peer color from a seed (peer ID / nickname), matching BitChat's
/// djb2 → HSV approach (orange reserved for self).
Color meshPeerColor(String seed, {bool isDark = true}) {
  var hash = 5381;
  final bytes = seed.codeUnits;
  for (final b in bytes) {
    hash = ((hash << 5) + hash) + (b & 0xff);
    hash &= 0x7fffffff;
  }

  var hue = (hash % 360) / 360.0;
  const orange = 30.0 / 360.0;
  if ((hue - orange).abs() < 0.05) {
    hue = (hue + 0.12) % 1.0;
  }

  final sat = isDark ? 0.55 : 0.70;
  final value = isDark ? 0.82 : 0.42;
  return HSVColor.fromAHSV(1, hue * 360, sat, value).toColor();
}

Color meshSenderColor({
  required bool isLocal,
  required String peerId,
}) {
  if (isLocal) return kMeshSelfColor;
  return meshPeerColor(peerId);
}

String meshFormatChatTime(int timestampMs) {
  final t = DateTime.fromMillisecondsSinceEpoch(timestampMs);
  final hh = t.hour.toString().padLeft(2, '0');
  final mm = t.minute.toString().padLeft(2, '0');
  return '$hh:$mm';
}

/// Soft body color derived from the sender accent (BitChat tints content).
Color meshBodyColor(Color sender, {bool isPrivate = false}) {
  if (isPrivate) {
    return Color.lerp(sender, OfflineColors.ink, 0.35) ?? OfflineColors.ink;
  }
  return Color.lerp(sender, OfflineColors.ink, 0.45) ?? OfflineColors.ink;
}
