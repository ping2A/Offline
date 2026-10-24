//! BitChat-compatible binary packet codec.
//!
//! Wire format matches BitChat `BinaryProtocol` (v1 14-byte header, v2 16-byte
//! header, big-endian multi-byte fields). See `docs/protocol.md`.

mod announce;
mod capabilities;
mod compression;
mod file_transfer;
mod fragment;
mod gcs;
mod packet_id;
mod padding;
mod peer_state;
mod private_media_id;
mod private_message;
mod request_sync;
mod types;
mod voice_burst;

pub use announce::{encode_announce_tlv, parse_announce_payload, AnnouncePayload};
pub use capabilities::PeerCapabilities;
pub use peer_state::AuthenticatedPeerState;
pub use private_media_id::{is_stable_private_media_id, private_media_stable_id};
pub use voice_burst::{
    VoiceBurstFlags, VoiceBurstPacket, VoiceBurstPayload, VOICE_BURST_MAX_BYTES,
    VOICE_CODEC_AAC_LC_16KHZ_MONO,
};
pub use file_transfer::{
    decode_file_transfer, encode_file_transfer, is_allowed_mime, normalize_mime, sniff_mime,
    FileTransferPayload, MAX_FILE_PAYLOAD_BYTES, MAX_IMAGE_BYTES, MAX_VOICE_NOTE_BYTES,
};
pub use fragment::{
    maybe_fragment, maybe_fragment_sized, FragmentPayload, FragmentReassembler,
    BITCHAT_COMPAT_MAX_FRAGMENTS, FRAGMENT_SIZE_THRESHOLD, MAX_FRAGMENT_CHUNK,
    MIN_FRAGMENT_CHUNK,
};
pub use gcs::{bucket as gcs_bucket, contains as gcs_contains, decode_to_sorted_set};
pub use packet_id::compute_packet_id;
pub use padding::{MessagePadding, BLOCK_SIZES};
pub use private_message::{decode_private_message, encode_private_message, PrivateMessagePayload};
pub use request_sync::{
    build_request_sync_payload, decode_fragment_id_filter, decode_request_sync,
    encode_fragment_id_filter, encode_request_sync, RequestSyncPayload, SyncCandidate,
    SyncTypeFlags,
};
pub use types::{
    MessageType, NoisePayloadType, PacketFlags, PeerId, BROADCAST_RECIPIENT, DEFAULT_TTL,
    SENDER_ID_SIZE, SIGNATURE_SIZE,
};

use compression::{decompress_zlib, should_compress, compress_zlib};
use thiserror::Error;

pub const V1_HEADER_SIZE: usize = 14;
pub const V2_HEADER_SIZE: usize = 16;
/// Soft cap for framed packet payloads (file TLV + overhead under BitChat limits).
pub const MAX_FRAMED_PAYLOAD: usize = 1_048_576 + 65_536;

#[derive(Debug, Error, PartialEq, Eq)]
pub enum PacketError {
    #[error("unsupported protocol version {0}")]
    UnsupportedVersion(u8),
    #[error("packet too short")]
    Truncated,
    #[error("invalid payload length")]
    InvalidLength,
    #[error("compression failed")]
    Compression,
    #[error("suspicious compression ratio")]
    SuspiciousCompression,
    #[error("route hop empty or too many hops")]
    InvalidRoute,
}

/// Core BitChat packet (pre-padding).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Packet {
    pub version: u8,
    pub packet_type: u8,
    pub ttl: u8,
    pub timestamp: u64,
    pub sender_id: PeerId,
    pub recipient_id: Option<PeerId>,
    pub route: Vec<PeerId>,
    pub payload: Vec<u8>,
    pub signature: Option<[u8; SIGNATURE_SIZE]>,
    pub is_rsr: bool,
}

impl Packet {
    pub fn new(packet_type: MessageType, sender_id: PeerId, payload: Vec<u8>) -> Self {
        Self {
            version: 1,
            packet_type: packet_type as u8,
            ttl: DEFAULT_TTL,
            timestamp: 0,
            sender_id,
            recipient_id: None,
            route: Vec::new(),
            payload,
            signature: None,
            is_rsr: false,
        }
    }

