# Client feature requirements

Requirements for any Offline client (Flutter mobile, Flutter web, or
`packages/offline-web`). Protocol behavior lives in the Rust/`@offline/core`
crates; clients own transport I/O, UI, and media capture.

**Reference implementation:** Flutter app under `flutter/lib/ui/`.  
**JS web target:** `packages/offline-web` (this doc’s parity column).  
**BitChat wire gaps** (e.g. private-media E2E warning): [`BITCHAT_ALIGNMENT.md`](BITCHAT_ALIGNMENT.md).

Legend for **Parity (JS web)**:

| Status | Meaning |
|--------|---------|
| ✅ | Implemented |
| 🚧 | Partial / in progress |
| ❌ | Missing |
| N/A | Not applicable (e.g. native-only advertise) |

---

## 0. Non-goals (all clients)

- Nostr, Tor, geohash channels
- Browser BLE **advertise** (web is always a GATT **leaf**)
- Replacing `flutter_rust_bridge` bindings in the Flutter app

---

## 1. Identity & keys

| ID | Requirement | Notes | Parity |
|----|-------------|-------|--------|
| I-1 | Load-or-create Noise X25519 + Ed25519 identity | Secrets never logged | ✅ |
| I-2 | Persist secrets in platform secure storage | Flutter: Keychain/Keystore. Web: IndexedDB (document XSS risk) | 🚧 |
| I-3 | Show peer ID (16-hex BitChat binding) | Copy to clipboard | ✅ |
| I-4 | Show/copy Noise + signing public keys | | ✅ |
| I-5 | Regenerate identity (confirm) | Wipes secrets; new peer ID | ✅ |
| I-6 | Nickname ≤ 32 chars, editable while mesh runs | Force announce on change | ✅ |
| I-7 | BitChat verify QR (`bitchat://verify?…`) | Signed; refresh ≤ 2 min | ✅ |
| I-8 | Offline share URI/QR (`offline:noise:<hex>`) | | ✅ |
| I-9 | Toggle BitChat \| Offline QR modes | | ✅ |

---

## 2. Mesh public chat

| ID | Requirement | Notes | Parity |
|----|-------------|-------|--------|
| M-1 | Start / stop mesh session | Stop → `queueLeave` + teardown transport | ✅ |
| M-2 | Public text messages | `queuePublicMessage` | ✅ |
| M-3 | Chronological transcript by packet timestamp | | ✅ |
| M-4 | Auto-scroll on new messages | | ✅ |
| M-5 | Surface signature status when known | `signed` / `unsigned` / `invalid_sig` | ✅ |
| M-6 | Emoji insertion helper | | ✅ |
| M-7 | Pub \| DM channel toggle | | ✅ |

---

## 3. Private DMs / Noise

| ID | Requirement | Notes | Parity |
|----|-------------|-------|--------|
| D-1 | Select peer → DM mode | | ✅ |
| D-2 | Private text via Noise | `queuePrivateMessage` (handshake on demand) | ✅ |
| D-3 | Show Noise state (none/handshaking/ready/failed) | | ✅ |
| D-4 | Explicit start Noise handshake control | Optional; first-send also starts | ✅ |
| D-5 | Delivery / read receipt display on local DMs | From `delivered` / `read` events | ✅ |

---

## 4. Peers / announce / leave

| ID | Requirement | Notes | Parity |
|----|-------------|-------|--------|
| P-1 | Announce on start, rename, Join; every **12 s** | | ✅ |
| P-2 | Leave on stop | | ✅ |
| P-3 | Peer list from announces (`listPeers`) | Nick, id, noise, verified | ✅ |
| P-4 | Clear DM selection if selected peer leaves | | ✅ |
| P-5 | Link / peer counts in chrome | | ✅ |

---

## 5. Files / photos / voice

| ID | Requirement | Notes | Parity |
|----|-------------|-------|--------|
| F-1 | Send photo (public or directed) | JPEG ≤ **45 KiB**, edge ≤ **448**, quality ladder | ✅ |
| F-2 | Show inbound images in chat; tap to enlarge | | ✅ |
| F-3 | Hold-to-record / tap voice note | Web: WAV **8 kHz**; ≤ **512 KiB** | ✅ |
| F-4 | Playback inbound voice notes | | ✅ |
| F-5 | Fragment outbound pacing **25 ms** for type `0x20` | | ✅ |
| F-6 | Soft-fail bad ingest frames | Don’t freeze mid-transfer | ✅ |

