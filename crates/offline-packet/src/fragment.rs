//! BitChat-compatible fragmentation (type 0x20).
//!
//! Fragment payload: fragID(8) + index u16 BE + total u16 BE + originalType(1) + data.
//! Split when unpadded encoded packet length > 512; chunk data size ≤ 469
//! (`TransportConfig.bleDefaultFragmentSize`).
//!
//! Fragment **packets** use version 1 when there is no source route (BitChat
//! `BLEOutboundFragmentPlanner`); the reassembled inner packet keeps its own
//! version (file transfers are v2).

use crate::{MessageType, Packet, PacketError, PeerId};
use rand::RngCore;

pub const FRAGMENT_HEADER_SIZE: usize = 13;
pub const FRAGMENT_ID_SIZE: usize = 8;
pub const FRAGMENT_SIZE_THRESHOLD: usize = 512;
/// BitChat `TransportConfig.bleDefaultFragmentSize` — fits ~512 ATT MTU.
/// Stay under 469 so directed fragments (extra 8-byte recipient) remain
/// strictly below Chrome Web Bluetooth's 512-byte `writeValue` hard cap.
pub const MAX_FRAGMENT_CHUNK: usize = 440;
/// BitChat planner floor when sizing against a negotiated MTU.
pub const MIN_FRAGMENT_CHUNK: usize = 64;
/// BitChat `BLEOutboundFragmentPlanner.privateMediaV1MaxFragments` — Android
/// receivers reject longer trains. Keep mesh photos/voice under this.
pub const BITCHAT_COMPAT_MAX_FRAGMENTS: usize = 256;
/// Wire `total` is `u16`; allow full range so 1 MiB file transfers can fragment
/// for Offline↔Offline. Callers targeting BitChat should stay ≤
/// [`BITCHAT_COMPAT_MAX_FRAGMENTS`].
pub const MAX_FRAGMENTS_PER_PACKET: usize = u16::MAX as usize;
/// Soft cap on `total` accepted during reassembly (S-7). Above this, refuse the set
/// unless the caller raised [`FragmentReassembler::max_fragments_per_set`].
pub const DEFAULT_MAX_REASSEMBLY_FRAGMENTS: u16 = BITCHAT_COMPAT_MAX_FRAGMENTS as u16;
/// Global byte budget across all incomplete fragment sets (S-7).
pub const DEFAULT_MAX_REASSEMBLY_BYTES: usize = 2 * 1024 * 1024;
/// BitChat uses 30 s; we keep a longer window so slow links can still finish
/// receiving BitChat media after partial loss/retry.
pub const FRAGMENT_ASSEMBLY_TIMEOUT_SECS: u64 = 120;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FragmentPayload {
    pub fragment_id: [u8; FRAGMENT_ID_SIZE],
    pub index: u16,
    pub total: u16,
    pub original_type: u8,
    pub data: Vec<u8>,
}

impl FragmentPayload {
    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::with_capacity(FRAGMENT_HEADER_SIZE + self.data.len());
        out.extend_from_slice(&self.fragment_id);
        out.extend_from_slice(&self.index.to_be_bytes());
        out.extend_from_slice(&self.total.to_be_bytes());
        out.push(self.original_type);
        out.extend_from_slice(&self.data);
        out
    }

    pub fn decode(bytes: &[u8]) -> Option<Self> {
        if bytes.len() < FRAGMENT_HEADER_SIZE {
            return None;
        }
        let mut fragment_id = [0u8; FRAGMENT_ID_SIZE];
        fragment_id.copy_from_slice(&bytes[..FRAGMENT_ID_SIZE]);
        let index = u16::from_be_bytes([bytes[8], bytes[9]]);
        let total = u16::from_be_bytes([bytes[10], bytes[11]]);
        let original_type = bytes[12];
        if total == 0 || index >= total {
            return None;
        }
        Some(Self {
            fragment_id,
            index,
            total,
            original_type,
            data: bytes[FRAGMENT_HEADER_SIZE..].to_vec(),
        })
    }
}

