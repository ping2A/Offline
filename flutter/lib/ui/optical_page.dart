import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:offline/ui/identity_store.dart';
import 'package:offline/ui/optical_receive_page.dart';
import 'package:offline/ui/optical_send_page.dart';
import 'package:offline/ui/widgets.dart';

class OpticalPage extends StatelessWidget {
  const OpticalPage({super.key, required this.identity});

  final StoredIdentity identity;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const OfflinePageHeader(
          title: 'Optical',
          subtitle: kIsWeb
              ? 'Move a file screen-to-camera with fountain-coded QR frames — no Wi‑Fi, no cables.'
              : 'Send a file as an animated QR stream. Another device receives it with the camera.',
        ),
        OfflineActionTile(
          primary: true,
          icon: Icons.upload_file_outlined,
          title: 'Send a file',
          subtitle: 'Pick a file and display the QR stream at full brightness',
          onTap: () {
            Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const OpticalSendPage()),
            );
          },
        ),
        const SizedBox(height: 12),
        OfflineActionTile(
          icon: Icons.photo_camera_outlined,
          title: 'Receive with camera',
          subtitle: kIsWeb
              ? 'Allow camera access and point at the sender’s screen'
              : 'Scan the other device until the transfer completes',
          onTap: () {
            Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const OpticalReceivePage()),
            );
          },
        ),
        const Spacer(),
        Text(
          'Tip: steady hands, high brightness, and a short distance work best.',
          style: Theme.of(context).textTheme.bodySmall,
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}
