import 'dart:convert';
import 'dart:typed_data';

import 'package:offline/src/rust/api/identity.dart';
import 'package:shared_preferences/shared_preferences.dart';

class StoredIdentity {
  StoredIdentity({
    required this.peerId,
    required this.noisePublicKey,
    required this.signingPublicKey,
    required this.noiseSecretKey,
    required this.signingSecretKey,
  });

  final String peerId;
  final Uint8List noisePublicKey;
  final Uint8List signingPublicKey;
  final Uint8List noiseSecretKey;
  final Uint8List signingSecretKey;

  factory StoredIdentity.fromBundle(IdentityBundle b) => StoredIdentity(
        peerId: b.peerId,
        noisePublicKey: b.noisePublicKey,
        signingPublicKey: b.signingPublicKey,
        noiseSecretKey: b.noiseSecretKey,
        signingSecretKey: b.signingSecretKey,
      );
}

class IdentityStore {
  static const _kNoiseSecret = 'identity.noise_secret';
  static const _kSigningSecret = 'identity.signing_secret';

  static Future<StoredIdentity> loadOrCreate() async {
    final prefs = await SharedPreferences.getInstance();
    final noiseB64 = prefs.getString(_kNoiseSecret);
    final signingB64 = prefs.getString(_kSigningSecret);

    if (noiseB64 != null && signingB64 != null) {
      final view = identityFromSecrets(
        noiseSecretKey: base64Decode(noiseB64),
        signingSecretKey: base64Decode(signingB64),
      );
      return StoredIdentity(
        peerId: view.peerId,
        noisePublicKey: view.noisePublicKey,
        signingPublicKey: view.signingPublicKey,
        noiseSecretKey: Uint8List.fromList(base64Decode(noiseB64)),
        signingSecretKey: Uint8List.fromList(base64Decode(signingB64)),
      );
    }

    final bundle = generateIdentity();
    await prefs.setString(_kNoiseSecret, base64Encode(bundle.noiseSecretKey));
    await prefs.setString(_kSigningSecret, base64Encode(bundle.signingSecretKey));
    return StoredIdentity.fromBundle(bundle);
  }

  static Future<StoredIdentity> regenerate() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kNoiseSecret);
    await prefs.remove(_kSigningSecret);
    return loadOrCreate();
  }
}
