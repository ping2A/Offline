import 'dart:math';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// BitChat `ImageUtils.targetImageBytes` (~45 KiB). Larger JPEGs explode into
/// >256 BLE fragments; current Android BitChat rejects those trains.
const kMaxMeshImageBytes = 45 * 1024;

/// BitChat `ImageUtils` default max edge.
const kMaxMeshImageEdge = 448;

/// Decode and re-encode as JPEG under [maxBytes], matching BitChat's mesh photo
/// pipeline (scale ≤448px, quality ladder down to ~0.3).
Uint8List? compressMeshJpeg(
  Uint8List raw, {
  int maxBytes = kMaxMeshImageBytes,
  int maxEdge = kMaxMeshImageEdge,
}) {
  final decoded = img.decodeImage(raw);
  if (decoded == null) return null;

  var image = decoded;
  if (image.width > maxEdge || image.height > maxEdge) {
    image = img.copyResize(
      image,
      width: image.width >= image.height ? maxEdge : null,
      height: image.height > image.width ? maxEdge : null,
      interpolation: img.Interpolation.average,
    );
  }

  for (final quality in [82, 70, 55, 40, 30]) {
    final encoded = Uint8List.fromList(img.encodeJpg(image, quality: quality));
    // BitChat MimeType.matches requires JPEG SOI (FF D8 FF).
    if (encoded.length <= maxBytes && _isJpeg(encoded)) return encoded;
  }

  // Last resort: shrink dimensions further.
  var edge = maxEdge ~/ 2;
  while (edge >= 160) {
    final smaller = img.copyResize(
      image,
      width: image.width >= image.height ? edge : null,
      height: image.height > image.width ? edge : null,
      interpolation: img.Interpolation.average,
    );
    for (final quality in [40, 30, 22]) {
      final encoded =
          Uint8List.fromList(img.encodeJpg(smaller, quality: quality));
      if (encoded.length <= maxBytes && _isJpeg(encoded)) return encoded;
    }
    edge ~/= 2;
  }
  return null;
}

bool _isJpeg(Uint8List bytes) =>
    bytes.length >= 3 && bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF;

/// BitChat `ImageUtils`: `img_yyyyMMdd_HHmmss_<UUID>.jpg` (receipt-eligible).
String meshImageFileName([String? _ignored]) {
  final now = DateTime.now();
  String two(int n) => n.toString().padLeft(2, '0');
  final stamp =
      '${now.year}${two(now.month)}${two(now.day)}_'
      '${two(now.hour)}${two(now.minute)}${two(now.second)}';
  // RFC-4122 string form required by BitChat stable-media identity.
  final bytes = List<int>.generate(16, (_) => Random().nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  final uuid =
      '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-'
      '${hex.substring(16, 20)}-${hex.substring(20)}';
  return 'img_${stamp}_$uuid.jpg';
}
