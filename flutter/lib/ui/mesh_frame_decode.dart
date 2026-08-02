import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:offline/ui/app_theme.dart';

/// One labeled slice of a BitChat BinaryProtocol wire frame.
class FramePart {
  const FramePart({
    required this.name,
    required this.offset,
    required this.length,
    required this.bytes,
    required this.value,
    required this.explanation,
    required this.color,
  });

  final String name;
  final int offset;
  final int length;
  final Uint8List bytes;
  final String value;
  final String explanation;
  final Color color;

  String get hex {
    final b = StringBuffer();
    final n = bytes.length > 24 ? 24 : bytes.length;
    for (var i = 0; i < n; i++) {
      if (i > 0) b.write(' ');
      b.write(bytes[i].toRadixString(16).padLeft(2, '0'));
    }
    if (bytes.length > 24) b.write(' …');
    return b.toString();
  }

  String get rangeLabel =>
      length <= 1 ? '@$offset' : '@$offset–${offset + length - 1}';
}

/// Parsed layout of a raw mesh frame for the Frames debug pane.
class FrameBreakdown {
  const FrameBreakdown({
    required this.parts,
    required this.payloadParts,
    required this.summary,
    this.error,
    this.padded = false,
    this.padBytes = 0,
  });

  final List<FramePart> parts;
  /// Nested decode of the payload (fragment header, announce TLVs, …).
  final List<FramePart> payloadParts;
  final String summary;
  final String? error;
  final bool padded;
  final int padBytes;

  bool get ok => error == null && parts.isNotEmpty;
}

const _palette = <Color>[
  Color(0xFF6B8F71), // version
  Color(0xFFD4A35C), // type
  Color(0xFF8A6B3A), // ttl
  Color(0xFF5B7C99), // timestamp
  Color(0xFFB07D4A), // flags
  Color(0xFF7A9E6A), // payload_len
  Color(0xFFC4A35A), // sender
  Color(0xFF9B6B5A), // recipient
  Color(0xFF6A8A9B), // route
  Color(0xFF8B7A5A), // orig_len / compressed meta
  Color(0xFFE8C07A), // payload
  Color(0xFFA67C52), // signature
  Color(0xFF6E6A62), // padding
];

FrameBreakdown decodeMeshFrame(Uint8List raw) {
  if (raw.isEmpty) {
    return const FrameBreakdown(
      parts: [],
      payloadParts: [],
      summary: 'empty',
      error: 'Empty frame',
    );
  }

  try {
    return _breakdownFrom(raw, raw, padBytes: 0);
  } catch (_) {
    final unpadded = _unpad(raw);
    if (unpadded != null && unpadded.length < raw.length) {
      try {
        return _breakdownFrom(raw, unpadded, padBytes: raw.length - unpadded.length);
      } catch (e) {
        return _fail(raw, e);
      }
    }
    try {
      // Re-throw original path error.
      return _breakdownFrom(raw, raw, padBytes: 0);
    } catch (e) {
      return _fail(raw, e);
    }
  }
}

FrameBreakdown _fail(Uint8List raw, Object e) {
  return FrameBreakdown(
    parts: [
      FramePart(
        name: 'raw',
        offset: 0,
        length: raw.length,
        bytes: raw,
        value: '${raw.length} B',
        explanation: 'Could not parse as BinaryProtocol: $e',
        color: OfflineColors.danger,
      ),
    ],
    payloadParts: const [],
    summary: 'unparsed ${raw.length}B',
    error: e.toString(),
  );
}

FrameBreakdown _breakdownFrom(
  Uint8List raw,
  Uint8List working, {
  required int padBytes,
}) {
  final parsed = _decodeCore(working);
  final parts = List<FramePart>.from(parsed.parts);
  if (padBytes > 0) {
    parts.add(
      FramePart(
        name: 'padding',
        offset: working.length,
        length: padBytes,
        bytes: Uint8List.sublistView(raw, working.length),
        value: '$padBytes B PKCS#7 → ${raw.length} B block',
        explanation:
            'BitChat MessagePadding: trailing bytes equal to the pad length '
            '(Noise handshake / encrypted frames pad to 256/512/1024/2048).',
        color: _palette[12],
      ),
    );
  }
  return FrameBreakdown(
    parts: parts,
    payloadParts: parsed.payloadParts,
    summary: parsed.summary,
    padded: padBytes > 0,
    padBytes: padBytes,
  );
}