    pub fn with_timestamp(mut self, timestamp: u64) -> Self {
        self.timestamp = timestamp;
        self
    }

    pub fn with_recipient(mut self, recipient: PeerId) -> Self {
        self.recipient_id = Some(recipient);
        self
    }

    pub fn with_version(mut self, version: u8) -> Self {
        self.version = version;
        self
    }

    pub fn with_ttl(mut self, ttl: u8) -> Self {
        self.ttl = ttl;
        self
    }

    pub fn with_signature(mut self, signature: [u8; SIGNATURE_SIZE]) -> Self {
        self.signature = Some(signature);
        self
    }

    pub fn with_route(mut self, route: Vec<PeerId>) -> Self {
        self.route = route;
        self.version = self.version.max(2);
        self
    }

    /// Encode to wire bytes. When `pad` is true, applies BitChat PKCS#7 block padding
    /// (used for Noise handshake / encrypted frames).
    pub fn encode(&self, pad: bool) -> Result<Vec<u8>, PacketError> {
        encode_packet(self, pad)
    }

    /// Decode from wire bytes (tries unpadded first, then PKCS#7 unpad).
    pub fn decode(data: &[u8]) -> Result<Self, PacketError> {
        match decode_core(data) {
            Ok(p) => Ok(p),
            Err(_) => {
                let unpadded = MessagePadding::unpad(data);
                if unpadded.len() == data.len() {
                    return Err(PacketError::Truncated);
                }
                decode_core(&unpadded)
            }
        }
    }

    /// Bytes used for Ed25519 signing: same as encode with signature cleared,
    /// TTL forced to 0, is_rsr cleared.
    ///
    /// BitChat's `toBinaryDataForSigning()` calls `BinaryProtocol.encode` with the
    /// **default `padding: true`**, so the signature covers PKCS#7-padded bytes
    /// (typically to a 256-byte block). We must match that or BitChat rejects
    /// our announces and public messages.
    pub fn signing_bytes(&self) -> Result<Vec<u8>, PacketError> {
        let mut unsigned = self.clone();
        unsigned.signature = None;
        unsigned.ttl = 0;
        unsigned.is_rsr = false;
        encode_packet(&unsigned, true)
    }
}

fn header_size(version: u8) -> Result<usize, PacketError> {
    match version {
        1 => Ok(V1_HEADER_SIZE),
        2 => Ok(V2_HEADER_SIZE),
        v => Err(PacketError::UnsupportedVersion(v)),
    }
}

fn length_field_size(version: u8) -> usize {
    if version == 2 {
        4
    } else {
        2
    }
}

