#!/usr/bin/env bash
# Build and serve the Offline web UI at http://127.0.0.1:8080
#
# Usage:
#   ./scripts/run_web.sh              # build if needed, serve on :8080
#   ./scripts/run_web.sh --rebuild    # force WASM + web rebuild, then serve
#   ./scripts/run_web.sh --dev        # flutter run -d chrome (hot reload, random port)
#   ./scripts/run_web.sh --port 9090  # serve on another port
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="/opt/homebrew/bin:${PATH:-}"
export JAVA_HOME="${JAVA_HOME:-/Applications/Android Studio.app/Contents/jbr/Contents/Home}"

REBUILD=0
DEV=0
PORT=8080

while [[ $# -gt 0 ]]; do
  case "$1" in
    --rebuild|-r) REBUILD=1; shift ;;
    --dev|-d) DEV=1; shift ;;
    --port|-p)
      PORT="${2:?port number required}"
      shift 2
      ;;
    -h|--help)
      sed -n '2,9p' "$0"
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
done

need_wasm() {
  [[ ! -f "$ROOT/flutter/web/pkg/rust_lib_offline.js" ]] ||
    [[ ! -f "$ROOT/flutter/web/pkg/rust_lib_offline_bg.wasm" ]]
}

build_wasm() {
  echo "==> Compiling Rust → WASM (flutter/web/pkg)"
  flutter_rust_bridge_codegen build-web \
    --rust-root "$ROOT/crates/offline_ffi" \
    --dart-root "$ROOT/flutter" \
    --output "$ROOT/flutter/web" \
    --release
}

cd "$ROOT/flutter"

if [[ "$REBUILD" -eq 1 ]] || need_wasm; then
  build_wasm
else
  echo "==> WASM pkg present (use --rebuild to refresh)"
fi

echo "==> flutter pub get"
flutter pub get

if [[ "$DEV" -eq 1 ]]; then
  echo "==> flutter run -d chrome (dev / hot reload)"
  echo "    Chrome will open on Flutter's debug URL (not :$PORT)."
  exec flutter run -d chrome \
    --web-header=Cross-Origin-Opener-Policy=same-origin \
    --web-header=Cross-Origin-Embedder-Policy=require-corp
fi

# Stale .dart_tool/flutter_build can omit newly added web plugins (e.g. record_web),
# which surfaces as MissingPluginException / "Uncaught Error" in the browser.
if [[ "$REBUILD" -eq 1 ]]; then
  echo "==> Clearing Flutter web build cache"
  rm -rf .dart_tool/flutter_build
fi

echo "==> flutter build web"
flutter build web --release --no-wasm-dry-run

WEB_DIR="$ROOT/flutter/build/web"
if [[ ! -f "$WEB_DIR/index.html" ]]; then
  echo "error: missing $WEB_DIR/index.html" >&2
  exit 1
fi

# Free the port if a previous server is still bound.
if command -v lsof >/dev/null 2>&1; then
  if lsof -tiTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
    echo "==> Stopping process on port $PORT"
    lsof -tiTCP:"$PORT" -sTCP:LISTEN | xargs kill 2>/dev/null || true
    sleep 0.5
  fi
fi

URL="http://127.0.0.1:${PORT}/"
echo "==> Serving $WEB_DIR"
echo ""
echo "  Open: $URL"
echo "  Stop: Ctrl+C"
echo ""

# Tiny static server with COOP/COEP (needed for FRB / SharedArrayBuffer).
exec python3 - "$WEB_DIR" "$PORT" <<'PY'
import functools
import sys
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

directory = Path(sys.argv[1]).resolve()
port = int(sys.argv[2])

class Handler(SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header("Cross-Origin-Opener-Policy", "same-origin")
        self.send_header("Cross-Origin-Embedder-Policy", "require-corp")
        self.send_header("Cache-Control", "no-cache")
        super().end_headers()

    def log_message(self, fmt, *args):
        sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))

handler = functools.partial(Handler, directory=str(directory))
server = ThreadingHTTPServer(("127.0.0.1", port), handler)
print(f"Serving Offline web UI at http://127.0.0.1:{port}/", flush=True)
try:
    server.serve_forever()
except KeyboardInterrupt:
    print("\nStopped.", flush=True)
PY
