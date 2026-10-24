# Security improvements

Review of the Rust workspace (`crates/`), the `flutter_rust_bridge` FFI, and the
Flutter/web glue. Findings are ordered by severity. Line numbers are from the
tree reviewed on 2026-10-24.

Scope note: Offline inherits BitChat's **open mesh** trust model. On the public
mesh, relays forward packets they cannot authenticate, and public chat is
unauthenticated by design. The findings below are therefore split into:

- **Defects** — code that is exploitable *beyond* what the protocol model
  already concedes (memory-safety, unbounded allocation, a broken replay
  window, plaintext key storage). These should be fixed.
- **Model-level hardening** — places where Offline is as permissive as BitChat
  but could reasonably do better (sender-spoofing of public/leave/directed
  frames). These are choices, flagged so they are explicit.

---

## Severity summary

| # | Severity | Area | Short description |
|---|----------|------|-------------------|
| S-1 | **High** | `offline-noise/session.rs` | Replay window is a `u64` but sized at 1024 → shift overflow (debug panic / silent 64-deep window) |
| S-2 | **High** | `offline-packet/compression.rs` | Decompression memory amplification: full stream inflated before the size check |
| S-3 | **High** | `offline-core/mesh_ctrl.rs` | Nested single-fragment reassembly recurses with no depth bound → stack overflow |
| S-4 | **High** | Flutter `identity_store.dart` | Long-term secret keys stored in `SharedPreferences` (plaintext), not Keychain/Keystore |
| S-5 | **Medium** | `offline-core/lib.rs` (optical) | `total_len` / `k` / `block_len` from one QR frame are trusted → up to ~4 GiB allocation |
| S-6 | **Medium** | `offline-core/mesh_ctrl.rs` | Unbounded `sessions` / `peers` / deferred maps keyed by spoofable 8-byte sender id |
| S-7 | **Medium** | `offline-packet/fragment.rs` | Per-reassembly buffer bounded only by `total`×chunk (~28 MiB) × `max_sets` |
| S-8 | **Medium** | `offline-core/mesh_ctrl.rs` | `Leave` (0x03) is unauthenticated → spoofed sender id drops a peer + its Noise session |
| S-9 | **Low/Model** | `offline-core/mesh_ctrl.rs` | Public `Message` (0x02) and directed `FileTransfer` (0x22) accepted without signature check |
| S-10 | **Low** | Android `AndroidManifest.xml` / `build.gradle.kts` | `usesCleartextTraffic=true`; release APK signed with the debug key |
| S-11 | **Low** | `offline-noise/verify_qr.rs` | Hand-rolled percent-decoder drops a trailing `%XX`; QR fields unbounded before parse |

---

## S-1 — Replay window is undersized (`u64` for a 1024-wide window)

**File:** `crates/offline-noise/src/session.rs:13`, `:222-256`

`REPLAY_WINDOW_SIZE = 1024` but the sliding window is a single `u64`
(`replay_window: u64`). The logic admits offsets up to 1023:

```rust
// is_valid_nonce
if offset >= REPLAY_WINDOW_SIZE { return false; }   // offset up to 1023 proceeds
(window & (1u64 << offset)) == 0                     // 1u64 << offset, offset may be 64..1023
```

```rust
// mark_nonce_seen
let new_window = if shift >= REPLAY_WINDOW_SIZE { 1 } else { window << shift }; // shift may be 64..1023
...
(highest, window | (1u64 << offset))                 // same overflow
```

Shifting a `u64` by ≥ 64 is a defect in both profiles:

- **Debug builds** — `1u64 << 64` panics (`attempt to shift left with overflow`).
  A peer that sends a transport frame whose extracted nonce is ≥ 64 behind the
  current highest nonce **crashes the session thread** inside `decrypt`.
- **Release builds** (`[profile.release]` ships) — the shift amount is masked to
  `offset % 64`. Nonces 64…1023 behind the head **alias** onto bits 0…63. A
  genuinely new but reordered frame at offset 64 aliases to bit 0 (the head
  marker, always set) and is wrongly rejected as a replay; conversely some
  replays alias onto a clear bit and are wrongly accepted. In practice the
  replay window is only **64 deep**, not the 1024 the comment and
  `REPLAY_WINDOW_SIZE` claim.

**Impact:** crypto-layer correctness bug. Debug-build crash vector; in release,
silent truncation of the anti-replay guarantee and dropped legitimate frames on
reordered/lossy BLE links.

**Fix (either):**

- Make the window actually 1024 bits: `replay_window: [u64; 16]`, index with
  `offset / 64` and `offset % 64`; shift the whole array on advance. This keeps
  BitChat's documented 1024 window.