fn encode_packet(packet: &Packet, pad: bool) -> Result<Vec<u8>, PacketError> {
    let version = packet.version;
    if version != 1 && version != 2 {
        return Err(PacketError::UnsupportedVersion(version));
    }

    let mut payload = packet.payload.clone();
    let mut is_compressed = false;
    let mut original_payload_size: Option<usize> = None;

    // Fragments wrap already-encoded frames — never re-compress the wrapper.
    // FileTransfer MUST follow BitChat: zlib when beneficial, because Ed25519
    // signatures cover the (possibly compressed) encode used by
    // `toBinaryDataForSigning`. Skipping compress made Offline reject BitChat
    // photos/voice once the peer's signing key was known.
    let skip_compress = packet.packet_type == MessageType::Fragment as u8;
    if !skip_compress && should_compress(&payload) {
        let max_representable = if version == 2 {
            u32::MAX as usize
        } else {
            u16::MAX as usize
        };
        if payload.len() <= max_representable {
            if let Some(compressed) = compress_zlib(&payload) {
                if compressed.len() < payload.len() {
                    original_payload_size = Some(payload.len());
                    payload = compressed;
                    is_compressed = true;
                }
            }
        }
    }

    let length_field_bytes = length_field_size(version);
    let sanitized_route: Vec<[u8; SENDER_ID_SIZE]> = if version >= 2 {
        packet
            .route
            .iter()
            .map(|hop| {
                let mut out = [0u8; SENDER_ID_SIZE];
                let n = hop.as_bytes().len().min(SENDER_ID_SIZE);
                out[..n].copy_from_slice(&hop.as_bytes()[..n]);
                out
            })
            .collect()
    } else {
        Vec::new()
    };
    if sanitized_route.len() > 255 {
        return Err(PacketError::InvalidRoute);
    }

    let has_route = !sanitized_route.is_empty();
    let original_size_field_bytes = if is_compressed { length_field_bytes } else { 0 };
    let payload_data_size = payload.len() + original_size_field_bytes;

    if version == 1 && payload_data_size > u16::MAX as usize {
        return Err(PacketError::InvalidLength);
    }
    if version == 2 && payload_data_size > u32::MAX as usize {
        return Err(PacketError::InvalidLength);
    }

    let hdr = header_size(version)?;
    let mut data = Vec::with_capacity(
        hdr + SENDER_ID_SIZE
            + packet.recipient_id.map(|_| SENDER_ID_SIZE).unwrap_or(0)
            + if has_route {
                1 + sanitized_route.len() * SENDER_ID_SIZE
            } else {
                0
            }
            + payload_data_size
            + packet.signature.map(|_| SIGNATURE_SIZE).unwrap_or(0)
            + 255,
    );

    data.push(version);
    data.push(packet.packet_type);
    data.push(packet.ttl);
    data.extend_from_slice(&packet.timestamp.to_be_bytes());

    let mut flags = 0u8;
    if packet.recipient_id.is_some() {
        flags |= PacketFlags::HAS_RECIPIENT;
    }
    if packet.signature.is_some() {
        flags |= PacketFlags::HAS_SIGNATURE;
    }
    if is_compressed {
        flags |= PacketFlags::IS_COMPRESSED;
    }
    if has_route && version >= 2 {
        flags |= PacketFlags::HAS_ROUTE;
    }
    if packet.is_rsr {
        flags |= PacketFlags::IS_RSR;
    }
    data.push(flags);

    if version == 2 {
        data.extend_from_slice(&(payload_data_size as u32).to_be_bytes());
    } else {
        data.extend_from_slice(&(payload_data_size as u16).to_be_bytes());
    }

    data.extend_from_slice(packet.sender_id.as_bytes());

    if let Some(recipient) = &packet.recipient_id {
        data.extend_from_slice(recipient.as_bytes());
    }

    if has_route {
        data.push(sanitized_route.len() as u8);
        for hop in &sanitized_route {
            data.extend_from_slice(hop);
        }
    }

    if is_compressed {
        let original = original_payload_size.unwrap();
        if version == 2 {
            data.extend_from_slice(&(original as u32).to_be_bytes());
        } else {
            data.extend_from_slice(&(original as u16).to_be_bytes());
        }
    }
    data.extend_from_slice(&payload);

    if let Some(sig) = &packet.signature {
        data.extend_from_slice(sig);
    }

    if pad {
        let optimal = MessagePadding::optimal_block_size(data.len());
        Ok(MessagePadding::pad(&data, optimal))
    } else {
        Ok(data)
    }
}

