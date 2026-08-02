import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:offline/src/rust/api/optical.dart';
import 'package:offline/ui/app_theme.dart';
import 'package:offline/ui/binary_qr.dart';

class OpticalSendPage extends StatefulWidget {
  const OpticalSendPage({super.key});

  @override
  State<OpticalSendPage> createState() => _OpticalSendPageState();
}

class _OpticalSendPageState extends State<OpticalSendPage>
    with SingleTickerProviderStateMixin {
  OpticalSendSession? _session;
  String? _fileName;
  int _framesSent = 0;
  int _fps = 8;
  bool _busy = false;

  /// Only the QR pane listens to this — avoids rebuilding chrome every frame.
  final ValueNotifier<Uint8List?> _frame = ValueNotifier<Uint8List?>(null);

  Ticker? _ticker;
  Duration _lastTick = Duration.zero;

  @override
  void dispose() {
    _stopTicker();
    _frame.dispose();
    _session?.dispose();
    super.dispose();
  }

  static int _sourceBlocks(OpticalSendSession session) {
    final blockLen = session.blockLen();
    final total = session.totalLen();
    if (blockLen <= 0) return 1;
    return ((total + blockLen - 1) ~/ blockLen).clamp(1, 0xffff);
  }

  static int _recommendedFrames(OpticalSendSession session) {
    return (_sourceBlocks(session) * 1.15).ceil().clamp(1, 1 << 30);
  }

  void _stopTicker() {
    _ticker?.dispose();
    _ticker = null;
    _lastTick = Duration.zero;
  }

  void _ensureTicker() {
    _stopTicker();
    _ticker = createTicker(_onTick)..start();
  }

  void _onTick(Duration elapsed) {
    final session = _session;
    if (session == null) return;

    final intervalMs = (1000 / _fps).round().clamp(40, 250);
    if (elapsed - _lastTick < Duration(milliseconds: intervalMs)) {
      return;
    }
    _lastTick = elapsed;

    // Encode next fountain frame; QR paint work stays in BinaryQrView.
    final bytes = session.nextFrame();
    _frame.value = bytes;
    _framesSent++;

    // Progress text/bar: throttle UI rebuilds (~4 Hz).
    if (_framesSent == 1 || _framesSent % 4 == 0) {
      setState(() {});
    }
  }

  Future<void> _pickAndStart() async {
    setState(() => _busy = true);
    try {
      final result = await FilePicker.pickFiles(withData: true);
      if (result == null || result.files.isEmpty) return;
      final file = result.files.first;
      final bytes = file.bytes;
      if (bytes == null || bytes.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Could not read file bytes')),
          );
        }
        return;
      }
      _stopTicker();
      _session?.dispose();

      final session = opticalStartSend(
        payload: bytes,
        blockLen: opticalDefaultBlockLen(),
      );
      final first = session.nextFrame();
      setState(() {
        _session = session;
        _fileName = file.name;
        _framesSent = 1;
      });
      _frame.value = first;
      _ensureTicker();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _stop() {
    _stopTicker();
    _session?.dispose();
    _frame.value = null;
    setState(() {
      _session = null;
      _fileName = null;
      _framesSent = 0;
    });
  }

  @override
  Widget build(BuildContext context) {
    final session = _session;
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: OfflineColors.canvas,
      appBar: AppBar(title: const Text('Send optically')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            if (session == null) ...[
              Text(
                'Pick a file to stream as animated QR codes.',
                style: theme.textTheme.bodyLarge,
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: _busy ? null : _pickAndStart,
                child: Text(_busy ? 'Starting…' : 'Choose file'),
              ),
            ] else ...[
              Text(
                _fileName ?? 'file',
                style: theme.textTheme.titleMedium,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 4),
              Text(
                '${session.totalLen()} bytes · session ${session.sessionId().toRadixString(16)}',
                style: theme.textTheme.bodySmall,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 14),
              _SendProgress(
                framesSent: _framesSent,
                recommended: _recommendedFrames(session),
                sourceBlocks: _sourceBlocks(session),
                fps: _fps,
              ),
              const SizedBox(height: 12),
              Expanded(
                child: Center(
                  child: AspectRatio(
                    aspectRatio: 1,
                    child: ColoredBox(
                      color: Colors.white,
                      child: ValueListenableBuilder<Uint8List?>(
                        valueListenable: _frame,
                        builder: (context, frame, _) {
                          if (frame == null) {
                            return const Center(
                              child: CircularProgressIndicator(),
                            );
                          }
                          return BinaryQrView(data: frame);
                        },
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Hold the other phone steady. Max brightness helps.',
                style: theme.textTheme.bodySmall,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  const Text('FPS'),
                  Expanded(
                    child: Slider(
                      value: _fps.toDouble(),
                      min: 4,
                      max: 16,
                      divisions: 12,
                      label: '$_fps',
                      onChanged: (v) {
                        setState(() => _fps = v.round());
                      },
                    ),
                  ),
                  Text('$_fps'),
                ],
              ),
              OutlinedButton(onPressed: _stop, child: const Text('Stop')),
            ],
          ],
        ),
      ),
    );
  }
}

class _SendProgress extends StatelessWidget {
  const _SendProgress({
    required this.framesSent,
    required this.recommended,
    required this.sourceBlocks,
    required this.fps,
  });

  final int framesSent;
  final int recommended;
  final int sourceBlocks;
  final int fps;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final passComplete = framesSent >= recommended;
    final withinPass = passComplete ? recommended : framesSent;
    final value = (withinPass / recommended).clamp(0.0, 1.0);
    final pct = (value * 100).round();
    final label = passComplete
        ? 'Recommended pass done · redundancy +${framesSent - recommended}'
        : 'Recommended pass · $framesSent / $recommended frames ($pct%)';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: LinearProgressIndicator(
            value: value,
            minHeight: 10,
            backgroundColor: OfflineColors.line.withValues(alpha: 0.45),
            color: passComplete ? OfflineColors.leaf : OfflineColors.moss,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          label,
          style: theme.textTheme.bodySmall?.copyWith(
            color: OfflineColors.ink.withValues(alpha: 0.8),
            fontWeight: FontWeight.w600,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 2),
        Text(
          passComplete
              ? 'Keep streaming until the receiver shows complete.'
              : '$sourceBlocks source blocks · ~${(recommended / fps).ceil()}s at $fps FPS',
          style: theme.textTheme.bodySmall,
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}