- Or, if a 64-deep window is acceptable, set `REPLAY_WINDOW_SIZE = 64` and keep
  the `u64`. This removes the overflow but narrows the window — note it in the
  protocol doc so it stays compatible with BitChat peers that expect 1024.

Add a regression test: deliver nonce `N`, then `N+70`, then replay `N` and
assert `Err(Replay)`; and deliver `N+100` then an in-window `N+40` and assert it
decrypts.

---

## S-2 — Decompression memory amplification

**File:** `crates/offline-packet/src/compression.rs:58-81`, decode path
`crates/offline-packet/src/lib.rs:394-423`

`decode_core` bounds the *claimed* original size and the *claimed* ratio:

```rust
if original_size > MAX_FRAMED_PAYLOAD { return Err(InvalidLength); }   // ~1.1 MiB
let ratio = original_size as f64 / compressed_size as f64;
if ratio > 50_000.0 { return Err(SuspiciousCompression); }
let decompressed = decompress_zlib(compressed, original_size)?;
```

But the ratio guard uses the **attacker-supplied** `original_size`, and the
actual inflation is unbounded:

```rust
fn inflate_exact<R: Read>(mut decoder: R, original_size: usize) -> ... {
    let mut out = Vec::with_capacity(original_size);
    decoder.read_to_end(&mut out)?;          // reads the ENTIRE real stream
    if out.len() != original_size { return Err(Compression); }   // checked only AFTER
    ...
}
```

An attacker sends `original_size = 1000` (passes every check) with a compressed
body up to `MAX_FRAMED_PAYLOAD` that actually inflates to the DEFLATE ceiling
(~1032× → on the order of a gigabyte). `read_to_end` buffers all of it into
`out` before the `!= original_size` comparison rejects it. Compressed frames are
accepted on the public mesh with no prior authentication, and relays decode
them, so this is a remote, unauthenticated memory-exhaustion DoS that also
amplifies across every relaying node.

**Fix:** bound the reader to the claimed size and fail as soon as it is
exceeded, instead of inflating first:

```rust
use std::io::Read;
let mut out = Vec::with_capacity(original_size.min(MAX_FRAMED_PAYLOAD));
// read at most original_size + 1 bytes; a 1-byte overrun proves a mismatch
let mut limited = decoder.take(original_size as u64 + 1);
limited.read_to_end(&mut out)?;
if out.len() != original_size { return Err(PacketError::Compression); }
```

Because `original_size` is already capped at `MAX_FRAMED_PAYLOAD`, the bounded
reader caps peak allocation at ~1.1 MiB regardless of the compressed contents.

---

## S-3 — Unbounded recursion in fragment reassembly

**File:** `crates/offline-core/src/mesh_ctrl.rs:852-871`

`ingest_frame` reassembles a fragment set and then re-enters itself with the
reassembled bytes:

```rust
match self.fragments.ingest(&packet) {
    Some(assembled) => match self.ingest_frame(&assembled) {  // recursive
        ...
    },
    None => return self.maybe_relay(&packet),
}
```

`FragmentPayload::decode` accepts `total == 1, index == 0` and an
`original_type` of `Fragment` (0x20) itself. So a fragment can carry a whole
*other* single-fragment packet, nested arbitrarily. Each layer costs one
`ingest_frame` stack frame; a deep enough nest overflows the stack and aborts
the process. The frames are tiny (a 1-fragment wrapper adds ~30 bytes), so a few
thousand nestings fit well within one BLE transfer / gossip reply, and it is
unauthenticated.

**Fix:**

- Reject the degenerate wrapper: in `FragmentReassembler::ingest` or in
  `ingest_frame`, drop a fragment whose `original_type == Fragment as u8`.
- Convert the reassembly re-entry to a bounded loop (or pass an explicit depth
  counter, cap at e.g. 2) so a reassembled packet is decoded at most once more.

---

## S-4 — Long-term secret keys stored in `SharedPreferences`

**File:** `flutter/lib/ui/identity_store.dart:32-57`

The device's long-term Noise X25519 secret and Ed25519 signing secret are the
whole identity. They are persisted base64-encoded in `SharedPreferences`:

```dart
await prefs.setString(_kNoiseSecret, base64Encode(bundle.noiseSecretKey));
await prefs.setString(_kSigningSecret, base64Encode(bundle.signingSecretKey));
```

`SharedPreferences` is a plaintext `.xml` file on Android and
`NSUserDefaults`/plist on iOS — not encrypted, included in some backup paths,
and readable by anything that gets at app storage (rooted/jailbroken device, ADB
backup, forensic image). The Rust side carefully `Zeroize`s these keys
(`identity.rs:22`), but that effort is undone the moment they are handed to
Dart and written to prefs. For a tool whose premise is identity and private
messaging, key-at-rest protection matters.

