import 'dart:async';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:offline/src/rust/api/identity.dart';
import 'package:offline/src/rust/api/mesh.dart';
import 'package:offline/ui/identity_store.dart';
import 'package:offline/ui/mesh_image.dart';
import 'package:offline/ui/mesh_transport.dart';
import 'package:offline/ui/mesh_transport_factory.dart';
import 'package:offline/ui/mesh_voice.dart';
import 'package:offline/ui/mesh_voice_bytes.dart';
import 'package:offline/ui/mesh_wav.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';

class ChatLine {
  ChatLine({
    required this.fromPeerId,
    required this.text,
    required this.timestampMs,
    this.isLocal = false,
    this.isPrivate = false,
    this.withPeerId,
    this.mimeType,
    this.fileName,
    this.fileBytes,
    this.messageId,
    this.deliveryStatus,
    this.sendProgress,
    this.readByUs = false,
  });

  final String fromPeerId;
  final String text;
  final int timestampMs;
  final bool isLocal;
  final bool isPrivate;
  /// Other party in a DM (sender for inbound, recipient for outbound).
  final String? withPeerId;
  final String? mimeType;
  final String? fileName;
  final Uint8List? fileBytes;
  final String? messageId;
  /// BitChat Noise receipt: `sending` → `sent` → `delivered` → `read`.
  String? deliveryStatus;
  /// 0..1 while BLE fragment train is in flight (BitChat block-reveal).
  double? sendProgress;
  /// Inbound: we have opened / acked this private message.
  bool readByUs;

  bool get isImage {
    final m = mimeType?.toLowerCase() ?? '';
    if (m.startsWith('image/')) return true;
    final name = (fileName ?? text).toLowerCase();
    return name.endsWith('.jpg') ||
        name.endsWith('.jpeg') ||
        name.endsWith('.png') ||
        name.endsWith('.gif') ||
        name.endsWith('.webp');
  }

  bool get isAudio {
    final m = mimeType?.toLowerCase() ?? '';
    if (m.startsWith('audio/')) return true;
    final name = (fileName ?? text).toLowerCase();
    if (name.endsWith('.m4a') ||
        name.endsWith('.mp4') ||
        name.endsWith('.aac') ||
        name.endsWith('.wav') ||
        name.endsWith('.mp3') ||
        name.endsWith('.ogg') ||
        name.startsWith('voice_')) {
      return true;
    }
    // BitChat AAC-in-M4A often has an early `ftyp` box even when MIME is odd.
    final bytes = fileBytes;
    if (bytes != null && bytes.length > 100) {
      final n = bytes.length < 64 ? bytes.length - 3 : 64;
      for (var i = 0; i < n; i++) {
        if (bytes[i] == 0x66 &&
            bytes[i + 1] == 0x74 &&
            bytes[i + 2] == 0x79 &&
            bytes[i + 3] == 0x70) {
          return true;
        }
      }
    }
    return false;
  }
}

/// One raw BitChat BinaryProtocol frame on the wire (for the Frames debug pane).
class MeshWireFrame {
  MeshWireFrame({
    required this.direction,
    required this.bytes,
    required this.atMs,
    this.note = '',
  });

  /// `in` | `out` | `relay`
  final String direction;
  final Uint8List bytes;
  final int atMs;
  final String note;

  int get length => bytes.length;

  int? get version => bytes.isNotEmpty ? bytes[0] : null;
  int? get typeByte => bytes.length > 1 ? bytes[1] : null;
  int? get ttl => bytes.length > 2 ? bytes[2] : null;

  String get typeName {
    final t = typeByte;
    if (t == null) return '?';
    return switch (t) {
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
  }

  String get hexFull {
    final b = StringBuffer();
    for (var i = 0; i < bytes.length; i++) {
      if (i > 0) b.write(i % 16 == 0 ? '\n' : ' ');
      b.write(bytes[i].toRadixString(16).padLeft(2, '0'));
    }
    return b.toString();
  }

  String get hexPreview {
    const max = 24;
    final n = math.min(bytes.length, max);
    final parts = <String>[];
    for (var i = 0; i < n; i++) {
      parts.add(bytes[i].toRadixString(16).padLeft(2, '0'));
    }
    var s = parts.join(' ');
    if (bytes.length > max) s = '$s …';
    return s;
  }
}

/// Coordinates Rust mesh logic with a platform transport (BLE or web).
class MeshControllerService extends ChangeNotifier {
  MeshControllerService(this.identity);

  final StoredIdentity identity;

  late final MeshTransport _transport = createMeshTransport();

  MeshSession? _session;
  Timer? _announceTimer;
  Timer? _syncTimer;
  bool _running = false;
  int _linkCount = 0;
  String _nickname = '';
  final List<ChatLine> _messages = [];
  final List<MeshPeerInfo> _peers = [];
  final List<MeshWireFrame> _frames = [];
  List<String> _bleDeviceNames = [];
  String? _selectedPeerId;
  /// Peer whose DM thread is open in the UI (null = general channel).
  String? _privateViewPeerId;
  String? _status;
  bool _connectingNearby = false;
  static const _maxFrames = 200;

