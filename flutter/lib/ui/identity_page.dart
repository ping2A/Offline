import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:offline/src/rust/api/identity.dart';
import 'package:offline/ui/app_theme.dart';
import 'package:offline/ui/binary_qr.dart';
import 'package:offline/ui/identity_store.dart';
import 'package:offline/ui/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Share URI for Noise static public key (scannable / copy-paste).
String offlineNoiseShareUri(List<int> noisePublicKey) =>
    'offline:noise:${_hex(noisePublicKey)}';

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

enum _QrMode { offline, bitchat }

class IdentityPage extends StatefulWidget {
  const IdentityPage({
    super.key,
    required this.identity,
    required this.onRegenerated,
  });

  final StoredIdentity identity;
  final ValueChanged<StoredIdentity> onRegenerated;

  @override
  State<IdentityPage> createState() => _IdentityPageState();
}

class _IdentityPageState extends State<IdentityPage> {
  static const _nickPrefsKey = 'identity.verify_nick';

  _QrMode _mode = _QrMode.bitchat;
  late final TextEditingController _nick;
  String? _bitchatUri;
  String? _bitchatError;
  Timer? _refresh;
  Timer? _nickDebounce;

  StoredIdentity get identity => widget.identity;

  @override
  void initState() {
    super.initState();
    final fallback = identity.peerId.length >= 8
        ? identity.peerId.substring(0, 8)
        : identity.peerId;
    _nick = TextEditingController(text: fallback);
    unawaited(_loadNick());
    _rebuildBitChatQr();
    // BitChat rejects verify QRs older than ~5 minutes — refresh early.
    _refresh = Timer.periodic(const Duration(minutes: 2), (_) {
      if (_mode == _QrMode.bitchat && mounted) _rebuildBitChatQr();
    });
  }

