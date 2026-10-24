import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:offline/ui/app_theme.dart';
import 'package:offline/ui/open_external_url.dart';

/// Official BitChat client storefronts (mesh-compatible with Offline).
const kBitChatIosUrl =
    'https://apps.apple.com/us/app/bitchat-mesh/id6748219622';
const kBitChatAndroidUrl =
    'https://play.google.com/store/apps/details?id=com.bitchat.droid';
const kBitChatSiteUrl = 'https://bitchat.free';
const kBitChatGithubUrl = 'https://github.com/permissionlesstech/bitchat';

Future<void> launchStoreOrCopy(BuildContext context, String url) async {
  final opened = await openExternalUrl(url);
  if (opened || !context.mounted) return;
  await Clipboard.setData(ClipboardData(text: url));
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    const SnackBar(
      content: Text('Link copied — paste in a browser to open'),
      duration: Duration(seconds: 2),
    ),
  );
}

/// How Offline mesh works + links to the official BitChat apps.
Future<void> showMeshHowItWorks(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: OfflineColors.raised,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (ctx) {
      final bottom = MediaQuery.paddingOf(ctx).bottom;
      return SafeArea(
        child: Padding(
          padding: EdgeInsets.fromLTRB(20, 12, 20, 16 + bottom),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                Center(
                  child: Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: OfflineColors.line,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  'How it works',
                  style: GoogleFonts.spaceGrotesk(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                    color: OfflineColors.ink,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  'Mesh chat with Offline / BitChat over Bluetooth — no internet, no accounts.',
                  style: GoogleFonts.sourceSans3(
                    fontSize: 14,
                    height: 1.4,
                    color: OfflineColors.mist,
                  ),
                ),
                const SizedBox(height: 16),
                ..._steps.map(
                  (s) => Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${s.$1}.',
                          style: GoogleFonts.ibmPlexMono(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: OfflineColors.moss,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text.rich(
                            TextSpan(
                              style: GoogleFonts.sourceSans3(
                                fontSize: 14,
                                height: 1.4,
                                color: OfflineColors.ink,
                              ),
                              children: [
                                TextSpan(
                                  text: s.$2,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                TextSpan(text: ' — ${s.$3}'),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Offline speaks the same Bluetooth mesh wire format as BitChat. '
                  'No internet is required for mesh chat.',
                  style: GoogleFonts.sourceSans3(
                    fontSize: 13,
                    height: 1.4,
                    color: OfflineColors.mist,
                  ),
                ),
                const SizedBox(height: 18),
                Text(
                  'OFFICIAL BITCHAT APPS',
                  style: GoogleFonts.ibmPlexMono(
                    fontSize: 10,
                    letterSpacing: 1.2,
                    fontWeight: FontWeight.w600,
                    color: OfflineColors.mist,
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _StoreChip(
                      label: 'iPhone · App Store',
                      onTap: () => launchStoreOrCopy(ctx, kBitChatIosUrl),
                    ),
                    _StoreChip(
                      label: 'Android · Google Play',
                      onTap: () => launchStoreOrCopy(ctx, kBitChatAndroidUrl),
                    ),
                    _StoreChip(
                      label: 'bitchat.free',
                      ghost: true,
                      onTap: () => launchStoreOrCopy(ctx, kBitChatSiteUrl),
                    ),
                    _StoreChip(
                      label: 'Source on GitHub',
                      ghost: true,
                      onTap: () => launchStoreOrCopy(ctx, kBitChatGithubUrl),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}

const _steps = <(int, String, String)>[
  (1, 'Go online', 'Start mesh so this device joins as a peer.'),
  (
    2,
    'Connect',
    'On web/desktop, link a nearby phone running Offline or BitChat over Bluetooth.',
  ),
  (3, 'General', 'Public messages flood the mesh; anyone in range can read them.'),
  (
    4,
    'DM',
    'Pick a peer, start Noise if needed, then chat end-to-end with delivery/read receipts.',
  ),
  (
    5,
    'Photos & voice',
    'Private media is encrypted over Noise and split into BLE fragments.',
  ),
  (
    6,
    'Verify',
    'Identity shows a BitChat verify QR once you’re visible on their mesh.',
  ),
];

class _StoreChip extends StatelessWidget {
  const _StoreChip({
    required this.label,
    required this.onTap,
    this.ghost = false,
  });

  final String label;
  final VoidCallback onTap;
  final bool ghost;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: ghost
          ? OfflineColors.canvas.withValues(alpha: 0.5)
          : OfflineColors.canvas,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: OfflineColors.line),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          child: Text(
            label,
            style: GoogleFonts.spaceGrotesk(
              fontSize: ghost ? 12 : 13,
              fontWeight: FontWeight.w600,
              color: OfflineColors.ink.withValues(alpha: ghost ? 0.85 : 1),
            ),
          ),
        ),
      ),
    );
  }
}

/// Compact help control for toolbars / nav.
class MeshHelpButton extends StatelessWidget {
  const MeshHelpButton({super.key, this.compact = false});

  final bool compact;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: 'How it works',
      visualDensity: compact ? VisualDensity.compact : null,
      padding: compact ? EdgeInsets.zero : null,
      constraints: compact
          ? const BoxConstraints(minWidth: 32, minHeight: 32)
          : null,
      icon: Icon(
        Icons.help_outline,
        size: compact ? 18 : 22,
        color: OfflineColors.ink.withValues(alpha: 0.75),
      ),
      onPressed: () => showMeshHowItWorks(context),
    );
  }
}
