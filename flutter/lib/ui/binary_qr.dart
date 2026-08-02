import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:qr/qr.dart';

/// Renders a QR code from raw bytes (byte mode), not a UTF-8 string.
///
/// Encodes the QR once when [data] changes, then paints with a single path.
class BinaryQrView extends StatelessWidget {
  const BinaryQrView({
    super.key,
    required this.data,
    this.padding = 12,
  });

  final Uint8List data;
  final double padding;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _BinaryQrPainter(
        matrix: _QrMatrix.encodeBytes(data),
        padding: padding,
      ),
      child: const SizedBox.expand(),
    );
  }
}

/// QR from a UTF-8 / ASCII string (e.g. share URIs). Phone scanners show the text.
class TextQrView extends StatelessWidget {
  const TextQrView({
    super.key,
    required this.data,
    this.padding = 14,
  });

  final String data;
  final double padding;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _BinaryQrPainter(
        matrix: _QrMatrix.encodeBytes(Uint8List.fromList(utf8.encode(data))),
        padding: padding,
      ),
      child: const SizedBox.expand(),
    );
  }
}

class _QrMatrix {
  _QrMatrix({required this.moduleCount, required this.path});

  final int moduleCount;
  final Path path;

  factory _QrMatrix.encodeBytes(Uint8List data) {
    final qrCode = QrCode.fromUint8List(
      data: data,
      errorCorrectLevel: QrErrorCorrectLevel.M,
    );
    final qrImage = QrImage(qrCode);
    final n = qrImage.moduleCount;
    final path = Path();
    for (var y = 0; y < n; y++) {
      for (var x = 0; x < n; x++) {
        if (qrImage.isDark(y, x)) {
          path.addRect(Rect.fromLTWH(x.toDouble(), y.toDouble(), 1, 1));
        }
      }
    }
    return _QrMatrix(moduleCount: n, path: path);
  }
}

class _BinaryQrPainter extends CustomPainter {
  _BinaryQrPainter({required this.matrix, required this.padding});

  final _QrMatrix matrix;
  final double padding;

  static final _bg = Paint()..color = const Color(0xFFFFFFFF);
  static final _fg = Paint()
    ..color = const Color(0xFF000000)
    ..style = PaintingStyle.fill
    ..isAntiAlias = false;

  @override
  void paint(Canvas canvas, Size size) {
    final n = matrix.moduleCount;
    final side = size.shortestSide - padding * 2;
    final cell = side / n;
    final origin = Offset(
      (size.width - side) / 2,
      (size.height - side) / 2,
    );

    canvas.drawRect(Offset.zero & size, _bg);
    canvas.save();
    canvas.translate(origin.dx, origin.dy);
    canvas.scale(cell, cell);
    canvas.drawPath(matrix.path, _fg);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _BinaryQrPainter oldDelegate) =>
      !identical(oldDelegate.matrix, matrix) || oldDelegate.padding != padding;
}
