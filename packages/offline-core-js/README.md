# `@offline/core`

Standalone WebAssembly / JavaScript build of Offline's Rust mesh + optical core.
Pure computation — the host supplies transport bytes. **GPL-3.0-or-later**.

## Quick start

From the repo root (installs toolchain bits if needed, then build + test):

```bash
./scripts/setup_js.sh
```

**Mesh chat UI** (tabs + Web Bluetooth phones):

```bash
./scripts/run_js_web.sh
# open http://127.0.0.1:5173 — second tab chats automatically
```

Or from this package (Rust + `wasm-pack` already installed):

```bash
cd packages/offline-core-js
npm run setup    # install + build + test
npm run demo     # Node smoke demo
npm run ui       # same as packages/offline-web npm start
```

## Requirements

- Node.js ≥ 18
- Rust (`rustup target add wasm32-unknown-unknown`)
- [`wasm-pack`](https://rustwasm.github.io/wasm-pack/) — `cargo install wasm-pack`

## Usage sketch

```ts
import init, { Identity, MeshController } from "@offline/core";

await init(); // or pass { module_or_path: wasmBytes } in Node
const mesh = new MeshController(new Identity(), "alice");
mesh.queuePublicMessage("hello mesh");
for (const frame of mesh.drainOutbound()) {
  // send frame.bytes on your transport
}
```

## Security

Do **not** persist `exportSecrets()` in clear `localStorage` / IndexedDB.
See `docs/WASM_JS_PACKAGE.md` §7 and `docs/SECURITY_IMPROVEMENTS.md`.
