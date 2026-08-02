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

String meshImageFileName(String? name) {
  final base = (name == null || name.trim().isEmpty) ? 'photo.jpg' : name.trim();
  if (base.toLowerCase().endsWith('.jpg') ||
      base.toLowerCase().endsWith('.jpeg')) {
    return base;
  }
  final dot = base.lastIndexOf('.');
  if (dot > 0) return '${base.substring(0, dot)}.jpg';
  return '$base.jpg';
}
