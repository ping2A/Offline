import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

Future<String?> saveBytes(Uint8List bytes, {required String fileName}) async {
  final dir = await getApplicationDocumentsDirectory();
  final path = '${dir.path}/$fileName';
  await File(path).writeAsBytes(bytes);
  return path;
}
