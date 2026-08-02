import 'dart:io';
import 'dart:typed_data';

Future<Uint8List> readRecordingBytes(String path) =>
    File(path).readAsBytes();

void revokeRecordingUrl(String path) {}
