//! BitChat AnnouncementPacket TLV (1-byte type, 1-byte length).

use crate::types::PeerId;

/// TLV tags matching BitChat `AnnouncementPacket`.
pub mod announce_tlv {
    pub const NICKNAME: u8 = 0x01;
    pub const NOISE_PUBLIC_KEY: u8 = 0x02;
    pub const SIGNING_PUBLIC_KEY: u8 = 0x03;
    pub const DIRECT_NEIGHBORS: u8 = 0x04;
    pub const CAPABILITIES: u8 = 0x05;
    pub const BRIDGE_GEOHASH: u8 = 0x06;
}

/// Decoded announce fields (BitChat TLV or Offline v1 plain nickname).
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct AnnouncePayload {
    pub nickname: String,
    pub noise_public_key: Option<[u8; 32]>,
    pub signing_public_key: Option<[u8; 32]>,
    pub direct_neighbors: Vec<PeerId>,
    /// True when payload used BitChat TLV encoding.
    pub is_tlv: bool,
}

/// Encode BitChat-compatible announce TLV.
pub fn encode_announce_tlv(
    nickname: &str,
    noise_public_key: &[u8; 32],
    signing_public_key: &[u8; 32],
    direct_neighbors: &[PeerId],
) -> Vec<u8> {
    let nick = nickname.as_bytes();
    let nick_len = nick.len().min(255);
    let mut out = Vec::with_capacity(2 + nick_len + 2 + 32 + 2 + 32 + 2 + 80);
    out.push(announce_tlv::NICKNAME);
    out.push(nick_len as u8);
    out.extend_from_slice(&nick[..nick_len]);

    out.push(announce_tlv::NOISE_PUBLIC_KEY);
    out.push(32);
    out.extend_from_slice(noise_public_key);

    out.push(announce_tlv::SIGNING_PUBLIC_KEY);
    out.push(32);
    out.extend_from_slice(signing_public_key);

    let neighbor_bytes: Vec<u8> = direct_neighbors
        .iter()
        .take(10)
        .flat_map(|p| p.as_bytes().iter().copied())
        .collect();
    if !neighbor_bytes.is_empty() && neighbor_bytes.len() % 8 == 0 && neighbor_bytes.len() <= 255 {
        out.push(announce_tlv::DIRECT_NEIGHBORS);
        out.push(neighbor_bytes.len() as u8);
        out.extend_from_slice(&neighbor_bytes);
    }
    out
}

/// Parse announce payload: BitChat TLV when possible, else Offline v1 UTF-8 nickname.
pub fn parse_announce_payload(payload: &[u8]) -> AnnouncePayload {
    if let Some(parsed) = try_decode_announce_tlv(payload) {
        if parsed.is_tlv {
            return parsed;
        }
    }
    AnnouncePayload {
        nickname: String::from_utf8_lossy(payload).to_string(),
        noise_public_key: None,
        signing_public_key: None,
        direct_neighbors: Vec::new(),
        is_tlv: false,
    }
}

fn try_decode_announce_tlv(data: &[u8]) -> Option<AnnouncePayload> {
    if data.is_empty() {
        return None;
    }
    let mut offset = 0;
    let mut nickname: Option<String> = None;
    let mut noise_public_key: Option<[u8; 32]> = None;
    let mut signing_public_key: Option<[u8; 32]> = None;
    let mut direct_neighbors = Vec::new();
    let mut saw_known = false;

    while offset + 2 <= data.len() {
        let tag = data[offset];
        let len = data[offset + 1] as usize;
        offset += 2;
        if offset + len > data.len() {
            return None;
        }
        let value = &data[offset..offset + len];
        offset += len;

        match tag {
            announce_tlv::NICKNAME => {
                saw_known = true;
                nickname = Some(String::from_utf8_lossy(value).to_string());
            }
            announce_tlv::NOISE_PUBLIC_KEY if value.len() == 32 => {
                saw_known = true;
                let mut k = [0u8; 32];
                k.copy_from_slice(value);
                noise_public_key = Some(k);
            }
            announce_tlv::SIGNING_PUBLIC_KEY if value.len() == 32 => {
                saw_known = true;
                let mut k = [0u8; 32];
                k.copy_from_slice(value);
                signing_public_key = Some(k);
            }
            announce_tlv::DIRECT_NEIGHBORS if !value.is_empty() && value.len() % 8 == 0 => {
                saw_known = true;
                for chunk in value.chunks_exact(8) {
                    let mut id = [0u8; 8];
                    id.copy_from_slice(chunk);
                    direct_neighbors.push(PeerId::from_bytes(id));
                }
            }
            announce_tlv::CAPABILITIES | announce_tlv::BRIDGE_GEOHASH => {
                saw_known = true;
            }
            _ => {}
        }
    }

    if !saw_known {
        return None;
    }
    if nickname.is_none() && noise_public_key.is_none() && signing_public_key.is_none() {
        return None;
    }

    Some(AnnouncePayload {
        nickname: nickname.unwrap_or_default(),
        noise_public_key,
        signing_public_key,
        direct_neighbors,
        is_tlv: true,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn roundtrip_tlv() {
        let nick = "alice";
        let noise = [1u8; 32];
        let signing = [2u8; 32];
        let neighbors = [PeerId::from_bytes([9; 8])];
        let bytes = encode_announce_tlv(nick, &noise, &signing, &neighbors);
        let parsed = parse_announce_payload(&bytes);
        assert!(parsed.is_tlv);
        assert_eq!(parsed.nickname, nick);
        assert_eq!(parsed.noise_public_key, Some(noise));
        assert_eq!(parsed.signing_public_key, Some(signing));
        assert_eq!(parsed.direct_neighbors.len(), 1);
    }

    #[test]
    fn legacy_utf8_nickname() {
        let parsed = parse_announce_payload(b"bob");
        assert!(!parsed.is_tlv);
        assert_eq!(parsed.nickname, "bob");
        assert!(parsed.noise_public_key.is_none());
    }
}
