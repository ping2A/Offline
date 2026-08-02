import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:offline/src/rust/api/optical.dart';
import 'package:offline/ui/save_bytes.dart';

class OpticalReceivePage extends StatefulWidget {
  const OpticalReceivePage({super.key});

  @override
  State<OpticalReceivePage> createState() => _OpticalReceivePageState();
}

class _OpticalReceivePageState extends State<OpticalReceivePage> {
  late final OpticalReceiveSession _session = opticalStartReceive();
  late final MobileScannerController _controller = MobileScannerController(
    detectionSpeed: DetectionSpeed.unrestricted,
    returnImage: false,
    formats: const [BarcodeFormat.qrCode],
  );

  BigInt _collected = BigInt.zero;
  BigInt _target = BigInt.one;
  Uint8List? _payload;
  String? _error;
  bool _saving = false;
  final Set<String> _recent = {};

  @override
  void dispose() {
    _controller.dispose();
    _session.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_payload != null) return;
    for (final barcode in capture.barcodes) {
      final bytes = _extractBytes(barcode);
      if (bytes == null || bytes.isEmpty) continue;
      // Deduplicate identical frames in the UI thread burst.
      final key =
          '${bytes.length}:${bytes[0]}:${bytes[bytes.length - 1]}:${bytes[bytes.length ~/ 2]}';
      if (!_recent.add(key)) continue;
      if (_recent.length > 64) _recent.clear();

      try {
        final progress = _session.ingestFrame(frame: bytes);
        setState(() {
          _collected = progress.framesCollected;
          _target = progress.framesTarget == BigInt.zero
              ? BigInt.one
              : progress.framesTarget;
          _error = null;
          if (progress.completePayload != null) {
            _payload = progress.completePayload;
            _controller.stop();
          }
        });
      } catch (e) {
        // Ignore non-offline frames (other QR codes in view).
        if (e.toString().contains('invalid frame') ||
            e.toString().contains('InvalidFrame')) {
          continue;
        }
        setState(() => _error = e.toString());
      }
    }
  }

  static Uint8List? _extractBytes(Barcode barcode) {
    switch (barcode.rawDecodedBytes) {
      case DecodedBarcodeBytes(:final bytes):
        return bytes;
      case DecodedVisionBarcodeBytes(:final bytes, :final rawBytes):
        return bytes ?? rawBytes;
      case null:
        // ignore: deprecated_member_use
        return barcode.rawBytes;
    }
  }

  Future<void> _save() async {
    final payload = _payload;
    if (payload == null) return;
    setState(() => _saving = true);
    try {
      final name =
          'offline-received-${DateTime.now().millisecondsSinceEpoch}.bin';
      final where = await saveBytes(payload, fileName: name);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              where == null
                  ? 'Saved ${payload.length} bytes'
                  : kIsWeb
                      ? 'Downloaded $where (${payload.length} bytes)'
                      : 'Saved ${payload.length} bytes to $where',
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final done = _payload != null;
    final progress = (_collected.toDouble() / _target.toDouble()).clamp(0.0, 1.0);

    return Scaffold(
      appBar: AppBar(title: const Text('Receive optically')),
      body: Column(
        children: [
          Expanded(
            child: done
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.check_circle, size: 64, color: Colors.green),
                          const SizedBox(height: 16),
                          Text(
                            'Transfer complete',
                            style: Theme.of(context).textTheme.headlineSmall,
                          ),
                          Text('${_payload!.length} bytes verified'),
                          const SizedBox(height: 24),
                          FilledButton(
                            onPressed: _saving ? null : _save,
                            child: Text(
                              _saving
                                  ? 'Saving…'
                                  : (kIsWeb ? 'Download file' : 'Save file'),
                            ),
                          ),
                          const SizedBox(height: 8),
                          TextButton(
                            onPressed: () {
                              setState(() {
                                _payload = null;
                                _collected = BigInt.zero;
                                _error = null;
                              });
                              _controller.start();
                            },
                            child: const Text('Receive another'),
                          ),
                        ],
                      ),
                    ),
                  )
                : MobileScanner(
                    controller: _controller,
                    onDetect: _onDetect,
                  ),
          ),
          Material(
            elevation: 4,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    done
                        ? 'Done'
                        : 'Frames collected: $_collected / ~$_target',
                  ),
                  const SizedBox(height: 8),
                  LinearProgressIndicator(value: done ? 1 : progress),
                  if (_error != null) ...[
                    const SizedBox(height: 8),
                    Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                  ],
                  const SizedBox(height: 8),
                  Text(
                    'Point at the sender’s QR stream. Progress tracks frames, not blocks.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
