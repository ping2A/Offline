import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
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

/// Persists Noise / Ed25519 secrets in platform secure storage (Keychain /
/// Keystore), not plaintext SharedPreferences (SECURITY_IMPROVEMENTS S-4).
class IdentityStore {
  static const _kNoiseSecret = 'identity.noise_secret';
  static const _kSigningSecret = 'identity.signing_secret';

  static const FlutterSecureStorage _secure = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
    ),
  );

  static Future<StoredIdentity> loadOrCreate() async {
    var noiseB64 = await _secure.read(key: _kNoiseSecret);
    var signingB64 = await _secure.read(key: _kSigningSecret);

    // One-time migrate from legacy plaintext SharedPreferences.
    if (noiseB64 == null || signingB64 == null) {
      final migrated = await _migrateFromPrefs();
      noiseB64 = migrated?.$1;
      signingB64 = migrated?.$2;
    }

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
    await _secure.write(
      key: _kNoiseSecret,
      value: base64Encode(bundle.noiseSecretKey),
    );
    await _secure.write(
      key: _kSigningSecret,
      value: base64Encode(bundle.signingSecretKey),
    );
    return StoredIdentity.fromBundle(bundle);
  }

  static Future<(String, String)?> _migrateFromPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final noiseB64 = prefs.getString(_kNoiseSecret);
    final signingB64 = prefs.getString(_kSigningSecret);
    if (noiseB64 == null || signingB64 == null) {
      return null;
    }
    await _secure.write(key: _kNoiseSecret, value: noiseB64);
    await _secure.write(key: _kSigningSecret, value: signingB64);
    await prefs.remove(_kNoiseSecret);
    await prefs.remove(_kSigningSecret);
    return (noiseB64, signingB64);
  }

  static Future<StoredIdentity> regenerate() async {
    await _secure.delete(key: _kNoiseSecret);
    await _secure.delete(key: _kSigningSecret);
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kNoiseSecret);
    await prefs.remove(_kSigningSecret);
    return loadOrCreate();
  }
}
