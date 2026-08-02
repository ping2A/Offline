import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:offline/ui/app_theme.dart';
import 'package:offline/ui/identity_page.dart';
import 'package:offline/ui/identity_store.dart';
import 'package:offline/ui/mesh_page.dart';
import 'package:offline/ui/optical_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.identity});

  final StoredIdentity identity;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _tab = 0;
  late StoredIdentity _identity = widget.identity;

  static const _destinations = [
    (Icons.hub_outlined, Icons.hub, 'Mesh'),
    (Icons.qr_code_2_outlined, Icons.qr_code_2, 'Optical'),
    (Icons.fingerprint, Icons.fingerprint, 'Identity'),
  ];

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 900;

    return OfflineBackdrop(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1280),
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  wide ? 10 : 6,
                  wide ? 6 : 4,
                  wide ? 10 : 6,
                  wide ? 6 : 4,
                ),
                child: wide ? _wideLayout() : _narrowLayout(),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _brandMark({double size = 26}) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(7),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [OfflineColors.moss, Color(0xFFA67A35)],
        ),
      ),
      alignment: Alignment.center,
      child: Text(
        'O',
        style: GoogleFonts.spaceGrotesk(
          color: OfflineColors.onAccent,
          fontWeight: FontWeight.w700,
          fontSize: size * 0.55,
        ),
      ),
    );
  }

  Widget _peerChip() {
    final short = _identity.peerId.length >= 8
        ? _identity.peerId.substring(0, 8)
        : _identity.peerId;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        border: Border.all(color: OfflineColors.line),
        borderRadius: BorderRadius.circular(6),
        color: OfflineColors.raised,
      ),
      child: Text(
        short,
        style: GoogleFonts.ibmPlexMono(
          fontSize: 10,
          color: OfflineColors.leaf,
          letterSpacing: 0.3,
        ),
      ),
    );
  }

  Widget _pages() {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 180),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeIn,
      child: KeyedSubtree(
        key: ValueKey(_tab),
        child: switch (_tab) {
          0 => MeshPage(identity: _identity),
          1 => OpticalPage(identity: _identity),
          _ => IdentityPage(
              identity: _identity,
              onRegenerated: (id) => setState(() => _identity = id),
            ),
        },
      ),
    );
  }

  Widget _wideLayout() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          width: 132,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  _brandMark(),
                  const SizedBox(width: 8),
                  Text(
                    'Offline',
                    style: GoogleFonts.spaceGrotesk(
                      fontWeight: FontWeight.w700,
                      fontSize: 16,
                      letterSpacing: -0.4,
                      color: OfflineColors.ink,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              for (var i = 0; i < _destinations.length; i++) ...[
                _NavTile(
                  selected: _tab == i,
                  icon: _tab == i
                      ? _destinations[i].$2
                      : _destinations[i].$1,
                  label: _destinations[i].$3,
                  onTap: () => setState(() => _tab = i),
                ),
                const SizedBox(height: 2),
              ],
              const Spacer(),
              _peerChip(),
            ],
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: OfflineColors.raised.withValues(alpha: 0.72),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: OfflineColors.line),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
                child: _pages(),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _narrowLayout() {
    return Column(
      children: [
        Row(
          children: [
            _brandMark(size: 24),
            const SizedBox(width: 8),
            Text(
              'Offline',
              style: GoogleFonts.spaceGrotesk(
                fontWeight: FontWeight.w700,
                fontSize: 16,
                color: OfflineColors.ink,
              ),
            ),
            const Spacer(),
            _peerChip(),
          ],
        ),
        const SizedBox(height: 4),
        Expanded(child: _pages()),
        const SizedBox(height: 4),
        DecoratedBox(
          decoration: BoxDecoration(
            color: OfflineColors.raised,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: OfflineColors.line),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
            child: Row(
              children: [
                for (var i = 0; i < _destinations.length; i++)
                  Expanded(
                    child: _BottomTab(
                      selected: _tab == i,
                      icon: _tab == i
                          ? _destinations[i].$2
                          : _destinations[i].$1,
                      label: _destinations[i].$3,
                      onTap: () => setState(() => _tab = i),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _NavTile extends StatefulWidget {
  const _NavTile({
    required this.selected,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final bool selected;
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  State<_NavTile> createState() => _NavTileState();
}

class _NavTileState extends State<_NavTile> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final selected = widget.selected;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Material(
        color: selected
            ? OfflineColors.moss
            : (_hover ? OfflineColors.raisedHigh : Colors.transparent),
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          onTap: widget.onTap,
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Row(
              children: [
                Icon(
                  widget.icon,
                  size: 16,
                  color: selected
                      ? OfflineColors.onAccent
                      : OfflineColors.ink.withValues(alpha: 0.7),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    widget.label,
                    style: GoogleFonts.spaceGrotesk(
                      fontWeight: FontWeight.w600,
                      fontSize: 13,
                      color: selected
                          ? OfflineColors.onAccent
                          : OfflineColors.ink,
                    ),
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

class _BottomTab extends StatelessWidget {
  const _BottomTab({
    required this.selected,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final bool selected;
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        padding: const EdgeInsets.symmetric(vertical: 4),
        decoration: BoxDecoration(
          color: selected ? OfflineColors.moss : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 16,
              color: selected
                  ? OfflineColors.onAccent
                  : OfflineColors.mist,
            ),
            Text(
              label,
              style: GoogleFonts.spaceGrotesk(
                fontSize: 10,
                fontWeight: FontWeight.w600,
                color: selected
                    ? OfflineColors.onAccent
                    : OfflineColors.mist,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