  @override
  void didUpdateWidget(covariant IdentityPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.identity.peerId != widget.identity.peerId) {
      _rebuildBitChatQr();
    }
  }

  @override
  void dispose() {
    _refresh?.cancel();
    _nickDebounce?.cancel();
    _nick.dispose();
    super.dispose();
  }

  Future<void> _loadNick() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_nickPrefsKey)?.trim();
    if (saved != null && saved.isNotEmpty && mounted) {
      _nick.text = saved;
      _rebuildBitChatQr();
    }
  }

  Future<void> _saveNick(String nick) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_nickPrefsKey, nick.trim());
  }

  void _rebuildBitChatQr() {
    try {
      final uri = buildBitchatVerifyQr(
        noiseSecretKey: identity.noiseSecretKey,
        signingSecretKey: identity.signingSecretKey,
        nickname: _nick.text.trim().isEmpty
            ? identity.peerId.substring(0, 8)
            : _nick.text.trim(),
      );
      setState(() {
        _bitchatUri = uri;
        _bitchatError = null;
      });
    } catch (e) {
      setState(() {
        _bitchatUri = null;
        _bitchatError = '$e';
      });
    }
  }

  void _copy(BuildContext context, String label, String value) {
    Clipboard.setData(ClipboardData(text: value));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$label copied')),
    );
  }

  String get _activeUri =>
      _mode == _QrMode.offline
          ? offlineNoiseShareUri(identity.noisePublicKey)
          : (_bitchatUri ?? '');

  @override
  Widget build(BuildContext context) {
    final noiseHex = _hex(identity.noisePublicKey);
    final wide = MediaQuery.sizeOf(context).width >= 720;
    final shareUri = _activeUri;

    return ListView(
      padding: const EdgeInsets.only(bottom: 28),
      children: [
        const OfflinePageHeader(
          title: 'Identity',
          subtitle:
              'Share a QR BitChat (or Offline) can scan — same Noise key that binds your peer ID.',
        ),
        if (wide)
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: _qrCard(context, shareUri)),
              const SizedBox(width: 16),
              Expanded(child: _peerCard(context)),
            ],
          )
        else ...[
          _qrCard(context, shareUri),
          const SizedBox(height: 16),
          _peerCard(context),
        ],
        const SizedBox(height: 22),
        OfflineMonoBlock(
          label: 'Noise public key',
          value: noiseHex,
          onCopy: () => _copy(context, 'Noise public key', noiseHex),
        ),
        const SizedBox(height: 18),
        OfflineMonoBlock(
          label: 'Signing public key',
          value: _hex(identity.signingPublicKey),
          onCopy: () => _copy(
            context,
            'Signing public key',
            _hex(identity.signingPublicKey),
          ),
        ),
        const SizedBox(height: 18),
        OfflineMonoBlock(
          label: _mode == _QrMode.bitchat ? 'BitChat verify URI' : 'Share URI',
          value: shareUri.isEmpty ? (_bitchatError ?? '…') : shareUri,
          onCopy: shareUri.isEmpty
              ? null
              : () => _copy(context, 'Share URI', shareUri),
        ),
        const SizedBox(height: 28),
        OutlinedButton(
          onPressed: () async {
            final ok = await showDialog<bool>(
              context: context,
              builder: (ctx) => AlertDialog(
                title: const Text('Regenerate identity?'),
                content: const Text(
                  'This creates a new peer ID and keys. Existing mesh peers will treat you as a new device.',
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: const Text('Cancel'),
                  ),
                  FilledButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: const Text('Regenerate'),
                  ),
                ],
              ),
            );
            if (ok == true) {
              widget.onRegenerated(await IdentityStore.regenerate());
            }
          },
          child: const Text('Regenerate identity'),
        ),
      ],
    );
  }

  Widget _qrCard(BuildContext context, String shareUri) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: OfflineColors.raised,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: OfflineColors.line),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'VERIFY QR',
              style: GoogleFonts.ibmPlexMono(
                fontSize: 11,
                letterSpacing: 1.4,
                fontWeight: FontWeight.w600,
                color: OfflineColors.mist,
              ),
            ),
            const SizedBox(height: 10),
            SegmentedButton<_QrMode>(
              segments: const [
                ButtonSegment(
                  value: _QrMode.bitchat,
                  label: Text('BitChat'),
                  icon: Icon(Icons.verified_outlined, size: 16),
                ),
                ButtonSegment(
                  value: _QrMode.offline,
                  label: Text('Offline'),
                  icon: Icon(Icons.key_outlined, size: 16),
                ),
              ],
              selected: {_mode},
              onSelectionChanged: (s) {
                setState(() => _mode = s.first);
                if (_mode == _QrMode.bitchat) _rebuildBitChatQr();
              },
            ),
            if (_mode == _QrMode.bitchat) ...[
              const SizedBox(height: 12),
              TextField(
                controller: _nick,
                maxLength: 32,
                textInputAction: TextInputAction.done,
                decoration: const InputDecoration(
                  labelText: 'Nickname in QR',
                  counterText: '',
                  isDense: true,
                ),
                onChanged: (_) {
                  _nickDebounce?.cancel();
                  _nickDebounce = Timer(const Duration(milliseconds: 450), () {
                    _rebuildBitChatQr();
                    unawaited(_saveNick(_nick.text));
                  });
                },
                onSubmitted: (_) {
                  _nickDebounce?.cancel();
                  _rebuildBitChatQr();
                  unawaited(_saveNick(_nick.text));
                },
              ),
            ],
            const SizedBox(height: 14),
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 360),
                child: AspectRatio(
                  aspectRatio: 1,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: OfflineColors.line),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: shareUri.isEmpty
                          ? Center(
                              child: Text(
                                _bitchatError ?? 'Building…',
                                textAlign: TextAlign.center,
                                style: GoogleFonts.sourceSans3(
                                  color: OfflineColors.danger,
                                  fontSize: 13,
                                ),
                              ),
                            )
                          : TextQrView(data: shareUri),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              _mode == _QrMode.bitchat
                  ? 'BitChat must already see you on the mesh (Start mesh / Join BitChat), then scan this QR in BitChat’s verifier. Use Enlarge for a reliable scan.'
                  : 'Encodes offline:noise:… — your Curve25519 Noise static public key.',
              textAlign: TextAlign.center,
              style: GoogleFonts.sourceSans3(
                fontSize: 13,
                height: 1.35,
                color: OfflineColors.mist,
              ),
            ),
            const SizedBox(height: 4),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 4,
              children: [
                if (shareUri.isNotEmpty)
                  TextButton.icon(
                    onPressed: () => showLargeQrDialog(
                      context,
                      data: shareUri,
                      title: _mode == _QrMode.bitchat
                          ? 'BitChat verify QR'
                          : 'Offline share QR',
                    ),
                    icon: const Icon(Icons.fullscreen_rounded, size: 16),
                    label: const Text('Enlarge'),
                  ),
                if (_mode == _QrMode.bitchat)
                  TextButton.icon(
                    onPressed: _rebuildBitChatQr,
                    icon: const Icon(Icons.refresh_rounded, size: 16),
                    label: const Text('Refresh'),
                  ),
                TextButton.icon(
                  onPressed: shareUri.isEmpty
                      ? null
                      : () => _copy(context, 'Share URI', shareUri),
                  icon: const Icon(Icons.copy_rounded, size: 16),
                  label: const Text('Copy share link'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _peerCard(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: OfflineColors.raised,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: OfflineColors.line),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'PEER ID',
              style: GoogleFonts.ibmPlexMono(
                fontSize: 11,
                letterSpacing: 1.4,
                fontWeight: FontWeight.w600,
                color: OfflineColors.mist,
              ),
            ),
            const SizedBox(height: 10),
            SelectableText(
              identity.peerId,
              style: GoogleFonts.ibmPlexMono(
                fontSize: 28,
                fontWeight: FontWeight.w500,
                letterSpacing: 1.8,
                height: 1.2,
                color: OfflineColors.leaf,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              'First 8 bytes of SHA-256(Noise public key), shown as 16 hex chars — BitChat-compatible.',
              style: GoogleFonts.sourceSans3(
                fontSize: 14,
                height: 1.4,
                color: OfflineColors.mist,
              ),
            ),
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: () => _copy(context, 'Peer ID', identity.peerId),
              icon: const Icon(Icons.copy_rounded, size: 16),
              label: const Text('Copy peer ID'),
            ),
          ],
        ),
      ),
    );
  }
}
