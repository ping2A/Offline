# Offline protocol (BitChat mesh + optical)

Offline speaks the **BitChat BLE mesh wire protocol** for chat and private sessions, and a separate **optical fountain frame** format for camera/QR file transfer. Internet transports (Nostr / Tor / geohash) are **out of scope**.

**Interop status vs BitChat Android/iOS** (including the private-media “not E2E” warning): see [`BITCHAT_ALIGNMENT.md`](BITCHAT_ALIGNMENT.md).

## Mesh identity

- Noise static key: X25519
- Signing key: Ed25519
- Peer ID: first 8 bytes of `SHA-256(noise_static_public)`, rendered as 16 lowercase hex characters  
  (see BitChat `NOISE_PEER_ID_BINDING`)

### Identity verify QR (BitChat-compatible)

Offline can emit BitChat’s signed verification URL (UTF-8 QR), matching `VerificationService`:

```text
bitchat://verify?v=1&noise=<hex>&sign=<hex>&nick=<utf8>&ts=<unix_s>&nonce=<b64url>&sig=<hex>
```

Signature covers length-prefixed UTF-8 fields under context `bitchat-verify-v1` (Noise/sign hex lowercased; optional `npub` empty when omitted). BitChat rejects QR older than ~5 minutes — Offline refreshes every 2 minutes. An `offline:noise:<hex>` QR remains available for Offline-only sharing.

**BitChat scan flow:** BitChat only accepts the QR if your Offline Noise key is already a live mesh peer, then sends a Noise `verifyChallenge` (0x10). Offline answers with `verifyResponse` (0x11) signed under `bitchat-verify-resp-v1`. So: start mesh / Join BitChat first, wait until you appear in BitChat’s peer list, then scan.

## Packet header

Big-endian multi-byte fields.

| Version | Header size | Payload length field |
|---------|-------------|----------------------|
| 1 | 14 bytes | `u16` |
| 2 | 16 bytes | `u32` (+ optional source route) |

Layout:

```text
version(1) type(1) ttl(1) timestamp(8) flags(1) payload_len(2|4)
sender_id(8) [recipient_id(8)] [route: count(1) + hops*8] [orig_len?] payload [signature(64)]
```

Flags: `HAS_RECIPIENT=0x01`, `HAS_SIGNATURE=0x02`, `IS_COMPRESSED=0x04`, `HAS_ROUTE=0x08`, `IS_RSR=0x10`.

Signatures cover the packet with **TTL=0**, **no signature bytes**, **is_rsr cleared**, and with **PKCS#7 padding applied** (BitChat `toBinaryDataForSigning` defaults to `BinaryProtocol.encode(…, padding: true)`). Relays may decrement TTL without breaking the signature.