  AudioRecorder? _recorder;
  bool _recording = false;
  bool _recordStarting = false;
  DateTime? _recordStartedAt;
  Timer? _recordLimitTimer;
  MeshVoiceFormat? _activeVoiceFormat;
  bool _privateVoiceIntent = false;
  /// If the user released before start finished, apply this when start completes.
  bool? _pendingStopSend;
  Future<void> _flushChain = Future<void>.value();
  final List<ChatLine> _mediaSendQueue = [];
  final Map<String, Set<String>> _pendingReadReceipts = {};
  DateTime _lastProgressNotify = DateTime.fromMillisecondsSinceEpoch(0);

  AudioRecorder _voiceRecorder() => _recorder ??= AudioRecorder();

  bool get running => _running;
  int get linkCount => _linkCount;
  String get nickname => _nickname;
  String? get status => _status;
  List<ChatLine> get messages => List.unmodifiable(_messages);
  List<MeshPeerInfo> get peers => List.unmodifiable(_peers);
  List<MeshWireFrame> get frames => List.unmodifiable(_frames);
  List<String> get bleDeviceNames => List.unmodifiable(_bleDeviceNames);
  bool get canConnectNearby =>
      kIsWeb ? true : _transport.supportsNearbyConnect;
  String? get selectedPeerId => _selectedPeerId;
  String? get privateViewPeerId => _privateViewPeerId;
  bool get connectingNearby => _connectingNearby;
  bool get isRecordingVoice => _recording;
  /// True while getUserMedia / encoder startup is in progress (hold already down).
  bool get isVoiceArming => _recordStarting;
  Duration get recordingElapsed {
    final start = _recordStartedAt;
    if (start == null) return Duration.zero;
    return DateTime.now().difference(start);
  }

  MeshPeerInfo? get selectedPeer {
    final id = _selectedPeerId;
    if (id == null) return null;
    for (final p in _peers) {
      if (p.peerId == id) return p;
    }
    return null;
  }

  bool get canSendPrivate {
    // BitChat queues DMs and starts Noise when needed — only need a selected peer.
    return selectedPeer != null;
  }

  void clearFrames() {
    _frames.clear();
    notifyListeners();
  }

