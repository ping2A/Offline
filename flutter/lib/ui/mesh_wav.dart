import 'dart:typed_data';

import 'package:offline/ui/mesh_voice.dart';

/// True when [bytes] look like a RIFF/WAVE file.
bool isWavBytes(Uint8List bytes) =>
    bytes.length >= 44 &&
    bytes[0] == 0x52 &&
    bytes[1] == 0x49 &&
    bytes[2] == 0x46 &&
    bytes[3] == 0x46 &&
    bytes[8] == 0x57 &&
    bytes[9] == 0x41 &&
    bytes[10] == 0x56 &&
    bytes[11] == 0x45;

/// Duration in seconds from a PCM WAV, or null if not parseable.
double? wavDurationSeconds(Uint8List input) {
  if (!isWavBytes(input) || input.length < 44) return null;
  var offset = 12;
  int? channels;
  int? sampleRate;
  int? bitsPerSample;
  int? dataSize;
  while (offset + 8 <= input.length) {
    final id = String.fromCharCodes(input.sublist(offset, offset + 4));
    final size = ByteData.sublistView(input, offset + 4, offset + 8)
        .getUint32(0, Endian.little);
    final chunkStart = offset + 8;
    final chunkEnd = chunkStart + size;
    if (chunkEnd > input.length) break;
    if (id == 'fmt ' && size >= 16) {
      final bd = ByteData.sublistView(input, chunkStart, chunkEnd);
      channels = bd.getUint16(2, Endian.little);
      sampleRate = bd.getUint32(4, Endian.little);
      bitsPerSample = bd.getUint16(14, Endian.little);
    } else if (id == 'data') {
      dataSize = size;
      break;
    }
    offset = chunkEnd + (size.isOdd ? 1 : 0);
  }
  if (channels == null ||
      sampleRate == null ||
      bitsPerSample == null ||
      dataSize == null ||
      channels == 0 ||
      sampleRate == 0 ||
      bitsPerSample == 0) {
    return null;
  }
  final bytesPerFrame = channels * (bitsPerSample ~/ 8);
  if (bytesPerFrame <= 0) return null;
  return dataSize / (bytesPerFrame * sampleRate);
}

bool isWebmBytes(Uint8List bytes) =>
    bytes.length >= 4 &&
    bytes[0] == 0x1A &&
    bytes[1] == 0x45 &&
    bytes[2] == 0xDF &&
    bytes[3] == 0xA3;

/// Chrome's AudioContext is usually 48 kHz, so a few seconds of PCM WAV exceeds
/// BitChat's 512 KiB / 256-fragment budgets. Always downsample mesh WAVs to
/// 8 kHz mono so a 10s clip stays under BitChat's fragment train limit.
Uint8List prepareMeshVoiceBytes(Uint8List bytes, {required String mimeType}) {
  if (bytes.isEmpty) return bytes;

  if (isWavBytes(bytes) || mimeType.toLowerCase().contains('wav')) {
    var out = bytes;
    if (!isWavBytes(out)) return out;
    // Prefer 8 kHz for mesh: 10s mono PCM ≈ 160 KiB before zlib.
    out = downsampleWav(out, targetRate: 8000) ?? out;
    if (out.length > kMaxMeshVoiceBytes) {
      out = downsampleWav(out, targetRate: 8000) ?? out;
    }
    return out;
  }
  return bytes;
}

/// Decimate 16-bit PCM WAV to [targetRate] mono. Returns null if not PCM WAV.
Uint8List? downsampleWav(Uint8List input, {required int targetRate}) {
  if (!isWavBytes(input) || input.length < 44) return null;

  // Parse fmt + data chunks (BitChat / MicRecorder layout is typically
  // RIFF/WAVE with fmt then data; tolerate extra chunks).
  var offset = 12;
  int? channels;
  int? sampleRate;
  int? bitsPerSample;
  int? dataOffset;
  int? dataSize;

  while (offset + 8 <= input.length) {
    final id = String.fromCharCodes(input.sublist(offset, offset + 4));
    final size = ByteData.sublistView(input, offset + 4, offset + 8)
        .getUint32(0, Endian.little);
    final chunkStart = offset + 8;
    final chunkEnd = chunkStart + size;
    if (chunkEnd > input.length) break;

    if (id == 'fmt ' && size >= 16) {
      final bd = ByteData.sublistView(input, chunkStart, chunkEnd);
      final format = bd.getUint16(0, Endian.little);
      if (format != 1) return null; // PCM only
      channels = bd.getUint16(2, Endian.little);
      sampleRate = bd.getUint32(4, Endian.little);
      bitsPerSample = bd.getUint16(14, Endian.little);
    } else if (id == 'data') {
      dataOffset = chunkStart;
      dataSize = size;
      break;
    }
    offset = chunkEnd + (size.isOdd ? 1 : 0);
  }

  if (channels == null ||
      sampleRate == null ||
      bitsPerSample == null ||
      dataOffset == null ||
      dataSize == null) {
    return null;
  }
  if (bitsPerSample != 16) return null;
  if (sampleRate <= targetRate && channels == 1 && input.length <= kMaxMeshVoiceBytes) {
    return input;
  }

  final bytesPerFrame = channels * (bitsPerSample ~/ 8);
  if (bytesPerFrame <= 0 || dataSize < bytesPerFrame) return null;
  final totalFrames = dataSize ~/ bytesPerFrame;
  final step = sampleRate / targetRate;
  if (step < 1) return input;

  final outFrames = (totalFrames / step).floor();
  if (outFrames <= 0) return null;

  final pcmOut = BytesBuilder(copy: false);
  final bdIn = ByteData.sublistView(input, dataOffset, dataOffset + dataSize);
  for (var i = 0; i < outFrames; i++) {
    final srcFrame = (i * step).floor();
    if (srcFrame >= totalFrames) break;
    // Mix channels → mono
    var sum = 0;
    for (var c = 0; c < channels; c++) {
      final idx = (srcFrame * channels + c) * 2;
      if (idx + 2 > dataSize) break;
      sum += bdIn.getInt16(idx, Endian.little);
    }
    final sample = (sum / channels).round().clamp(-32768, 32767);
    pcmOut.addByte(sample & 0xff);
    pcmOut.addByte((sample >> 8) & 0xff);
  }
  final pcm = pcmOut.takeBytes();

  final header = BytesBuilder(copy: false);
  final dataLen = pcm.length;
  final riffLen = 36 + dataLen;
  final byteRate = targetRate * 2; // mono 16-bit
  void u32(int v) {
    header.addByte(v & 0xff);
    header.addByte((v >> 8) & 0xff);
    header.addByte((v >> 16) & 0xff);
    header.addByte((v >> 24) & 0xff);
  }

  void u16(int v) {
    header.addByte(v & 0xff);
    header.addByte((v >> 8) & 0xff);
  }

  header.add('RIFF'.codeUnits);
  u32(riffLen);
  header.add('WAVE'.codeUnits);
  header.add('fmt '.codeUnits);
  u32(16);
  u16(1); // PCM
  u16(1); // mono
  u32(targetRate);
  u32(byteRate);
  u16(2); // block align
  u16(16); // bits
  header.add('data'.codeUnits);
  u32(dataLen);
  header.add(pcm);
  return header.toBytes();
}
