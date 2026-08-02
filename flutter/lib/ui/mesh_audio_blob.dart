import 'dart:typed_data';

import 'mesh_audio_blob_stub.dart'
    if (dart.library.js_interop) 'mesh_audio_blob_web.dart' as impl;

String? createMeshAudioBlobUrl(Uint8List bytes, String mimeType) =>
    impl.createMeshAudioBlobUrl(bytes, mimeType);

void revokeMeshAudioBlobUrl(String? url) => impl.revokeMeshAudioBlobUrl(url);
