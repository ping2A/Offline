#!/usr/bin/env bash
# Build the standalone WASM web client (release) and pack a deployable archive.
#
# Usage:
#   ./scripts/archive_js_web.sh              # → dist/Offline-web-<ver>.zip (+ .tar.gz)
#   ./scripts/archive_js_web.sh --out DIR    # write archives into DIR
#   ./scripts/archive_js_web.sh --skip-build # pack existing packages/offline-web/dist
#   ./scripts/archive_js_web.sh --zip-only
#   ./scripts/archive_js_web.sh --tar-only
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WEB="$ROOT/packages/offline-web"
CORE="$ROOT/packages/offline-core-js"
WASM_CRATE="$ROOT/crates/offline-wasm"
PKG="$CORE/pkg"
OUT_DIR="$ROOT/dist"
SKIP_BUILD=0
DO_ZIP=1
DO_TAR=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out|-o)
      OUT_DIR="${2:?--out requires a directory}"
      shift 2
      ;;
    --skip-build) SKIP_BUILD=1; shift ;;
    --zip-only) DO_TAR=0; shift ;;
    --tar-only) DO_ZIP=0; shift ;;
    -h|--help)
      sed -n '2,12p' "$0"
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

read_version_field() {
  local key="$1"
  local file="$ROOT/VERSION"
  if [[ -f "$file" ]]; then
    local line
    line="$(grep -E "^${key}=" "$file" | head -n1 || true)"
    echo "${line#*=}"
  fi
}

CLIENT_VERSION="$(read_version_field CLIENT_VERSION)"
PROTOCOL_ID="$(read_version_field PROTOCOL_ID)"
PROTOCOL_VERSION="$(read_version_field PROTOCOL_VERSION)"
CLIENT_VERSION="${CLIENT_VERSION:-0.0.0}"
PROTOCOL_LABEL="${PROTOCOL_ID:-bitchat-mesh}/${PROTOCOL_VERSION:-1}"

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BASE_NAME="Offline-web-${CLIENT_VERSION}"
STAGE="$OUT_DIR/.stage-${BASE_NAME}"
ARCHIVE_ROOT="${BASE_NAME}"
WASM_PROFILE="release"

mkdir -p "$OUT_DIR"

build_release_wasm() {
  if ! command -v wasm-pack >/dev/null; then
    echo "wasm-pack missing — run: ./scripts/setup_js.sh" >&2
    exit 1
  fi
  echo "==> Clean + wasm-pack build (release)"
  rm -rf "$PKG"
  # Explicit --release so we never ship a debug .wasm in the archive.
  wasm-pack build "$WASM_CRATE" \
    --release \
    --target web \
    --out-dir "$PKG"

  local wasm="$PKG/offline_wasm_bg.wasm"
  if [[ ! -f "$wasm" ]]; then
    echo "Missing release wasm at $wasm" >&2
    exit 1
  fi

  # Sanity: release builds are typically a few hundred KB, not multi‑MB debug.
  local bytes
  bytes="$(wc -c <"$wasm" | tr -d ' ')"
  if [[ "$bytes" -lt 50000 ]]; then
    echo "WASM suspiciously small (${bytes} B) — aborting" >&2
    exit 1
  fi
  if [[ "$bytes" -gt 5000000 ]]; then
    echo "WASM suspiciously large (${bytes} B) — likely not --release; aborting" >&2
    exit 1
  fi

  # Prefer packaged dist/ for Vite production resolve (not TS source → debug drift).
  echo "==> Building @offline/core TypeScript"
  (cd "$CORE" && npm install --prefer-offline --no-audit --no-fund >/dev/null && npm run build:ts)

  echo "==> Vite production build (offline-web)"
  (cd "$WEB" && npm install --prefer-offline --no-audit --no-fund >/dev/null)
  (cd "$WEB" && npx tsc -p tsconfig.json --noEmit && npx vite build)

  # Confirm the built site embeds a .wasm asset.
  if ! find "$WEB/dist" -name '*.wasm' | grep -q .; then
    echo "No .wasm found under $WEB/dist — aborting" >&2
    exit 1
  fi

  local dist_wasm
  dist_wasm="$(find "$WEB/dist" -name '*.wasm' | head -n1)"
  local dist_bytes
  dist_bytes="$(wc -c <"$dist_wasm" | tr -d ' ')"
  echo "    release wasm: $(basename "$dist_wasm") (${dist_bytes} bytes)"
  WASM_PROFILE="release (${dist_bytes} bytes)"
}