fn decode_core(raw: &[u8]) -> Result<Packet, PacketError> {
    if raw.len() < V1_HEADER_SIZE + SENDER_ID_SIZE {
        return Err(PacketError::Truncated);
    }

    let mut offset = 0;
    let mut read = |n: usize| -> Result<&[u8], PacketError> {
        if offset + n > raw.len() {
            return Err(PacketError::Truncated);
        }
        let slice = &raw[offset..offset + n];
        offset += n;
        Ok(slice)
    };

    let version = read(1)?[0];
    if version != 1 && version != 2 {
        return Err(PacketError::UnsupportedVersion(version));
    }
    let length_field_bytes = length_field_size(version);
    let hdr = header_size(version)?;
    if raw.len() < hdr + SENDER_ID_SIZE {
        return Err(PacketError::Truncated);
    }

    let packet_type = read(1)?[0];
    let ttl = read(1)?[0];
    let mut timestamp_bytes = [0u8; 8];
    timestamp_bytes.copy_from_slice(read(8)?);
    let timestamp = u64::from_be_bytes(timestamp_bytes);

    let flags = read(1)?[0];
    let has_recipient = flags & PacketFlags::HAS_RECIPIENT != 0;
    let has_signature = flags & PacketFlags::HAS_SIGNATURE != 0;
    let is_compressed = flags & PacketFlags::IS_COMPRESSED != 0;
    let has_route = version >= 2 && flags & PacketFlags::HAS_ROUTE != 0;
    let is_rsr = flags & PacketFlags::IS_RSR != 0;

    let payload_length = if version == 2 {
        let mut b = [0u8; 4];
        b.copy_from_slice(read(4)?);
        u32::from_be_bytes(b) as usize
    } else {
        let mut b = [0u8; 2];
        b.copy_from_slice(read(2)?);
        u16::from_be_bytes(b) as usize
    };

    if payload_length > MAX_FRAMED_PAYLOAD {
        return Err(PacketError::InvalidLength);
    }

    let mut sender = [0u8; SENDER_ID_SIZE];
    sender.copy_from_slice(read(SENDER_ID_SIZE)?);
    let sender_id = PeerId::from_bytes(sender);

    let recipient_id = if has_recipient {
        let mut r = [0u8; SENDER_ID_SIZE];
        r.copy_from_slice(read(SENDER_ID_SIZE)?);
        Some(PeerId::from_bytes(r))
    } else {
        None
    };

    let mut route = Vec::new();
    if has_route {
        let count = read(1)?[0] as usize;
        for _ in 0..count {
            let mut hop = [0u8; SENDER_ID_SIZE];
            hop.copy_from_slice(read(SENDER_ID_SIZE)?);
            route.push(PeerId::from_bytes(hop));
        }
    }

    let payload = if is_compressed {
        if payload_length < length_field_bytes {
            return Err(PacketError::InvalidLength);
        }
        let original_size = if version == 2 {
            let mut b = [0u8; 4];
            b.copy_from_slice(read(4)?);
            u32::from_be_bytes(b) as usize
        } else {
            let mut b = [0u8; 2];
            b.copy_from_slice(read(2)?);
            u16::from_be_bytes(b) as usize
        };
        if original_size > MAX_FRAMED_PAYLOAD {
            return Err(PacketError::InvalidLength);
        }
        let compressed_size = payload_length - length_field_bytes;
        if compressed_size == 0 {
            return Err(PacketError::InvalidLength);
        }
        let compressed = read(compressed_size)?;
        let ratio = original_size as f64 / compressed_size as f64;
        if ratio > 50_000.0 {
            return Err(PacketError::SuspiciousCompression);
        }
        let decompressed = decompress_zlib(compressed, original_size)?;
        if decompressed.len() != original_size {
            return Err(PacketError::Compression);
        }
        decompressed
    } else {
        read(payload_length)?.to_vec()
    };

    let signature = if has_signature {
        let mut sig = [0u8; SIGNATURE_SIZE];
        sig.copy_from_slice(read(SIGNATURE_SIZE)?);
        Some(sig)
    } else {
        None
    };

    Ok(Packet {
        version,
        packet_type,
        ttl,
        timestamp,
        sender_id,
        recipient_id,
        route,
        payload,
        signature,
        is_rsr,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn roundtrip_v1_public_message() {
        let sender = PeerId::from_bytes([1, 2, 3, 4, 5, 6, 7, 8]);
        let pkt = Packet::new(MessageType::Message, sender, b"hello mesh".to_vec())
            .with_timestamp(1_700_000_000_000);
        let bytes = pkt.encode(false).unwrap();
        let decoded = Packet::decode(&bytes).unwrap();
        assert_eq!(decoded.payload, b"hello mesh");
        assert_eq!(decoded.packet_type, MessageType::Message as u8);
        assert_eq!(decoded.sender_id, sender);
        assert_eq!(decoded.version, 1);
        assert_eq!(decoded.timestamp, 1_700_000_000_000);
    }

    #[test]
    fn roundtrip_v2_with_route() {
        let sender = PeerId::from_bytes([9; 8]);
        let recipient = PeerId::from_bytes([8; 8]);
        let hop = PeerId::from_bytes([7; 8]);
        let pkt = Packet::new(MessageType::NoiseEncrypted, sender, vec![0xAA; 32])
            .with_version(2)
            .with_recipient(recipient)
            .with_route(vec![hop])
            .with_timestamp(42);
        let bytes = pkt.encode(true).unwrap();
        let decoded = Packet::decode(&bytes).unwrap();
        assert_eq!(decoded.version, 2);
        assert_eq!(decoded.route.len(), 1);
        assert_eq!(decoded.recipient_id, Some(recipient));
        assert_eq!(decoded.payload, vec![0xAA; 32]);
    }

    #[test]
    fn signing_bytes_zero_ttl() {
        let sender = PeerId::from_bytes([1; 8]);
        let pkt = Packet::new(MessageType::Announce, sender, vec![1, 2, 3])
            .with_ttl(7)
            .with_timestamp(99);
        let a = pkt.signing_bytes().unwrap();
        let mut clone = pkt.clone();
        clone.ttl = 3;
        let b = clone.signing_bytes().unwrap();
        assert_eq!(a, b);
        // BitChat signs padded frames (default encode padding=true).
        assert!(a.len() >= 256, "signing payload should be PKCS#7 padded");
    }

    #[test]
    fn signed_message_verifies_after_padded_signing() {
        let sender = PeerId::from_bytes([2; 8]);
        let pkt = Packet::new(MessageType::Message, sender, b"hi".to_vec())
            .with_ttl(7)
            .with_timestamp(1_700_000_000_000);
        let signing = pkt.signing_bytes().unwrap();
        let mut unsigned = pkt.clone();
        unsigned.signature = None;
        unsigned.ttl = 0;
        unsigned.is_rsr = false;
        let expected = unsigned.encode(true).unwrap();
        assert_eq!(signing, expected);
    }

    #[test]
    fn peer_id_hex_roundtrip() {
        let id = PeerId::from_bytes([0xab, 0xcd, 0xef, 0x01, 0x23, 0x45, 0x67, 0x89]);
        assert_eq!(id.to_hex(), "abcdef0123456789");
        assert_eq!(PeerId::from_hex("abcdef0123456789").unwrap(), id);
    }

    #[test]
    fn file_transfer_compress_sign_roundtrip_like_bitchat() {
        // Highly compressible TLV body (WAV-like) so zlib engages — this is the
        // case that broke Offline↔BitChat verify when FileTransfer skipped compress.
        let sender = PeerId::from_bytes([0x11; 8]);
        let mut content = b"RIFF".to_vec();
        content.extend_from_slice(&[0, 0, 0, 0]);
        content.extend_from_slice(b"WAVE");
        content.extend(std::iter::repeat_n(0u8, 2_000));
        let tlv = encode_file_transfer(&FileTransferPayload::new(
            "voice.wav",
            "audio/wav",
            content.clone(),
        ))
        .unwrap();
        let mut pkt = Packet::new(MessageType::FileTransfer, sender, tlv)
            .with_timestamp(99)
            .with_version(2)
            .with_ttl(7);
        // Fake signature bytes — we only check encode/decode + compress flag consistency.
        let signing = pkt.signing_bytes().unwrap();
        // signing_bytes must match a padded encode of the same packet (BitChat default).
        let mut unsigned = pkt.clone();
        unsigned.signature = None;
        unsigned.ttl = 0;
        unsigned.is_rsr = false;
        assert_eq!(signing, unsigned.encode(true).unwrap());

        pkt = pkt.with_signature([0x42; 64]);
        let wire = pkt.encode(false).unwrap();
        let decoded = Packet::decode(&wire).unwrap();
        assert_eq!(decoded.packet_type, MessageType::FileTransfer as u8);
        let file = decode_file_transfer(&decoded.payload).unwrap();
        assert_eq!(file.content, content);
        // Re-verify signing bytes after decode (payload decompressed in memory).
        assert_eq!(decoded.signing_bytes().unwrap(), signing);
    }
}