class _CoreResult {
  const _CoreResult({
    required this.parts,
    required this.payloadParts,
    required this.summary,
  });
  final List<FramePart> parts;
  final List<FramePart> payloadParts;
  final String summary;
}

_CoreResult _decodeCore(Uint8List data) {
  if (data.length < 14 + 8) {
    throw StateError('truncated (${data.length} B)');
  }

  final parts = <FramePart>[];
  var o = 0;

  Uint8List take(int n) {
    if (o + n > data.length) throw StateError('truncated at offset $o');
    final slice = Uint8List.sublistView(data, o, o + n);
    o += n;
    return slice;
  }

  void add(
    String name,
    Uint8List bytes,
    String value,
    String explanation,
    Color color,
  ) {
    final start = o - bytes.length;
    parts.add(
      FramePart(
        name: name,
        offset: start,
        length: bytes.length,
        bytes: bytes,
        value: value,
        explanation: explanation,
        color: color,
      ),
    );
  }

  final versionB = take(1);
  final version = versionB[0];
  if (version != 1 && version != 2) {
    throw StateError('unsupported version $version');
  }
  final lenField = version == 2 ? 4 : 2;
  add(
    'version',
    versionB,
    'v$version',
    version == 1
        ? 'BinaryProtocol v1 — 14-byte header, u16 payload length.'
        : 'BinaryProtocol v2 — 16-byte header, u32 payload length; may carry source route.',
    _palette[0],
  );

  final typeB = take(1);
  final type = typeB[0];
  final typeName = _typeName(type);
  add(
    'type',
    typeB,
    '0x${type.toRadixString(16).padLeft(2, '0')} · $typeName',
    _typeExplanation(type),
    _palette[1],
  );

  final ttlB = take(1);
  add(
    'ttl',
    ttlB,
    '${ttlB[0]}',
    'Time-to-live hop budget. Relays decrement TTL; signing covers TTL=0 so relays stay valid.',
    _palette[2],
  );

  final tsB = take(8);
  final ts = _u64be(tsB);
  add(
    'timestamp',
    tsB,
    _fmtTs(ts),
    'Sender wall-clock timestamp (u64 BE, milliseconds). Used for announce freshness and ordering.',
    _palette[3],
  );

  final flagsB = take(1);
  final flags = flagsB[0];
  final flagNames = _flagNames(flags, version);
  add(
    'flags',
    flagsB,
    '0x${flags.toRadixString(16).padLeft(2, '0')}${flagNames.isEmpty ? '' : ' · ${flagNames.join(' | ')}'}',
    _flagsExplanation(flags, version),
    _palette[4],
  );

  final hasRecipient = flags & 0x01 != 0;
  final hasSignature = flags & 0x02 != 0;
  final isCompressed = flags & 0x04 != 0;
  final hasRoute = version >= 2 && flags & 0x08 != 0;

  final lenB = take(lenField);
  final payloadLength = version == 2 ? _u32be(lenB) : _u16be(lenB);
  add(
    'payload_len',
    lenB,
    '$payloadLength B',
    version == 2
        ? 'Payload length as u32 BE (compressed size when IS_COMPRESSED is set).'
        : 'Payload length as u16 BE (compressed size when IS_COMPRESSED is set).',
    _palette[5],
  );

  final senderB = take(8);
  add(
    'sender_id',
    senderB,
    _hexId(senderB),
    '8-byte peer ID = first 8 bytes of SHA-256(Noise static public key).',
    _palette[6],
  );

  if (hasRecipient) {
    final recipB = take(8);
    final broadcast = recipB.every((b) => b == 0xFF);
    add(
      'recipient_id',
      recipB,
      broadcast ? 'broadcast (ff…)' : _hexId(recipB),
      'Directed recipient (HAS_RECIPIENT). Broadcast uses all 0xFF; private files/DMs set a real peer id.',
      _palette[7],
    );
  }

  if (hasRoute) {
    final countB = take(1);
    final count = countB[0];
    add(
      'route_count',
      countB,
      '$count hop(s)',
      'Source-route hop count (v2 HAS_ROUTE). Each hop is an 8-byte peer ID.',
      _palette[8],
    );
    for (var i = 0; i < count; i++) {
      final hop = take(8);
      add(
        'route[$i]',
        hop,
        _hexId(hop),
        'Source-route hop $i — next relay peer ID.',
        _palette[8],
      );
    }
  }

  late final Uint8List payloadBytes;
  if (isCompressed) {
    final origB = take(lenField);
    final origLen = version == 2 ? _u32be(origB) : _u16be(origB);
    add(
      'orig_len',
      origB,
      '$origLen B',
      'Uncompressed payload size (IS_COMPRESSED). Followed by zlib/raw-DEFLATE bytes.',
      _palette[9],
    );
    final compressedSize = payloadLength - lenField;
    if (compressedSize < 0) throw StateError('bad compressed length');
    payloadBytes = take(compressedSize);
    add(
      'payload',
      payloadBytes,
      'compressed $compressedSize B → $origLen B',
      'Compressed application payload (raw DEFLATE / zlib). Type-specific contents after inflate.',
      _palette[10],
    );
  } else {
    payloadBytes = take(payloadLength);
    add(
      'payload',
      payloadBytes,
      '${payloadBytes.length} B',
      _payloadExplanation(type, payloadBytes),
      _palette[10],
    );
  }

  if (hasSignature) {
    final sig = take(64);
    add(
      'signature',
      sig,
      'Ed25519 (64 B)',
      'Ed25519 over padded signing bytes (TTL=0, no signature, IS_RSR cleared). Relays keep the signature.',
      _palette[11],
    );
  }

  if (o < data.length) {
    final start = o;
    final trail = take(data.length - o);
    final padLike = _looksLikePkcs7(trail);
    parts.add(
      FramePart(
        name: padLike ? 'padding' : 'trailing',
        offset: start,
        length: trail.length,
        bytes: trail,
        value: padLike ? '${trail.length} B PKCS#7' : '${trail.length} B',
        explanation: padLike
            ? 'PKCS#7 block padding after the packet (Noise frames pad to 256/512/1024/2048).'
            : 'Bytes after the declared packet fields.',
        color: _palette[12],
      ),
    );
  }

  final payloadParts = isCompressed
      ? const <FramePart>[]
      : _decodePayload(type, payloadBytes);

  final summary = StringBuffer(typeName)
    ..write(' · ${data.length}B')
    ..write(hasRecipient ? ' · directed' : ' · flood')
    ..write(isCompressed ? ' · zlib' : '')
    ..write(hasSignature ? ' · signed' : '');

  return _CoreResult(
    parts: parts,
    payloadParts: payloadParts,
    summary: summary.toString(),
  );
}

