# BitChat alignment tracker

Living checklist of how Offline matches
[bitchat-android](https://github.com/permissionlesstech/bitchat-android)
(and the shared BitChat BLE mesh wire protocol). Update this file whenever
we bump mesh behaviour or re-check against upstream.

| Field | Value |
|-------|--------|
| **Upstream** | `permissionlesstech/bitchat-android` `main` |
| **Last checked** | 2026-10-24 |
| **Offline protocol label** | `bitchat-mesh/1` (see root [`VERSION`](../VERSION)) |
| **Primary refs** | Upstream `docs/PRIVATE_MEDIA_V1.md`, `docs/file_transfer.md`, `docs/sync.md`, `BinaryProtocol.kt`, `NoiseEncrypted.kt`, `PeerCapabilities.kt` |
| **Ours** | [`docs/protocol.md`](protocol.md), crates `offline-packet` / `offline-noise` / `offline-core` |
| **Official apps** | [iOS App Store](https://apps.apple.com/us/app/bitchat-mesh/id6748219622) · [Android Play](https://play.google.com/store/apps/details?id=com.bitchat.droid) · [bitchat.free](https://bitchat.free) |

Legend:

| Status | Meaning |
|--------|---------|
| ✅ | Compatible with current Android/iOS BitChat mesh |
| 🚧 | Partial (decode-only, legacy path, or incomplete) |
| ❌ | Not implemented (gap) |
| ◯ | Intentionally out of scope for Offline |

---

## Why you see “not protected” / “without end-to-end encryption”

BitChat Android’s private-media v1 policy (see upstream
[`PRIVATE_MEDIA_V1.md`](https://github.com/permissionlesstech/bitchat-android/blob/main/docs/PRIVATE_MEDIA_V1.md)):

1. Capable peers advertise **capability bit 8** (`PRIVATE_MEDIA`) in announce TLV `0x05`.
2. After each Noise generation they exchange authenticated **peer state** (`NoisePayloadType` `0x21`).
3. Private photos/voice are sent as **Noise-encrypted** outer `0x11` with inner type **`0x20`** (full `BitchatFilePacket` TLV).
4. If the peer looks like an **older client** (no bit 8 / no `0x21` within ~5 s), BitChat shows:

   > **Send without end-to-end encryption?**  
   > …their client is older…

   and only then may send a **legacy** directed signed raw `FILE_TRANSFER` (`0x22`). That path is **relay-visible** (not Noise-wrapped).

**Offline today (private-media v1):**

| Behaviour | Offline |
|-----------|---------|
| Announce TLV `0x05` bit 8 (`PRIVATE_MEDIA`) | ✅ encoded + decoded |
| Noise `0x21` authenticated peer state after handshake | ✅ send / accept / pin / 5 s watchdog |
| Private media send via Noise `0x11` + inner `0x20` | ✅ when peer proves `PRIVATE_MEDIA` |
| Private media send via directed signed `0x22` | ✅ legacy only after consent (`queue_file_ex` / web confirm) |
| Private media **receive** Noise inner `0x20` | ✅ decode + deliver |
| Private **text** via Noise `0x01` | ✅ |

With capable Offline ↔ BitChat peers, private media should no longer trip the “not protected” warning. Legacy directed `0x22` remains for older peers only after explicit consent (web) or `queue_file_allow_legacy` after FRB regen (Flutter).

---

## 1. Mesh wire — aligned

| Area | Status | Notes |
|------|--------|-------|
| Peer ID = first 8 B of SHA-256(Noise static pub) | ✅ | |
| Packet v1 (14 B) / v2 (16 B) headers, BE fields | ✅ | |
| Flags: recipient, signature, compressed, route, RSR | ✅ | We encode/decode; source-route *use* still limited |
| Announce TLV nick / noise / signing / neighbors / caps `0x05` | ✅ | |
| Public `message` `0x02` + Ed25519 sign / verify | ✅ | |
| Leave `0x03` | ✅ | |
| Noise XX `Noise_XX_25519_ChaChaPoly_SHA256` | ✅ | |
| Noise handshake `0x10` / encrypted `0x11` | ✅ | |
| Transport `nonce_u32_be ‖ ct ‖ tag`, replay window | ✅ | |
| Crossed XX initiator = lex smaller peer ID | ✅ | |
| Private text Noise payload `0x01` + TLV | ✅ | |
| Delivered `0x03` / read receipt `0x02` | ✅ | Text DMs + private-media stable ids (`media-…`) |
| Fragment `0x20`, chunk ~469 B, pacing | ✅ | |
| `requestSync` `0x21` + GCS gossip | ✅ | Packet type `0x21`; Noise peer-state also uses payload type `0x21` |
| File TLV `0x22` public (signed broadcast) | ✅ | |
| Noise private file **send/recv** inner `0x20` (alias `0x09`) | ✅ | Receipt-eligible names: `img_*_<UUID>.jpg`, `voice_*` |
| Authenticated peer state Noise payload `0x21` | ✅ | Caps bits 8+9 |
| Live PTT public `0x29` / Noise `0x08` | ✅ | Codec + mesh send/recv; clients wire UI as needed |
| Verify QR + Noise challenge/response `0x10`/`0x11` | ✅ | |
| Compression raw DEFLATE (+ legacy zlib accept) | ✅ | |
| PKCS#7-style padding on Noise frames | ✅ | |

---

## 2. Mesh wire — gaps (in-scope for Offline)

Priority roughly reflects interop pain with current BitChat Android.

| ID | Gap | Status | Impact |
|----|-----|--------|--------|
| **A-1** | **Private media v1 send** (Noise `0x11` + inner `0x20`) | ✅ | Capable peers get E2E media |
| **A-2** | **Announce capability TLV `0x05`** with `PRIVATE_MEDIA` (1≪8) | ✅ | |
| **A-3** | **Authenticated peer state** Noise `0x21` (send + accept + pin) | ✅ | |
| **A-4** | Private media **legacy consent UX** when talking to old peers | ✅ | Core error + web confirm; Flutter needs FRB for `queue_file_allow_legacy` |
| **A-5** | Decode/retain announce capability bits | ✅ | Low-64 retained; local announce encodes `LOCAL_SUPPORTED` |
| **A-6** | Source routing (v2 `HAS_ROUTE`) end-to-end | 🚧 | Codec exists; flood still primary (soft-deferred) |
| **A-7** | Live PTT `voiceFrame` `0x29` / Noise voice `0x08` | ✅ | `VoiceBurstPacket` + mesh/WASM; voice *note* file path remains fallback |
| **A-8** | Reject spoofed plaintext into DM UI (only Noise-decrypted) | ✅ | Directed plaintext `0x02` ignored; DMs only from Noise |
| **A-9** | Wi-Fi Aware / higher-bandwidth local transport | ❌ | BLE (+ web BC / Web Bluetooth leaf) only (soft-deferred) |
| **A-10** | `PRIVATE_MEDIA_RECEIPTS` (cap bit 9) | ✅ | Advertised; stable `media-` id + delivered/read on Noise private files |

---

## 3. Intentionally out of scope (◯)

BitChat Android also ships features Offline **does not** aim to clone on the mesh wire:

| Area | BitChat | Offline |
|------|---------|---------|
| Nostr relays / NIP-17 DMs | ✅ | ◯ |
| Geohash location channels | ✅ | ◯ |
| Tor (Arti) | ✅ | ◯ |
| Password channel chats (Argon2id + AES-GCM) | ✅ | ◯ |
| IRC-style `/join` `/msg` | ✅ | ◯ |
| Favorites + Nostr fallback routing | ✅ | ◯ |
| Wear OS companion | ✅ | ◯ |
| Emergency triple-tap wipe (product) | ✅ | ◯ (clients may add later) |
| Optical QR fountain transfer | — | ✅ Offline-only |

---

## 4. How to re-check

```bash
# Caps + peer-state + announce
cargo test -p offline-packet --lib
cargo test -p offline-core --lib file_transfer_broadcast_and_noise_private
cargo test -p offline-core --lib legacy_private_media_requires_consent

# Optional: diff Noise payload types vs Android
# rg -n "NoisePayloadType|PrivateFile|AuthenticatedPeerState" crates/offline-packet/src/types.rs
```