/// If `encoded` fits under the threshold, returns a single frame. Otherwise splits
/// the *original packet's payload path* by re-encoding fragment packets that carry
/// chunks of `encoded` (BitChat splits the already-encoded unpadded packet bytes).
pub fn maybe_fragment(encoded_unpadded: &[u8], template: &Packet) -> Result<Vec<Vec<u8>>, PacketError> {
    maybe_fragment_sized(encoded_unpadded, template, MAX_FRAGMENT_CHUNK)
}

/// Same as [`maybe_fragment`] with an explicit chunk size (clamped to BitChat min/max).
pub fn maybe_fragment_sized(
    encoded_unpadded: &[u8],
    template: &Packet,
    chunk_size: usize,
) -> Result<Vec<Vec<u8>>, PacketError> {
    if encoded_unpadded.len() <= FRAGMENT_SIZE_THRESHOLD {
        let pad = MessageType::from_u8(template.packet_type)
            .map(|t| t.should_pad())
            .unwrap_or(false);
        return Ok(vec![template.encode(pad)?]);
    }

    let chunk = chunk_size.clamp(MIN_FRAGMENT_CHUNK, MAX_FRAGMENT_CHUNK);
    let mut frag_id = [0u8; FRAGMENT_ID_SIZE];
    rand::thread_rng().fill_bytes(&mut frag_id);

    let chunks: Vec<&[u8]> = encoded_unpadded.chunks(chunk).collect();
    let total = chunks.len();
    if total == 0 || total > MAX_FRAGMENTS_PER_PACKET {
        return Err(PacketError::InvalidLength);
    }
    let total_u16 = total as u16;

    // BitChat: fragment wrappers are v1 unless the original carries a source route.
    let fragment_version: u8 = if template.route.is_empty() { 1 } else { 2 };

    let mut out = Vec::with_capacity(chunks.len());
    for (i, part) in chunks.into_iter().enumerate() {
        let payload = FragmentPayload {
            fragment_id: frag_id,
            index: i as u16,
            total: total_u16,
            original_type: template.packet_type,
            data: part.to_vec(),
        };
        let mut frag = Packet::new(MessageType::Fragment, template.sender_id, payload.encode())
            .with_timestamp(template.timestamp)
            .with_ttl(template.ttl)
            .with_version(fragment_version);
        if let Some(r) = template.recipient_id {
            frag = frag.with_recipient(r);
        }
        if !template.route.is_empty() {
            frag = frag.with_route(template.route.clone());
        }
        // Fragments are unsigned; the reassembled original carries the signature.
        out.push(frag.encode(false)?);
    }
    Ok(out)
}

/// Reassembles fragment packets into the original encoded packet bytes.
pub struct FragmentReassembler {
    sets: std::collections::HashMap<[u8; FRAGMENT_ID_SIZE], FragmentSet>,
    max_sets: usize,
    max_fragments_per_set: u16,
    max_buffered_bytes: usize,
    buffered_bytes: usize,
}

struct FragmentSet {
    total: u16,
    original_type: u8,
    parts: std::collections::HashMap<u16, Vec<u8>>,
    buffered_bytes: usize,
    created: web_time::Instant,
    #[allow(dead_code)]
    sender: PeerId,
    #[allow(dead_code)]
    recipient: Option<PeerId>,
    #[allow(dead_code)]
    ttl: u8,
    #[allow(dead_code)]
    version: u8,
    #[allow(dead_code)]
    timestamp: u64,
}

impl Default for FragmentReassembler {
    fn default() -> Self {
        Self::new(64)
    }
}

impl FragmentReassembler {
    pub fn new(max_sets: usize) -> Self {
        Self {
            sets: std::collections::HashMap::new(),
            max_sets,
            max_fragments_per_set: DEFAULT_MAX_REASSEMBLY_FRAGMENTS,
            max_buffered_bytes: DEFAULT_MAX_REASSEMBLY_BYTES,
            buffered_bytes: 0,
        }
    }

