import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart';

/// BitChat-style "play from a file URL": object URL over a Blob with the
/// declared MIME (`audio/mp4` for AAC voice notes).
String? createMeshAudioBlobUrl(Uint8List bytes, String mimeType) {
  if (bytes.isEmpty) return null;
  final parts = <BlobPart>[bytes.toJS].toJS;
  final blob = Blob(parts, BlobPropertyBag(type: mimeType));
  return URL.createObjectURL(blob);
}

void revokeMeshAudioBlobUrl(String? url) {
  if (url == null || !url.startsWith('blob:')) return;
  URL.revokeObjectURL(url);
}
