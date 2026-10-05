import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:qr/qr.dart';

/// Renders a QR code from raw bytes (byte mode), not a UTF-8 string.
///
/// Encodes the QR once when [data] changes, then paints with integer-sized
/// modules (avoids blurry sub-pixel cells that phone cameras cannot read).
class BinaryQrView extends StatelessWidget {
  const BinaryQrView({
    super.key,
    required this.data,
    this.paddingModules = 4,
    this.errorCorrectLevel = QrErrorCorrectLevel.M,
  });

  final Uint8List data;
  /// Quiet zone in modules (QR spec minimum is 4).
  final int paddingModules;
  final int errorCorrectLevel;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _BinaryQrPainter(
        matrix: _QrMatrix.encodeBytes(data, errorCorrectLevel),
        paddingModules: paddingModules,
        dpr: MediaQuery.devicePixelRatioOf(context),
      ),
      child: const SizedBox.expand(),
    );
  }
}

/// QR from a UTF-8 / ASCII string (e.g. BitChat / Offline share URIs).
class TextQrView extends StatelessWidget {
  const TextQrView({
    super.key,
    required this.data,
    this.paddingModules = 4,
    /// Prefer L for long URLs so modules stay large enough to scan off a screen.
    this.errorCorrectLevel = QrErrorCorrectLevel.L,
  });

  final String data;
  final int paddingModules;
  final int errorCorrectLevel;

  @override
  Widget build(BuildContext context) {
    return BinaryQrView(
      data: Uint8List.fromList(utf8.encode(data)),
      paddingModules: paddingModules,
      errorCorrectLevel: errorCorrectLevel,
    );
  }
}

class _QrMatrix {
  _QrMatrix({required this.moduleCount, required this.dark});

  final int moduleCount;
  final List<bool> dark; // row-major, length moduleCount²

  factory _QrMatrix.encodeBytes(Uint8List data, int errorCorrectLevel) {
    final qrCode = QrCode.fromUint8List(
      data: data,
      errorCorrectLevel: errorCorrectLevel,
    );
    final qrImage = QrImage(qrCode);
    final n = qrImage.moduleCount;
    final dark = List<bool>.filled(n * n, false);
    for (var y = 0; y < n; y++) {
      for (var x = 0; x < n; x++) {
        dark[y * n + x] = qrImage.isDark(y, x);
      }
    }
    return _QrMatrix(moduleCount: n, dark: dark);
  }
}

class _BinaryQrPainter extends CustomPainter {
  _BinaryQrPainter({
    required this.matrix,
    required this.paddingModules,
    required this.dpr,
  });

  final _QrMatrix matrix;
  final int paddingModules;
  final double dpr;

  static final _bg = Paint()..color = const Color(0xFFFFFFFF);
  static final _fg = Paint()
    ..color = const Color(0xFF000000)
    ..style = PaintingStyle.fill
    ..isAntiAlias = false
    ..filterQuality = FilterQuality.none;

  @override
  void paint(Canvas canvas, Size size) {
    final n = matrix.moduleCount;
    final total = n + paddingModules * 2;
    // Snap module size to whole device pixels so web/GPU don't blur edges.
    final maxSide = math.min(size.width, size.height);
    final rawCell = maxSide / total;
    final cellPx = math.max(1.0, (rawCell * dpr).floorToDouble()) / dpr;
    final side = cellPx * total;
    final origin = Offset(
      ((size.width - side) / 2).floorToDouble(),
      ((size.height - side) / 2).floorToDouble(),
    );

    canvas.drawRect(Offset.zero & size, _bg);

    final path = Path();
    for (var y = 0; y < n; y++) {
      for (var x = 0; x < n; x++) {
        if (!matrix.dark[y * n + x]) continue;
        path.addRect(
          Rect.fromLTWH(
            origin.dx + (x + paddingModules) * cellPx,
            origin.dy + (y + paddingModules) * cellPx,
            cellPx,
            cellPx,
          ),
        );
      }
    }
    canvas.drawPath(path, _fg);
  }

  @override
  bool shouldRepaint(covariant _BinaryQrPainter oldDelegate) =>
      !identical(oldDelegate.matrix, matrix) ||
      oldDelegate.paddingModules != paddingModules ||
      oldDelegate.dpr != dpr;
}

/// Full-screen black/white QR for reliable phone scanning.
Future<void> showLargeQrDialog(
  BuildContext context, {
  required String data,
  String title = 'Scan QR',
}) {
  return showDialog<void>(
    context: context,
    barrierColor: const Color(0xEE000000),
    builder: (ctx) {
      final side = math.min(MediaQuery.sizeOf(ctx).shortestSide - 48, 420.0);
      return Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              title,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 12),
            Material(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: SizedBox(
                  width: side,
                  height: side,
                  child: TextQrView(data: data),
                ),
              ),
            ),
            const SizedBox(height: 12),
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Close', style: TextStyle(color: Colors.white)),
            ),
          ],
        ),
      );
    },
  );
}
