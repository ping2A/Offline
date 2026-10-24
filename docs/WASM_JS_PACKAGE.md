# JavaScript / WASM package (`@offline/core`)

Technical design for a **standalone JavaScript build** of Offline's Rust core,
compiled to WebAssembly with `wasm-bindgen`, so the mesh codec, Noise sessions,
and optical fountain transfer can be published to npm and dropped into any web
page, Node service, Deno/Bun runtime, or Electron app — with no Flutter and no
`flutter_rust_bridge` runtime.

> This is **not** the existing `flutter/web/pkg/` artifact. That one is produced
> by `flutter_rust_bridge_codegen build-web` from `crates/offline_ffi` and is
> bound to the Flutter/FRB runtime and Dart glue. The package described here is
> a new, FRB-free crate (`crates/offline-wasm`) that targets plain JS consumers
> and ships its own ergonomic TypeScript API.

---

## 1. Goals and non-goals

**Goals**

- One `npm install @offline/core` gives: BitChat packet encode/decode, Noise XX
  identity + sessions, the optical LT fountain encoder/decoder, and the
  high-level `MeshController` state machine — all in the browser or Node.
- Pure computation / codec. The host supplies transport bytes (Web Bluetooth,
  `BroadcastChannel`, WebSocket, a file, a camera). The WASM core never touches
  I/O, matching how `offline-core` is already structured ("platform code owns
  BLE I/O; this crate decides whether and how to relay", `offline-mesh/lib.rs:3`).
- Deterministic wire compatibility with the native build (same crates compiled),
  so a browser peer and a phone speak the identical protocol.
- TypeScript types shipped, tree-shakeable, works with Vite/webpack/esbuild and
  `<script type="module">`.

**Non-goals**

- No BLE advertising (browsers cannot; the web app is a GATT-central *leaf*, as
  the README states). The package handles bytes, not radios.
- No replacement for the Flutter app's FRB bindings — both can coexist; they
  compile the same `offline-*` crates.

---

## 2. Where it sits

```
crates/
  offline-packet/   offline-noise/   offline-mesh/
  offline-fountain/ offline-core/            ← pure Rust, no_std-friendly logic
  offline_ffi/            ← flutter_rust_bridge bindings (Flutter app)   [existing]
  offline-wasm/           ← NEW: wasm-bindgen wrapper → npm package      [this doc]
packages/
  offline-core-js/        ← NEW: generated pkg + hand-written TS wrapper + tests
```

`offline-wasm` depends only on the existing core crates. It adds **no** method
to them; it re-exposes their public API across the JS boundary. Because the
cores already compile to `wasm32-unknown-unknown` for the Flutter web build
(`offline_ffi/Cargo.toml` already pins `getrandom = { features = ["js"] }` for
wasm), the toolchain is proven.

---

## 3. Crate: `crates/offline-wasm`

### 3.1 `Cargo.toml`

```toml
[package]
name = "offline-wasm"
version.workspace = true
edition.workspace = true
license.workspace = true
description = "WebAssembly/JS bindings for the Offline mesh + optical core"

[lib]
crate-type = ["cdylib", "rlib"]

[dependencies]
offline-packet   = { workspace = true }
offline-noise    = { workspace = true }
offline-mesh     = { workspace = true }
offline-fountain = { workspace = true }
offline-core     = { workspace = true }

wasm-bindgen = "0.2"
js-sys       = "0.3"
# Panics become JS exceptions with a readable message instead of an unhelpful
# "unreachable executed" trap.
console_error_panic_hook = { version = "0.1", optional = true }

# dalek / rand need a JS-backed RNG under wasm32 (same as offline_ffi does).
[target.'cfg(target_arch = "wasm32")'.dependencies]
getrandom = { version = "0.2", features = ["js"] }

[features]
default = ["panic-hook"]
panic-hook = ["dep:console_error_panic_hook"]

[package.metadata.wasm-pack.profile.release]
# Ship small: wasm-opt -Oz. The core is ~600 KiB today; aim < 350 KiB gzipped.
wasm-opt = ["-Oz"]
```

Add `"crates/offline-wasm"` to the workspace `members` in the root `Cargo.toml`.
Keep it out of the default `cargo build` for the Flutter path by building it
only via the web script / CI job (section 6).

### 3.2 Binding style

Use `wasm-bindgen` directly (not FRB). Expose a small set of `#[wasm_bindgen]`
structs that own the Rust state and hand `Uint8Array`/`string` across the
boundary. `Vec<u8>` ↔ `Uint8Array` and `String` ↔ `string` are built-in
conversions, so the surface stays thin.

Guidelines:

- One opaque JS class per stateful Rust type (`Identity`, `NoiseSession`,
  `MeshController`, `OpticalSender`, `OpticalReceiver`).
- Fallible Rust returns (`Result<T, E>`) map to `Result<T, JsError>` — they
  surface as thrown JS exceptions. Convert each crate error with its `Display`.
- Events / outbound frames return **plain JSON-serializable objects** (via
  `serde-wasm-bindgen` or explicit getters) so the JS side needs no enum codegen
  — this mirrors how `offline_ffi` already flattens `MeshEvent` into a struct
  with a `kind` string (`offline_ffi/src/api/mesh.rs:27-40`). Reuse that exact
  flattening so JS and Dart see the same event shape.

### 3.3 Proposed `src/lib.rs` surface

```rust
use wasm_bindgen::prelude::*;

#[wasm_bindgen(start)]
pub fn start() {
    #[cfg(feature = "panic-hook")]
    console_error_panic_hook::set_once();
}

// ---- Identity ---------------------------------------------------------------

#[wasm_bindgen]
pub struct Identity(offline_noise::Identity);

#[wasm_bindgen]
impl Identity {
    #[wasm_bindgen(constructor)]
    pub fn generate() -> Identity { Identity(offline_noise::Identity::generate()) }

    /// Restore from the two 32-byte secrets (host keeps them in secure storage).
    pub fn from_secrets(noise_secret: &[u8], signing_secret: &[u8]) -> Result<Identity, JsError> {
        let n: [u8;32] = noise_secret.try_into().map_err(|_| JsError::new("noise secret must be 32 bytes"))?;
        let s: [u8;32] = signing_secret.try_into().map_err(|_| JsError::new("signing secret must be 32 bytes"))?;
        Ok(Identity(offline_noise::Identity::from_secrets(
            &offline_noise::IdentitySecrets { noise_secret: n, signing_secret: s })))
    }

    #[wasm_bindgen(getter)] pub fn peer_id(&self) -> String { self.0.peer_id().to_hex() }
    #[wasm_bindgen(getter)] pub fn noise_public_key(&self) -> Vec<u8> { self.0.noise_public_key().to_vec() }
    #[wasm_bindgen(getter)] pub fn signing_public_key(&self) -> Vec<u8> { self.0.signing_public_key().to_vec() }

    /// Export secrets for the host to persist. SECURITY: see §7.
    pub fn export_secrets(&self) -> ExportedSecrets {
        let s = self.0.export_secrets();
        ExportedSecrets { noise_secret: s.noise_secret.to_vec(), signing_secret: s.signing_secret.to_vec() }
    }
}

#[wasm_bindgen(getter_with_clone)]
pub struct ExportedSecrets { pub noise_secret: Vec<u8>, pub signing_secret: Vec<u8> }

// ---- Mesh controller --------------------------------------------------------

#[wasm_bindgen]
pub struct MeshController(offline_core::MeshController);

#[wasm_bindgen]
impl MeshController {
    #[wasm_bindgen(constructor)]
    pub fn new(identity: Identity, nickname: String) -> MeshController {
        MeshController(offline_core::MeshController::new(identity.0, nickname))
    }

    pub fn peer_id(&self) -> String { /* peer_id_hex() */ }
    pub fn queue_public_message(&mut self, text: String) -> Result<(), JsError> { /* map_err */ }
    pub fn queue_private_message(&mut self, peer_id: String, text: String) -> Result<(), JsError> { /* ... */ }
    pub fn queue_file(&mut self, name: String, mime: String, content: Vec<u8>, to: Option<String>) -> Result<(), JsError> { /* ... */ }
    pub fn start_noise_handshake(&mut self, peer_id: String) -> Result<(), JsError> { /* ... */ }
    pub fn start_qr_verification(&mut self, peer_id: String) -> Result<(), JsError> { /* ... */ }

    /// Feed one inbound frame (bytes from BLE / BroadcastChannel / WS).
    pub fn ingest_frame(&mut self, bytes: &[u8]) -> Result<(), JsError> { /* ... */ }

    /// Pull frames to transmit; each is `{ toPeerId?: string, bytes: Uint8Array }`.
    pub fn drain_outbound(&mut self) -> Result<JsValue, JsError> { /* serde_wasm_bindgen::to_value */ }

    /// Pull UI events; shape identical to the FRB `MeshUiEvent` (kind string + fields).
    pub fn drain_events(&mut self) -> Result<JsValue, JsError> { /* ... */ }

    pub fn maintain_gossip_sync(&mut self) -> Result<(), JsError> { /* periodic tick */ }
}

// ---- Optical (QR fountain) --------------------------------------------------

#[wasm_bindgen]
pub struct OpticalSender(offline_core::OpticalSender);
#[wasm_bindgen]
impl OpticalSender {
    pub fn start(payload: &[u8], block_len: u16) -> OpticalSender { /* default 200 */ }
    pub fn next_frame(&mut self) -> Vec<u8> { /* encode one QR payload */ }
}

#[wasm_bindgen]
pub struct OpticalReceiver(offline_core::OpticalReceiver);
#[wasm_bindgen]
impl OpticalReceiver {
    #[wasm_bindgen(constructor)] pub fn new() -> OpticalReceiver { /* ... */ }
    /// Returns `{ framesCollected, framesTarget, completePayload? }`.
    pub fn ingest_frame(&mut self, frame: &[u8]) -> Result<JsValue, JsError> { /* ... */ }
}

// ---- Stateless codec helpers (optional, for inspectors/tests) ---------------

#[wasm_bindgen]
pub fn build_verify_qr(noise_secret: &[u8], signing_secret: &[u8], nickname: String, now_unix: f64) -> Result<String, JsError> { /* ... */ }
```

The method list is a 1:1 image of `offline_ffi/src/api/*` minus FRB attributes,
so behavior is already battle-tested by the Flutter app — only the binding layer
differs.

### 3.4 Time

`offline-core` uses `web-time` (`mesh_ctrl.rs:21`), which already reads
`performance.now()` / `Date.now()` under wasm. So `MeshController::now_ms()`
works in the browser unchanged. For Node < 20 without `performance`, the
`web-time` shim falls back to `Date.now()`. No extra work needed; just document
that the host clock must be roughly correct for the ±60 s QR freshness check.

---

## 4. JavaScript / TypeScript API

Generated `wasm-bindgen` output is low-level; ship a thin hand-written wrapper in
`packages/offline-core-js/src/index.ts` that:

- Lazily instantiates the WASM module (supports both bundler and `fetch`-based
  init), so consumers can `await init()` once.
- Wraps the opaque classes in idiomatic TS with typed event unions.

```ts
import init, {
  Identity, MeshController, OpticalReceiver, OpticalSender,
} from "@offline/core";

await init();                          // loads + instantiates the .wasm

const id = new Identity();             // or Identity.from_secrets(n, s)
const mesh = new MeshController(id, "alice");

// Transport is yours. Example with BroadcastChannel (two tabs):
const bc = new BroadcastChannel("offline-mesh");
bc.onmessage = (e) => {
  mesh.ingest_frame(new Uint8Array(e.data));
  for (const ev of mesh.drain_events()) handleEvent(ev);
  flush();
};
function flush() {
  for (const f of mesh.drain_outbound()) bc.postMessage(f.bytes.buffer);
}

mesh.queue_public_message("hello mesh");
flush();

// Periodic gossip tick (BitChat schedules ~15 s / 60 s):
setInterval(() => { mesh.maintain_gossip_sync(); flush(); }, 5000);
```

Typed event shape (matches FRB `MeshUiEvent`):

```ts
export type MeshEvent = {
  kind: "announce" | "message" | "leave" | "noise" | "dm" | "file"
      | "delivered" | "read" | "verified";
  peerId: string;
  nickname: string;
  text: string;
  timestampMs: number;
  detail: string;        // noise: "state:detail"; dm: messageId; file: mimeType
  isPrivate: boolean;
  fileName: string;
  fileBytes: Uint8Array; // empty for non-file events
};
```

### Optical example (camera → bytes)

```ts
const rx = new OpticalReceiver();
// per decoded QR (from any QR scanner lib producing raw bytes):
const { framesCollected, framesTarget, completePayload } = rx.ingest_frame(qrBytes);
if (completePayload) saveFile(completePayload);
```

---

## 5. Package layout and `package.json`

```
packages/offline-core-js/
  pkg/                      # wasm-bindgen output (web + bundler targets), gitignored
  src/index.ts              # typed wrapper around pkg/
  test/                     # vitest: wire-compat + roundtrip vectors
  package.json
  tsconfig.json
  README.md
```

```jsonc
{
  "name": "@offline/core",
  "version": "0.1.0",
  "license": "GPL-3.0-or-later",
  "type": "module",
  "sideEffects": ["*.wasm"],
  "exports": {
    ".": {
      "types": "./dist/index.d.ts",
      "import": "./dist/index.js"
    },
    "./wasm": "./pkg/offline_wasm_bg.wasm"
  },
  "files": ["dist", "pkg"],
  "scripts": {
    "build:wasm": "wasm-pack build ../../crates/offline-wasm --release --target web --out-dir ../../packages/offline-core-js/pkg",
    "build:ts": "tsc -p tsconfig.json",
    "build": "npm run build:wasm && npm run build:ts",
    "test": "vitest run"
  }
}
```

Build two `wasm-pack` targets if you want both worlds:

- `--target web` — direct `<script type="module">` / Deno, init via `fetch`.
- `--target bundler` — Vite/webpack/esbuild friendly (default ESM + `import.meta`).

A `--target nodejs` build is useful for server-side relays and CI tests.

License note: the cores are **GPL-3.0-or-later** (`Cargo.toml`), so the published
npm package is GPL too. State this prominently in the package README; consumers
linking it inherit GPL obligations.

---

## 6. Build pipeline

Local:

```bash
# one-time
cargo install wasm-pack           # or rustup target add wasm32-unknown-unknown + wasm-bindgen-cli

# build the npm package
cd packages/offline-core-js
npm run build        # wasm-pack --target web → pkg/, then tsc → dist/
npm test
```

CI (new job in `.github/workflows/`, mirrors the existing release flow):

```yaml
  wasm-js:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: dtolnay/rust-toolchain@stable
        with: { targets: wasm32-unknown-unknown }
      - run: cargo install wasm-pack --locked
      - uses: actions/setup-node@v4
        with: { node-version: "20", registry-url: "https://registry.npmjs.org" }
      - working-directory: packages/offline-core-js
        run: npm ci && npm run build && npm test
      # On a v* tag, publish:
      - if: startsWith(github.ref, 'refs/tags/v')
        working-directory: packages/offline-core-js
        run: npm publish --access public
        env: { NODE_AUTH_TOKEN: ${{ secrets.NPM_TOKEN }} }
```

Size budget: today's FRB wasm is ~600 KiB (`flutter/web/pkg/rust_lib_offline_bg.wasm`).
Without the FRB runtime and with `wasm-opt -Oz` + `lto` (already on in the
release profile), target < 350 KiB gzipped. Track it in CI with a size check.

---

## 7. Security considerations specific to the JS build

The browser is a hostile, multi-tenant runtime. Carry over every guard from the
native path and add web-specific ones. See `docs/SECURITY_IMPROVEMENTS.md` — the
core fixes there (decompression bound S-2, fragment-recursion bound S-3, optical
`total_len` clamp S-5, replay window S-1) **must** land before shipping to the
web, because a web peer accepts frames from any page/tab it is connected to.

Additional, WASM-only concerns:

- **Key storage.** `export_secrets()` hands the raw 32-byte secrets to JS. In a
  browser, do **not** persist them in `localStorage`/`IndexedDB` in the clear
  (readable by any script on the origin, by extensions, and by XSS). Prefer a
  non-extractable key held by the host, or wrap with the WebCrypto API and a
  user passphrase (PBKDF2/Argon2 → AES-GCM) before storage. This is the web
  analogue of native finding S-4. Document that the package itself never
  persists anything.
- **RNG.** `getrandom` with the `js` feature uses `crypto.getRandomValues`,
  which is a CSPRNG in browsers and Node ≥ 15. Fail closed if it is absent
  (old/embedded runtimes) rather than falling back to a weak source — identity
  and Noise ephemerals depend on it.
- **`SharedArrayBuffer` / isolation.** The Flutter web build wants COOP/COEP for
  SAB workers (`web/_headers`, `web/index.html`). This package is single-threaded
  and needs **no** cross-origin isolation — note that so consumers don't assume
  they must set those headers.
- **Transport authentication is the host's job.** The core authenticates Noise
  sessions and (for broadcast files) Ed25519 signatures, but public `Message`
  and directed `FileTransfer` are unauthenticated (native finding S-9). A web UI
  should surface the same verified/unverified distinction and must not present
  spoofable public-chat sender ids as trusted identities.
- **Panic = exception.** With `console_error_panic_hook`, a Rust panic throws a
  JS `Error` instead of trapping. Ensure the S-1 debug-shift panic is fixed so a
  crafted nonce cannot throw inside `ingest_frame` and wedge the host's event
  loop.
- **DoS amplification across tabs.** `BroadcastChannel` fan-out means one
  malicious tab reaches every other tab. The memory-bound fixes (S-2/S-3/S-5/S-7)
  are what keep a single crafted frame from OOM-ing every listener.

---

## 8. Testing / wire-compatibility

The package must prove byte-identical behavior with the native build:

1. **Cross-build vectors.** In Rust (native), generate fixtures: encoded packets,
   a Noise XX transcript, and an optical frame stream for a known payload. Commit
   them as `test/vectors/*.bin`. In `vitest`, load the WASM build and assert it
   decodes/encodes the same bytes and reassembles the same payload. Because both
   builds compile the *same* crates, divergence means a binding bug.
2. **Noise roundtrip.** Two `MeshController`s in one test (A ↔ B) complete the XX
   handshake over the drained-outbound/ingest loop and exchange an encrypted DM —
   the same shape as the native integration tests.
3. **Optical roundtrip.** `OpticalSender` → feed frames (and drop ~15 %) into
   `OpticalReceiver`, assert the FNV-checked payload matches.
4. **Fuzz the decoders** with random/truncated byte strings through
   `Packet.decode`, `OpticalReceiver.ingest_frame`, and `MeshController.ingest_frame`;
   assert they return/throw without hanging or OOM (regression coverage for the
   DoS findings).

---

## 9. Rollout steps

1. Add `crates/offline-wasm` (section 3) and wire it into the workspace.
2. Land the core security fixes (S-1, S-2, S-3, S-5, S-7) so the web surface is
   safe to expose.
3. Add `packages/offline-core-js` with the TS wrapper, tests, and build scripts.
4. Add the `wasm-js` CI job; gate `npm publish` on `v*` tags.
5. Ship `packages/offline-web` UI to Flutter-web feature parity — track against
   `docs/CLIENT_FEATURES.md`.
6. (Optional) migrate `flutter/web` to consume `@offline/core` instead of the
   FRB web pkg, or keep both — they compile the same cores, so they stay in sync.
