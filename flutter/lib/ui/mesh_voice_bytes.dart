import 'dart:typed_data';

import 'mesh_voice_bytes_stub.dart'
    if (dart.library.io) 'mesh_voice_bytes_io.dart'
    if (dart.library.js_interop) 'mesh_voice_bytes_web.dart' as impl;

Future<Uint8List> readRecordingBytes(String path) =>
    impl.readRecordingBytes(path);

void revokeRecordingUrl(String path) => impl.revokeRecordingUrl(path);
