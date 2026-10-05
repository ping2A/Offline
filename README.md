# Offline

Decentralized offline messaging and file transfer for Android, iOS, and Web.

- **Mesh chat** over Bluetooth LE, wire-compatible with [BitChat](https://github.com/permissionlesstech/bitchat) (Noise XX, binary packets, multi-hop relay). No Nostr, Tor, or geohash channels.
- **Optical file transfer** via fountain-coded animated QR codes (screen → camera), based on [decimen-optical-transfer](https://github.com/bashalarmistalt/decimen-optical-transfer).

Low-level crypto, packet codec, routing policy, and fountain codes are implemented in **Rust**. The mobile UI is **Flutter**.

## Status

Usable early build: Rust mesh + optical core, Flutter UI (Android / iOS 14+ / **Web**), Android dual-role BLE foreground service, iOS CoreBluetooth (mainnet+testnet scan, notify queue). Public mesh chat with **BitChat announce TLV**, **Noise XX private DMs**, **photo & voice-note fileTransfer (0x22)** send & receive, and optical QR + identity on web.

**Web Bluetooth note:** browsers cannot advertise as a BLE peripheral, so the web app is a **leaf** — the phone must run Offline/BitChat and advertise; Chrome/Edge connects as GATT central.

## Workspace

```text
crates/
  offline-packet/    # BitChat binary packet codec (v1/v2) + fragments
  offline-noise/     # Noise_XX_25519_ChaChaPoly_SHA256 + peer IDs
  offline-mesh/      # TTL flood, dedupe, duty-cycle policy
  offline-fountain/  # LT fountain codes + optical frame header
  offline-core/      # App façade + MeshController
  offline_ffi/       # flutter_rust_bridge bindings
flutter/             # Flutter app (Android / iOS / Web)
docs/protocol.md     # Compatibility notes
```

## Build (Rust)

```bash
cargo test --workspace
```

## Flutter app

Prefer Homebrew Flutter on this Mac (`~/dev/flutter`’s `dart` can hang at `_dyld_start`):

```bash
export PATH="/opt/homebrew/bin:$PATH"   # must come before ~/dev/flutter
export JAVA_HOME="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
export ANDROID_HOME="$HOME/Library/Android/sdk"
hash -r
flutter --version   # Flutter 3.44.x
```

Then:

```bash
# After changing Rust API bindings:
cd flutter && flutter_rust_bridge_codegen generate
# If codegen resets the loader path, set ioDirectory to '../target/debug/' in
# lib/src/rust/frb_generated.dart for desktop FFI smoke tests.
cd .. && cargo build -p rust_lib_offline

cd flutter
flutter pub get
flutter run          # device / emulator
# or: flutter build apk --debug
```

Tabs:

- **Mesh** — BLE start/stop, peers, public channel, Noise DMs (tap peer → Start secure chat). On web: tab chat + Connect phone (BLE leaf).
- **Optical** — send/receive files via fountain-coded QR (works on web too)
- **Identity** — BitChat-compatible peer ID from Noise static key

`android/app/build.gradle.kts` must keep `flutter { source = "../.." }` (relative to `android/app/`). A wrong `../` makes Flutter treat `android/` as the Dart package root and crash native-assets builds.

### Mobile (APK / iOS)

```bash
./scripts/build_mobile.sh              # release APK → flutter/build/app/outputs/flutter-apk/
./scripts/build_mobile.sh --ios        # unsigned .xcarchive zip (macOS + Xcode)
./scripts/build_mobile.sh --all        # Android + iOS
./scripts/build_mobile.sh --debug      # debug APK
./scripts/build_mobile.sh --out dist   # also copy named artifacts into dist/
```

Cargokit builds the Rust mesh crate during the Flutter build (Rust toolchain required on PATH).

### Web

Rust runs as WASM under `flutter/web/pkg/` (generated; not committed).

**Mesh on web:** Start mesh in two browser tabs to chat over `BroadcastChannel`. In Chrome/Edge, **Join BitChat** uses the [Web Bluetooth API](https://developer.mozilla.org/en-US/docs/Web/API/Web_Bluetooth_API) to connect directly to nearby **BitChat** (or Offline) phones — no Offline mobile app required. The browser cannot advertise, so it is a leaf on the phone(s) it joins.

```bash
./scripts/run_web.sh              # build + serve http://127.0.0.1:8080/
./scripts/run_web.sh --rebuild    # force WASM rebuild, then serve :8080
./scripts/run_web.sh --dev        # Flutter Chrome hot-reload (random debug port)
./scripts/build_web.sh            # release artifacts only → flutter/build/web
```

Platform IDs: `app.offline.offline`.

## Release builds (GitHub Actions)

Pushing a version tag `v*` (for example `v0.1.0`) runs [`.github/workflows/release.yml`](.github/workflows/release.yml), which:

1. Builds a **release APK** (Android) and attaches `Offline-<tag>-android.apk` to the GitHub Release
2. Builds an **unsigned iOS `.xcarchive`** (no Apple Distribution cert in CI) and attaches `Offline-<tag>-ios-unsigned.xcarchive.zip`

```bash
git tag v0.1.0
git push origin v0.1.0
```

Open the archive zip on a Mac, sign in Xcode / Organizer (or add App Store Connect API secrets later for a signed IPA). The Android APK is currently signed with the debug keystore (see `flutter/android/app/build.gradle.kts`) until a release keystore is configured.

GPL-3.0-or-later (see [LICENSE](LICENSE)). Protocol ideas from BitChat (public domain / Unlicense) and optical framing from decimen (MIT); this tree is an independent implementation.