**Fix:** store the two secrets with `flutter_secure_storage` (backed by the
Android Keystore and iOS Keychain), or keep them in platform secure storage and
pass them to Rust only transiently. Mark the Keychain items
`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` and exclude the prefs file
from Android auto-backup (`android:allowBackup`, `fullBackupContent` rules).

---

## S-5 — Optical header fields are trusted for allocation

**File:** `crates/offline-core/src/lib.rs:143-183`; `offline-fountain/src/protocol.rs:31-61`

`OpticalReceiver::ingest` builds the decoder straight from one untrusted QR
frame header:

```rust
self.decoder = Some(LTDecoder::new(
    header.k as usize,
    header.block_len as usize,
    header.session_id,
    header.total_len as usize,   // u32, up to ~4 GiB
));
```

`LTDecoder::new` allocates `solved: vec![None; k]` (k up to 65535) and
`assemble()` allocates `vec![0u8; total_len]`. A single crafted QR with `k = 1`
solves immediately and `assemble()` allocates `total_len` bytes — up to ~4 GiB
from one scanned frame. `parse_frame` only rejects zero values, not large ones.

**Impact:** a malicious QR (or a corrupted scan) can OOM the receiver. Lower
severity than the mesh findings because it requires the user to point the camera
at attacker-controlled frames, but it is a one-frame trigger.

**Fix:** clamp in `parse_frame` / `OpticalReceiver::ingest` to sane optical
limits, e.g. `total_len <= MAX_OPTICAL_BYTES` (a few MiB), `k <= some_max`,
`block_len` within `[1, 2048]`, and reject frames that violate
`total_len <= k * block_len`. Reuse the same ceiling the sender enforces.

---

## S-6 — Unbounded per-peer state keyed by a spoofable id

**File:** `crates/offline-core/src/mesh_ctrl.rs` — `handle_noise_handshake:1313-1358`,
`touch_peer:1577-1609`, `defer_noise_encrypted:1409-1419`

Noise XX message 1 is a bare 32-byte ephemeral with no static key, so the
responder creates a `NoiseSession` *before* any identity is bound:

```rust
if !self.sessions.contains_key(from) {
    match NoiseSession::start(&self.identity, HandshakeRole::Responder, remote) { ... }
}
```

`from` is the 8-byte sender id off the wire, which anyone can forge and vary.
Each forged msg1 with a fresh sender id inserts a new entry into `sessions`
(a full snow handshake state), and `peers`, `pending_initial_sync`,
`deferred_noise_encrypted`, `pending_private_messages`, etc. grow in lockstep.
None of these maps is capacity-bounded. A single sender can mint unbounded
sessions → memory exhaustion.

**Fix:** cap concurrent half-open handshakes and total tracked peers
(e.g. LRU-evict oldest handshaking sessions above a ceiling); rate-limit new
responder sessions per unit time; and prefer binding/eviction once a handshake
fails. The `FragmentReassembler` already shows the LRU pattern to copy.

---

## S-7 — Fragment reassembly buffers are weakly bounded

**File:** `crates/offline-packet/src/fragment.rs:332-421`

`FragmentReassembler` caps the *number* of concurrent sets (`max_sets`, 64/128)
and expires after 120 s, but a single set is bounded only by its wire `total`:

```rust
pub const MAX_FRAGMENTS_PER_PACKET: usize = u16::MAX as usize; // 65535
```

Each part can be up to `MAX_FRAGMENT_CHUNK` (440 B), so one incomplete set can
hold ~65535 × 440 ≈ 28 MiB, and `max_sets` of them → multiple GiB of
never-completed buffers held for the full timeout. An attacker streams many
distinct indices for sets they never finish.

**Fix:** track total buffered bytes across all sets and evict/refuse past a
global ceiling; cap `total` for mesh use at `BITCHAT_COMPAT_MAX_FRAGMENTS` (256)
unless a larger train is explicitly expected; and consider dropping a set whose
first-seen `total` implies more than a per-set byte budget.

---

## S-8 — `Leave` is unauthenticated

**File:** `crates/offline-core/src/mesh_ctrl.rs:945-949`

```rust
Some(MessageType::Leave) => {
    self.peers.remove(&from);
    self.sessions.remove(&from);
    self.events.push_back(MeshEvent::PeerLeave { peer_id: from });
}
```

`from` is the unauthenticated sender id. Anyone within mesh range can broadcast
a `Leave` carrying a victim's 8-byte id and force every node to drop that peer
and **tear down its established Noise session**, repeatedly. Cheap targeted DoS
against a specific conversation.

**Fix:** only honor a `Leave` for a peer with whom there is no verified Noise
session, or require the `Leave` to be signed (BitChat signs control frames) /
delivered inside the peer's Noise transport. At minimum, do not drop a
`Transport`-state session on an unauthenticated `Leave`.