if [[ "$SKIP_BUILD" -eq 0 ]]; then
  build_release_wasm
else
  if [[ ! -d "$WEB/dist" ]] || [[ -z "$(ls -A "$WEB/dist" 2>/dev/null || true)" ]]; then
    echo "No build at $WEB/dist — run without --skip-build" >&2
    exit 1
  fi
  if ! find "$WEB/dist" -name '*.wasm' | grep -q .; then
    echo "Existing dist has no .wasm — rebuild without --skip-build" >&2
    exit 1
  fi
  echo "==> Using existing $WEB/dist (ensure it was built with wasm-pack --release)"
  WASM_PROFILE="unknown (skipped rebuild)"
fi

rm -rf "$STAGE"
mkdir -p "$STAGE/$ARCHIVE_ROOT"
cp -R "$WEB/dist/." "$STAGE/$ARCHIVE_ROOT/"

cat >"$STAGE/$ARCHIVE_ROOT/VERSION.txt" <<EOF
Offline web client
==================
client:   ${CLIENT_VERSION}
protocol: ${PROTOCOL_LABEL}
built:    ${STAMP}
wasm:     ${WASM_PROFILE}
source:   packages/offline-web + crates/offline-wasm (--release)

Deploy
------
Serve this folder (keep index.html next to assets/) over HTTPS or localhost.
Asset URLs are relative (./assets/…), so a subpath or nested folder works.
Web Bluetooth requires a secure context (https:// or http://127.0.0.1).

Example:
  npx --yes serve -l 8080 .
  # → http://127.0.0.1:8080/
EOF

cat >"$STAGE/$ARCHIVE_ROOT/README.md" <<EOF
# Offline web (${CLIENT_VERSION})

Static build of the Offline mesh UI (Rust **release** WASM + Vite).

- **Client:** \`${CLIENT_VERSION}\`
- **Protocol:** \`${PROTOCOL_LABEL}\`
- **WASM:** \`${WASM_PROFILE}\`
- **Built:** \`${STAMP}\`

## Deploy

Upload **this whole folder** (keep \`index.html\` beside \`assets/\`) to any static host.
Scripts and WASM use **relative** paths (\`./assets/…\`), so the site works at a
subpath or when the archive root is not the domain root.

\`\`\`bash
# quick local check
npx --yes serve -l 8080 .
\`\`\`

Chrome / Edge can **Connect to the mesh** via Web Bluetooth. Safari and Firefox cannot use Web Bluetooth for mesh join.
EOF

ZIP_PATH="$OUT_DIR/${BASE_NAME}.zip"
TAR_PATH="$OUT_DIR/${BASE_NAME}.tar.gz"

(
  cd "$STAGE"
  if [[ "$DO_ZIP" -eq 1 ]]; then
    rm -f "$ZIP_PATH"
    if command -v zip >/dev/null; then
      zip -qr "$ZIP_PATH" "$ARCHIVE_ROOT"
    else
      echo "zip not found — skipping .zip" >&2
      DO_ZIP=0
    fi
  fi
  if [[ "$DO_TAR" -eq 1 ]]; then
    rm -f "$TAR_PATH"
    tar -czf "$TAR_PATH" "$ARCHIVE_ROOT"
  fi
)

rm -rf "$STAGE"

echo
echo "Done."
[[ "$DO_ZIP" -eq 1 && -f "$ZIP_PATH" ]] && echo "  $ZIP_PATH  ($(du -h "$ZIP_PATH" | awk '{print $1}'))"
[[ "$DO_TAR" -eq 1 && -f "$TAR_PATH" ]] && echo "  $TAR_PATH  ($(du -h "$TAR_PATH" | awk '{print $1}'))"
echo
echo "Unpack and serve the ${ARCHIVE_ROOT}/ folder as a static site."
