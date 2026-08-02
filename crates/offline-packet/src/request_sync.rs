//! BitChat `RequestSyncPacket` TLV (type 0x21 payload).

use crate::gcs::{build_filter, estimate_max_elements, derive_p, GcsParams};

/// Sync type bitfield (BitChat `SyncTypeFlags`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SyncTypeFlags(pub u64);

impl SyncTypeFlags {
    pub const ANNOUNCE: u64 = 1 << 0;
    pub const MESSAGE: u64 = 1 << 1;
    pub const FRAGMENT: u64 = 1 << 5;
    pub const FILE_TRANSFER: u64 = 1 << 7;

    pub fn public_messages() -> Self {
        Self(Self::ANNOUNCE | Self::MESSAGE)
    }

    pub fn fragment_only() -> Self {
        Self(Self::FRAGMENT)
    }

    pub fn file_transfer_only() -> Self {
        Self(Self::FILE_TRANSFER)
    }

    /// Initial join catch-up: publics + files (not raw fragments — those flood BLE).
    pub fn join_catchup() -> Self {
        Self(Self::ANNOUNCE | Self::MESSAGE | Self::FILE_TRANSFER)
    }

    pub fn contains_announce(self) -> bool {
        self.0 & Self::ANNOUNCE != 0
    }

    pub fn contains_message(self) -> bool {
        self.0 & Self::MESSAGE != 0
    }

    pub fn contains_fragment(self) -> bool {
        self.0 & Self::FRAGMENT != 0
    }

    pub fn contains_file_transfer(self) -> bool {
        self.0 & Self::FILE_TRANSFER != 0
    }

    pub fn to_bytes(self) -> Vec<u8> {
        let mut v = self.0;
        if v == 0 {
            return Vec::new();
        }
        let mut bytes = Vec::new();
        while v > 0 {
            bytes.push((v & 0xff) as u8);
            v >>= 8;
        }
        bytes
    }

    pub fn from_bytes(data: &[u8]) -> Self {
        let mut raw = 0u64;
        for (i, &b) in data.iter().take(8).enumerate() {
            raw |= u64::from(b) << (8 * i);
        }
        // Known bits only (announce..groupMessage).
        const KNOWN: u64 = (1 << 11) - 1;
        Self(raw & KNOWN)
    }
}