    /// Raise the per-set fragment cap (Offline↔Offline large file trains).
    pub fn with_max_fragments_per_set(mut self, max: u16) -> Self {
        self.max_fragments_per_set = max.max(1);
        self
    }

    /// Raise the global incomplete-buffer budget (default 2 MiB).
    pub fn with_max_buffered_bytes(mut self, max: usize) -> Self {
        self.max_buffered_bytes = max.max(MAX_FRAGMENT_CHUNK);
        self
    }

    /// Feed a decoded fragment packet. Returns reassembled original wire bytes when complete.
    pub fn ingest(&mut self, packet: &Packet) -> Option<Vec<u8>> {
        if packet.packet_type != MessageType::Fragment as u8 {
            return None;
        }
        let fp = FragmentPayload::decode(&packet.payload)?;
        // Nested fragment wrappers (original_type == Fragment) enable unbounded
        // re-entry recursion in mesh ingest — reject them (S-3).
        if fp.original_type == MessageType::Fragment as u8 {
            return None;
        }
        if fp.total == 0 || fp.total > self.max_fragments_per_set {
            return None;
        }
        self.purge_expired();

        let is_new = !self.sets.contains_key(&fp.fragment_id);
        if is_new {
            while self.sets.len() >= self.max_sets {
                self.evict_oldest()?;
            }
        }

        let entry = self.sets.entry(fp.fragment_id).or_insert_with(|| FragmentSet {
            total: fp.total,
            original_type: fp.original_type,
            parts: std::collections::HashMap::new(),
            buffered_bytes: 0,
            created: web_time::Instant::now(),
            sender: packet.sender_id,
            recipient: packet.recipient_id,
            ttl: packet.ttl,
            version: packet.version,
            timestamp: packet.timestamp,
        });

        if entry.total != fp.total || entry.original_type != fp.original_type {
            return None;
        }
        let part_len = fp.data.len();
        if let Some(old) = entry.parts.insert(fp.index, fp.data) {
            entry.buffered_bytes = entry.buffered_bytes.saturating_sub(old.len());
            self.buffered_bytes = self.buffered_bytes.saturating_sub(old.len());
        }
        entry.buffered_bytes = entry.buffered_bytes.saturating_add(part_len);
        self.buffered_bytes = self.buffered_bytes.saturating_add(part_len);

        while self.buffered_bytes > self.max_buffered_bytes {
            // Prefer evicting a set that is not the one we just updated.
            let victim = self
                .sets
                .iter()
                .filter(|(id, _)| **id != fp.fragment_id)
                .min_by_key(|(_, s)| s.created)
                .map(|(k, _)| *k)
                .or_else(|| {
                    self.sets
                        .iter()
                        .min_by_key(|(_, s)| s.created)
                        .map(|(k, _)| *k)
                })?;
            if !self.remove_set(&victim) {
                break;
            }
            if victim == fp.fragment_id {
                return None;
            }
        }

        let entry = self.sets.get(&fp.fragment_id)?;
        if entry.parts.len() != entry.total as usize {
            return None;
        }

        let mut assembled = Vec::new();
        for i in 0..entry.total {
            assembled.extend_from_slice(entry.parts.get(&i)?);
        }
        let id = fp.fragment_id;
        self.remove_set(&id);
        Some(assembled)
    }

    fn remove_set(&mut self, id: &[u8; FRAGMENT_ID_SIZE]) -> bool {
        if let Some(set) = self.sets.remove(id) {
            self.buffered_bytes = self.buffered_bytes.saturating_sub(set.buffered_bytes);
            true
        } else {
            false
        }
    }

    fn evict_oldest(&mut self) -> Option<()> {
        let oldest = self
            .sets
            .iter()
            .min_by_key(|(_, s)| s.created)
            .map(|(k, _)| *k)?;
        self.remove_set(&oldest);
        Some(())
    }