List<FramePart> _decodePayload(int type, Uint8List payload) {
  switch (type) {
    case 0x01:
      return _decodeAnnounceTlvs(payload);
    case 0x02:
      return _decodeMessagePayload(payload);
    case 0x20:
      return _decodeFragmentPayload(payload);
    case 0x22:
      return _decodeFileTlvs(payload);
    case 0x10:
      return [
        FramePart(
          name: 'handshake',
          offset: 0,
          length: payload.length,
          bytes: payload,
          value: '${payload.length} B Noise XX message',
          explanation:
              'Noise_XX_25519_ChaChaPoly_SHA256 handshake message (msg1/msg2/msg3). '
              'Opaque on the wire; completes to a transport session.',
          color: _palette[10],
        ),
      ];
    case 0x11:
      return _decodeNoiseEncrypted(payload);
    case 0x21:
      return [
        FramePart(
          name: 'sync_filter',
          offset: 0,
          length: payload.length,
          bytes: payload,
          value: '${payload.length} B requestSync TLV',
          explanation:
              'Golomb-Coded Set of known packet IDs. Peer replies with missing '
              'public messages/announces marked IS_RSR.',
          color: _palette[10],
        ),
      ];
    default:
      return const [];
  }
}

List<FramePart> _decodeAnnounceTlvs(Uint8List payload) {
  final out = <FramePart>[];
  var o = 0;
  var i = 0;
  while (o + 2 <= payload.length) {
    final tag = payload[o];
    final len = payload[o + 1];
    if (o + 2 + len > payload.length) break;
    final body = Uint8List.sublistView(payload, o + 2, o + 2 + len);
    final meta = _announceTag(tag, body);
    out.add(
      FramePart(
        name: 'tlv[$i] ${meta.$1}',
        offset: o,
        length: 2 + len,
        bytes: Uint8List.sublistView(payload, o, o + 2 + len),
        value: meta.$2,
        explanation: meta.$3,
        color: _palette[i % _palette.length],
      ),
    );
    o += 2 + len;
    i++;
  }
  if (out.isEmpty && payload.isNotEmpty) {
    // Legacy UTF-8 nickname.
    final text = _tryUtf8(payload);
    out.add(
      FramePart(
        name: 'legacy_nickname',
        offset: 0,
        length: payload.length,
        bytes: payload,
        value: text ?? '${payload.length} B',
        explanation:
            'Legacy announce payload (raw UTF-8 nickname) without TLV tags.',
        color: _palette[10],
      ),
    );
  }
  return out;
}

