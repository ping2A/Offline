import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:offline/ui/mesh_audio_blob.dart';

/// Build a playable [Source] for mesh voice notes.
///
/// BitChat writes AAC-in-M4A (`audio/mp4`) to disk and plays the file path.
/// On web we mirror that with a blob: URL (or [BytesSource], which builds a
/// data URI *inside* audioplayers_web).
///
/// Do **not** pass a hand-built `data:` URI through [UrlSource] on web:
/// `AudioPlayer.setSourceUrl` runs `UriCoder.encodeOnce`, which percent-encodes
/// base64 `+` / `/` and breaks AAC/WAV playback.
Source meshAudioSource(Uint8List bytes, String mimeType) {
  final mime = normalizeMeshAudioMime(mimeType, bytes);
  if (kIsWeb) {
    final blobUrl = createMeshAudioBlobUrl(bytes, mime);
    if (blobUrl != null) {
      return UrlSource(blobUrl, mimeType: mime);
    }
  }
  return BytesSource(bytes, mimeType: mime);
}

/// Canonical MIME for BitChat voice notes + Offline WAV fallback.
String normalizeMeshAudioMime(String mimeType, Uint8List bytes) {
  var mime = mimeType.trim().toLowerCase();
  if (mime.isEmpty || mime == 'application/octet-stream') {
    mime = sniffMeshAudioMime(bytes) ?? 'audio/wav';
  }
  // Browsers and BitChat treat AAC-in-M4A as audio/mp4.
  if (mime == 'audio/m4a' || mime == 'audio/aac' || mime == 'audio/x-m4a') {
    return 'audio/mp4';
  }
  if (mime == 'audio/x-wav') return 'audio/wav';
  return mime;
}

String? sniffMeshAudioMime(Uint8List bytes) {
  if (bytes.length >= 12 &&
      bytes[0] == 0x52 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46 &&
      bytes[3] == 0x46 &&
      bytes[8] == 0x57 &&
      bytes[9] == 0x41 &&
      bytes[10] == 0x56 &&
      bytes[11] == 0x45) {
    return 'audio/wav';
  }
  if (bytes.length > 100) {
    final n = bytes.length < 64 ? bytes.length - 3 : 64;
    for (var i = 0; i < n; i++) {
      if (bytes[i] == 0x66 &&
          bytes[i + 1] == 0x74 &&
          bytes[i + 2] == 0x79 &&
          bytes[i + 3] == 0x70) {
        return 'audio/mp4';
      }
    }
  }
  if (bytes.length >= 4 &&
      bytes[0] == 0x4F &&
      bytes[1] == 0x67 &&
      bytes[2] == 0x67 &&
      bytes[3] == 0x53) {
    return 'audio/ogg';
  }
  return null;
}
