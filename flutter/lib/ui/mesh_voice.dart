import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

/// BitChat-aligned voice note budget (`FileTransferLimits.maxVoiceNoteBytes`).
const kMaxMeshVoiceBytes = 512 * 1024;
/// Wall-clock floor after the recorder is actually running (not press→mic grant).
const kMinVoiceSeconds = 0.35;
/// Keep clips short so web WAV (and BitChat's 256-fragment cap) stay deliverable.
const kMaxVoiceSeconds = 10.0;

class MeshVoiceFormat {
  const MeshVoiceFormat({
    required this.encoder,
    required this.extension,
    required this.mimeType,
    required this.bitRate,
    required this.sampleRate,
  });

  final AudioEncoder encoder;
  final String extension;
  final String mimeType;
  final int bitRate;
  final int sampleRate;
}

/// Prefer BitChat `audio/mp4` AAC on native. On web, Chrome's MediaRecorder
/// almost never produces real AAC/mp4 — MicRecorder WAV is reliable, then we
/// downsample to ≤16 kHz so short clips stay under 512 KiB.
Future<MeshVoiceFormat> resolveMeshVoiceFormat(AudioRecorder recorder) async {
  if (kIsWeb) {
    return const MeshVoiceFormat(
      encoder: AudioEncoder.wav,
      extension: 'wav',
      mimeType: 'audio/wav',
      bitRate: 128000,
      sampleRate: 8000,
    );
  }
  if (await recorder.isEncoderSupported(AudioEncoder.aacLc)) {
    return const MeshVoiceFormat(
      encoder: AudioEncoder.aacLc,
      extension: 'm4a',
      mimeType: 'audio/mp4',
      bitRate: 16000,
      sampleRate: 16000,
    );
  }
  if (await recorder.isEncoderSupported(AudioEncoder.wav)) {
    return const MeshVoiceFormat(
      encoder: AudioEncoder.wav,
      extension: 'wav',
      mimeType: 'audio/wav',
      bitRate: 128000,
      sampleRate: 8000,
    );
  }
  throw StateError('No BitChat-compatible audio encoder available');
}

Future<String> meshVoiceOutputPath(String extension) async {
  if (kIsWeb) {
    // Unique path each take so blob URLs / caches cannot leak prior takes.
    final ts = DateTime.now().millisecondsSinceEpoch;
    return 'offline_voice_$ts.$extension';
  }
  final dir = await getTemporaryDirectory();
  final ts = DateTime.now().millisecondsSinceEpoch;
  return '${dir.path}/offline_voice_$ts.$extension';
}

/// BitChat `ChatMediaPreparation`: `voice_yyyyMMdd_HHmmss_<UUID>.m4a`.
String meshVoiceFileName({required String extension}) {
  final now = DateTime.now();
  String two(int n) => n.toString().padLeft(2, '0');
  final stamp =
      '${now.year}${two(now.month)}${two(now.day)}_'
      '${two(now.hour)}${two(now.minute)}${two(now.second)}';
  final bytes = List<int>.generate(16, (_) => Random().nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  final uuid =
      '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-'
      '${hex.substring(16, 20)}-${hex.substring(20)}';
  final ext = extension.toLowerCase() == 'm4a' || extension.toLowerCase() == 'mp4'
      ? 'm4a'
      : extension.toLowerCase();
  return 'voice_${stamp}_$uuid.$ext';
}
