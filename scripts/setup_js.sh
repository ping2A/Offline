#!/usr/bin/env bash
# One-shot setup + build + test for packages/offline-core-js (@offline/core).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PKG="$ROOT/packages/offline-core-js"

echo "==> Checking toolchain"
if ! command -v rustc >/dev/null; then
  echo "Rust is required. Install from https://rustup.rs" >&2
  exit 1
fi
if ! command -v npm >/dev/null; then
  echo "Node.js/npm is required (Node >= 18)." >&2
  exit 1
fi

rustup target add wasm32-unknown-unknown >/dev/null
if ! command -v wasm-pack >/dev/null; then
  echo "==> Installing wasm-pack"
  cargo install wasm-pack --locked
fi

echo "==> npm install"
cd "$PKG"
npm install

echo "==> build (wasm-pack + tsc)"
npm run build

echo "==> test"
npm test

echo "==> web UI deps"
cd "$ROOT/packages/offline-web"
npm install

echo
echo "OK — @offline/core + web UI are ready."
echo "  Mesh UI:  ./scripts/run_js_web.sh"
echo "            open http://127.0.0.1:5173  (second tab = chat)"
echo "  Core demo: cd packages/offline-core-js && npm run demo"