(String, String, String) _announceTag(int tag, Uint8List body) {
  switch (tag) {
    case 0x01:
      return (
        'nickname',
        _tryUtf8(body) ?? '${body.length} B',
        'Display name TLV (0x01). Shown in peer presence.',
      );
    case 0x02:
      return (
        'noise_key',
        body.length == 32 ? '${_hexId(body.sublist(0, 8))}…' : '${body.length} B',
        'X25519 Noise static public key (32 B). Must hash to sender_id.',
      );
    case 0x03:
      return (
        'signing_key',
        body.length == 32 ? '${body.length} B Ed25519' : '${body.length} B',
        'Ed25519 signing public key used to verify signed packets from this peer.',
      );
    case 0x04:
      final n = body.length ~/ 8;
      return (
        'neighbors',
        '$n peer id(s)',
        'Direct neighbors: concatenated 8-byte peer IDs.',
      );
    case 0x05:
      return ('capabilities', '${body.length} B', 'Forward-compat capabilities blob.');
    case 0x06:
      return ('geohash', _tryUtf8(body) ?? '${body.length} B', 'Bridge geohash (ignored).');
    default:
      return (
        '0x${tag.toRadixString(16)}',
        '${body.length} B',
        'Unknown announce TLV tag.',
      );
  }
}

List<FramePart> _decodeMessagePayload(Uint8List payload) {
  final text = _tryUtf8(payload);
  return [
    FramePart(
      name: 'text',
      offset: 0,
      length: payload.length,
      bytes: payload,
      value: text != null
          ? (text.length > 80 ? '${text.substring(0, 80)}…' : text)
          : '${payload.length} B binary',
      explanation: 'Public mesh chat body (UTF-8). Flooded to the mesh with TTL.',
      color: _palette[10],
    ),
  ];
}

List<FramePart> _decodeFragmentPayload(Uint8List payload) {
  if (payload.length < 13) {
    return [
      FramePart(
        name: 'fragment',
        offset: 0,
        length: payload.length,
        bytes: payload,
        value: 'truncated fragment header',
        explanation: 'Expected fragID(8)+index(2)+total(2)+originalType(1)+data.',
        color: OfflineColors.danger,
      ),
    ];
  }
  final id = Uint8List.sublistView(payload, 0, 8);
  final index = _u16be(Uint8List.sublistView(payload, 8, 10));
  final total = _u16be(Uint8List.sublistView(payload, 10, 12));
  final orig = payload[12];
  final data = Uint8List.sublistView(payload, 13);
  return [
    FramePart(
      name: 'frag_id',
      offset: 0,
      length: 8,
      bytes: id,
      value: _hexId(id),
      explanation: 'Fragment group ID — all chunks of one original frame share this.',
      color: _palette[6],
    ),
    FramePart(
      name: 'index',
      offset: 8,
      length: 2,
      bytes: Uint8List.sublistView(payload, 8, 10),
      value: '$index / $total',
      explanation: 'Zero-based fragment index within the train.',
      color: _palette[1],
    ),
    FramePart(
      name: 'total',
      offset: 10,
      length: 2,
      bytes: Uint8List.sublistView(payload, 10, 12),
      value: '$total',
      explanation: 'Total fragment count (u16). BitChat Android caps practical trains at 256.',
      color: _palette[2],
    ),
    FramePart(
      name: 'original_type',
      offset: 12,
      length: 1,
      bytes: Uint8List.sublistView(payload, 12, 13),
      value: '0x${orig.toRadixString(16).padLeft(2, '0')} · ${_typeName(orig)}',
      explanation: 'Message type of the reassembled inner packet.',
      color: _palette[4],
    ),
    FramePart(
      name: 'chunk',
      offset: 13,
      length: data.length,
      bytes: data,
      value: '${data.length} B',
      explanation:
          'Slice of the already-encoded original packet. Reassemble by index to recover the inner frame.',
      color: _palette[10],
    ),
  ];
}

