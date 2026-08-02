#!/usr/bin/env bash
# Build Flutter web app with Rust WASM (flutter_rust_bridge).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="/opt/homebrew/bin:${PATH:-}"

cd "$ROOT/flutter"

echo "==> Compiling Rust → WASM (web/pkg)"
flutter_rust_bridge_codegen build-web \
  --rust-root "$ROOT/crates/offline_ffi" \
  --dart-root "$ROOT/flutter" \
  --output "$ROOT/flutter/web" \
  --release

echo "==> flutter build web"
flutter pub get
flutter build web --release --no-wasm-dry-run

echo "Done: $ROOT/flutter/build/web"
echo
echo "Dev run:"
echo "  cd flutter && flutter run -d chrome \\"
echo "    --web-header=Cross-Origin-Opener-Policy=same-origin \\"
echo "    --web-header=Cross-Origin-Embedder-Policy=require-corp"
echo
echo "APIs are sync (default_dart_async: false), so the app also runs without"
echo "those headers; they remain recommended for SharedArrayBuffer / workers."