    fn purge_expired(&mut self) {
        let timeout = std::time::Duration::from_secs(FRAGMENT_ASSEMBLY_TIMEOUT_SECS);
        let expired: Vec<_> = self
            .sets
            .iter()
            .filter(|(_, s)| s.created.elapsed() >= timeout)
            .map(|(k, _)| *k)
            .collect();
        for id in expired {
            self.remove_set(&id);
        }
        while self.sets.len() > self.max_sets {
            if self.evict_oldest().is_none() {
                break;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{Packet, SENDER_ID_SIZE};

    #[test]
    fn directed_fragment_wire_size_at_max_chunk() {
        let sender = PeerId::from_bytes([1; SENDER_ID_SIZE]);
        let recipient = PeerId::from_bytes([2; SENDER_ID_SIZE]);
        let big: Vec<u8> = (0..8000).map(|i| (i % 251) as u8).collect();
        let pkt = Packet::new(MessageType::FileTransfer, sender, big)
            .with_timestamp(1)
            .with_ttl(7)
            .with_version(2)
            .with_recipient(recipient)
            .with_signature([9u8; 64]);
        let encoded = pkt.encode(false).unwrap();
        assert!(encoded.len() > FRAGMENT_SIZE_THRESHOLD);
        let frames = maybe_fragment(&encoded, &pkt).unwrap();
        let max = frames.iter().map(|f| f.len()).max().unwrap();
        let min = frames.iter().map(|f| f.len()).min().unwrap();
        eprintln!("directed fragment frames={} min={} max={}", frames.len(), min, max);
        assert!(
            max <= 512,
            "Web Bluetooth rejects writes >512; got max={max}"
        );
    }

    #[test]
    fn fragment_roundtrip_payload() {
        let fp = FragmentPayload {
            fragment_id: [1, 2, 3, 4, 5, 6, 7, 8],
            index: 2,
            total: 5,
            original_type: MessageType::Message as u8,
            data: vec![9, 8, 7],
        };
        let enc = fp.encode();
        assert_eq!(FragmentPayload::decode(&enc).unwrap(), fp);
    }

    #[test]
    fn split_and_reassemble_large_packet() {
        let sender = PeerId::from_bytes([9; SENDER_ID_SIZE]);
        let big: Vec<u8> = (0..3000).map(|i| (i % 251) as u8).collect();
        let pkt = Packet::new(MessageType::Message, sender, big.clone()).with_timestamp(1);
        let encoded = pkt.encode(false).unwrap();
        assert!(
            encoded.len() > FRAGMENT_SIZE_THRESHOLD,
            "encoded len {}",
            encoded.len()
        );

        let frames = maybe_fragment(&encoded, &pkt).unwrap();
        assert!(frames.len() > 1);

        let mut re = FragmentReassembler::new(8);
        let mut done = None;
        for frame in &frames {
            let p = Packet::decode(frame).unwrap();
            if let Some(raw) = re.ingest(&p) {
                done = Some(raw);
            }
        }
        let reassembled = done.expect("should reassemble");
        let decoded = Packet::decode(&reassembled).unwrap();
        assert_eq!(decoded.payload, big);
    }

    #[test]
    fn file_sized_payload_fragments_beyond_legacy_256_cap() {
        let sender = PeerId::from_bytes([3; SENDER_ID_SIZE]);
        // True-ish entropy so zlib will not shrink under the fragment threshold.
        // (LCG patterns look random to unique-byte heuristics but compress well.)
        let mut big = vec![0u8; 200_000];
        let mut state: u64 = 0xC0FFEE;
        for b in &mut big {
            state = state
                .wrapping_mul(0x9E3779B97F4A7C15)
                .wrapping_add(0xD1B54A32D192ED03);
            *b = (state >> 56) as u8;
            // Mix in a rotating counter to defeat zlib dictionary patterns.
            *b ^= (state as u8).wrapping_mul(31);
        }
        // Force incompressible: XOR with position-dependent noise that zlib hates.
        for (i, b) in big.iter_mut().enumerate() {
            *b ^= ((i * 2654435761) >> 24) as u8;
            *b = b.wrapping_add((i >> 8) as u8);
        }
        let pkt = Packet::new(MessageType::FileTransfer, sender, big.clone())
            .with_timestamp(42)
            .with_version(2)
            .with_signature([7u8; 64]);
        let encoded = pkt.encode(false).unwrap();
        assert!(
            encoded.len() > FRAGMENT_SIZE_THRESHOLD,
            "encoded should stay large, got {}",
            encoded.len()
        );
        let frames = maybe_fragment(&encoded, &pkt).unwrap();
        assert!(
            frames.len() > 256,
            "expected >256 fragments, got {} (encoded {})",
            frames.len(),
            encoded.len()
        );

        let mut re = FragmentReassembler::new(8).with_max_fragments_per_set(u16::MAX);
        let mut done = None;
        for frame in &frames {
            let p = Packet::decode(frame).unwrap();
            // BitChat wraps file fragments as v1 even when the inner file packet is v2.
            assert_eq!(p.version, 1, "fragment wrapper must be v1 without route");
            assert!(p.signature.is_none());
            if let Some(raw) = re.ingest(&p) {
                done = Some(raw);
            }
        }
        let reassembled = done.expect("should reassemble file-sized packet");
        let decoded = Packet::decode(&reassembled).unwrap();
        assert_eq!(decoded.payload, big);
        assert_eq!(decoded.packet_type, MessageType::FileTransfer as u8);
        assert_eq!(decoded.version, 2);
    }

    #[test]
    fn bitchat_file_tlv_fragments_like_official_app() {
        use crate::decode_file_transfer;
        use crate::encode_file_transfer;
        use crate::FileTransferPayload;

        let sender = PeerId::from_bytes([0xCA; SENDER_ID_SIZE]);
        // Minimal JPEG SOI + incompressible body so the signed packet fragments.
        let mut jpeg = vec![0xFF, 0xD8, 0xFF, 0xE0];
        for i in 0..40_000 {
            let x = (i as u32)
                .wrapping_mul(0x9E3779B9)
                .wrapping_add(i as u32);
            jpeg.push(((x >> 16) ^ (x >> 8) ^ x ^ (i as u32)) as u8);
        }
        let tlv = encode_file_transfer(&FileTransferPayload::new(
            "photo.jpg",
            "image/jpeg",
            jpeg.clone(),
        ))
        .unwrap();
        let pkt = Packet::new(MessageType::FileTransfer, sender, tlv)
            .with_timestamp(1_700_000_000_000)
            .with_version(2)
            .with_signature([0xAB; 64]);
        let encoded = pkt.encode(false).unwrap();
        let frames = maybe_fragment(&encoded, &pkt).unwrap();
        assert!(
            frames.len() > 1,
            "expected fragmentation, encoded {}",
            encoded.len()
        );

        let mut re = FragmentReassembler::new(8);
        let mut done = None;
        for frame in &frames {
            let p = Packet::decode(frame).unwrap();
            assert_eq!(p.packet_type, MessageType::Fragment as u8);
            assert_eq!(p.version, 1);
            if let Some(raw) = re.ingest(&p) {
                done = Some(raw);
            }
        }
        let decoded = Packet::decode(&done.unwrap()).unwrap();
        assert_eq!(decoded.packet_type, MessageType::FileTransfer as u8);
        let file = decode_file_transfer(&decoded.payload).unwrap();
        assert_eq!(file.mime_type.as_deref(), Some("image/jpeg"));
        assert_eq!(file.file_name.as_deref(), Some("photo.jpg"));
        assert_eq!(file.content, jpeg);
    }
}