List<FramePart> _decodeFileTlvs(Uint8List payload) {
  final out = <FramePart>[];
  var o = 0;
  var i = 0;
  while (o + 3 <= payload.length) {
    final tag = payload[o];
    late final int len;
    late final int header;
    if (tag == 0x04) {
      // CONTENT uses u32 length.
      if (o + 5 > payload.length) break;
      len = _u32be(Uint8List.sublistView(payload, o + 1, o + 5));
      header = 5;
    } else {
      if (o + 3 > payload.length) break;
      len = _u16be(Uint8List.sublistView(payload, o + 1, o + 3));
      header = 3;
    }
    if (o + header + len > payload.length) break;
    final body = Uint8List.sublistView(payload, o + header, o + header + len);
    final meta = _fileTag(tag, body);
    out.add(
      FramePart(
        name: 'tlv[$i] ${meta.$1}',
        offset: o,
        length: header + len,
        bytes: Uint8List.sublistView(payload, o, o + header + len),
        value: meta.$2,
        explanation: meta.$3,
        color: _palette[i % _palette.length],
      ),
    );
    o += header + len;
    i++;
  }
  return out;
}

(String, String, String) _fileTag(int tag, Uint8List body) {
  switch (tag) {
    case 0x01:
      return (
        'file_name',
        _tryUtf8(body) ?? '${body.length} B',
        'File name TLV (0x01), UTF-8.',
      );
    case 0x02:
      final size = body.length >= 4 ? _u32be(body.sublist(0, 4)) : body.length;
      return (
        'file_size',
        '$size B',
        'Declared file size (u32 BE inside TLV 0x02).',
      );
    case 0x03:
      return (
        'mime',
        _tryUtf8(body) ?? '${body.length} B',
        'MIME type (image/jpeg, audio/mp4, audio/wav, …).',
      );
    case 0x04:
      return (
        'content',
        '${body.length} B',
        'Raw file bytes (photos/voice). May span many BLE fragments on the wire.',
      );
    default:
      return (
        '0x${tag.toRadixString(16)}',
        '${body.length} B',
        'Unknown file-transfer TLV.',
      );
  }
}

List<FramePart> _decodeNoiseEncrypted(Uint8List payload) {
  if (payload.length < 20) {
    return [
      FramePart(
        name: 'ciphertext',
        offset: 0,
        length: payload.length,
        bytes: payload,
        value: '${payload.length} B',
        explanation: 'Noise transport payload (too short for nonce+tag layout).',
        color: _palette[10],
      ),
    ];
  }
  final nonce = Uint8List.sublistView(payload, 0, 4);
  final tag = Uint8List.sublistView(payload, payload.length - 16);
  final ct = Uint8List.sublistView(payload, 4, payload.length - 16);
  final nonceVal = _u32be(nonce);
  return [
    FramePart(
      name: 'nonce',
      offset: 0,
      length: 4,
      bytes: nonce,
      value: 'u32 BE = $nonceVal',
      explanation:
          'BitChat extracted-nonce prefix. Receiver loads this into ChaChaPoly before decrypt '
          '(sliding ~1024-nonce replay window).',
      color: _palette[3],
    ),
    FramePart(
      name: 'ciphertext',
      offset: 4,
      length: ct.length,
      bytes: ct,
      value: '${ct.length} B',
      explanation:
          'Encrypted Noise payload. After decrypt: type byte + privateMessage/file/receipt body.',
      color: _palette[10],
    ),
    FramePart(
      name: 'tag',
      offset: payload.length - 16,
      length: 16,
      bytes: tag,
      value: 'Poly1305 (16 B)',
      explanation: 'ChaChaPoly authentication tag. Tamper or wrong key → decrypt fails.',
      color: _palette[11],
    ),
  ];
}

String _typeName(int t) => switch (t) {
      0x01 => 'announce',
      0x02 => 'message',
      0x03 => 'leave',
      0x10 => 'noiseHandshake',
      0x11 => 'noiseEncrypted',
      0x20 => 'fragment',
      0x21 => 'requestSync',
      0x22 => 'fileTransfer',
      _ => '0x${t.toRadixString(16).padLeft(2, '0')}',
    };

String _typeExplanation(int t) => switch (t) {
      0x01 =>
        'Peer announce — nickname + Noise/signing keys so others can address and verify you.',
      0x02 => 'Public mesh chat message (flood).',
      0x03 => 'Peer leave — remove from presence.',
      0x10 => 'Noise XX handshake message (establishes a private session).',
      0x11 =>
        'Noise transport frame — private messages, receipts, or private files after decrypt.',
      0x20 =>
        'Fragment wrapper — carries a chunk of a larger encoded packet (photos/voice/large frames).',
      0x21 => 'Gossip sync request — GCS of known packet IDs for catch-up.',
      0x22 => 'File transfer — photo, voice note, or file (TLV; often fragmented).',
      _ => 'Unknown or unimplemented message type.',
    };

