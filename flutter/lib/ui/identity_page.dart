import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:offline/ui/app_theme.dart';
import 'package:offline/ui/binary_qr.dart';
import 'package:offline/ui/identity_store.dart';
import 'package:offline/ui/widgets.dart';

/// Share URI for Noise static public key (scannable / copy-paste).
String offlineNoiseShareUri(List<int> noisePublicKey) =>
    'offline:noise:${_hex(noisePublicKey)}';

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

class IdentityPage extends StatelessWidget {
  const IdentityPage({
    super.key,
    required this.identity,
    required this.onRegenerated,
  });

  final StoredIdentity identity;
  final ValueChanged<StoredIdentity> onRegenerated;

  void _copy(BuildContext context, String label, String value) {
    Clipboard.setData(ClipboardData(text: value));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$label copied')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final noiseHex = _hex(identity.noisePublicKey);
    final shareUri = offlineNoiseShareUri(identity.noisePublicKey);
    final wide = MediaQuery.sizeOf(context).width >= 720;

    return ListView(
      padding: const EdgeInsets.only(bottom: 28),
      children: [
        const OfflinePageHeader(
          title: 'Identity',
          subtitle:
              'Share your Noise public key so someone can verify you out of band — same key BitChat binds to your peer ID.',
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
          label: 'Share URI',
          value: shareUri,
          onCopy: () => _copy(context, 'Share URI', shareUri),
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
              onRegenerated(await IdentityStore.regenerate());
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
              'NOISE KEY',
              style: GoogleFonts.ibmPlexMono(
                fontSize: 11,
                letterSpacing: 1.4,
                fontWeight: FontWeight.w600,
                color: OfflineColors.mist,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Scan to share your public key',
              style: GoogleFonts.sourceSans3(
                fontSize: 15,
                height: 1.3,
                color: OfflineColors.ink,
              ),
            ),
            const SizedBox(height: 14),
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 280),
                child: AspectRatio(
                  aspectRatio: 1,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: TextQrView(data: shareUri),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'Encodes offline:noise:… — your Curve25519 Noise static public key.',
              textAlign: TextAlign.center,
              style: GoogleFonts.sourceSans3(
                fontSize: 13,
                height: 1.35,
                color: OfflineColors.mist,
              ),
            ),
            const SizedBox(height: 4),
            TextButton.icon(
              onPressed: () => _copy(context, 'Share URI', shareUri),
              icon: const Icon(Icons.copy_rounded, size: 16),
              label: const Text('Copy share link'),
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
