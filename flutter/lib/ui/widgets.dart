import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:offline/ui/app_theme.dart';

class OfflinePageHeader extends StatelessWidget {
  const OfflinePageHeader({
    super.key,
    required this.title,
    required this.subtitle,
    this.trailing,
  });

  final String title;
  final String subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 0, 0, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: GoogleFonts.spaceGrotesk(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.5,
                    color: OfflineColors.ink,
                    height: 1.1,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  style: GoogleFonts.sourceSans3(
                    fontSize: 13,
                    height: 1.35,
                    color: OfflineColors.mist,
                  ),
                ),
              ],
            ),
          ),
          if (trailing != null) ...[
            const SizedBox(width: 12),
            trailing!,
          ],
        ],
      ),
    );
  }
}

class OfflineEmptyState extends StatelessWidget {
  const OfflineEmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.body,
  });

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 36, color: OfflineColors.moss.withValues(alpha: 0.85)),
              const SizedBox(height: 16),
              Text(
                title,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              Text(
                body,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class OfflineStatusDot extends StatelessWidget {
  const OfflineStatusDot({super.key, required this.active, required this.label});

  final bool active;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        AnimatedContainer(
          duration: const Duration(milliseconds: 280),
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: active ? OfflineColors.signal : OfflineColors.mist,
          ),
        ),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            label,
            style: Theme.of(context).textTheme.bodySmall,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}

class OfflineActionTile extends StatefulWidget {
  const OfflineActionTile({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.primary = false,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final bool primary;

  @override
  State<OfflineActionTile> createState() => _OfflineActionTileState();
}

class _OfflineActionTileState extends State<OfflineActionTile> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final bg = widget.primary
        ? OfflineColors.moss
        : (_hover ? OfflineColors.raisedHigh : OfflineColors.raised);
    final fg = widget.primary ? OfflineColors.onAccent : OfflineColors.ink;
    final muted = widget.primary
        ? OfflineColors.onAccent.withValues(alpha: 0.72)
        : OfflineColors.mist;

    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: AnimatedScale(
        scale: _hover ? 1.012 : 1,
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOut,
        child: Material(
          color: bg,
          borderRadius: BorderRadius.circular(16),
          child: InkWell(
            onTap: widget.onTap,
            borderRadius: BorderRadius.circular(16),
            child: Container(
              decoration: widget.primary
                  ? null
                  : BoxDecoration(
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: OfflineColors.line),
                    ),
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 18),
              child: Row(
                children: [
                  Icon(widget.icon, color: fg, size: 26),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.title,
                          style: GoogleFonts.spaceGrotesk(
                            color: fg,
                            fontWeight: FontWeight.w600,
                            fontSize: 17,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          widget.subtitle,
                          style: GoogleFonts.sourceSans3(
                            color: muted,
                            fontSize: 14,
                            height: 1.3,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Icon(
                    Icons.arrow_forward,
                    size: 18,
                    color: fg.withValues(alpha: 0.7),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class OfflineMonoBlock extends StatelessWidget {
  const OfflineMonoBlock({
    super.key,
    required this.label,
    required this.value,
    this.onCopy,
  });

  final String label;
  final String value;
  final VoidCallback? onCopy;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label.toUpperCase(),
          style: GoogleFonts.ibmPlexMono(
            fontSize: 11,
            letterSpacing: 1.4,
            fontWeight: FontWeight.w600,
            color: OfflineColors.mist,
          ),
        ),
        const SizedBox(height: 10),
        DecoratedBox(
          decoration: BoxDecoration(
            color: OfflineColors.raised,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: OfflineColors.line),
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: SelectableText(
                    value,
                    style: GoogleFonts.ibmPlexMono(
                      fontSize: 13,
                      height: 1.45,
                      color: OfflineColors.ink,
                    ),
                  ),
                ),
                if (onCopy != null)
                  IconButton(
                    tooltip: 'Copy',
                    onPressed: onCopy,
                    icon: Icon(Icons.copy_rounded, size: 18),
                    color: OfflineColors.moss,
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
