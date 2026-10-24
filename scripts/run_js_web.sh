#!/usr/bin/env bash
# Setup (if needed) and launch the standalone WASM mesh UI.
#
# Usage:
#   ./scripts/run_js_web.sh           # ensure build, then start Vite
#   ./scripts/run_js_web.sh --setup   # force full setup_js (incl. tests), then start
#   ./scripts/run_js_web.sh --skip-setup  # start only (assumes already built)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CORE="$ROOT/packages/offline-core-js"
WEB="$ROOT/packages/offline-web"

FORCE_SETUP=0
SKIP_SETUP=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --setup|-s) FORCE_SETUP=1; shift ;;
    --skip-setup) SKIP_SETUP=1; shift ;;
    -h|--help)
      sed -n '2,8p' "$0"
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

need_setup() {
  [[ ! -f "$CORE/pkg/offline_wasm_bg.wasm" ]] ||
    [[ ! -f "$CORE/dist/index.js" ]] ||
    [[ ! -d "$WEB/node_modules" ]] ||
    [[ ! -d "$CORE/node_modules" ]]
}

if [[ "$SKIP_SETUP" -eq 0 ]]; then
  if [[ "$FORCE_SETUP" -eq 1 ]] || need_setup; then
    echo "==> Running setup_js.sh"
    "$ROOT/scripts/setup_js.sh"
  else
    echo "==> WASM + deps present; rebuilding core package"
    if ! command -v wasm-pack >/dev/null; then
      echo "wasm-pack missing — run: ./scripts/setup_js.sh" >&2
      exit 1
    fi
    (cd "$CORE" && npm run build)
    (cd "$WEB" && npm install --prefer-offline --no-audit --no-fund >/dev/null)
  fi
fi

echo
echo "==> Starting Offline mesh UI at http://127.0.0.1:5173"
echo "    Open a second tab to chat; Chrome/Edge can Join phone (BLE)."
echo
cd "$WEB"
exec npm start
