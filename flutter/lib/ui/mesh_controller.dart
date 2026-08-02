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
  /// BitChat Noise receipt: `delivered` or `read`.
  String? deliveryStatus;

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
  String? _status;
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
        _status = 'Joined mesh via ${names.join(', ')}';
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
        ? 'Live — Join BitChat to reach nearby BitChat phones'
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
    _peers.clear();
    _status = 'Mesh stopped';
    notifyListeners();
  }

  Future<void> connectNearbyDevice({bool showAllDevices = false}) async {
    if (!_running) {
      _status = 'Start mesh before joining BitChat';
      notifyListeners();
      return;
    }
    _status = showAllDevices
        ? 'All Bluetooth devices — pick the one advertising BitChat service '
            'f47b5e2d-… (often unnamed). Skip headphones/keyboards.'
        : 'Chrome will list devices advertising BitChat’s mesh service '
            'UUID (f47b5e2d-…). BitChat phones are often unnamed — pick that one.';
    notifyListeners();
    try {
      await _transport.connectNearbyDevice(showAllDevices: showAllDevices);
      _bleDeviceNames = _transport.bleDeviceNames;
      _linkCount = _transport.linkCount();
      _session?.setLinkCount(count: _linkCount);
      _status = _bleDeviceNames.isEmpty
          ? 'Device connected'
          : 'Joined via ${_bleDeviceNames.join(', ')}';
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
        _status = 'Join cancelled';
      } else {
        var detail = msg.replaceFirst(RegExp(r'^[^:]+:\s*'), '');
        if (detail.length > 180) {
          detail = '${detail.substring(0, 177)}…';
        }
        _status = detail;
      }
      notifyListeners();
    }
  }

  void selectPeer(String? peerId) {
    _selectedPeerId = peerId;
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
      _status = 'Photo send failed: $e';
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
      _status = 'Voice send failed: $e';
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
    // BitChat assembly window is ~30s; pace at 25ms (closer to BitChat's
    // bleFragmentSpacingMs) so large voice trains stay intact over BLE.
    const fragmentPace = Duration(milliseconds: 25);
    var sent = 0;
    for (var i = 0; i < frames.length; i++) {
      final frame = frames[i];
      _logFrame('out', frame.bytes, note: frame.toPeerId ?? 'flood');
      try {
        await _transport.send(frame.bytes);
        sent++;
      } catch (e) {
        debugPrint('[Offline] send failed: $e');
      }
      final isFragment =
          frame.bytes.length > 1 && frame.bytes[1] == 0x20;
      if (isFragment && i + 1 < frames.length) {
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
          _addMessage(
            ChatLine(
              fromPeerId: ev.peerId,
              text: ev.text,
              timestampMs: ev.timestampMs.toInt(),
              isLocal: ev.peerId == identity.peerId,
              isPrivate: true,
              // Local DMs report our own peer id; conversation peer is selected.
              withPeerId: ev.peerId == identity.peerId
                  ? _selectedPeerId
                  : ev.peerId,
              messageId: ev.detail.isNotEmpty ? ev.detail : null,
            ),
          );
          break;
        case 'delivered':
        case 'read':
          final mid = ev.detail;
          if (mid.isNotEmpty) {
            for (final m in _messages) {
              if (m.isLocal && m.isPrivate && m.messageId == mid) {
                m.deliveryStatus = ev.kind;
                break;
              }
            }
          }
          break;
        case 'file':
          final local = ev.peerId == identity.peerId;
          _addMessage(
            ChatLine(
              fromPeerId: ev.peerId,
              text: ev.fileName.isNotEmpty ? ev.fileName : ev.text,
              timestampMs: ev.timestampMs.toInt(),
              isLocal: local,
              isPrivate: ev.isPrivate,
              withPeerId: ev.isPrivate
                  ? (local ? _selectedPeerId : ev.peerId)
                  : null,
              mimeType: ev.detail.isNotEmpty ? ev.detail : null,
              fileName: ev.fileName.isNotEmpty ? ev.fileName : null,
              fileBytes: ev.fileBytes.isNotEmpty
                  ? Uint8List.fromList(ev.fileBytes)
                  : null,
            ),
          );
          break;
        case 'noise':
          _refreshPeers();
          final parts = ev.detail.split(':');
          final state = parts.isNotEmpty ? parts.first : '';
          if (state == 'ready') {
            _status = 'Secure chat ready · ${ev.peerId.substring(0, 8)}';
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
          _refreshPeers();
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
