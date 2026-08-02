import 'dart:async';
import 'dart:math' as math;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:offline/src/rust/api/mesh.dart';
import 'package:offline/ui/app_theme.dart';
import 'package:offline/ui/identity_store.dart';
import 'package:offline/ui/mesh_audio_blob.dart';
import 'package:offline/ui/mesh_audio_source.dart';
import 'package:offline/ui/mesh_chat_style.dart';
import 'package:offline/ui/mesh_controller.dart';
import 'package:offline/ui/mesh_emoji.dart';
import 'package:offline/ui/mesh_frame_decode.dart';

class MeshPage extends StatefulWidget {
  const MeshPage({super.key, required this.identity});

  final StoredIdentity identity;

  @override
  State<MeshPage> createState() => _MeshPageState();
}

class _MeshPageState extends State<MeshPage> with SingleTickerProviderStateMixin {
  late final MeshControllerService _mesh =
      MeshControllerService(widget.identity);
  final _text = TextEditingController();
  final _nick = TextEditingController();
  final _nickFocus = FocusNode();
  final _chatScroll = ScrollController();
  final _frameScroll = ScrollController();
  final _frameDetailScroll = ScrollController();
  final _frameQuery = TextEditingController();
  bool _sendPrivate = false;
  bool _showEmojiPicker = false;
  int _emojiCategory = 0;
  bool _showFrames = false;
  int? _selectedFrame;
  /// `in` | `out` | `relay` | null = all
  String? _frameDirFilter;
  /// Packet type name filter, or null = all
  String? _frameTypeFilter;
  int _chatFlex = 7;
  int _framesFlex = 2;
  Timer? _recordTick;

  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  )..repeat(reverse: true);

  @override
  void initState() {
    super.initState();
    _nick.text = widget.identity.peerId.substring(0, 8);
    _mesh.addListener(_onUpdate);
    // BitChat allows renaming after join — commit on blur.
    _nickFocus.addListener(() {
      if (!mounted) return;
      setState(() {});
      if (!_nickFocus.hasFocus) {
        unawaited(_commitNickname());
      }
    });
  }

  @override
  void dispose() {
    _recordTick?.cancel();
    _pulse.dispose();
    _mesh.removeListener(_onUpdate);
    _mesh.dispose();
    _text.dispose();
    _nick.dispose();
    _nickFocus.dispose();
    _chatScroll.dispose();
    _frameScroll.dispose();
    _frameDetailScroll.dispose();
    _frameQuery.dispose();
    super.dispose();
  }

  Future<void> _commitNickname() async {
    final next = _nick.text.trim();
    if (next.isEmpty) {
      _nick.text = _mesh.nickname.isNotEmpty
          ? _mesh.nickname
          : widget.identity.peerId.substring(0, 8);
      return;
    }
    if (next == _mesh.nickname) return;
    await _mesh.updateNickname(next);
    if (!mounted) return;
    // Reflect clipping / empty fallback from the controller.
    if (_nick.text != _mesh.nickname) {
      _nick.text = _mesh.nickname;
      _nick.selection = TextSelection.collapsed(offset: _nick.text.length);
    }
  }

  void _onUpdate() {
    if (!mounted) return;
    if (_selectedFrame != null &&
        _selectedFrame! >= _mesh.frames.length) {
      _selectedFrame = _mesh.frames.isEmpty ? null : _mesh.frames.length - 1;
    }
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_chatScroll.hasClients) {
        _chatScroll.animateTo(
          _chatScroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 240),
          curve: Curves.easeOutCubic,
        );
      }
      if (_showFrames &&
          _selectedFrame == null &&
          _frameScroll.hasClients) {
        _frameScroll.jumpTo(_frameScroll.position.maxScrollExtent);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final tip = kIsWeb &&
        _mesh.running &&
        _mesh.bleDeviceNames.isEmpty &&
        _mesh.peers.isEmpty;
    final hasPeers =
        _mesh.peers.isNotEmpty || _mesh.bleDeviceNames.isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _toolbar(),
        if (tip)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              'Join BitChat → UUID f47b5e2d-… (often unnamed)',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.sourceSans3(
                fontSize: 10,
                color: OfflineColors.mist,
              ),
            ),
          ),
        if (_mesh.status != null)
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: _statusLine(_mesh.status!),
          ),
        const SizedBox(height: 3),
        // Peers + Public/Private share one row to free vertical chat space.
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            if (hasPeers) ...[
              Expanded(child: _participantsPanel()),
              const SizedBox(width: 6),
              SizedBox(width: 148, child: _channelToggle()),
            ] else
              Expanded(child: _channelToggle()),
          ],
        ),
        if (_sendPrivate) ...[
          const SizedBox(height: 3),
          _dmPanel(),
        ],
        const SizedBox(height: 3),
        Expanded(
          flex: _showFrames ? _chatFlex : 1,
          child: _chatPane(),
        ),
        const SizedBox(height: 3),
        _composer(),
        if (_showFrames) ...[
          _framesResizeHandle(),
          Expanded(
            flex: _framesFlex,
            child: _framesDock(),
          ),
        ],
      ],
    );
  }

  Widget _framesResizeHandle() {
    return MouseRegion(
      cursor: SystemMouseCursors.resizeRow,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onVerticalDragUpdate: (d) {
          if (d.delta.dy.abs() < 1.5) return;
          setState(() {
            if (d.delta.dy > 0 && _framesFlex > 2) {
              _chatFlex += 1;
              _framesFlex -= 1;
            } else if (d.delta.dy < 0 && _chatFlex > 3) {
              _chatFlex -= 1;
              _framesFlex += 1;
            }
          });
        },
        child: SizedBox(
          height: 6,
          child: Center(
            child: Container(
              width: 28,
              height: 2,
              decoration: BoxDecoration(
                color: OfflineColors.line,
                borderRadius: BorderRadius.circular(999),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Indices into `_mesh.frames` matching search + chips.
  List<int> _filteredFrameIndices() {
    final q = _frameQuery.text.trim().toLowerCase();
    final out = <int>[];
    for (var i = 0; i < _mesh.frames.length; i++) {
      final f = _mesh.frames[i];
      if (_frameDirFilter != null && f.direction != _frameDirFilter) {
        continue;
      }
      if (_frameTypeFilter != null && f.typeName != _frameTypeFilter) {
        continue;
      }
      if (_frameMatches(f, q)) out.add(i);
    }
    return out;
  }

  bool _frameMatches(MeshWireFrame f, String q) {
    if (q.isEmpty) return true;
    if (f.direction.toLowerCase().contains(q)) return true;
    if (f.typeName.toLowerCase().contains(q)) return true;
    if (f.note.toLowerCase().contains(q)) return true;
    if ('${f.length}'.contains(q) || '${f.length}b'.contains(q)) return true;
    if (f.ttl != null && 'ttl ${f.ttl}'.contains(q)) return true;
    final typeByte = f.typeByte;
    if (typeByte != null) {
      final hex = typeByte.toRadixString(16).padLeft(2, '0');
      if (hex.contains(q) || '0x$hex'.contains(q)) return true;
    }
    final compactHex =
        f.hexFull.replaceAll(RegExp(r'\s+'), '').toLowerCase();
    final qHex = q.replaceAll(RegExp(r'[\s:]'), '');
    if (qHex.isNotEmpty && compactHex.contains(qHex)) return true;
    final breakdown = decodeMeshFrame(f.bytes);
    if (breakdown.summary.toLowerCase().contains(q)) return true;
    for (final p in breakdown.parts) {
      if (p.name.toLowerCase().contains(q)) return true;
      if (p.value.toLowerCase().contains(q)) return true;
    }
    for (final p in breakdown.payloadParts) {
      if (p.name.toLowerCase().contains(q)) return true;
      if (p.value.toLowerCase().contains(q)) return true;
    }
    return false;
  }

  static const double _toolbarH = 28;

  Widget _toolbar() {
    return SizedBox(
      height: _toolbarH,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _liveBadge(),
          const SizedBox(width: 6),
          _nickField(),
          const SizedBox(width: 4),
          FilledButton(
            style: FilledButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              minimumSize: const Size(0, _toolbarH),
              maximumSize: const Size(double.infinity, _toolbarH),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            onPressed: () async {
              if (_mesh.running) {
                await _mesh.stop();
              } else {
                await _mesh.start(nickname: _nick.text);
              }
            },
            child: Text(
              _mesh.running ? 'Stop' : 'Start',
              style: GoogleFonts.spaceGrotesk(
                fontSize: 12,
                height: 1.0,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          if (kIsWeb) ...[
            const SizedBox(width: 4),
            OutlinedButton(
              style: OutlinedButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: const Size(0, _toolbarH),
                maximumSize: const Size(double.infinity, _toolbarH),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              onPressed: _mesh.running ? () => _joinBitChat() : null,
              onLongPress: _mesh.running
                  ? () => _joinBitChat(showAllDevices: true)
                  : null,
              child: Text(
                _mesh.bleDeviceNames.isEmpty
                    ? 'Join'
                    : 'BLE ${_mesh.bleDeviceNames.length}',
                style: GoogleFonts.spaceGrotesk(
                  fontSize: 12,
                  height: 1.0,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
          const SizedBox(width: 4),
          _segmentToggle(),
          const Spacer(),
          Align(
            alignment: Alignment.centerRight,
            child: Text(
              '${_mesh.linkCount}L · ${_mesh.peers.length}P'
              '${_showFrames ? ' · ${_mesh.frames.length}F' : ''}',
              textAlign: TextAlign.right,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.ibmPlexMono(
                fontSize: 10,
                height: 1.0,
                color: OfflineColors.mist,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Same 28px shell as [_liveBadge] so label baselines match.
  /// Editable while live — BitChat force-announces renames to the mesh.
  Widget _nickField() {
    return Container(
      width: 104,
      height: _toolbarH,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: OfflineColors.raised,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: _nickFocus.hasFocus ? OfflineColors.moss : OfflineColors.line,
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: TextField(
        controller: _nick,
        focusNode: _nickFocus,
        enabled: true,
        textInputAction: TextInputAction.done,
        textAlignVertical: TextAlignVertical.center,
        style: GoogleFonts.spaceGrotesk(
          fontWeight: FontWeight.w600,
          fontSize: 12,
          height: 1.0,
          color: OfflineColors.ink,
        ),
        cursorHeight: 14,
        decoration: InputDecoration(
          hintText: 'Nick',
          hintStyle: GoogleFonts.spaceGrotesk(
            fontWeight: FontWeight.w600,
            fontSize: 12,
            height: 1.0,
            color: OfflineColors.mist,
          ),
          isDense: true,
          isCollapsed: true,
          filled: false,
          border: InputBorder.none,
          enabledBorder: InputBorder.none,
          focusedBorder: InputBorder.none,
          disabledBorder: InputBorder.none,
          contentPadding: EdgeInsets.zero,
        ),
        onSubmitted: (_) => unawaited(_commitNickname()),
      ),
    );
  }

  Widget _liveBadge() {
    return Container(
      height: _toolbarH,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: OfflineColors.raisedHigh,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: _mesh.running
              ? OfflineColors.signal.withValues(alpha: 0.35)
              : OfflineColors.line,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          AnimatedBuilder(
            animation: _pulse,
            builder: (context, _) {
              return Opacity(
                opacity: _mesh.running ? 0.55 + 0.45 * _pulse.value : 0.45,
                child: Container(
                  width: 5,
                  height: 5,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _mesh.running
                        ? OfflineColors.signal
                        : OfflineColors.mist,
                  ),
                ),
              );
            },
          ),
          const SizedBox(width: 5),
          Text(
            _mesh.running ? 'LIVE' : 'IDLE',
            style: GoogleFonts.ibmPlexMono(
              fontSize: 10,
              height: 1.0,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.6,
              color: OfflineColors.ink,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _joinBitChat({bool showAllDevices = false}) async {
    final proceed = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: Text(
            showAllDevices ? 'Pick BitChat from all devices' : 'Join BitChat',
            style: GoogleFonts.spaceGrotesk(fontWeight: FontWeight.w700),
          ),
          content: Text(
            showAllDevices
                ? 'Chrome will list every Bluetooth device nearby.\n\n'
                    'Select the phone advertising BitChat’s mesh service UUID:\n'
                    'f47b5e2d-4a9e-4c5a-9b3f-8e1d2c3a4b5c\n\n'
                    'BitChat usually has no device name — skip headphones, '
                    'keyboards, and other peripherals.'
                : 'Chrome’s picker is filtered to BitChat / Offline mesh.\n\n'
                    'Pick the entry advertising service UUID:\n'
                    'f47b5e2d-4a9e-4c5a-9b3f-8e1d2c3a4b5c\n\n'
                    'BitChat phones are often unnamed. Keep BitChat open in '
                    'the foreground. Long-press Join only if the list is empty.',
            style: GoogleFonts.sourceSans3(height: 1.4, fontSize: 15),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Open picker'),
            ),
          ],
        );
      },
    );
    if (proceed != true || !mounted) return;
    await _mesh.connectNearbyDevice(showAllDevices: showAllDevices);
  }

  Widget _segmentToggle() {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: OfflineColors.raised,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: OfflineColors.line),
      ),
      child: Material(
        color: _showFrames ? OfflineColors.moss : Colors.transparent,
        borderRadius: BorderRadius.circular(7),
        child: InkWell(
          onTap: () => setState(() {
            _showFrames = !_showFrames;
            if (!_showFrames) {
              _selectedFrame = null;
              _frameDirFilter = null;
              _frameTypeFilter = null;
            }
          }),
          borderRadius: BorderRadius.circular(7),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Center(
              child: Text(
                'Frames',
                style: GoogleFonts.spaceGrotesk(
                  fontWeight: FontWeight.w600,
                  fontSize: 11,
                  height: 1.0,
                  color: _showFrames
                      ? OfflineColors.onAccent
                      : OfflineColors.mist,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _statusLine(String text) {
    return Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: GoogleFonts.sourceSans3(
        fontSize: 11,
        color: OfflineColors.mist,
      ),
    );
  }

  Widget _participantsPanel() {
    final peers = _sortedPeers();
    final ble = _mesh.bleDeviceNames;
    final ready = peers.where((p) => p.noiseState == 'ready').length;
    const inlineCap = 10;
    final overflow = peers.length > inlineCap ? peers.length - inlineCap : 0;
    final inline = overflow > 0 ? peers.take(inlineCap).toList() : peers;

    return SizedBox(
      height: 28,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          _countPill('${peers.length}'),
          if (ble.isNotEmpty) ...[
            const SizedBox(width: 3),
            _countPill('${ble.length}B', accent: true),
          ],
          if (ready > 0) ...[
            const SizedBox(width: 3),
            _countPill('${ready}s'),
          ],
          const SizedBox(width: 6),
          Expanded(
            child: ListView(
              scrollDirection: Axis.horizontal,
              children: [
                for (final name in ble)
                  Padding(
                    padding: const EdgeInsets.only(right: 3),
                    child: _bleAvatar(
                      name == '(unnamed phone)' ? 'BLE' : name,
                    ),
                  ),
                for (final p in inline)
                  Padding(
                    padding: const EdgeInsets.only(right: 3),
                    child: _peerAvatar(p),
                  ),
                if (overflow > 0)
                  Padding(
                    padding: const EdgeInsets.only(right: 2),
                    child: _overflowAvatar(
                      overflow,
                      onTap: () => _showAllParticipants(peers),
                    ),
                  ),
              ],
            ),
          ),
          if (peers.length > 1)
            SizedBox(
              width: 28,
              height: 28,
              child: IconButton(
                tooltip: 'All participants',
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                onPressed: () => _showAllParticipants(peers),
                icon: const Icon(Icons.unfold_more_rounded, size: 16),
              ),
            ),
        ],
      ),
    );
  }

  List<MeshPeerInfo> _sortedPeers() {
    final list = List<MeshPeerInfo>.from(_mesh.peers);
    final selected = _mesh.selectedPeerId;
    int rank(MeshPeerInfo p) {
      if (p.peerId == selected) return 0;
      if (p.noiseState == 'ready') return 1;
      if (p.noiseState == 'handshaking') return 2;
      return 3;
    }

    list.sort((a, b) {
      final r = rank(a).compareTo(rank(b));
      if (r != 0) return r;
      final an = a.nickname.isEmpty ? a.peerId : a.nickname;
      final bn = b.nickname.isEmpty ? b.peerId : b.nickname;
      return an.toLowerCase().compareTo(bn.toLowerCase());
    });
    return list;
  }

  Widget _countPill(String text, {bool accent = false}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: accent
            ? OfflineColors.signal.withValues(alpha: 0.12)
            : OfflineColors.raised.withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: accent
              ? OfflineColors.signal.withValues(alpha: 0.35)
              : OfflineColors.line,
        ),
      ),
      child: Text(
        text,
        style: GoogleFonts.ibmPlexMono(
          fontSize: 9,
          fontWeight: FontWeight.w600,
          color: accent ? OfflineColors.signal : OfflineColors.mist,
        ),
      ),
    );
  }

  Widget _bleAvatar(String name) {
    return Tooltip(
      message: name,
      child: Container(
        width: 24,
        height: 24,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: OfflineColors.raisedHigh,
          border: Border.all(
            color: OfflineColors.signal.withValues(alpha: 0.5),
          ),
        ),
        child: const Icon(
          Icons.bluetooth_connected,
          size: 12,
          color: OfflineColors.signal,
        ),
      ),
    );
  }

  Widget _peerAvatar(MeshPeerInfo p) {
    final label =
        p.nickname.isEmpty ? p.peerId.substring(0, 8) : p.nickname;
    final selected = _mesh.selectedPeerId == p.peerId && _sendPrivate;
    final color = meshPeerColor(p.peerId);
    final lock = switch (p.noiseState) {
      'ready' => Icons.lock,
      'handshaking' => Icons.lock_clock,
      'failed' => Icons.lock_open,
      _ => null,
    };

    return Tooltip(
      message: '$label · ${p.noiseState}',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: () => _togglePeerDm(p),
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 160),
                width: 24,
                height: 24,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: color.withValues(alpha: selected ? 0.35 : 0.2),
                  border: Border.all(
                    color: selected ? OfflineColors.moss : color,
                    width: selected ? 2 : 1,
                  ),
                ),
                alignment: Alignment.center,
                child: Text(
                  _initials(label),
                  textAlign: TextAlign.center,
                  style: GoogleFonts.spaceGrotesk(
                    fontWeight: FontWeight.w700,
                    fontSize: 9,
                    height: 1.0,
                    color: OfflineColors.ink,
                  ),
                ),
              ),
              if (lock != null)
                Positioned(
                  right: -2,
                  bottom: -2,
                  child: Container(
                    width: 12,
                    height: 12,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: OfflineColors.canvas,
                      border: Border.all(color: OfflineColors.line),
                    ),
                    child: Icon(
                      lock,
                      size: 8,
                      color: p.noiseState == 'ready'
                          ? OfflineColors.signal
                          : OfflineColors.mist,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _overflowAvatar(int count, {required VoidCallback onTap}) {
    return Tooltip(
      message: '+$count more',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: Container(
            width: 24,
            height: 24,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: OfflineColors.raisedHigh,
              border: Border.all(color: OfflineColors.line),
            ),
            child: Text(
              '+$count',
              style: GoogleFonts.ibmPlexMono(
                fontSize: 8,
                fontWeight: FontWeight.w700,
                color: OfflineColors.ink,
              ),
            ),
          ),
        ),
      ),
    );
  }

  String _initials(String label) {
    final cleaned = label.trim();
    if (cleaned.isEmpty) return '?';
    final parts =
        cleaned.split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.length >= 2) {
      return ('${parts[0][0]}${parts[1][0]}').toUpperCase();
    }
    if (cleaned.length >= 2) return cleaned.substring(0, 2).toUpperCase();
    return cleaned[0].toUpperCase();
  }

  void _togglePeerDm(MeshPeerInfo p) {
    final selected = _mesh.selectedPeerId == p.peerId;
    if (selected && _sendPrivate) {
      _mesh.selectPeer(null);
      setState(() => _sendPrivate = false);
    } else {
      _mesh.selectPeer(p.peerId);
      setState(() => _sendPrivate = true);
    }
  }

  Future<void> _showAllParticipants(List<MeshPeerInfo> peers) async {
    final query = TextEditingController();
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: OfflineColors.canvas,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setModal) {
            final q = query.text.trim().toLowerCase();
            final filtered = q.isEmpty
                ? peers
                : peers.where((p) {
                    final nick = p.nickname.toLowerCase();
                    final id = p.peerId.toLowerCase();
                    return nick.contains(q) || id.contains(q);
                  }).toList();
            final height = MediaQuery.sizeOf(ctx).height * 0.62;
            return SizedBox(
              height: height,
              child: Padding(
                padding: EdgeInsets.only(
                  left: 16,
                  right: 16,
                  top: 12,
                  bottom: MediaQuery.paddingOf(ctx).bottom + 12,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Center(
                      child: Container(
                        width: 36,
                        height: 4,
                        decoration: BoxDecoration(
                          color: OfflineColors.line,
                          borderRadius: BorderRadius.circular(999),
                        ),
                      ),
                    ),
                    const SizedBox(height: 14),
                    Text(
                      'Participants',
                      style: GoogleFonts.spaceGrotesk(
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                        color: OfflineColors.ink,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${peers.length} on the mesh — tap to open a DM',
                      style: GoogleFonts.sourceSans3(
                        fontSize: 13,
                        color: OfflineColors.mist,
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: query,
                      onChanged: (_) => setModal(() {}),
                      autofocus: peers.length > 6,
                      decoration: const InputDecoration(
                        hintText: 'Filter by nickname or peer id',
                        prefixIcon: Icon(Icons.search, size: 20),
                        isDense: true,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Expanded(
                      child: filtered.isEmpty
                          ? Center(
                              child: Text(
                                'No matches',
                                style: GoogleFonts.sourceSans3(
                                  color: OfflineColors.mist,
                                ),
                              ),
                            )
                          : ListView.separated(
                              itemCount: filtered.length,
                              separatorBuilder: (_, __) => Divider(
                                height: 1,
                                color: OfflineColors.line.withValues(alpha: 0.7),
                              ),
                              itemBuilder: (context, i) {
                                final p = filtered[i];
                                final label = p.nickname.isEmpty
                                    ? p.peerId.substring(0, 8)
                                    : p.nickname;
                                final selected =
                                    _mesh.selectedPeerId == p.peerId &&
                                        _sendPrivate;
                                final color = meshPeerColor(p.peerId);
                                return ListTile(
                                  contentPadding: EdgeInsets.zero,
                                  leading: CircleAvatar(
                                    backgroundColor:
                                        color.withValues(alpha: 0.25),
                                    foregroundColor: OfflineColors.ink,
                                    child: Text(
                                      _initials(label),
                                      style: GoogleFonts.spaceGrotesk(
                                        fontWeight: FontWeight.w700,
                                        fontSize: 13,
                                      ),
                                    ),
                                  ),
                                  title: Text(
                                    label,
                                    style: GoogleFonts.spaceGrotesk(
                                      fontWeight: FontWeight.w600,
                                      color: selected
                                          ? OfflineColors.moss
                                          : OfflineColors.ink,
                                    ),
                                  ),
                                  subtitle: Text(
                                    '${p.peerId.substring(0, 8)} · ${p.noiseState}',
                                    style: GoogleFonts.ibmPlexMono(
                                      fontSize: 11,
                                      color: OfflineColors.mist,
                                    ),
                                  ),
                                  trailing: Icon(
                                    selected
                                        ? Icons.lock_rounded
                                        : Icons.chevron_right_rounded,
                                    color: selected
                                        ? OfflineColors.moss
                                        : OfflineColors.mist,
                                  ),
                                  onTap: () {
                                    Navigator.of(ctx).pop();
                                    _mesh.selectPeer(p.peerId);
                                    setState(() => _sendPrivate = true);
                                  },
                                );
                              },
                            ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
    query.dispose();
  }

  Widget _channelToggle() {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: OfflineColors.raised,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: OfflineColors.line),
      ),
      child: Padding(
        padding: const EdgeInsets.all(2),
        child: Row(
          children: [
            Expanded(
              child: _channelTab(
                label: 'Pub',
                icon: Icons.public_outlined,
                selected: !_sendPrivate,
                privateAccent: false,
                onTap: () => setState(() {
                  _sendPrivate = false;
                }),
              ),
            ),
            Expanded(
              child: _channelTab(
                label: 'DM',
                icon: Icons.lock_rounded,
                selected: _sendPrivate,
                privateAccent: true,
                onTap: () {
                  setState(() => _sendPrivate = true);
                  if (_mesh.selectedPeerId == null && _mesh.peers.isNotEmpty) {
                    _mesh.selectPeer(_mesh.peers.first.peerId);
                  }
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _channelTab({
    required String label,
    required IconData icon,
    required bool selected,
    required bool privateAccent,
    required VoidCallback onTap,
  }) {
    final accent = privateAccent ? OfflineColors.moss : OfflineColors.ink;
    final selectedFill = privateAccent
        ? OfflineColors.moss.withValues(alpha: 0.2)
        : OfflineColors.raisedHigh;
    return Material(
      color: selected ? selectedFill : Colors.transparent,
      borderRadius: BorderRadius.circular(6),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 5),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 12,
                color: selected ? accent : OfflineColors.mist,
              ),
              const SizedBox(width: 3),
              Flexible(
                child: Text(
                  label,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: GoogleFonts.spaceGrotesk(
                    fontWeight: FontWeight.w600,
                    fontSize: 11,
                    height: 1.0,
                    color: selected
                        ? (privateAccent
                            ? OfflineColors.leaf
                            : OfflineColors.ink)
                        : OfflineColors.mist,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _dmPanel() {
    final p = _mesh.selectedPeer;
    if (p == null) {
      return DecoratedBox(
        decoration: BoxDecoration(
          color: OfflineColors.moss.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: OfflineColors.moss.withValues(alpha: 0.35)),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(6, 3, 6, 3),
          child: Row(
            children: [
              const Icon(Icons.person_search_outlined,
                  size: 12, color: OfflineColors.moss),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  _mesh.peers.isEmpty
                      ? 'No peers yet — wait for an announce.'
                      : 'Tap a peer to open a DM.',
                  style: GoogleFonts.sourceSans3(
                    fontSize: 11,
                    height: 1.2,
                    color: OfflineColors.ink,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    final label =
        p.nickname.isEmpty ? p.peerId.substring(0, 8) : p.nickname;
    final ready = p.noiseState == 'ready';
    final handshaking = p.noiseState == 'handshaking';
    final status = ready
        ? 'Secure'
        : handshaking
            ? 'Handshaking…'
            : 'Noise on first send';

    return DecoratedBox(
      decoration: BoxDecoration(
        color: OfflineColors.moss.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: OfflineColors.moss.withValues(alpha: 0.45)),
      ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(6, 2, 0, 2),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Icon(
                ready ? Icons.lock_rounded : Icons.lock_outline_rounded,
                size: 13,
                color: OfflineColors.moss,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: label,
                        style: GoogleFonts.spaceGrotesk(
                          fontWeight: FontWeight.w700,
                          fontSize: 12,
                          height: 1.1,
                          color: OfflineColors.ink,
                        ),
                      ),
                      TextSpan(
                        text: ' · $status',
                        style: GoogleFonts.ibmPlexMono(
                          fontSize: 10,
                          height: 1.1,
                          color: ready
                              ? OfflineColors.signal
                              : OfflineColors.mist,
                        ),
                      ),
                    ],
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  strutStyle: const StrutStyle(
                    fontSize: 12,
                    height: 1.1,
                    forceStrutHeight: true,
                  ),
                ),
              ),
            if (_mesh.peers.length > 1)
              PopupMenuButton<String>(
                tooltip: 'Switch peer',
                padding: EdgeInsets.zero,
                onSelected: (id) {
                  _mesh.selectPeer(id);
                  setState(() => _sendPrivate = true);
                },
                itemBuilder: (ctx) => [
                  for (final peer in _mesh.peers)
                    PopupMenuItem(
                      value: peer.peerId,
                      child: Text(
                        peer.nickname.isEmpty
                            ? peer.peerId.substring(0, 8)
                            : peer.nickname,
                      ),
                    ),
                ],
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 4),
                  child: Icon(Icons.swap_horiz, size: 18, color: OfflineColors.moss),
                ),
              ),
            SizedBox(
              width: 28,
              height: 28,
              child: IconButton(
                tooltip: 'Back to public mesh',
                padding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
                onPressed: () {
                  _mesh.selectPeer(null);
                  setState(() => _sendPrivate = false);
                },
                icon: const Icon(Icons.close_rounded, size: 16),
                color: OfflineColors.mist,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _paneShell({required Widget child, bool privateTint = false}) {
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: privateTint
              ? OfflineColors.moss.withValues(alpha: 0.45)
              : OfflineColors.line,
        ),
        color: privateTint
            ? OfflineColors.moss.withValues(alpha: 0.05)
            : OfflineColors.canvas.withValues(alpha: 0.85),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: child,
      ),
    );
  }

  List<ChatLine> _visibleMessages() {
    if (!_sendPrivate) {
      return _mesh.messages.where((m) => !m.isPrivate).toList();
    }
    final peer = _mesh.selectedPeerId;
    if (peer == null) return const [];
    return _mesh.messages.where((m) {
      if (!m.isPrivate) return false;
      final other = m.withPeerId ?? (m.isLocal ? null : m.fromPeerId);
      return other == peer;
    }).toList();
  }

  Widget _chatPane() {
    final messages = _visibleMessages();
    if (messages.isEmpty) {
      return _paneShell(
        child: _EmptyChat(
          running: _mesh.running,
          privateMode: _sendPrivate,
          hasPeer: _mesh.selectedPeerId != null,
        ),
      );
    }
    return _paneShell(
      privateTint: _sendPrivate,
      child: ListView.builder(
        controller: _chatScroll,
        padding: const EdgeInsets.fromLTRB(6, 4, 6, 4),
        itemCount: messages.length,
        itemBuilder: (context, i) => _chatLine(messages[i]),
      ),
    );
  }

  String _senderName(ChatLine m) {
    if (m.isLocal) {
      final nick = _mesh.nickname.trim();
      return nick.isEmpty ? 'you' : nick;
    }
    for (final p in _mesh.peers) {
      if (p.peerId == m.fromPeerId) {
        final nick = p.nickname.trim();
        if (nick.isNotEmpty) return nick;
      }
    }
    final id = m.fromPeerId;
    return id.length >= 8 ? id.substring(0, 8) : id;
  }

  /// BitChat-style transcript: public lines stay plain; DMs get a locked rail.
  Widget _chatLine(ChatLine m) {
    final name = _senderName(m);
    final sender = meshSenderColor(isLocal: m.isLocal, peerId: m.fromPeerId);
    final bodyColor = meshBodyColor(sender, isPrivate: m.isPrivate);
    final time = meshFormatChatTime(m.timestampMs);
    final hasImage = m.fileBytes != null && m.fileBytes!.isNotEmpty && m.isImage;
    final hasAudio = m.fileBytes != null && m.fileBytes!.isNotEmpty && m.isAudio;

    String bodyText;
    if (hasImage) {
      bodyText = m.fileName ?? 'image';
    } else if (hasAudio) {
      bodyText = 'voice note';
    } else if (m.fileBytes != null && m.fileBytes!.isNotEmpty) {
      bodyText = m.fileName ?? m.text;
    } else {
      bodyText = m.text;
    }

    final receipt = m.isLocal && m.isPrivate && m.deliveryStatus != null
        ? ' · ${m.deliveryStatus}'
        : '';
    final textBlock = Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: m.isPrivate ? '$name  ' : '$name: ',
            style: meshTextStyle(
              GoogleFonts.ibmPlexMono(
                fontSize: 13,
                fontWeight: m.isLocal ? FontWeight.w700 : FontWeight.w600,
                color: sender,
                height: 1.35,
              ),
            ),
          ),
          TextSpan(
            text: bodyText,
            style: meshTextStyle(
              GoogleFonts.sourceSans3(
                fontSize: 13,
                height: 1.35,
                color: bodyColor,
                fontStyle: m.isPrivate ? FontStyle.italic : FontStyle.normal,
              ),
            ),
          ),
          TextSpan(
            text: ' [$time$receipt]',
            style: meshTextStyle(
              GoogleFonts.ibmPlexMono(
                fontSize: 11,
                color: OfflineColors.mist.withValues(alpha: 0.7),
                height: 1.35,
              ),
            ),
          ),
        ],
      ),
    );

    final media = hasImage
        ? Padding(
            padding: const EdgeInsets.only(top: 4),
            child: GestureDetector(
              onTap: () => _showPhoto(m),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: Image.memory(
                  m.fileBytes!,
                  width: 180,
                  fit: BoxFit.cover,
                  filterQuality: FilterQuality.medium,
                ),
              ),
            ),
          )
        : hasAudio
            ? Padding(
                padding: const EdgeInsets.only(top: 4),
                child: _VoiceNoteBubble(
                  bytes: m.fileBytes!,
                  mimeType: m.mimeType ?? 'audio/mp4',
                  fileName: m.fileName ?? m.text,
                  isLocal: m.isLocal,
                  isPrivate: m.isPrivate,
                ),
              )
            : const SizedBox.shrink();

    if (!m.isPrivate) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 3),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [textBlock, media],
        ),
      );
    }

    // Dedicated DM pane already signals privacy — skip the "Private" badge.
    if (_sendPrivate) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Align(
          alignment: m.isLocal ? Alignment.centerRight : Alignment.centerLeft,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: OfflineColors.moss.withValues(
                  alpha: m.isLocal ? 0.16 : 0.08,
                ),
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(10),
                  topRight: const Radius.circular(10),
                  bottomLeft: Radius.circular(m.isLocal ? 10 : 3),
                  bottomRight: Radius.circular(m.isLocal ? 3 : 10),
                ),
                border: Border.all(
                  color: OfflineColors.moss.withValues(alpha: 0.28),
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 5, 8, 5),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [textBlock, media],
                ),
              ),
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 5),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: OfflineColors.moss.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(8),
          border: const Border(
            left: BorderSide(color: OfflineColors.moss, width: 2),
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 5, 8, 5),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.lock_rounded,
                    size: 11,
                    color: OfflineColors.moss.withValues(alpha: 0.9),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    'Private',
                    style: GoogleFonts.ibmPlexMono(
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.5,
                      color: OfflineColors.moss,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 2),
              textBlock,
              media,
            ],
          ),
        ),
      ),
    );
  }

  void _showPhoto(ChatLine m) {
    final bytes = m.fileBytes;
    if (bytes == null) return;
    showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.black,
        insetPadding: const EdgeInsets.all(16),
        child: Stack(
          children: [
            InteractiveViewer(
              child: Center(
                child: Image.memory(bytes, fit: BoxFit.contain),
              ),
            ),
            Positioned(
              top: 8,
              right: 8,
              child: IconButton(
                onPressed: () => Navigator.of(ctx).pop(),
                icon: const Icon(Icons.close, color: Colors.white),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _framesDock() {
    final filtered = _filteredFrameIndices();
    final selected = _selectedFrame;
    final hasSelection =
        selected != null && selected >= 0 && selected < _mesh.frames.length;
    final selectedVisible =
        hasSelection && filtered.contains(selected);
    final selectedRow =
        selectedVisible ? filtered.indexOf(selected) : -1;

    final typeOptions = <String>{
      for (final f in _mesh.frames) f.typeName,
    }.toList()
      ..sort();

    return LayoutBuilder(
      builder: (context, constraints) {
        final sideBySide = constraints.maxWidth >= 720;
        final listPane = _frameListPane(filtered);
        final detailPane = selectedVisible
            ? _FrameDetailPane(
                frame: _mesh.frames[selected],
                indexLabel: '#${selected + 1}',
                scrollController: _frameDetailScroll,
                onClose: () => setState(() => _selectedFrame = null),
                onPrev: selectedRow > 0
                    ? () => setState(
                          () => _selectedFrame = filtered[selectedRow - 1],
                        )
                    : null,
                onNext: selectedRow >= 0 && selectedRow < filtered.length - 1
                    ? () => setState(
                          () => _selectedFrame = filtered[selectedRow + 1],
                        )
                    : null,
              )
            : _FramesEmptyDetail(
                emptyLog: _mesh.frames.isEmpty,
                filteredOut: filtered.isEmpty && _mesh.frames.isNotEmpty,
              );

        return _paneShell(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 4, 2, 3),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    const Icon(Icons.terminal_rounded,
                        size: 14, color: OfflineColors.leaf),
                    const SizedBox(width: 6),
                    Text(
                      'FRAMES',
                      style: GoogleFonts.ibmPlexMono(
                        fontSize: 11,
                        height: 1.0,
                        letterSpacing: 1.1,
                        fontWeight: FontWeight.w700,
                        color: OfflineColors.leaf,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: OfflineColors.raisedHigh,
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(color: OfflineColors.line),
                      ),
                      child: Text(
                        filtered.length == _mesh.frames.length
                            ? '${_mesh.frames.length}'
                            : '${filtered.length}/${_mesh.frames.length}',
                        style: GoogleFonts.ibmPlexMono(
                          fontSize: 10,
                          height: 1.0,
                          fontWeight: FontWeight.w600,
                          color: OfflineColors.mist,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: SizedBox(
                        height: 26,
                        child: TextField(
                          controller: _frameQuery,
                          onChanged: (_) => setState(() {}),
                          textAlignVertical: TextAlignVertical.center,
                          style: GoogleFonts.ibmPlexMono(
                            fontSize: 11,
                            height: 1.0,
                          ),
                          decoration: InputDecoration(
                            isDense: true,
                            isCollapsed: true,
                            hintText: 'Filter type · hex · field…',
                            hintStyle: GoogleFonts.sourceSans3(
                              fontSize: 11,
                              height: 1.0,
                              color: OfflineColors.mist,
                            ),
                            prefixIcon: const Icon(Icons.search, size: 14),
                            prefixIconConstraints: const BoxConstraints(
                              minWidth: 28,
                              minHeight: 26,
                            ),
                            suffixIcon: _frameQuery.text.isEmpty
                                ? null
                                : IconButton(
                                    tooltip: 'Clear',
                                    padding: EdgeInsets.zero,
                                    onPressed: () {
                                      _frameQuery.clear();
                                      setState(() {});
                                    },
                                    icon: const Icon(Icons.close, size: 14),
                                  ),
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 6,
                            ),
                            filled: true,
                            fillColor: OfflineColors.raised,
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(6),
                              borderSide:
                                  const BorderSide(color: OfflineColors.line),
                            ),
                            enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(6),
                              borderSide:
                                  const BorderSide(color: OfflineColors.line),
                            ),
                            focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(6),
                              borderSide: const BorderSide(
                                color: OfflineColors.moss,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    SizedBox(
                      width: 28,
                      height: 26,
                      child: IconButton(
                        tooltip: 'Clear frames',
                        padding: EdgeInsets.zero,
                        onPressed: _mesh.frames.isEmpty
                            ? null
                            : () {
                                _mesh.clearFrames();
                                setState(() => _selectedFrame = null);
                              },
                        icon: const Icon(Icons.delete_outline, size: 16),
                      ),
                    ),
                    SizedBox(
                      width: 28,
                      height: 26,
                      child: IconButton(
                        tooltip: 'Hide inspector',
                        padding: EdgeInsets.zero,
                        onPressed: () => setState(() {
                          _showFrames = false;
                          _selectedFrame = null;
                        }),
                        icon: const Icon(Icons.close_rounded, size: 16),
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      _filterChip(
                        label: 'All',
                        selected: _frameDirFilter == null &&
                            _frameTypeFilter == null,
                        onTap: () => setState(() {
                          _frameDirFilter = null;
                          _frameTypeFilter = null;
                        }),
                      ),
                      const SizedBox(width: 4),
                      _filterChip(
                        label: 'IN',
                        selected: _frameDirFilter == 'in',
                        color: OfflineColors.leaf,
                        onTap: () => setState(() {
                          _frameDirFilter =
                              _frameDirFilter == 'in' ? null : 'in';
                        }),
                      ),
                      const SizedBox(width: 4),
                      _filterChip(
                        label: 'OUT',
                        selected: _frameDirFilter == 'out',
                        color: OfflineColors.moss,
                        onTap: () => setState(() {
                          _frameDirFilter =
                              _frameDirFilter == 'out' ? null : 'out';
                        }),
                      ),
                      const SizedBox(width: 4),
                      _filterChip(
                        label: 'RELAY',
                        selected: _frameDirFilter == 'relay',
                        color: const Color(0xFF8A6B3A),
                        onTap: () => setState(() {
                          _frameDirFilter =
                              _frameDirFilter == 'relay' ? null : 'relay';
                        }),
                      ),
                      if (typeOptions.isNotEmpty) ...[
                        const SizedBox(width: 8),
                        Container(
                          width: 1,
                          height: 14,
                          color: OfflineColors.line,
                        ),
                        const SizedBox(width: 8),
                      ],
                      for (final t in typeOptions) ...[
                        _filterChip(
                          label: t,
                          selected: _frameTypeFilter == t,
                          color: _frameTypeColor(t),
                          onTap: () => setState(() {
                            _frameTypeFilter =
                                _frameTypeFilter == t ? null : t;
                          }),
                        ),
                        const SizedBox(width: 4),
                      ],
                    ],
                  ),
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: sideBySide
                    ? Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          SizedBox(
                            width: math
                                .min(340.0, constraints.maxWidth * 0.4)
                                .toDouble(),
                            child: listPane,
                          ),
                          Container(width: 1, color: OfflineColors.line),
                          Expanded(child: detailPane),
                        ],
                      )
                    : Column(
                        children: [
                          Expanded(flex: 2, child: listPane),
                          Container(height: 1, color: OfflineColors.line),
                          Expanded(flex: 3, child: detailPane),
                        ],
                      ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _filterChip({
    required String label,
    required bool selected,
    required VoidCallback onTap,
    Color? color,
  }) {
    final accent = color ?? OfflineColors.moss;
    return Material(
      color: selected
          ? accent.withValues(alpha: 0.2)
          : OfflineColors.raised.withValues(alpha: 0.6),
      borderRadius: BorderRadius.circular(5),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(5),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(5),
            border: Border.all(
              color: selected
                  ? accent.withValues(alpha: 0.7)
                  : OfflineColors.line,
            ),
          ),
          child: Text(
            label,
            style: GoogleFonts.ibmPlexMono(
              fontSize: 10,
              height: 1.0,
              fontWeight: FontWeight.w600,
              color: selected ? accent : OfflineColors.mist,
            ),
          ),
        ),
      ),
    );
  }

  Widget _frameListPane(List<int> filtered) {
    if (_mesh.frames.isEmpty) {
      return Center(
        child: Text(
          'Waiting for wire traffic…',
          style: GoogleFonts.sourceSans3(
            fontSize: 12,
            color: OfflineColors.mist,
          ),
        ),
      );
    }
    if (filtered.isEmpty) {
      return Center(
        child: Text(
          'No frames match filters',
          style: GoogleFonts.sourceSans3(
            fontSize: 12,
            color: OfflineColors.mist,
          ),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 4, 8, 2),
          child: Row(
            children: [
              SizedBox(
                width: 36,
                child: Text('#',
                    style: GoogleFonts.ibmPlexMono(
                        fontSize: 9, color: OfflineColors.mist)),
              ),
              SizedBox(
                width: 36,
                child: Text('DIR',
                    style: GoogleFonts.ibmPlexMono(
                        fontSize: 9, color: OfflineColors.mist)),
              ),
              Expanded(
                child: Text('TYPE',
                    style: GoogleFonts.ibmPlexMono(
                        fontSize: 9, color: OfflineColors.mist)),
              ),
              SizedBox(
                width: 44,
                child: Text('SIZE',
                    textAlign: TextAlign.right,
                    style: GoogleFonts.ibmPlexMono(
                        fontSize: 9, color: OfflineColors.mist)),
              ),
              SizedBox(
                width: 58,
                child: Text('TIME',
                    textAlign: TextAlign.right,
                    style: GoogleFonts.ibmPlexMono(
                        fontSize: 9, color: OfflineColors.mist)),
              ),
            ],
          ),
        ),
        Container(height: 1, color: OfflineColors.line.withValues(alpha: 0.6)),
        Expanded(
          child: ListView.builder(
            controller: _frameScroll,
            padding: EdgeInsets.zero,
            itemCount: filtered.length,
            itemBuilder: (context, row) {
              final i = filtered[row];
              final f = _mesh.frames[i];
              final selectedHere = _selectedFrame == i;
              return _FrameTile(
                frame: f,
                index: i + 1,
                selected: selectedHere,
                onSelect: () => setState(() {
                  _selectedFrame = selectedHere ? null : i;
                }),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _composer() {
    final enabled = _mesh.running;
    final privateMode = _sendPrivate && _mesh.canSendPrivate;
    final dmWaitingPeer = _sendPrivate && !_mesh.canSendPrivate;
    final recording =
        _mesh.isRecordingVoice || _mesh.isVoiceArming;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: privateMode
            ? OfflineColors.moss.withValues(alpha: 0.08)
            : OfflineColors.raised,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: recording
              ? OfflineColors.danger.withValues(alpha: 0.55)
              : privateMode
                  ? OfflineColors.moss.withValues(alpha: 0.55)
                  : OfflineColors.line,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(0, 2, 4, 2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (recording)
              Padding(
                padding: const EdgeInsets.fromLTRB(6, 1, 6, 2),
                child: Row(
                  children: [
                    Container(
                      width: 6,
                      height: 6,
                      decoration: const BoxDecoration(
                        color: OfflineColors.danger,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      'REC ${_formatRec(_mesh.recordingElapsed)}/0:10',
                      style: GoogleFonts.ibmPlexMono(
                        fontSize: 10,
                        color: OfflineColors.danger,
                      ),
                    ),
                  ],
                ),
              ),
            if (_showEmojiPicker) _emojiPickerPanel(),
            SizedBox(
              height: 34,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  SizedBox(
                    width: 32,
                    height: 32,
                    child: IconButton(
                      tooltip:
                          privateMode ? 'Send private photo' : 'Send photo',
                      padding: EdgeInsets.zero,
                      visualDensity: VisualDensity.compact,
                      onPressed: enabled && !recording && !dmWaitingPeer
                          ? () => _mesh.sendPhoto(private: privateMode)
                          : null,
                      icon: Icon(
                        Icons.photo_outlined,
                        size: 18,
                        color: enabled && !recording && !dmWaitingPeer
                            ? OfflineColors.moss
                            : OfflineColors.mist,
                      ),
                    ),
                  ),
                  SizedBox(
                    width: 32,
                    height: 32,
                    child: IconButton(
                      tooltip: _showEmojiPicker ? 'Hide emoji' : 'Emoji',
                      padding: EdgeInsets.zero,
                      visualDensity: VisualDensity.compact,
                      onPressed: enabled && !recording && !dmWaitingPeer
                          ? () => setState(
                                () => _showEmojiPicker = !_showEmojiPicker,
                              )
                          : null,
                      icon: Icon(
                        _showEmojiPicker
                            ? Icons.keyboard_outlined
                            : Icons.emoji_emotions_outlined,
                        size: 18,
                        color: enabled && !recording && !dmWaitingPeer
                            ? (_showEmojiPicker
                                ? OfflineColors.moss
                                : OfflineColors.moss.withValues(alpha: 0.9))
                            : OfflineColors.mist,
                      ),
                    ),
                  ),
                  Tooltip(
                    message: 'Hold to record voice',
                    child: Listener(
                      // Must not defer to a disabled IconButton — IgnorePointer
                      // would swallow hold-to-record on web.
                      behavior: HitTestBehavior.opaque,
                      onPointerDown: enabled && !dmWaitingPeer
                          ? (_) {
                              _recordTick?.cancel();
                              _recordTick = Timer.periodic(
                                const Duration(milliseconds: 200),
                                (_) {
                                  if (mounted) setState(() {});
                                },
                              );
                              unawaited(
                                _mesh
                                    .startVoiceRecording(private: privateMode)
                                    .catchError((e) {
                                  debugPrint('startVoiceRecording: $e');
                                }),
                              );
                            }
                          : null,
                      onPointerUp: enabled && !dmWaitingPeer
                          ? (_) {
                              _recordTick?.cancel();
                              _recordTick = null;
                              unawaited(
                                _mesh
                                    .stopVoiceRecording(send: true)
                                    .catchError((e) {
                                  debugPrint('stopVoiceRecording: $e');
                                }),
                              );
                            }
                          : null,
                      onPointerCancel: enabled && !dmWaitingPeer
                          ? (_) {
                              _recordTick?.cancel();
                              _recordTick = null;
                              unawaited(
                                _mesh
                                    .stopVoiceRecording(send: false)
                                    .catchError((e) {
                                  debugPrint('cancelVoiceRecording: $e');
                                }),
                              );
                            }
                          : null,
                      child: SizedBox(
                        width: 32,
                        height: 32,
                        child: Center(
                          child: Icon(
                            recording || _mesh.isVoiceArming
                                ? Icons.mic
                                : Icons.mic_none_outlined,
                            size: 18,
                            color: recording || _mesh.isVoiceArming
                                ? OfflineColors.danger
                                : (enabled && !dmWaitingPeer
                                    ? OfflineColors.moss
                                    : OfflineColors.mist),
                          ),
                        ),
                      ),
                    ),
                  ),
                  Expanded(
                    child: TextField(
                      controller: _text,
                      enabled: enabled && !recording && !dmWaitingPeer,
                      textInputAction: TextInputAction.send,
                      textAlignVertical: TextAlignVertical.center,
                      style: meshTextStyle(
                        GoogleFonts.sourceSans3(
                          fontSize: 14,
                          height: 1.2,
                          color: OfflineColors.ink,
                        ),
                      ),
                      decoration: InputDecoration(
                        isDense: true,
                        hintText: !enabled
                            ? 'Start mesh to chat'
                            : recording
                                ? 'Recording…'
                                : dmWaitingPeer
                                    ? 'Select a peer…'
                                    : privateMode
                                        ? 'Private message…'
                                        : 'Message…',
                        filled: false,
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: 0,
                        ),
                      ),
                      onTap: () {
                        if (_showEmojiPicker) {
                          setState(() => _showEmojiPicker = false);
                        }
                      },
                      onSubmitted: enabled && !recording && !dmWaitingPeer
                          ? (_) => _send()
                          : null,
                    ),
                  ),
                  const SizedBox(width: 2),
                  SizedBox(
                    width: 34,
                    height: 30,
                    child: FilledButton(
                      onPressed: enabled && !recording && !dmWaitingPeer
                          ? _send
                          : null,
                      style: FilledButton.styleFrom(
                        minimumSize: const Size(34, 30),
                        padding: EdgeInsets.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        backgroundColor:
                            privateMode ? OfflineColors.moss : null,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                      child: Icon(
                        privateMode ? Icons.lock : Icons.north_east_rounded,
                        size: 16,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatRec(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  Widget _emojiPickerPanel() {
    final catIndex = _emojiCategory.clamp(0, kMeshEmojiCategories.length - 1);
    final emojis = kMeshEmojiCategories[catIndex].items;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 3),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: OfflineColors.canvas.withValues(alpha: 0.92),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: OfflineColors.line),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              height: 26,
              child: Row(
                children: [
                  for (var i = 0; i < kMeshEmojiCategories.length; i++)
                    Expanded(
                      child: Material(
                        color: i == catIndex
                            ? OfflineColors.moss.withValues(alpha: 0.2)
                            : Colors.transparent,
                        child: InkWell(
                          onTap: () => setState(() => _emojiCategory = i),
                          child: Center(
                            child: Text(
                              kMeshEmojiCategories[i].tab,
                              style: meshTextStyle(
                                TextStyle(
                                  fontSize: 14,
                                  height: 1.0,
                                  color: i == catIndex
                                      ? OfflineColors.ink
                                      : OfflineColors.mist,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            Container(height: 1, color: OfflineColors.line),
            SizedBox(
              height: 64,
              child: GridView.builder(
                padding: const EdgeInsets.fromLTRB(3, 2, 3, 2),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 10,
                  mainAxisSpacing: 0,
                  crossAxisSpacing: 0,
                  childAspectRatio: 1.15,
                ),
                itemCount: emojis.length,
                itemBuilder: (context, i) {
                  final e = emojis[i];
                  return InkWell(
                    borderRadius: BorderRadius.circular(4),
                    onTap: () {
                      insertEmojiAtCursor(_text, e);
                      setState(() {});
                    },
                    child: Center(
                      child: Text(
                        e,
                        style: meshTextStyle(
                          const TextStyle(fontSize: 16, height: 1.0),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _send() async {
    final text = _text.text;
    if (text.trim().isEmpty) return;
    if (_showEmojiPicker) {
      setState(() => _showEmojiPicker = false);
    }
    if (_sendPrivate) {
      if (!_mesh.canSendPrivate) return;
      _text.clear();
      await _mesh.sendPrivate(text);
      return;
    }
    _text.clear();
    await _mesh.sendPublic(text);
  }
}

class _EmptyChat extends StatelessWidget {
  const _EmptyChat({
    required this.running,
    this.privateMode = false,
    this.hasPeer = false,
  });

  final bool running;
  final bool privateMode;
  final bool hasPeer;

  @override
  Widget build(BuildContext context) {
    final title = privateMode
        ? (hasPeer ? 'No private messages yet' : 'Pick someone to DM')
        : (running ? 'Listening on the mesh' : 'Mesh is quiet');
    final body = privateMode
        ? (hasPeer
            ? 'Messages here stay between you and this peer over Noise.'
            : (_meshPeersHint()))
        : (kIsWeb
            ? (running
                ? 'Open another tab, or Join BitChat. Switch to Frames to inspect raw BinaryProtocol bytes.'
                : 'Start mesh, then Join BitChat. Pick the device with '
                    'service UUID f47b5e2d-… (often unnamed).')
            : (running
                ? 'Nearby peers appear when they announce. Tap one for Noise DMs.'
                : 'Start the mesh to advertise and chat offline.'));

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              privateMode ? Icons.lock_outline_rounded : Icons.graphic_eq_rounded,
              size: 22,
              color: OfflineColors.moss.withValues(alpha: 0.75),
            ),
            const SizedBox(height: 6),
            Text(
              title,
              style: GoogleFonts.spaceGrotesk(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: OfflineColors.ink,
              ),
            ),
            const SizedBox(height: 4),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 320),
              child: Text(
                body,
                textAlign: TextAlign.center,
                style: GoogleFonts.sourceSans3(
                  fontSize: 12,
                  height: 1.35,
                  color: OfflineColors.mist,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _meshPeersHint() {
    return 'Tap a peer chip above, or use the switcher in the DM header.';
  }
}

class _VoiceNoteBubble extends StatefulWidget {
  const _VoiceNoteBubble({
    required this.bytes,
    required this.mimeType,
    required this.fileName,
    required this.isLocal,
    required this.isPrivate,
  });

  final Uint8List bytes;
  final String mimeType;
  final String fileName;
  final bool isLocal;
  final bool isPrivate;

  @override
  State<_VoiceNoteBubble> createState() => _VoiceNoteBubbleState();
}

class _VoiceNoteBubbleState extends State<_VoiceNoteBubble> {
  final AudioPlayer _player = AudioPlayer();
  bool _playing = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  String? _blobUrl;

  @override
  void initState() {
    super.initState();
    _player.onPlayerComplete.listen((_) {
      if (mounted) {
        setState(() {
          _playing = false;
          _position = Duration.zero;
        });
      }
    });
    _player.onDurationChanged.listen((d) {
      if (mounted) setState(() => _duration = d);
    });
    _player.onPositionChanged.listen((p) {
      if (mounted) setState(() => _position = p);
    });
  }

  @override
  void dispose() {
    try {
      _player.stop();
    } catch (_) {}
    _player.dispose();
    if (_blobUrl != null) {
      revokeMeshAudioBlobUrl(_blobUrl);
      _blobUrl = null;
    }
    super.dispose();
  }

  Future<void> _toggle() async {
    if (_playing) {
      try {
        await _player.pause();
      } catch (_) {}
      if (mounted) setState(() => _playing = false);
      return;
    }
    try {
      await _player.stop();
      // Prefer blob:/BytesSource — never hand-roll data: UrlSource on web
      // (UriCoder.encodeOnce corrupts base64 AAC from BitChat).
      final source = meshAudioSource(widget.bytes, widget.mimeType);
      if (source is UrlSource && source.url.startsWith('blob:')) {
        if (_blobUrl != null && _blobUrl != source.url) {
          revokeMeshAudioBlobUrl(_blobUrl);
        }
        _blobUrl = source.url;
      }
      await _player.setSource(source);
      await _player.resume();
      if (mounted) setState(() => _playing = true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _playing = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Playback failed: $e'),
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }

  String _fmt(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final progress = _duration.inMilliseconds == 0
        ? 0.0
        : (_position.inMilliseconds / _duration.inMilliseconds).clamp(0.0, 1.0);

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Material(
          color: OfflineColors.moss,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: _toggle,
            child: SizedBox(
              width: 36,
              height: 36,
              child: Center(
                child: Icon(
                  _playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                  color: OfflineColors.onAccent,
                  size: 22,
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 10),
        SizedBox(
          width: 140,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: LinearProgressIndicator(
                  value: progress,
                  minHeight: 4,
                  backgroundColor: OfflineColors.ink.withValues(alpha: 0.12),
                  color: OfflineColors.moss,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                _duration == Duration.zero
                    ? 'voice note'
                    : (_playing ? _fmt(_position) : _fmt(_duration)),
                style: GoogleFonts.ibmPlexMono(
                  fontSize: 12,
                  color: OfflineColors.mist,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

Color _frameTypeColor(String typeName) {
  return switch (typeName) {
    'announce' => const Color(0xFF6B8F71),
    'message' => OfflineColors.leaf,
    'leave' => OfflineColors.mist,
    'noiseHandshake' => const Color(0xFF5B7C99),
    'noiseEncrypted' => const Color(0xFF7A9E6A),
    'fragment' => const Color(0xFFB07D4A),
    'requestSync' => const Color(0xFF8A6B9B),
    'fileTransfer' => OfflineColors.moss,
    _ => OfflineColors.mist,
  };
}

Color _frameDirColor(String dir) {
  return switch (dir) {
    'in' => OfflineColors.leaf,
    'out' => OfflineColors.moss,
    _ => const Color(0xFF8A6B3A),
  };
}

class _FramesEmptyDetail extends StatelessWidget {
  const _FramesEmptyDetail({
    required this.emptyLog,
    required this.filteredOut,
  });

  final bool emptyLog;
  final bool filteredOut;

  @override
  Widget build(BuildContext context) {
    final text = emptyLog
        ? 'Select a frame from the list — BinaryProtocol fields and a hex dump appear here.'
        : filteredOut
            ? 'No frames match these filters.'
            : 'Click a row to decode header, payload, and hex.';
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: GoogleFonts.sourceSans3(
            fontSize: 12,
            height: 1.35,
            color: OfflineColors.mist,
          ),
        ),
      ),
    );
  }
}

class _FrameTile extends StatelessWidget {
  const _FrameTile({
    required this.frame,
    required this.index,
    required this.selected,
    required this.onSelect,
  });

  final MeshWireFrame frame;
  final int index;
  final bool selected;
  final VoidCallback onSelect;

  @override
  Widget build(BuildContext context) {
    final time = DateTime.fromMillisecondsSinceEpoch(frame.atMs);
    final hh = time.hour.toString().padLeft(2, '0');
    final mm = time.minute.toString().padLeft(2, '0');
    final ss = time.second.toString().padLeft(2, '0');
    final dir = _frameDirColor(frame.direction);
    final typeColor = _frameTypeColor(frame.typeName);
    final subtitle = frame.note.isNotEmpty ? frame.note : frame.hexPreview;

    return Material(
      color: selected
          ? OfflineColors.moss.withValues(alpha: 0.12)
          : Colors.transparent,
      child: InkWell(
        onTap: onSelect,
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: Border(
              left: BorderSide(
                color: selected ? OfflineColors.moss : dir,
                width: selected ? 3 : 2,
              ),
              bottom: BorderSide(
                color: OfflineColors.line.withValues(alpha: 0.45),
              ),
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(6, 5, 8, 5),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    SizedBox(
                      width: 32,
                      child: Text(
                        '$index',
                        style: GoogleFonts.ibmPlexMono(
                          fontSize: 10,
                          height: 1.0,
                          color: OfflineColors.mist,
                        ),
                      ),
                    ),
                    SizedBox(
                      width: 36,
                      child: Text(
                        frame.direction.toUpperCase(),
                        style: GoogleFonts.ibmPlexMono(
                          fontSize: 10,
                          height: 1.0,
                          fontWeight: FontWeight.w700,
                          color: dir,
                        ),
                      ),
                    ),
                    Expanded(
                      child: Text(
                        frame.typeName,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.ibmPlexMono(
                          fontSize: 11,
                          height: 1.0,
                          fontWeight: FontWeight.w600,
                          color: typeColor,
                        ),
                      ),
                    ),
                    SizedBox(
                      width: 44,
                      child: Text(
                        '${frame.length}B',
                        textAlign: TextAlign.right,
                        style: GoogleFonts.ibmPlexMono(
                          fontSize: 10,
                          height: 1.0,
                          color: OfflineColors.mist,
                        ),
                      ),
                    ),
                    SizedBox(
                      width: 58,
                      child: Text(
                        '$hh:$mm:$ss',
                        textAlign: TextAlign.right,
                        style: GoogleFonts.ibmPlexMono(
                          fontSize: 10,
                          height: 1.0,
                          color: OfflineColors.mist,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.ibmPlexMono(
                    fontSize: 9,
                    height: 1.15,
                    color: OfflineColors.mist.withValues(alpha: 0.85),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _FrameDetailPane extends StatelessWidget {
  const _FrameDetailPane({
    required this.frame,
    required this.indexLabel,
    required this.scrollController,
    required this.onClose,
    this.onPrev,
    this.onNext,
  });

  final MeshWireFrame frame;
  final String indexLabel;
  final ScrollController scrollController;
  final VoidCallback onClose;
  final VoidCallback? onPrev;
  final VoidCallback? onNext;

  @override
  Widget build(BuildContext context) {
    final breakdown = decodeMeshFrame(frame.bytes);
    final dir = _frameDirColor(frame.direction);
    final typeColor = _frameTypeColor(frame.typeName);

    return ColoredBox(
      color: OfflineColors.canvas.withValues(alpha: 0.65),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 4, 2, 4),
            child: Row(
              children: [
                _navIcon(
                  Icons.chevron_left_rounded,
                  onPrev,
                  'Previous',
                ),
                _navIcon(
                  Icons.chevron_right_rounded,
                  onNext,
                  'Next',
                ),
                const SizedBox(width: 4),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                  decoration: BoxDecoration(
                    color: dir.withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    frame.direction.toUpperCase(),
                    style: GoogleFonts.ibmPlexMono(
                      fontSize: 10,
                      height: 1.0,
                      fontWeight: FontWeight.w700,
                      color: dir,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '$indexLabel  ${frame.typeName}',
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.ibmPlexMono(
                      fontSize: 12,
                      height: 1.0,
                      fontWeight: FontWeight.w700,
                      color: typeColor,
                    ),
                  ),
                ),
                Text(
                  '${frame.length}B',
                  style: GoogleFonts.ibmPlexMono(
                    fontSize: 10,
                    color: OfflineColors.mist,
                  ),
                ),
                if (frame.ttl != null) ...[
                  const SizedBox(width: 8),
                  Text(
                    'ttl ${frame.ttl}',
                    style: GoogleFonts.ibmPlexMono(
                      fontSize: 10,
                      color: OfflineColors.mist,
                    ),
                  ),
                ],
                const SizedBox(width: 4),
                _copyBtn(
                  context,
                  label: 'Copy',
                  tooltip: 'Copy hex',
                  text: frame.bytes
                      .map((b) => b.toRadixString(16).padLeft(2, '0'))
                      .join(''),
                ),
                _navIcon(Icons.unfold_less_rounded, onClose, 'Deselect'),
              ],
            ),
          ),
          if (breakdown.summary.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 4),
              child: Text(
                breakdown.summary,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: GoogleFonts.sourceSans3(
                  fontSize: 12,
                  height: 1.3,
                  color: OfflineColors.ink.withValues(alpha: 0.85),
                ),
              ),
            ),
          Expanded(
            child: ListView(
              controller: scrollController,
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
              children: [
                _FrameMapBar(parts: breakdown.parts, total: frame.length),
                const SizedBox(height: 10),
                _sectionLabel('HEADER', OfflineColors.leaf),
                const SizedBox(height: 4),
                if (breakdown.error != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      breakdown.error!,
                      style: GoogleFonts.sourceSans3(
                        fontSize: 12,
                        color: OfflineColors.danger,
                      ),
                    ),
                  ),
                for (final p in breakdown.parts) _FramePartRow(part: p),
                if (breakdown.payloadParts.isNotEmpty) ...[
                  const SizedBox(height: 10),
                  _sectionLabel('PAYLOAD', OfflineColors.moss),
                  const SizedBox(height: 4),
                  for (final p in breakdown.payloadParts)
                    _FramePartRow(part: p, nested: true),
                ],
                if (frame.note.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    frame.note,
                    style: GoogleFonts.sourceSans3(
                      fontSize: 11,
                      color: OfflineColors.mist,
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                _sectionLabel(
                  'HEX DUMP  ·  ${frame.length} bytes',
                  OfflineColors.mist,
                ),
                const SizedBox(height: 6),
                _HexDump(bytes: frame.bytes, parts: breakdown.parts),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static Widget _sectionLabel(String text, Color color) {
    return Text(
      text,
      style: GoogleFonts.ibmPlexMono(
        fontSize: 9,
        letterSpacing: 1.1,
        fontWeight: FontWeight.w700,
        color: color,
      ),
    );
  }

  static Widget _navIcon(IconData icon, VoidCallback? onTap, String tip) {
    return SizedBox(
      width: 28,
      height: 28,
      child: IconButton(
        tooltip: tip,
        padding: EdgeInsets.zero,
        onPressed: onTap,
        icon: Icon(icon, size: 18),
        color: onTap == null
            ? OfflineColors.mist.withValues(alpha: 0.35)
            : OfflineColors.ink,
      ),
    );
  }

  static Widget _copyBtn(
    BuildContext context, {
    required String label,
    required String tooltip,
    required String text,
  }) {
    return TextButton(
      onPressed: () async {
        await Clipboard.setData(ClipboardData(text: text));
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(tooltip),
              duration: const Duration(seconds: 1),
            ),
          );
        }
      },
      style: TextButton.styleFrom(
        foregroundColor: OfflineColors.mist,
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: 6),
        minimumSize: Size.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      child: Text(
        label,
        style: GoogleFonts.ibmPlexMono(fontSize: 10),
      ),
    );
  }
}

/// Classic offset · hex · ASCII dump, tinted by decoded field ranges.
class _HexDump extends StatelessWidget {
  const _HexDump({required this.bytes, required this.parts});

  final Uint8List bytes;
  final List<FramePart> parts;

  Color? _colorAt(int offset) {
    for (final p in parts) {
      if (offset >= p.offset && offset < p.offset + p.length) {
        return p.color;
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    if (bytes.isEmpty) {
      return Text(
        '(empty)',
        style: GoogleFonts.ibmPlexMono(fontSize: 11, color: OfflineColors.mist),
      );
    }
    final rows = <Widget>[];
    for (var base = 0; base < bytes.length; base += 16) {
      final end = math.min(base + 16, bytes.length);
      final hexSpans = <InlineSpan>[];
      final ascii = StringBuffer();
      for (var i = base; i < end; i++) {
        final b = bytes[i];
        final c = _colorAt(i) ?? OfflineColors.ink.withValues(alpha: 0.75);
        if (i > base) {
          hexSpans.add(TextSpan(
            text: i % 8 == 0 ? '  ' : ' ',
            style: GoogleFonts.ibmPlexMono(
              fontSize: 11,
              height: 1.45,
              color: OfflineColors.mist.withValues(alpha: 0.35),
            ),
          ));
        }
        hexSpans.add(TextSpan(
          text: b.toRadixString(16).padLeft(2, '0'),
          style: GoogleFonts.ibmPlexMono(
            fontSize: 11,
            height: 1.45,
            fontWeight: FontWeight.w500,
            color: c,
          ),
        ));
        final ch = b >= 0x20 && b < 0x7f ? String.fromCharCode(b) : '.';
        ascii.write(ch);
      }
      rows.add(
        Padding(
          padding: const EdgeInsets.only(bottom: 1),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 44,
                child: Text(
                  base.toRadixString(16).padLeft(4, '0'),
                  style: GoogleFonts.ibmPlexMono(
                    fontSize: 11,
                    height: 1.45,
                    color: OfflineColors.mist,
                  ),
                ),
              ),
              Expanded(
                flex: 5,
                child: Text.rich(TextSpan(children: hexSpans)),
              ),
              const SizedBox(width: 10),
              Expanded(
                flex: 2,
                child: Text(
                  ascii.toString(),
                  style: GoogleFonts.ibmPlexMono(
                    fontSize: 11,
                    height: 1.45,
                    color: OfflineColors.mist.withValues(alpha: 0.9),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }
    return DecoratedBox(
      decoration: BoxDecoration(
        color: OfflineColors.raised.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: OfflineColors.line),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
        child: SelectionArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: rows,
          ),
        ),
      ),
    );
  }
}

class _FrameMapBar extends StatelessWidget {
  const _FrameMapBar({
    required this.parts,
    required this.total,
  });

  final List<FramePart> parts;
  final int total;

  @override
  Widget build(BuildContext context) {
    if (parts.isEmpty || total <= 0) {
      return const SizedBox(height: 8);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: SizedBox(
            height: 12,
            child: Row(
              children: [
                for (final p in parts)
                  Expanded(
                    flex: p.length.clamp(1, total),
                    child: Tooltip(
                      message: '${p.name} · ${p.length}B · ${p.value}',
                      child: ColoredBox(color: p.color),
                    ),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 10,
          runSpacing: 4,
          children: [
            for (final p in parts)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: p.color,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    '${p.name} (${p.length}B)',
                    style: GoogleFonts.ibmPlexMono(
                      fontSize: 9,
                      color: OfflineColors.mist,
                    ),
                  ),
                ],
              ),
          ],
        ),
      ],
    );
  }
}

class _FramePartRow extends StatelessWidget {
  const _FramePartRow({required this.part, this.nested = false});

  final FramePart part;
  final bool nested;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: 3, left: nested ? 10 : 0),
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(
            left: BorderSide(color: part.color, width: 2.5),
          ),
          color: part.color.withValues(alpha: 0.05),
          borderRadius:
              const BorderRadius.horizontal(right: Radius.circular(5)),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 5, 8, 5),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Container(
                    width: 7,
                    height: 7,
                    margin: const EdgeInsets.only(right: 6),
                    decoration: BoxDecoration(
                      color: part.color,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      part.name,
                      style: GoogleFonts.ibmPlexMono(
                        fontSize: 11,
                        height: 1.15,
                        fontWeight: FontWeight.w700,
                        color: OfflineColors.ink,
                      ),
                    ),
                  ),
                  Text(
                    '${part.rangeLabel} · ${part.length}B',
                    style: GoogleFonts.ibmPlexMono(
                      fontSize: 9,
                      height: 1.15,
                      color: OfflineColors.mist,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 2),
              Text(
                part.value,
                style: GoogleFonts.ibmPlexMono(
                  fontSize: 11,
                  height: 1.25,
                  color: OfflineColors.leaf,
                ),
              ),
              if (part.explanation.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(
                  part.explanation,
                  style: GoogleFonts.sourceSans3(
                    fontSize: 11,
                    height: 1.3,
                    color: OfflineColors.ink.withValues(alpha: 0.72),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