---

## S-9 — Public and directed plaintext frames are accepted unsigned (model-level)

**File:** `crates/offline-core/src/mesh_ctrl.rs:929-938` (Message),
`:961-997` (FileTransfer, directed path)

- Public `Message` (0x02) is surfaced to the UI with no signature check; the
  `signature` field is ignored on receive. Sender attribution on public chat is
  therefore forgeable.
- Directed `FileTransfer` (0x22) with a recipient is delivered when `for_us`
  with **no** signature verification (only the *broadcast* path verifies against
  the announced signing key, `:980-997`). A directed "private" file is also
  plaintext on the wire — relays see it.

This matches BitChat's public-mesh model, so it is listed as a conscious choice,
not a bug. But two concrete hardening steps are cheap:

- When the sender's signing key is already known from a verified announce,
  verify the `Message`/directed-file signature and mark unverified ones in the
  UI (BitChat shows this distinction). Code to verify is already present for the
  broadcast-file path and for announces — reuse `Identity::verify` with
  `packet.signing_bytes()`.
- Document clearly that directed 0x22 files are **not** end-to-end encrypted;
  route genuinely private files through the Noise `PrivateFile` (0x20) path that
  `handle_noise_encrypted` already supports (`:1480-1505`), not through directed
  plaintext 0x22.

---

## S-10 — Android packaging

**Files:** `flutter/android/app/src/main/AndroidManifest.xml:20`,
`flutter/android/app/build.gradle.kts:36-37`

- `android:usesCleartextTraffic="true"` — an offline BLE/optical app has no need
  for cleartext HTTP; setting it weakens the network posture for no benefit.
  Remove it (or scope it with a network-security-config) unless a specific
  cleartext endpoint is required.
- The release APK is signed with the **debug** keystore (`signingConfig =
  signingConfigs.getByName("debug")`), as the README notes. Debug-signed
  releases are not upgrade-safe and carry a publicly-known key. Configure a real
  release keystore before distributing `v*` tags; the release workflow
  (`.github/workflows/release.yml`) ships whatever this produces.

---

## S-11 — QR verify parser edge cases

**File:** `crates/offline-noise/src/verify_qr.rs:60-95`, `:211-234`

- `percent_decode` uses `if bytes[i] == b'%' && i + 2 < bytes.len()`. The strict
  `<` drops a `%XX` escape that ends the string (when the two hex digits are the
  final two bytes), silently mangling the last field. Use `i + 2 <= bytes.len() - 1`
  equivalently `i + 3 <= bytes.len()`.
- `from_url` parses `ts`, keys, nonce, and signature with no length bounds before
  `verify_signature`; a malformed URL with huge fields is cheap to feed. Bound
  field lengths (hex keys are 64/128 chars, nonce is fixed) before doing work,
  and reject on the first malformed field.

These are low severity (the Ed25519 signature check ultimately rejects forged
QRs), but the decoder should be exact and bounded.

---

## Good practices already in place

Worth keeping and not regressing:

- X25519/Ed25519 secrets are wrapped in `Zeroize`/`ZeroizeOnDrop`
  (`identity.rs:22-32`) — the gap is only at the Dart storage boundary (S-4).
- Peer id is cryptographically bound to the Noise static key and re-checked
  during the handshake (`session.rs:134-148`) and on announce
  (`mesh_ctrl.rs:1028-1034`).
- Broadcast file transfers verify the Ed25519 signature against the announced
  signing key and drop unsigned broadcasts (`mesh_ctrl.rs:980-996`).
- Forged/replayed/truncated ciphertext drops the single packet instead of
  tearing down the session (`mesh_ctrl.rs:1447-1452`).
- Decode paths cap `payload_length` at `MAX_FRAMED_PAYLOAD` and reject malformed
  TLV lengths; the GCS/`request_sync` decoders bound their inputs
  (`request_sync.rs:152-170`).
- `MessagePadding::unpad` validates every padding byte, and transport encryption
  is AEAD (ChaCha20-Poly1305), so there is no padding-oracle surface.

---

## Suggested fix order

1. **S-2, S-3, S-5, S-7** — unauthenticated remote/one-frame DoS; all small,
   self-contained code changes with clear bounds.
2. **S-1** — crypto-layer correctness; pick the 1024-bit window or re-scope to 64.
3. **S-4** — move keys to secure storage.
4. **S-6, S-8** — session/peer bounds and `Leave` handling.
5. **S-9, S-10, S-11** — model-level hardening and packaging.

Each fix above is local to one function; none requires a protocol change except
the S-1 window choice, which should be reflected in `docs/protocol.md`.