  Future<bool> start({String? nickname}) async {
    if (!kIsWeb && !await _ensurePermissions()) {
      _status = 'Bluetooth / location permission denied';
      notifyListeners();
      return false;
    }

    final nick = (nickname == null || nickname.trim().isEmpty)
        ? identity.peerId.substring(0, 8)
        : nickname.trim();
    _nickname = nick;

    final bundle = IdentityBundle(
      peerId: identity.peerId,
      noisePublicKey: identity.noisePublicKey,
      signingPublicKey: identity.signingPublicKey,
      noiseSecretKey: identity.noiseSecretKey,
      signingSecretKey: identity.signingSecretKey,
    );

    _session?.dispose();
    _session = meshStart(bundle: bundle, nickname: nick);
    _frames.clear();

    _transport.onPacket = _handleInbound;
    _transport.onLinkCount = (count) {
      _linkCount = count;
      _session?.setLinkCount(count: count);
      notifyListeners();
    };
    _transport.onBleDevices = (names) {
      _bleDeviceNames = names;
      if (names.isNotEmpty) {
        _status = 'On mesh via ${names.join(', ')}';
      }
      notifyListeners();
    };

    try {
      await _transport.start(
        peerIdHex: identity.peerId,
        peerIdBytes: _session!.peerIdBytes(),
      );
    } catch (e) {
      _status = 'Failed to start transport: $e';
      _session?.dispose();
      _session = null;
      notifyListeners();
      return false;
    }

    _running = true;
    _bleDeviceNames = _transport.bleDeviceNames;
    _status = kIsWeb
        ? 'Live — connect to the mesh over Bluetooth'
        : 'Mesh live';
    _queueAnnounceAndFlush();
    _announceTimer?.cancel();
    _announceTimer = Timer.periodic(const Duration(seconds: 12), (_) {
      _queueAnnounceAndFlush();
    });
    _syncTimer?.cancel();
    // BitChat GossipSyncManager maintenance (~15s message rounds; also fires delayed join sync).
    _syncTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      _maintainGossipAndFlush();
    });
    notifyListeners();
    return true;
  }

  Future<void> stop() async {
    _announceTimer?.cancel();
    _announceTimer = null;
    _syncTimer?.cancel();
    _syncTimer = null;
    try {
      _session?.queueLeave();
      await _flushOutbound();
    } catch (_) {}
    await _transport.stop();
    _transport.onPacket = null;
    _transport.onLinkCount = null;
    _transport.onBleDevices = null;
    _session?.dispose();
    _session = null;
    _running = false;
    _linkCount = 0;
    _bleDeviceNames = [];
    _selectedPeerId = null;
    _privateViewPeerId = null;
    _mediaSendQueue.clear();
    _pendingReadReceipts.clear();
    _peers.clear();
    _status = 'Mesh stopped';
    notifyListeners();
  }

  Future<void> connectNearbyDevice({bool showAllDevices = false}) async {
    if (!_running) {
      _status = 'Start mesh before connecting over Bluetooth';
      notifyListeners();
      return;
    }
    _connectingNearby = true;
    _status = showAllDevices
        ? 'Waiting for Bluetooth… pick a mesh peer (often unnamed). '
            'Skip headphones/keyboards.'
        : 'Waiting for Bluetooth… choose Offline / BitChat in the system dialog.';
    notifyListeners();
    try {
      await _transport.connectNearbyDevice(showAllDevices: showAllDevices);
      _bleDeviceNames = _transport.bleDeviceNames;
      _linkCount = _transport.linkCount();
      _session?.setLinkCount(count: _linkCount);
      _status = _bleDeviceNames.isEmpty
          ? 'Connected to the mesh'
          : 'On mesh via ${_bleDeviceNames.join(', ')}';
      for (var i = 0; i < 3; i++) {
        _queueAnnounceAndFlush();
      }
      // BitChat scheduleInitialSyncToPeer default delay is ~5s (also via maintain_gossip_sync).
      Future<void>.delayed(const Duration(seconds: 5), () {
        if (!_running) return;
        _maintainGossipAndFlush();
      });
      notifyListeners();
    } catch (e, st) {
      debugPrint('[OfflineBLE] connectNearbyDevice error: $e\n$st');
      final msg = e.toString();
      if (msg.toLowerCase().contains('abort') ||
          msg.toLowerCase().contains('cancel')) {
        _status = 'Connect cancelled';
      } else {
        var detail = msg.replaceFirst(RegExp(r'^[^:]+:\s*'), '');
        if (detail.length > 180) {
          detail = '${detail.substring(0, 177)}…';
        }
        _status = detail;
      }
      notifyListeners();
    } finally {
      _connectingNearby = false;
      notifyListeners();
    }
  }

  void selectPeer(String? peerId) {
    _selectedPeerId = peerId;
    notifyListeners();
  }

  /// Tell the controller which private thread the UI is viewing.
  void setPrivateView(String? peerId) {
    _privateViewPeerId = peerId;
    if (peerId != null) markPeerMessagesRead(peerId);
  }

  /// Queue Noise read receipts for inbound DMs / private media from [peerId].
  void markPeerMessagesRead(String peerId) {
    if (peerId.isEmpty || _session == null) return;
    final ids = <String>[];
    final seen = <String>{};
    for (final m in _messages) {
      if (m.isLocal ||
          m.fromPeerId != peerId ||
          m.messageId == null ||
          m.messageId!.isEmpty ||
          !m.isPrivate) {
        continue;
      }
      if (seen.add(m.messageId!)) ids.add(m.messageId!);
    }
    if (ids.isEmpty) return;
    _sendReadReceipts(peerId, ids);
    notifyListeners();
  }

  Future<void> startSecureChat(String peerId) async {
    final session = _session;
    if (session == null) return;
    try {
      session.startNoiseHandshake(peerId: peerId);
      _selectedPeerId = peerId;
      _status = 'Noise handshake…';
      _pullEvents();
      await _flushOutbound();
      notifyListeners();
    } catch (e) {
      _status = 'Handshake failed: $e';
      notifyListeners();
    }
  }

  /// BitChat QR verification challenge toward [peerId] (needs announce keys + Noise).
  Future<void> startQrVerification(String peerId) async {
    final session = _session;
    if (session == null) return;
    try {
      _selectedPeerId = peerId;
      session.startQrVerification(peerId: peerId);
      _status = 'Verify challenge → ${peerId.substring(0, 8)}…';
      _pullEvents();
      await _flushOutbound();
      notifyListeners();
    } catch (e) {
      _status = 'Verify failed: $e';
      notifyListeners();
    }
  }

  /// BitChat-style live rename: update local nick and force-announce to peers.
  Future<void> updateNickname(String nickname) async {
    final nick = nickname.trim().isEmpty
        ? identity.peerId.substring(0, 8)
        : nickname.trim();
    // Cap like BitChat UI nicknames (keep announces small).
    final clipped = nick.length > 32 ? nick.substring(0, 32) : nick;
    if (clipped == _nickname) return;
    _nickname = clipped;
    final session = _session;
    if (session == null) {
      notifyListeners();
      return;
    }
    try {
      session.setNickname(nickname: clipped);
      _status = 'Nickname → $clipped';
      _queueAnnounceAndFlush();
      notifyListeners();
    } catch (e) {
      _status = 'Rename failed: $e';
      notifyListeners();
    }
  }

  Future<void> sendPublic(String text) async {
    final session = _session;
    if (session == null || text.trim().isEmpty) return;
    session.queuePublicMessage(text: text.trim());
    _pullEvents();
    await _flushOutbound();
    notifyListeners();
  }

  Future<void> sendPrivate(String text) async {
    final session = _session;
    final peerId = _selectedPeerId;
    if (session == null || peerId == null || text.trim().isEmpty) return;
    try {
      session.queuePrivateMessage(peerId: peerId, text: text.trim());
      _pullEvents();
      await _flushOutbound();
      notifyListeners();
    } catch (e) {
      _status = 'DM failed: $e';
      notifyListeners();
    }
  }

  /// Pick a photo, compress to ≤512 KiB JPEG, send as BitChat `fileTransfer`.
  /// When [private] and a peer is selected, sends a directed file (BitChat private file).
  Future<void> sendPhoto({bool private = false}) async {
    final session = _session;
    if (session == null) return;

    String? toPeer;
    if (private) {
      toPeer = _selectedPeerId;
      if (toPeer == null) {
        _status = 'Select a peer for private photo';
        notifyListeners();
        return;
      }
    }

    final result = await FilePicker.pickFiles(
      type: FileType.image,
      withData: true,
      allowMultiple: false,
    );
    if (result == null || result.files.isEmpty) return;
    final file = result.files.first;
    // Mobile FilePicker often returns path with null bytes even when withData: true.
    Uint8List? raw = file.bytes;
    if ((raw == null || raw.isEmpty) && file.path != null && file.path!.isNotEmpty) {
      try {
        raw = await readRecordingBytes(file.path!);
      } catch (e) {
        _status = 'Could not read photo: $e';
        notifyListeners();
        return;
      }
    }
    if (raw == null || raw.isEmpty) {
      _status = 'Could not read photo bytes';
      notifyListeners();
      return;
    }

    _status = 'Compressing photo…';
    notifyListeners();

    Uint8List? compressed;
    try {
      compressed = await compute(_compressIsolate, raw);
    } catch (e) {
      // Web / isolate fallback: compress on the UI isolate.
      compressed = compressMeshJpeg(raw);
      if (compressed == null) {
        _status = 'Photo compress failed: $e';
        notifyListeners();
        return;
      }
    }
    if (compressed == null) {
      _status = 'Photo too large (max ${kMaxMeshImageBytes ~/ 1024} KiB)';
      notifyListeners();
      return;
    }

    final name = meshImageFileName(file.name);
    try {
      session.queueFile(
        fileName: name,
        mimeType: 'image/jpeg',
        content: compressed,
        toPeerId: toPeer,
      );
      _status = private
          ? 'Sending private photo (${compressed.length ~/ 1024} KiB)…'
          : 'Sending photo (${compressed.length ~/ 1024} KiB)…';
      notifyListeners();
      _pullEvents();
      await _flushOutbound();
      _status = private ? 'Private photo sent' : 'Photo sent on mesh';
      notifyListeners();
    } catch (e) {
      final msg = e.toString();
      _status = msg.contains('legacy private media requires consent')
          ? 'Peer lacks E2E private media — send cancelled'
          : 'Photo send failed: $e';
      notifyListeners();
    }
  }

  /// Begin hold-to-record voice note (BitChat-compatible AAC/m4a or WAV).
  Future<void> startVoiceRecording({bool private = false}) async {
    if (!_running || _recording || _recordStarting || _session == null) return;
    _recordStarting = true;
    _pendingStopSend = null;
    notifyListeners();

    if (!kIsWeb) {
      final mic = await Permission.microphone.request();
      if (!mic.isGranted) {
        _recordStarting = false;
        _status = 'Microphone permission denied';
        notifyListeners();
        return;
      }
    }

    try {
      final recorder = _voiceRecorder();
      final hasPermission = await recorder.hasPermission();
      if (!hasPermission) {
        _recordStarting = false;
        _status = 'Microphone permission denied';
        notifyListeners();
        return;
      }

      final format = await resolveMeshVoiceFormat(recorder);
      // Web ignores path and returns a blob: URL from stop(); empty path is
      // the record_web recommended form. Native needs a real filesystem path.
      final path =
          kIsWeb ? '' : await meshVoiceOutputPath(format.extension);
      await recorder.start(
        RecordConfig(
          encoder: format.encoder,
          bitRate: format.bitRate,
          sampleRate: format.sampleRate,
          numChannels: 1,
          // Avoid feedback loop / Chrome autoplay quirks while capturing.
          echoCancel: true,
          noiseSuppress: true,
          autoGain: true,
        ),
        path: path,
      );
      _activeVoiceFormat = format;
      _privateVoiceIntent = private;
      _recording = true;
      _recordStarting = false;
      _recordStartedAt = DateTime.now();
      _status = private
          ? 'Recording private voice (max ${kMaxVoiceSeconds.toInt()}s)…'
          : 'Recording voice (max ${kMaxVoiceSeconds.toInt()}s)…';
      _recordLimitTimer?.cancel();
      _recordLimitTimer = Timer(
        Duration(milliseconds: (kMaxVoiceSeconds * 1000).round()),
        () {
          if (_recording) {
            stopVoiceRecording(send: true);
          }
        },
      );
      notifyListeners();

      final pending = _pendingStopSend;
      if (pending != null) {
        _pendingStopSend = null;
        await stopVoiceRecording(send: pending);
      }
    } catch (e) {
      _recording = false;
      _recordStarting = false;
      _recordStartedAt = null;
      _activeVoiceFormat = null;
      _pendingStopSend = null;
      try {
        await _recorder?.cancel();
      } catch (_) {}
      _status = 'Voice record failed: $e';
      notifyListeners();
    }
  }

  /// End recording. When [send] is true, queue a BitChat voice-note fileTransfer.
  Future<void> stopVoiceRecording({required bool send}) async {
    if (_recordStarting) {
      _pendingStopSend = send;
      return;
    }
    if (!_recording) return;
    _recordLimitTimer?.cancel();
    _recordLimitTimer = null;

    final started = _recordStartedAt;
    final format = _activeVoiceFormat;
    final private = _privateVoiceIntent;
    _recording = false;
    _recordStartedAt = null;
    _activeVoiceFormat = null;
    _privateVoiceIntent = false;
    notifyListeners();

    if (!send) {
      try {
        await _recorder?.cancel();
      } catch (_) {}
      _status = 'Voice recording discarded';
      notifyListeners();
      return;
    }

    String? path;
    try {
      path = await _recorder?.stop();
    } catch (e) {
      _status = 'Voice stop failed: $e';
      notifyListeners();
      return;
    }

    if (path == null || format == null || started == null) {
      _status = 'Voice recording cancelled';
      notifyListeners();
      return;
    }

    try {
      var bytes = await readRecordingBytes(path);
      if (kIsWeb && path.startsWith('blob:')) {
        try {
          revokeRecordingUrl(path);
        } catch (_) {}
      }
      if (bytes.isEmpty) {
        _status = 'Empty voice recording';
        notifyListeners();
        return;
      }
      if (isWebmBytes(bytes)) {
        _status =
            'Browser produced WebM audio (not BitChat-compatible). Try again.';
        notifyListeners();
        return;
      }

      // Web AudioContext is often 48 kHz → raw WAV blows the 512 KiB budget
      // in a few seconds. Downsample to 8 kHz mono before send.
      var mime = isWavBytes(bytes) ? 'audio/wav' : format.mimeType;
      var ext = isWavBytes(bytes) ? 'wav' : format.extension;
      bytes = prepareMeshVoiceBytes(bytes, mimeType: mime);
      if (isWavBytes(bytes)) {
        mime = 'audio/wav';
        ext = 'wav';
      }

      final elapsed =
          DateTime.now().difference(started).inMilliseconds / 1000.0;
      final audioSecs = wavDurationSeconds(bytes) ?? elapsed;
      if (audioSecs < kMinVoiceSeconds) {
        _status = 'Hold a bit longer to send a voice note';
        notifyListeners();
        return;
      }

      if (bytes.length > kMaxMeshVoiceBytes) {
        _status =
            'Voice note too large (${bytes.length ~/ 1024} KiB > ${kMaxMeshVoiceBytes ~/ 1024} KiB)';
        notifyListeners();
        return;
      }
      await _sendVoiceBytes(
        bytes: bytes,
        fileName: meshVoiceFileName(extension: ext),
        mimeType: mime,
        private: private,
      );
    } catch (e) {
      _status = 'Voice send failed: $e';
      notifyListeners();
    }
  }

  Future<void> _sendVoiceBytes({
    required Uint8List bytes,
    required String fileName,
    required String mimeType,
    required bool private,
  }) async {
    final session = _session;
    if (session == null) return;

    String? toPeer;
    if (private) {
      toPeer = _selectedPeerId;
      if (toPeer == null) {
        _status = 'Select a peer for private voice';
        notifyListeners();
        return;
      }
    }

    try {
      session.queueFile(
        fileName: fileName,
        mimeType: mimeType,
        content: bytes,
        toPeerId: toPeer,
      );
      _status = private
          ? 'Sending private voice (${bytes.length ~/ 1024} KiB)…'
          : 'Sending voice (${bytes.length ~/ 1024} KiB)…';
      _pullEvents();
      await _flushOutbound();
      _status = private ? 'Private voice sent' : 'Voice note sent on mesh';
      notifyListeners();
    } catch (e) {
      final msg = e.toString();
      _status = msg.contains('legacy private media requires consent')
          ? 'Peer lacks E2E private media — send cancelled'
          : 'Voice send failed: $e';
      notifyListeners();
    }
  }

  void _logFrame(String direction, Uint8List bytes, {String note = ''}) {
    _frames.add(
      MeshWireFrame(
        direction: direction,
        bytes: Uint8List.fromList(bytes),
        atMs: DateTime.now().millisecondsSinceEpoch,
        note: note,
      ),
    );
    while (_frames.length > _maxFrames) {
      _frames.removeAt(0);
    }
  }

  void _handleInbound(Uint8List bytes) {
    final session = _session;
    if (session == null) return;
    _logFrame('in', bytes);
    try {
      final relay = session.ingestFrame(bytes: bytes);
      _pullEvents();
      for (final frame in relay) {
        _logFrame('relay', frame.bytes, note: 'ttl hop');
        _safeSend(frame.bytes);
      }
      // REQUEST_SYNC / Noise / sync replies land in outbound, not relay.
      _scheduleFlushOutbound();
      notifyListeners();
    } catch (e) {
      // Soft-fail: BitChat drops bad BLE frames; don't freeze the UI status
      // on every glitch during a multi-fragment photo/voice transfer.
      debugPrint('[Offline] ingest dropped frame (${bytes.length} B): $e');
    }
  }

  void _queueAnnounceAndFlush() {
    try {
      _session?.queueAnnounce();
      _scheduleFlushOutbound();
    } catch (_) {}
  }

  void _maintainGossipAndFlush() {
    try {
      _session?.maintainGossipSync();
      _scheduleFlushOutbound();
    } catch (e) {
      debugPrint('[Offline] maintainGossipSync: $e');
    }
  }

  void _scheduleFlushOutbound() {
    // Never leave a bare Future — web surfaces those as "Uncaught Error".
    _flushOutbound().then((_) {}, onError: (Object e, StackTrace st) {
      debugPrint('[Offline] flushOutbound: $e\n$st');
    });
  }

  void _safeSend(Uint8List bytes) {
    _transport.send(bytes).then((_) {}, onError: (Object e, StackTrace st) {
      debugPrint('[Offline] transport.send: $e\n$st');
    });
  }

  Future<void> _flushOutbound() {
    // Serialize drains so a gossip tick cannot steal a voice/photo fragment train.
    final run = _flushChain.then((_) => _flushOutboundBody());
    _flushChain = run.catchError((_) {});
    return run;
  }

  Future<void> _flushOutboundBody() async {
    final session = _session;
    if (session == null) return;
    final frames = session.drainOutbound();
    if (frames.isEmpty) return;
    const fragmentPace = Duration(milliseconds: 18);
    var sent = 0;
    ChatLine? activeMedia;
    String? activeFragKey;

    for (var i = 0; i < frames.length; i++) {
      final frame = frames[i];
      final bytes = frame.bytes;
      final frag = _parseFragmentMeta(bytes);
      final isFragment = frag != null;
      if (frag != null) {
        if (frag.idHex != activeFragKey) {
          activeFragKey = frag.idHex;
          if (_mediaSendQueue.isNotEmpty) {
            activeMedia = _mediaSendQueue.removeAt(0);
          } else {
            for (final m in _messages) {
              if (m.isLocal &&
                  m.fileBytes != null &&
                  (m.deliveryStatus == 'sending' ||
                      (m.sendProgress != null && m.sendProgress! < 1))) {
                activeMedia = m;
                break;
              }
            }
          }
          if (activeMedia != null) {
            _setSendProgress(activeMedia, 0, 'sending');
          }
        }
        if (activeMedia != null) {
          _setSendProgress(
            activeMedia,
            (frag.index + 1) / frag.total,
            'sending',
          );
        }
      }

      _logFrame('out', bytes, note: frame.toPeerId ?? 'flood');
      try {
        await _transport.send(bytes, reliable: isFragment);
        sent++;
      } catch (e) {
        debugPrint('[Offline] send failed: $e');
      }

      if (frag != null &&
          activeMedia != null &&
          frag.index + 1 >= frag.total) {
        _setSendProgress(activeMedia, 1, 'sent');
        activeMedia = null;
        activeFragKey = null;
      } else if (!isFragment &&
          bytes.length > 1 &&
          (bytes[1] == 0x11 || bytes[1] == 0x22)) {
        if (_mediaSendQueue.isNotEmpty) {
          _setSendProgress(_mediaSendQueue.removeAt(0), 1, 'sent');
        }
      } else if (isFragment && i + 1 < frames.length) {
        await Future<void>.delayed(fragmentPace);
      }
    }
    if (sent < frames.length) {
      debugPrint(
        '[Offline] flush sent $sent/${frames.length} frames '
        '(${frames.length - sent} failed)',
      );
    }
  }

  void _setSendProgress(ChatLine m, double progress, String status) {
    final p = progress.clamp(0.0, 1.0);
    final changed =
        m.sendProgress != p || m.deliveryStatus != status;
    m.sendProgress = p;
    if (status == 'sending') {
      m.deliveryStatus = 'sending';
    } else if (m.deliveryStatus == 'sending' || m.deliveryStatus == null) {
      m.deliveryStatus = 'sent';
    }
    if (!changed) return;
    final now = DateTime.now();
    if (status == 'sent' ||
        now.difference(_lastProgressNotify).inMilliseconds > 80) {
      _lastProgressNotify = now;
      notifyListeners();
    }
  }

  void _sendReadReceipts(String peerId, List<String> messageIds) {
    final session = _session;
    if (session == null || messageIds.isEmpty) return;
    var queued = 0;
    for (final id in messageIds) {
      if (id.isEmpty) continue;
      try {
        session.queueReadReceipt(peerId: peerId, messageId: id);
        queued++;
        _pendingReadReceipts[peerId]?.remove(id);
        if (_pendingReadReceipts[peerId]?.isEmpty ?? false) {
          _pendingReadReceipts.remove(peerId);
        }
        for (final m in _messages) {
          if (!m.isLocal &&
              m.isPrivate &&
              m.messageId == id &&
              m.fromPeerId == peerId) {
            m.readByUs = true;
          }
        }
      } catch (_) {
        (_pendingReadReceipts[peerId] ??= <String>{}).add(id);
      }
    }
    if (queued > 0) _scheduleFlushOutbound();
  }

  void _flushPendingReadReceipts(String peerId) {
    final set = _pendingReadReceipts[peerId];
    if (set == null || set.isEmpty) return;
    _sendReadReceipts(peerId, set.toList());
  }

  void _pullEvents() {
    final session = _session;
    if (session == null) return;
    for (final ev in session.drainEvents()) {
      switch (ev.kind) {
        case 'announce':
          _refreshPeers();
          if (ev.nickname.isNotEmpty) {
            final short = ev.nickname.length > 24
                ? '${ev.nickname.substring(0, 21)}…'
                : ev.nickname;
            _status = 'Peer $short';
          }
          break;
        case 'message':
          _addMessage(
            ChatLine(
              fromPeerId: ev.peerId,
              text: ev.text,
              timestampMs: ev.timestampMs.toInt(),
              isLocal: ev.peerId == identity.peerId,
            ),
          );
          break;
        case 'dm':
          final local = ev.peerId == identity.peerId;
          final mid = ev.detail.isNotEmpty ? ev.detail : null;
          _addMessage(
            ChatLine(
              fromPeerId: ev.peerId,
              text: ev.text,
              timestampMs: ev.timestampMs.toInt(),
              isLocal: local,
              isPrivate: true,
              // Local DMs report our own peer id; conversation peer is selected.
              withPeerId: local ? _selectedPeerId : ev.peerId,
              messageId: mid,
              readByUs: local,
            ),
          );
          if (!local &&
              mid != null &&
              _privateViewPeerId == ev.peerId) {
            _sendReadReceipts(ev.peerId, [mid]);
          }
          break;
        case 'delivered':
        case 'read':
          final mid = ev.detail;
          if (mid.isNotEmpty) {
            for (final m in _messages) {
              if (m.isLocal &&
                  m.isPrivate &&
                  m.messageId == mid &&
                  _receiptRank(ev.kind) >= _receiptRank(m.deliveryStatus)) {
                m.deliveryStatus = ev.kind;
                break;
              }
            }
          }
          break;
        case 'file':
          final local = ev.peerId == identity.peerId;
          // Stable private-media id is mapped into `nickname` (FRB-safe).
          final mediaId =
              ev.nickname.isNotEmpty && ev.nickname.startsWith('media-')
                  ? ev.nickname
                  : null;
          final line = ChatLine(
            fromPeerId: ev.peerId,
            text: ev.fileName.isNotEmpty ? ev.fileName : ev.text,
            timestampMs: ev.timestampMs.toInt(),
            isLocal: local,
            isPrivate: ev.isPrivate,
            withPeerId: ev.isPrivate
                ? (local ? _selectedPeerId : ev.peerId)
                : null,
            messageId: mediaId,
            mimeType: ev.detail.isNotEmpty ? ev.detail : null,
            fileName: ev.fileName.isNotEmpty ? ev.fileName : null,
            fileBytes: ev.fileBytes.isNotEmpty
                ? Uint8List.fromList(ev.fileBytes)
                : null,
            deliveryStatus: local ? 'sending' : null,
            sendProgress: local ? 0 : null,
            readByUs: local,
          );
          _addMessage(line);
          if (local) _mediaSendQueue.add(line);
          if (!local &&
              ev.isPrivate &&
              mediaId != null &&
              _privateViewPeerId == ev.peerId) {
            _sendReadReceipts(ev.peerId, [mediaId]);
          }
          break;
        case 'noise':
          _refreshPeers();
          final parts = ev.detail.split(':');
          final state = parts.isNotEmpty ? parts.first : '';
          if (state == 'ready') {
            _status = 'Secure chat ready · ${ev.peerId.substring(0, 8)}';
            _flushPendingReadReceipts(ev.peerId);
            if (_privateViewPeerId == ev.peerId) {
              markPeerMessagesRead(ev.peerId);
            }
          } else if (state == 'failed') {
            _status = 'Noise failed: ${ev.detail}';
          } else if (state == 'handshaking') {
            _status = 'Handshaking · ${ev.peerId.substring(0, 8)}';
          }
          break;
        case 'leave':
          if (_selectedPeerId == ev.peerId) {
            _selectedPeerId = null;
          }
          if (_privateViewPeerId == ev.peerId) {
            _privateViewPeerId = null;
          }
          _pendingReadReceipts.remove(ev.peerId);
          _refreshPeers();
          break;
        case 'verified':
          _refreshPeers();
          final name = ev.nickname.isNotEmpty
              ? ev.nickname
              : ev.peerId.substring(0, 8);
          _status = 'Verified $name';
          _addMessage(
            ChatLine(
              fromPeerId: ev.peerId,
              text: '✓ Verified $name (QR challenge)',
              timestampMs: DateTime.now().millisecondsSinceEpoch,
              isLocal: true,
              isPrivate: true,
              withPeerId: ev.peerId,
            ),
          );
          break;
        case 'private_media_legacy':
          if (ev.detail == 'needs_consent') {
            _status =
                'Peer ${ev.peerId.substring(0, 8)} lacks E2E media — consent required';
          } else {
            _status =
                'Sent without E2E encryption → ${ev.peerId.substring(0, 8)}';
          }
          break;
      }
    }
    _refreshPeers();
  }

  /// Keep transcript chronological (BitChat packet timestamps, not receive order).
  void _addMessage(ChatLine line) {
    final ts = line.timestampMs;
    var i = _messages.length;
    while (i > 0 && _messages[i - 1].timestampMs > ts) {
      i--;
    }
    _messages.insert(i, line);
  }

  void _refreshPeers() {
    final session = _session;
    if (session == null) return;
    _peers
      ..clear()
      ..addAll(session.listPeers());
  }

  Future<bool> _ensurePermissions() async {
    if (defaultTargetPlatform != TargetPlatform.android &&
        defaultTargetPlatform != TargetPlatform.iOS) {
      return true;
    }
    final req = <Permission>[
      Permission.bluetooth,
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.bluetoothAdvertise,
      Permission.locationWhenInUse,
    ];
    if (defaultTargetPlatform == TargetPlatform.android) {
      req.add(Permission.notification);
    }
    final statuses = await req.request();
    final bleOk = (statuses[Permission.bluetoothScan]?.isGranted ?? true) ||
        (statuses[Permission.bluetooth]?.isGranted ?? false);
    final locOk = statuses[Permission.locationWhenInUse]?.isGranted ?? false;
    return bleOk && (locOk || defaultTargetPlatform == TargetPlatform.iOS);
  }

  @override
  void dispose() {
    _announceTimer?.cancel();
    _syncTimer?.cancel();
    _recordLimitTimer?.cancel();
    final recorder = _recorder;
    _recorder = null;
    if (recorder != null) {
      () async {
        try {
          if (_recording) await recorder.stop();
        } catch (_) {}
        try {
          await recorder.dispose();
        } catch (_) {}
      }();
    }
    _transport.onPacket = null;
    _transport.onLinkCount = null;
    _transport.onBleDevices = null;
    unawaited(_transport.stop().catchError((Object _) {}));
    _session?.dispose();
    super.dispose();
  }
}

