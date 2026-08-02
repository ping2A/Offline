import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart';

Future<Uint8List> readRecordingBytes(String path) async {
  final response = await window.fetch(path.toJS).toDart;
  if (!(response.ok)) {
    throw StateError('Failed to read recording (${response.status})');
  }
  final jsBuffer = await response.arrayBuffer().toDart;
  final byteBuffer = jsBuffer.toDart;
  return byteBuffer.asUint8List();
}

void revokeRecordingUrl(String path) {
  if (path.startsWith('blob:')) {
    URL.revokeObjectURL(path);
  }
}