---

## 6. Optical QR transfer

| ID | Requirement | Notes | Parity |
|----|-------------|-------|--------|
| O-1 | Optical hub: Send / Receive | | ✅ |
| O-2 | Send: pick file → fountain QR animation | FPS ~4–16; progress | ✅ |
| O-3 | Receive: camera/file QR frames → reassemble | Save/download result | ✅ |

---

## 7. QR verification (peer)

| ID | Requirement | Notes | Parity |
|----|-------------|-------|--------|
| V-1 | Show own BitChat verify QR from mesh | Uses current nickname | ✅ |
| V-2 | Challenge peer (`startQrVerification`) | Requires Noise key | ✅ |
| V-3 | Verified badge on peer | From `verified` event | ✅ |

---

## 8. Transport

| ID | Requirement | Notes | Parity |
|----|-------------|-------|--------|
| T-1 | Feed all inbound bytes → `ingestFrame` | Then `drainEvents` + `drainOutbound` | ✅ |
| T-2 | Flush outbound to all links | | ✅ |
| T-3 | `setLinkCount` from transport | | ✅ |
| T-4 | **Web:** BroadcastChannel `offline-mesh-v1` | Presence `join`/`ping`(8s)/`leave` | ✅ |
| T-5 | **Web:** Web Bluetooth Join (BitChat GATT) | Service `f47b5e2d-…4b5c` (+ testnet `…4b5a`); char `a1b2c3d4-…` | ✅ |
| T-6 | **Web:** Browse-all-devices escape hatch | | ✅ |
| T-7 | **Web:** BLE write ≤ 512 B; ~12 ms pace | Skip oversized on BLE, still BC | ✅ |
| T-8 | **Web:** Reconnect permitted BLE devices | | ✅ |
| T-9 | **Mobile:** Dual-role BLE advertise + scan | | N/A |
| T-10 | Gossip `maintainGossipSync` every **5 s** | Delayed sync ~5 s after Join | ✅ |

---

## 9. UI chrome

| ID | Requirement | Notes | Parity |
|----|-------------|-------|--------|
| U-1 | Tabs: Mesh / Optical / Identity | | ✅ |
| U-2 | Status line + LIVE/IDLE | | ✅ |
| U-3 | Theme (at least one complete palette) | Flutter has 6; web ships Carbon-like dark | ✅ |
| U-4 | Frames/wire inspector (optional debug) | Flutter has full dock; JS web deferred | 🚧 |
| U-5 | How-it-works helper + official BitChat iOS/Android links | Web sidebar; Flutter help sheet | ✅ |

---

## 10. Core API surface a client must use

From `@offline/core` / `MeshController` / optical helpers:

| API | Required for |
|-----|----------------|
| `init` | Boot |
| `Identity` / `fromSecrets` / `exportSecrets` | I-1…I-5 |
| `MeshController` + announce/message/DM/file/leave | M/D/F/P |
| `startNoiseHandshake` / `startQrVerification` | D/V |
| `ingestFrame` / `drainOutbound` / `drainEvents` / `listPeers` | Loop |
| `maintainGossipSync` / `setLinkCount` / `setNickname` | P/T |
| `buildVerifyQr` | I-7, V-1 |
| `OpticalSender` / `OpticalReceiver` | O-2, O-3 |

---

## 11. Event kinds to handle

`announce` · `message` · `dm` · `delivered` · `read` · `file` · `noise` · `leave` · `verified`

---

## 12. Platform matrix

| Capability | Flutter mobile | Flutter web | JS `offline-web` |
|------------|----------------|-------------|------------------|
| Public + DM chat | Yes | Yes | Yes |
| Photos / voice | Yes (AAC voice) | Yes (WAV) | Yes (WAV) |
| Optical | Yes | Yes | Yes |
| Verify QR / challenge | Yes | Yes | Yes |
| Tab mesh (BC) | — | Yes | Yes |
| Join phone (BLE leaf) | — | Yes | Yes |
| Advertise BLE | Yes | No | No |
| Secure keystore | Keychain/Keystore | Secure storage plugin | IndexedDB ⚠ |

---

## Maintaining this doc

When adding a Flutter user-facing feature:

1. Add a row under the right section with a new ID.
2. Implement it in Flutter.
3. Update the **Parity** column for `packages/offline-web` (✅/🚧/❌/N/A).
4. Prefer sharing protocol logic in Rust/`@offline/core` so clients stay thin.