Uint8List? _compressIsolate(Uint8List raw) => compressMeshJpeg(raw);

int _receiptRank(String? s) {
  switch (s) {
    case 'read':
      return 3;
    case 'delivered':
      return 2;
    case 'sent':
      return 1;
    case 'sending':
      return 0;
    default:
      return -1;
  }
}

class _FragmentMeta {
  const _FragmentMeta({
    required this.idHex,
    required this.index,
    required this.total,
  });
  final String idHex;
  final int index;
  final int total;
}

_FragmentMeta? _parseFragmentMeta(Uint8List bytes) {
  if (bytes.length < 14 || bytes[1] != 0x20) return null;
  final version = bytes[0];
  if (version != 1 && version != 2) return null;
  final flags = bytes[11];
  final hasRecipient = (flags & 0x01) != 0;
  final isCompressed = (flags & 0x04) != 0;
  final hasRoute = (flags & 0x08) != 0;
  var offset = 12;
  if (version == 2) {
    if (bytes.length < offset + 4) return null;
    offset += 4;
  } else {
    if (bytes.length < offset + 2) return null;
    offset += 2;
  }
  offset += 8; // sender
  if (hasRecipient) offset += 8;
  if (hasRoute) {
    if (bytes.length < offset + 1) return null;
    final hops = bytes[offset];
    offset += 1 + hops * 8;
  }
  if (isCompressed) offset += version == 2 ? 4 : 2;
  if (offset + 13 > bytes.length) return null;
  final idBuf = StringBuffer();
  for (var i = 0; i < 8; i++) {
    idBuf.write(bytes[offset + i].toRadixString(16).padLeft(2, '0'));
  }
  final index = (bytes[offset + 8] << 8) | bytes[offset + 9];
  final total = (bytes[offset + 10] << 8) | bytes[offset + 11];
  if (total == 0 || index >= total) return null;
  return _FragmentMeta(idHex: idBuf.toString(), index: index, total: total);
}