Padding (PKCS#7-style to 256/512/1024/2048) applies to **Noise handshake / Noise encrypted** frames on the wire, and also to the **canonical bytes used for Ed25519 signatures** (even for announce/message).

## Message types (subset we implement first)

| Type | Value | Notes |
|------|-------|--------|
| announce | 0x01 | Signed BitChat announce TLV (nickname + Noise/signing pubs + neighbors); Offline still accepts legacy UTF-8 nickname payloads |
| message | 0x02 | Public mesh chat |
| leave | 0x03 | |
| requestSync | 0x21 | Join catch-up: GCS of known packet IDs; peer replies with missing recent public messages/announces (`ttl=0`, `IS_RSR`) |
| noiseHandshake | 0x10 | Noise XX handshake (padded) |
| noiseEncrypted | 0x11 | Private payloads (padded) |
| fragment | 0x20 | Splits large packets; BitChat default chunk **469** B; fragment wrappers are **v1** (unless source-routed); `total` is u16 (full range) |
| fileTransfer | 0x22 | BitChat file TLV (photos / voice / files); v2 signed packets; fragments when >512 B; **zlib when beneficial** (same as BitChat — required for signature verify) |

### File transfer TLV (BitChat `BitchatFilePacket`)

Canonical v2 encoding (2-byte lengths except CONTENT):

| Tag | Field | Length field |
|-----|--------|--------------|
| `0x01` | File name (UTF-8) | u16 |
| `0x02` | File size (u32 BE value) | u16 (=4) |
| `0x03` | MIME type (UTF-8) | u16 |
| `0x04` | Content bytes | **u32** |

Limits: content ≤ 1 MiB. Mesh **photos** should stay near BitChat’s ~45 KiB target (≤256 BLE fragments — Android rejects longer trains). Voice notes ideally ≤ 512 KiB but AAC keeps them small in practice. Broadcast = no recipient (signed `0x22`). Private media to capable peers uses Noise `0x11` + inner `privateFile=0x20` (same TLV). Legacy directed signed `0x22` is only for older peers after consent.

**Official BitChat compatibility notes:**

- Broadcast media must be **Ed25519-signed**; BitChat drops unverified broadcasts. Offline re-announces (signing key TLV) immediately before each file send.
- MIME allow-list matches BitChat (`image/jpeg`, `audio/mp4`, `audio/wav`, …). JPEG content must start with `FF D8 FF`; WAV with `RIFF….WAVE`.
- Fragment pacing ~25–30 ms (BitChat `bleFragmentSpacingMs`); BitChat’s assembly window is ~30 s, so default chunk **469** is required for large photos.
- Voice notes: native AAC → `audio/mp4` / `.m4a`; web fallback → `audio/wav`.

Voice notes use the same `fileTransfer` path. Live PTT uses public signed `voiceFrame` `0x29` or Noise inner `0x08` (`VoiceBurstPacket`; see BitChat `LIVE_VOICE_V1.md`).

### Gossip sync (`requestSync`)

On join / peer announce, Offline sends a directed `requestSync` (TTL 0) with a Golomb-Coded Set of known packet IDs. `sinceTimestamp` is set only when the filter cannot cover the full newest-first candidate set (BitChat coverage cursor). Peers reply with missing packets marked `IS_RSR`, TTL 0.

Stores and typed rounds (BitChat defaults):

| Store | Capacity | Age | Sync interval |
|-------|----------|-----|---------------|
| public messages + announces | 1000 | 15 min | ~15 s |
| fragments | 600 | 15 min | ~30 s |
| file transfers | 200 | 15 min | ~60 s |

Initial sync to a new peer is delayed ~5 s and requests announce|message|fragment|fileTransfer. Responses are rate-limited (~8 / 30 s per peer). TLV `0x06` fragment-ID filters are decoded for targeted fragment recovery.

### Announce TLV (BitChat `AnnouncementPacket`)

1-byte type + 1-byte length:

| Tag | Field |
|-----|--------|
| `0x01` | Nickname (UTF-8) |
| `0x02` | Noise static public key (32) |
| `0x03` | Ed25519 signing public key (32) |
| `0x04` | Direct neighbors (concatenated 8-byte peer IDs) |
| `0x05` | Capabilities (ignored, forward-compat) |
| `0x06` | Bridge geohash (ignored, forward-compat) |

Announce signatures are verified when a signing key TLV is present. Noise public key must hash to the packet `sender_id`.

### Private message TLV (inside Noise)

After Noise decrypt, first byte is `NoisePayloadType`. For `privateMessage=0x01`, body is:

| Tag | Field |
|-----|--------|
| `0x00` | Message ID |
| `0x01` | Content (UTF-8) |

Noise payload type byte (inside decrypted Noise): `privateMessage=0x01`, `readReceipt=0x02`, `delivered=0x03`, `voiceFrame=0x08`, `privateFile=0x20`, `authenticatedPeerState=0x21`, …

Receivers ack DMs with `delivered` (body = message id UTF-8). Private media uses the same ACK types with a BitChat stable id `media-` + 32 hex (derived from sender, recipient, and receipt-eligible filename). Senders may queue private texts and start Noise XX when the session is not ready yet.

**Private media (BitChat private-media v1):** Offline advertises announce TLV `0x05` bits 8+9 (`PRIVATE_MEDIA` + `PRIVATE_MEDIA_RECEIPTS`), exchanges Noise `authenticatedPeerState` `0x21` after each Noise generation, and sends private photos/voice as Noise outer `0x11` + inner `0x20`. Filenames must be BitChat-shaped (`img_…_<UUID>.jpg` / `voice_…`) for receipt ids. Directed signed `fileTransfer` `0x22` is legacy-only (consent required). See [`BITCHAT_ALIGNMENT.md`](BITCHAT_ALIGNMENT.md).

Public / broadcast voice notes use BitChat `fileTransfer` (0x22) with `audio/mp4` AAC when available (`voice_yyyyMMdd_HHmmss_<uuid>.m4a`), or `audio/wav` fallback.

`CompressionUtil` uses **raw DEFLATE** (Apple `COMPRESSION_ZLIB` / Android `Deflater(nowrap)`), not the zlib wrapper. Decode accepts raw DEFLATE and legacy zlib-wrapped payloads. `shouldCompress` counts unique bytes over the **entire** payload and divides by `min(len, 256)` (threshold 100 bytes, ratio &lt; 0.9).

## Noise

`Noise_XX_25519_ChaChaPoly_SHA256` via `snow`. After handshake, remote static key must hash to the claimed peer ID or the session is aborted.

Transport ciphertext matches BitChat `useExtractedNonce`:

```text
nonce_u32_be (4) || ciphertext || poly1305_tag (16)
```

The receiver sets the ChaChaPoly nonce from the prefix (sliding 1024-nonce replay window) before decrypt. Crossed XX initiations (both peers send msg1): the lexicographically smaller peer ID keeps the initiator role; the other yields and responds.

## Routing (v1)

Controlled flood: origin TTL 7, dedupe LRU (~1000 / 5 min), degree-based TTL clamp, connection caps / announce intervals for duty cycling. Source routing (v2 `HAS_ROUTE`) comes after flood works end-to-end.

## Optical frames (decimen-compatible)

Little-endian 20-byte header + fountain block:

```text
magic 0xD1 0x0C | sessionId u16 | seq u32 | k u16 | blockLen u16 | totalLen u32 | payloadFnv u32
```

LT robust-soliton coding; progress UI must track **frames collected**, not blocks solved.

## Explicitly not implemented

- Nostr relays / private envelopes  
- Tor (Arti)  
- Geohash location channels / board posts over Nostr  
- Gateway `nostrCarrier` packets (type may be ignored)
