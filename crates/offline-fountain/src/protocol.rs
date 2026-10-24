//! Optical frame header: 20-byte little-endian layout from decimen.

pub const HEADER_LEN: usize = 20;
pub const MAGIC0: u8 = 0xD1;
pub const MAGIC1: u8 = 0x0C;
/// Hard ceiling for optical payloads (matches mesh file limit).
pub const MAX_OPTICAL_BYTES: usize = 1 * 1024 * 1024;
/// Max source blocks `k` accepted from a QR header.
pub const MAX_OPTICAL_K: u16 = 8192;
/// Max block length accepted from a QR header (bytes).
pub const MAX_OPTICAL_BLOCK_LEN: u16 = 2048;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct FrameHeader {
    pub session_id: u16,
    pub seq: u32,
    pub k: u16,
    pub block_len: u16,
    pub total_len: u32,
    pub payload_fnv: u32,
}

pub fn pack_frame(h: &FrameHeader, block: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(HEADER_LEN + block.len());
    out.push(MAGIC0);
    out.push(MAGIC1);
    out.extend_from_slice(&h.session_id.to_le_bytes());
    out.extend_from_slice(&h.seq.to_le_bytes());
    out.extend_from_slice(&h.k.to_le_bytes());
    out.extend_from_slice(&h.block_len.to_le_bytes());
    out.extend_from_slice(&h.total_len.to_le_bytes());
    out.extend_from_slice(&h.payload_fnv.to_le_bytes());
    out.extend_from_slice(block);
    out
}

pub fn parse_frame(bytes: &[u8]) -> Option<(FrameHeader, &[u8])> {
    if bytes.len() <= HEADER_LEN {
        return None;
    }
    if bytes[0] != MAGIC0 || bytes[1] != MAGIC1 {
        return None;
    }
    let session_id = u16::from_le_bytes([bytes[2], bytes[3]]);
    let seq = u32::from_le_bytes(bytes[4..8].try_into().ok()?);
    let k = u16::from_le_bytes([bytes[8], bytes[9]]);
    let block_len = u16::from_le_bytes([bytes[10], bytes[11]]);
    let total_len = u32::from_le_bytes(bytes[12..16].try_into().ok()?);
    let payload_fnv = u32::from_le_bytes(bytes[16..20].try_into().ok()?);
    if k == 0 || block_len == 0 || total_len == 0 {
        return None;
    }
    // Reject hostile allocation sizes before the decoder allocates (S-5).
    if k > MAX_OPTICAL_K
        || block_len > MAX_OPTICAL_BLOCK_LEN
        || total_len as usize > MAX_OPTICAL_BYTES
        || (total_len as u64) > (k as u64) * (block_len as u64)
    {
        return None;
    }
    if bytes.len() != HEADER_LEN + block_len as usize {
        return None;
    }
    Some((
        FrameHeader {
            session_id,
            seq,
            k,
            block_len,
            total_len,
            payload_fnv,
        },
        &bytes[HEADER_LEN..],
    ))
}

pub fn fnv1a(bytes: &[u8]) -> u32 {
    let mut h: u32 = 0x811c_9dc5;
    for &b in bytes {
        h ^= u32::from(b);
        h = h.wrapping_mul(0x0100_0193);
    }
    h
}

/// splitmix32 — integer-only, deterministic across engines.
pub fn splitmix32(seed: u32) -> impl FnMut() -> u32 {
    let mut s = seed as i32;
    move || {
        s = s.wrapping_add(0x9e37_79b9_u32 as i32);
        let mut t = (s as u32) ^ ((s as u32) >> 16);
        t = t.wrapping_mul(0x21f0_aaad);
        t ^= t >> 15;
        t = t.wrapping_mul(0x735a_2d97);
        t ^= t >> 15;
        t
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rejects_oversized_total_len() {
        let h = FrameHeader {
            session_id: 1,
            seq: 0,
            k: 1,
            block_len: 4,
            total_len: (MAX_OPTICAL_BYTES as u32) + 1,
            payload_fnv: 0,
        };
        let packed = pack_frame(&h, &[1, 2, 3, 4]);
        assert!(parse_frame(&packed).is_none());
    }

    #[test]
    fn frame_roundtrip() {
        let h = FrameHeader {
            session_id: 0xABCD,
            seq: 42,
            k: 10,
            block_len: 4,
            total_len: 40,
            payload_fnv: 0x1234_5678,
        };
        let packed = pack_frame(&h, &[1, 2, 3, 4]);
        let (parsed, block) = parse_frame(&packed).unwrap();
        assert_eq!(parsed, h);
        assert_eq!(block, &[1, 2, 3, 4]);
    }
}