String _payloadExplanation(int type, Uint8List payload) {
  switch (type) {
    case 0x02:
      final t = _tryUtf8(payload);
      if (t != null) {
        final preview = t.length > 40 ? '${t.substring(0, 40)}…' : t;
        return 'Public chat text: “$preview”';
      }
      return 'Public message payload (${payload.length} B).';
    case 0x20:
      return 'Fragment body — see payload breakdown for fragID / index / chunk.';
    case 0x11:
      return 'Noise ciphertext — see nonce ‖ ciphertext ‖ tag breakdown.';
    case 0x01:
      return 'Announce TLVs (nickname, keys, neighbors).';
    case 0x22:
      return 'File-transfer TLVs (name, size, MIME, content).';
    default:
      return 'Application payload for ${_typeName(type)}.';
  }
}

List<String> _flagNames(int flags, int version) {
  final names = <String>[];
  if (flags & 0x01 != 0) names.add('HAS_RECIPIENT');
  if (flags & 0x02 != 0) names.add('HAS_SIGNATURE');
  if (flags & 0x04 != 0) names.add('IS_COMPRESSED');
  if (version >= 2 && flags & 0x08 != 0) names.add('HAS_ROUTE');
  if (flags & 0x10 != 0) names.add('IS_RSR');
  return names;
}

String _flagsExplanation(int flags, int version) {
  final bits = <String>[];
  if (flags & 0x01 != 0) {
    bits.add('HAS_RECIPIENT (0x01): recipient_id follows sender_id');
  }
  if (flags & 0x02 != 0) {
    bits.add('HAS_SIGNATURE (0x02): 64-byte Ed25519 after payload');
  }
  if (flags & 0x04 != 0) {
    bits.add('IS_COMPRESSED (0x04): orig_len + deflate payload');
  }
  if (version >= 2 && flags & 0x08 != 0) {
    bits.add('HAS_ROUTE (0x08): source-route hops');
  }
  if (flags & 0x10 != 0) {
    bits.add('IS_RSR (0x10): request-sync response / special relay');
  }
  if (bits.isEmpty) {
    return 'No header flags set — broadcast flood, unsigned, uncompressed.';
  }
  return bits.join('\n');
}

Uint8List? _unpad(Uint8List data) {
  if (data.isEmpty) return null;
  final last = data.last;
  final padLen = last;
  if (padLen == 0 || padLen > data.length) return null;
  final start = data.length - padLen;
  for (var i = start; i < data.length; i++) {
    if (data[i] != last) return null;
  }
  return Uint8List.sublistView(data, 0, start);
}

bool _looksLikePkcs7(Uint8List trail) {
  if (trail.isEmpty) return false;
  final last = trail.last;
  if (last == 0 || last != trail.length) return false;
  for (final b in trail) {
    if (b != last) return false;
  }
  return true;
}

String _hexId(Uint8List b) {
  final n = b.length > 8 ? 8 : b.length;
  final buf = StringBuffer();
  for (var i = 0; i < n; i++) {
    buf.write(b[i].toRadixString(16).padLeft(2, '0'));
  }
  return buf.toString();
}

String? _tryUtf8(Uint8List b) {
  try {
    final s = utf8.decode(b);
    if (s.isEmpty) return null;
    // Reject mostly binary.
    var bad = 0;
    for (final r in s.runes) {
      if (r < 0x09 || (r > 0x0d && r < 0x20) || r == 0xFFFD) bad++;
    }
    if (bad > s.length ~/ 8) return null;
    return s;
  } catch (_) {
    return null;
  }
}

int _u16be(Uint8List b) => (b[0] << 8) | b[1];

int _u32be(Uint8List b) =>
    (b[0] << 24) | (b[1] << 16) | (b[2] << 8) | b[3];

int _u64be(Uint8List b) {
  var v = 0;
  for (var i = 0; i < 8; i++) {
    v = (v << 8) | b[i];
  }
  return v;
}

String _fmtTs(int ms) {
  if (ms <= 0) return '$ms';
  try {
    final dt = DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true).toLocal();
    final hh = dt.hour.toString().padLeft(2, '0');
    final mm = dt.minute.toString().padLeft(2, '0');
    final ss = dt.second.toString().padLeft(2, '0');
    return '$hh:$mm:$ss · $ms';
  } catch (_) {
    return '$ms';
  }
}
