#!/usr/bin/env bash
# Build Offline Android APK and/or iOS archive locally.
#
# Usage:
#   ./scripts/build_mobile.sh              # Android APK (release)
#   ./scripts/build_mobile.sh --android    # Android only
#   ./scripts/build_mobile.sh --ios        # iOS unsigned archive (macOS only)
#   ./scripts/build_mobile.sh --all        # Android + iOS
#   ./scripts/build_mobile.sh --debug      # debug APK instead of release
#   ./scripts/build_mobile.sh --out dist   # copy artifacts into dist/
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FLUTTER_DIR="$ROOT/flutter"
OUT_DIR=""
DO_ANDROID=0
DO_IOS=0
DEBUG=0

export PATH="/opt/homebrew/bin:${PATH:-}"
export JAVA_HOME="${JAVA_HOME:-/Applications/Android Studio.app/Contents/jbr/Contents/Home}"
export ANDROID_HOME="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}"
export ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-$ANDROID_HOME}"

usage() {
  sed -n '2,12p' "$0"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --android|-a) DO_ANDROID=1; shift ;;
    --ios|-i) DO_IOS=1; shift ;;
    --all) DO_ANDROID=1; DO_IOS=1; shift ;;
    --debug|-d) DEBUG=1; shift ;;
    --out|-o)
      OUT_DIR="${2:?output directory required}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

# Default: Android only (works on Linux/macOS; iOS needs macOS + Xcode).
if [[ "$DO_ANDROID" -eq 0 && "$DO_IOS" -eq 0 ]]; then
  DO_ANDROID=1
fi

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "error: '$1' not found in PATH" >&2
    exit 1
  }
}

need_cmd flutter
need_cmd rustc
need_cmd cargo

echo "==> flutter pub get"
(
  cd "$FLUTTER_DIR"
  flutter pub get
)

VERSION="$(
  grep -E '^version:' "$FLUTTER_DIR/pubspec.yaml" | head -1 | awk '{print $2}' | tr '+' '-'
)"
STAMP="${VERSION:-0.0.0}"

copy_out() {
  local src="$1"
  local name="$2"
  if [[ -z "$OUT_DIR" ]]; then
    return 0
  fi
  mkdir -p "$OUT_DIR"
  cp -f "$src" "$OUT_DIR/$name"
  echo "    copied → $OUT_DIR/$name"
}

if [[ "$DO_ANDROID" -eq 1 ]]; then
  need_cmd java
  if [[ ! -d "$ANDROID_HOME" ]]; then
    echo "error: Android SDK not found at ANDROID_HOME=$ANDROID_HOME" >&2
    exit 1
  fi
  if [[ "$DEBUG" -eq 1 ]]; then
    echo "==> flutter build apk --debug"
    (
      cd "$FLUTTER_DIR"
      flutter build apk --debug
    )
    APK="$FLUTTER_DIR/build/app/outputs/flutter-apk/app-debug.apk"
    NAME="Offline-${STAMP}-android-debug.apk"
  else
    echo "==> flutter build apk --release"
    (
      cd "$FLUTTER_DIR"
      flutter build apk --release
    )
    APK="$FLUTTER_DIR/build/app/outputs/flutter-apk/app-release.apk"
    NAME="Offline-${STAMP}-android.apk"
  fi
  ls -lh "$APK"
  echo "Android APK: $APK"
  copy_out "$APK" "$NAME"
fi

if [[ "$DO_IOS" -eq 1 ]]; then
  if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "error: iOS builds require macOS + Xcode" >&2
    exit 1
  fi
  need_cmd xcodebuild
  need_cmd pod

  echo "==> pod install (ios)"
  (
    cd "$FLUTTER_DIR/ios"
    pod install --repo-update
  )

  echo "==> flutter build ipa --release --no-codesign"
  (
    cd "$FLUTTER_DIR"
    flutter build ipa --release --no-codesign
  )

  ARCHIVE="$(find "$FLUTTER_DIR/build/ios/archive" -name '*.xcarchive' -print -quit || true)"
  if [[ -z "$ARCHIVE" ]]; then
    echo "error: no .xcarchive under flutter/build/ios/archive" >&2
    find "$FLUTTER_DIR/build/ios" -maxdepth 3 -type d -print >&2 || true
    exit 1
  fi

  ZIP_NAME="Offline-${STAMP}-ios-unsigned.xcarchive.zip"
  ZIP_PATH="$FLUTTER_DIR/build/ios/$ZIP_NAME"
  rm -f "$ZIP_PATH"
  ditto -c -k --sequesterRsrc --keepParent "$ARCHIVE" "$ZIP_PATH"
  ls -lh "$ZIP_PATH"
  echo "iOS archive zip: $ZIP_PATH"
  echo "    Open in Xcode to sign / export IPA."
  copy_out "$ZIP_PATH" "$ZIP_NAME"
fi

echo "==> done"