/// Newest-first candidate for GCS membership (BitChat `buildGcsPayload`).
#[derive(Debug, Clone, Copy)]
pub struct SyncCandidate {
    pub id: [u8; 16],
    pub timestamp: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RequestSyncPayload {
    pub p: i32,
    pub m: u32,
    pub data: Vec<u8>,
    pub types: Option<SyncTypeFlags>,
    pub since_timestamp: Option<u64>,
    /// TLV 0x06 — comma-separated 16-hex fragment stream IDs.
    pub fragment_id_filter: Option<String>,
}

impl RequestSyncPayload {
    pub fn from_gcs(
        params: GcsParams,
        types: SyncTypeFlags,
        since: Option<u64>,
        fragment_id_filter: Option<String>,
    ) -> Self {
        Self {
            p: params.p,
            m: params.m,
            data: params.data,
            types: Some(types),
            since_timestamp: since,
            fragment_id_filter,
        }
    }
}

pub fn encode_request_sync(packet: &RequestSyncPayload) -> Vec<u8> {
    let mut out = Vec::new();
    put_tlv(&mut out, 0x01, &[packet.p as u8]);
    put_tlv(&mut out, 0x02, &packet.m.to_be_bytes());
    put_tlv(&mut out, 0x03, &packet.data);
    if let Some(types) = packet.types {
        let b = types.to_bytes();
        if !b.is_empty() {
            put_tlv(&mut out, 0x04, &b);
        }
    }
    if let Some(ts) = packet.since_timestamp {
        put_tlv(&mut out, 0x05, &ts.to_be_bytes());
    }
    if let Some(ref fid) = packet.fragment_id_filter {
        put_tlv(&mut out, 0x06, fid.as_bytes());
    }
    out
}

pub fn decode_request_sync(data: &[u8]) -> Option<RequestSyncPayload> {
    let mut offset = 0;
    let mut p: Option<i32> = None;
    let mut m: Option<u32> = None;
    let mut payload: Option<Vec<u8>> = None;
    let mut types: Option<SyncTypeFlags> = None;
    let mut since: Option<u64> = None;
    let mut fragment_id_filter: Option<String> = None;

    while offset + 3 <= data.len() {
        let tag = data[offset];
        offset += 1;
        let len = u16::from_be_bytes([data[offset], data[offset + 1]]) as usize;
        offset += 2;
        if offset + len > data.len() {
            return None;
        }
        let value = &data[offset..offset + len];
        offset += len;
        match tag {
            0x01 if value.len() == 1 => p = Some(i32::from(value[0])),
            0x02 if value.len() == 4 => {
                m = Some(u32::from_be_bytes([value[0], value[1], value[2], value[3]]));
            }
            0x03 => {
                if value.len() > 1024 {
                    return None;
                }
                payload = Some(value.to_vec());
            }
            0x04 => types = Some(SyncTypeFlags::from_bytes(value)),
            0x05 if value.len() == 8 => {
                let mut ts = 0u64;
                for &b in value {
                    ts = (ts << 8) | u64::from(b);
                }
                since = Some(ts);
            }
            0x06 if value.len() <= 1024 => {
                if let Ok(s) = std::str::from_utf8(value) {
                    fragment_id_filter = Some(s.to_string());
                }
            }
            _ => {}
        }
    }

    let pp = p?;
    let mm = m?;
    let dd = payload?;
    if !(1..=crate::gcs::MAX_P).contains(&pp) || mm == 0 {
        return None;
    }
    Some(RequestSyncPayload {
        p: pp,
        m: mm,
        data: dd,
        types,
        since_timestamp: since,
        fragment_id_filter,
    })
}

/// Encode fragment stream IDs for TLV 0x06 (BitChat `encodeFragmentIdFilter`).
pub fn encode_fragment_id_filter(fragment_ids: &[[u8; 8]]) -> Option<String> {
    const MAX: usize = 60;
    let tokens: Vec<String> = fragment_ids
        .iter()
        .take(MAX)
        .map(|id| {
            id.iter()
                .map(|b| format!("{b:02x}"))
                .collect::<String>()
        })
        .collect();
    if tokens.is_empty() {
        None
    } else {
        Some(tokens.join(","))
    }
}

/// Decode TLV 0x06 into 8-byte fragment stream IDs.
pub fn decode_fragment_id_filter(filter: Option<&str>) -> Option<Vec<[u8; 8]>> {
    let filter = filter?;
    const MAX: usize = 60;
    let mut out = Vec::new();
    for token in filter.split(',').take(MAX) {
        if token.len() != 16 {
            continue;
        }
        let mut id = [0u8; 8];
        let mut ok = true;
        for i in 0..8 {
            let Some(byte) = u8::from_str_radix(&token[i * 2..i * 2 + 2], 16).ok() else {
                ok = false;
                break;
            };
            id[i] = byte;
        }
        if ok {
            out.push(id);
        }
    }
    if out.is_empty() {
        None
    } else {
        Some(out)
    }
}

/// Build a REQUEST_SYNC payload (BitChat `buildGcsPayload` since-cursor semantics).
///
/// `candidates` must be newest-first. `max_cap` is the store capacity for this type round
/// (e.g. seenCapacity / fragmentCapacity / fileTransferCapacity).
pub fn build_request_sync_payload(
    candidates: &[SyncCandidate],
    types: SyncTypeFlags,
    max_cap: usize,
    fragment_id_filter: Option<String>,
) -> RequestSyncPayload {
    const GCS_MAX_BYTES: usize = 400;
    const TARGET_FPR: f64 = 0.01;

    if candidates.is_empty() {
        let p = derive_p(TARGET_FPR);
        return RequestSyncPayload {
            p,
            m: 1,
            data: Vec::new(),
            types: Some(types),
            since_timestamp: None,
            fragment_id_filter,
        };
    }

    let p = derive_p(TARGET_FPR);
    let n_max = estimate_max_elements(GCS_MAX_BYTES, p);
    let take_n = candidates.len().min(n_max).min(max_cap.max(1));
    if take_n == 0 {
        return RequestSyncPayload {
            p,
            m: 1,
            data: Vec::new(),
            types: Some(types),
            since_timestamp: None,
            fragment_id_filter,
        };
    }

    let included = &candidates[..take_n];
    let ids: Vec<[u8; 16]> = included.iter().map(|c| c.id).collect();
    let params = build_filter(&ids, GCS_MAX_BYTES, TARGET_FPR);
    let covered = params.included_count;
    // Coverage cursor: only when the filter does not cover the full candidate set.
    let since = if covered < candidates.len() && covered > 0 {
        Some(included[covered - 1].timestamp)
    } else {
        None
    };

    RequestSyncPayload::from_gcs(params, types, since, fragment_id_filter)
}

fn put_tlv(out: &mut Vec<u8>, tag: u8, value: &[u8]) {
    out.push(tag);
    let len = value.len() as u16;
    out.extend_from_slice(&len.to_be_bytes());
    out.extend_from_slice(value);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn roundtrip_empty_gcs() {
        let payload = build_request_sync_payload(&[], SyncTypeFlags::public_messages(), 1000, None);
        let enc = encode_request_sync(&payload);
        let dec = decode_request_sync(&enc).unwrap();
        assert_eq!(dec.p, payload.p);
        assert_eq!(dec.m, payload.m);
        assert!(dec.types.unwrap().contains_message());
        assert!(dec.since_timestamp.is_none());
    }

    #[test]
    fn since_only_when_truncated() {
        let mut cands = Vec::new();
        for i in 0..50u64 {
            let mut id = [0u8; 16];
            id[0] = i as u8;
            id[1] = (i >> 8) as u8;
            // Newest first: higher timestamp first.
            cands.push(SyncCandidate {
                id,
                timestamp: 10_000 - i,
            });
        }
        // Tiny cap forces truncation → since cursor set.
        let payload = build_request_sync_payload(&cands, SyncTypeFlags::public_messages(), 3, None);
        assert!(payload.since_timestamp.is_some());
        assert_eq!(payload.since_timestamp, Some(cands[2].timestamp));
    }

    #[test]
    fn no_since_when_fully_covered() {
        let cands = [SyncCandidate {
            id: [1u8; 16],
            timestamp: 42,
        }];
        let payload = build_request_sync_payload(&cands, SyncTypeFlags::public_messages(), 1000, None);
        assert!(payload.since_timestamp.is_none());
    }

    #[test]
    fn fragment_filter_roundtrip() {
        let ids = [[0xabu8; 8], [0xcd; 8]];
        let enc = encode_fragment_id_filter(&ids).unwrap();
        let dec = decode_fragment_id_filter(Some(&enc)).unwrap();
        assert_eq!(dec, ids);
    }
}
