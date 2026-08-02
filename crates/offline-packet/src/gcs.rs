//! Golomb-Coded Set filter for BitChat REQUEST_SYNC (port of `GCSFilter.swift`).

use sha2::{Digest, Sha256};

pub const MAX_P: i32 = 32;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GcsParams {
    pub p: i32,
    pub m: u32,
    pub data: Vec<u8>,
    pub included_count: usize,
}

pub fn derive_p(target_fpr: f64) -> i32 {
    let f = target_fpr.clamp(0.000_001, 0.25);
    let p = (1.0 / f).log2().ceil() as i32;
    p.max(1)
}

pub fn estimate_max_elements(size_bytes: usize, p: i32) -> usize {
    let bits = size_bytes.saturating_mul(8).max(8);
    let per = (p + 2).max(3) as usize;
    (bits / per).max(1)
}

/// Build a GCS over 16-byte packet IDs (newest-first preferred by caller).
pub fn build_filter(ids: &[[u8; 16]], max_bytes: usize, target_fpr: f64) -> GcsParams {
    let p = derive_p(target_fpr);
    if ids.is_empty() {
        return GcsParams {
            p,
            m: 1,
            data: Vec::new(),
            included_count: 0,
        };
    }

    let cap = estimate_max_elements(max_bytes, p);
    let range = hash_range(ids.len().min(cap), p).max(1);
    let modulo = u64::from(range);

    let encode_first = |count: usize| -> Vec<u8> {
        let mut mapped: Vec<u64> = ids
            .iter()
            .take(count)
            .map(|id| map_hash(h64(id), modulo))
            .collect();
        mapped.sort_unstable();
        mapped = normalize_mapped(mapped, modulo);
        if mapped.is_empty() {
            Vec::new()
        } else {
            encode_golomb(&mapped, p)
        }
    };

    let mut count = ids.len().min(cap);
    let mut encoded = encode_first(count);
    while encoded.len() > max_bytes && count > 1 {
        count = (count * 9 / 10).max(1);
        encoded = encode_first(count);
    }
    if encoded.len() > max_bytes {
        return GcsParams {
            p,
            m: range,
            data: Vec::new(),
            included_count: 0,
        };
    }

    GcsParams {
        p,
        m: range,
        data: encoded.clone(),
        included_count: if encoded.is_empty() { 0 } else { count },
    }
}

pub fn decode_to_sorted_set(p: i32, m: u32, data: &[u8]) -> Vec<u64> {
    if !(1..=MAX_P).contains(&p) || m <= 1 {
        return Vec::new();
    }
    let mut values = Vec::new();
    let mut reader = BitReader::new(data);
    let mut acc: u64 = 0;
    loop {
        let Some(q) = reader.read_unary() else { break };
        let Some(r) = reader.read_bits(p as usize) else {
            break;
        };
        let x = ((q as u64) << p as u64) + r + 1;
        acc = acc.wrapping_add(x);
        if acc >= u64::from(m) {
            break;
        }
        values.push(acc);
    }
    values
}

pub fn contains(sorted: &[u64], candidate: u64) -> bool {
    sorted.binary_search(&candidate).is_ok()
}

pub fn bucket(id: &[u8; 16], m: u32) -> u64 {
    let modulo = u64::from(m.max(1));
    if modulo <= 1 {
        return 0;
    }
    map_hash(h64(id), modulo)
}

fn h64(id16: &[u8; 16]) -> u64 {
    let digest = Sha256::digest(id16);
    let mut x: u64 = 0;
    for &b in digest.iter().take(8) {
        x = (x << 8) | u64::from(b);
    }
    x & 0x7fff_ffff_ffff_ffff
}

fn hash_range(count: usize, p: i32) -> u32 {
    if count == 0 {
        return 1;
    }
    if p >= 64 {
        return u32::MAX;
    }
    let multiplier = 1u64 << p as u64;
    match (count as u64).checked_mul(multiplier) {
        None => u32::MAX,
        Some(0) => 1,
        Some(product) if product > u64::from(u32::MAX) => u32::MAX,
        Some(product) => product as u32,
    }
}

fn map_hash(hash: u64, modulo: u64) -> u64 {
    if modulo <= 1 {
        return 0;
    }
    let value = hash % modulo;
    if value == 0 {
        1
    } else {
        value
    }
}

fn normalize_mapped(values: Vec<u64>, modulo: u64) -> Vec<u64> {
    if modulo <= 1 || values.is_empty() {
        return Vec::new();
    }
    let mut result = Vec::with_capacity(values.len());
    let mut last = 0u64;
    for value in values {
        let normalized = value.min(modulo - 1);
        if normalized > last {
            result.push(normalized);
            last = normalized;
        }
    }
    result
}

fn encode_golomb(sorted: &[u64], p: i32) -> Vec<u8> {
    let mut writer = BitWriter::default();
    let mut prev = 0u64;
    let mask: u64 = if p >= 64 {
        !0
    } else {
        (1u64 << p as u64) - 1
    };
    for &v in sorted {
        let delta = v.wrapping_sub(prev);
        prev = v;
        let x = delta;
        let q = (x.wrapping_sub(1)) >> p as u64;
        let r = (x.wrapping_sub(1)) & mask;
        if q > 0 {
            writer.write_ones(q as usize);
        }
        writer.write_bit(0);
        writer.write_bits(r, p as usize);
    }
    writer.finish()
}

#[derive(Default)]
struct BitWriter {
    buf: Vec<u8>,
    cur: u8,
    nbits: i32,
}

impl BitWriter {
    fn write_bit(&mut self, bit: i32) {
        self.cur = ((u16::from(self.cur) << 1) | (bit as u16 & 1)) as u8;
        self.nbits += 1;
        if self.nbits == 8 {
            self.buf.push(self.cur);
            self.cur = 0;
            self.nbits = 0;
        }
    }

    fn write_ones(&mut self, count: usize) {
        for _ in 0..count {
            self.write_bit(1);
        }
    }

    fn write_bits(&mut self, value: u64, count: usize) {
        if count == 0 {
            return;
        }
        for i in (0..count).rev() {
            let bit = ((value >> i) & 1) as i32;
            self.write_bit(bit);
        }
    }

    fn finish(mut self) -> Vec<u8> {
        if self.nbits > 0 {
            let rem = (u16::from(self.cur) << (8 - self.nbits)) as u8;
            self.buf.push(rem);
        }
        self.buf
    }
}

struct BitReader<'a> {
    data: &'a [u8],
    idx: usize,
    cur: u8,
    left: i32,
}

impl<'a> BitReader<'a> {
    fn new(data: &'a [u8]) -> Self {
        let (cur, left) = if data.is_empty() {
            (0, 0)
        } else {
            (data[0], 8)
        };
        Self {
            data,
            idx: 0,
            cur,
            left,
        }
    }

    fn read_bit(&mut self) -> Option<i32> {
        if self.idx >= self.data.len() {
            return None;
        }
        let bit = (i32::from(self.cur) >> 7) & 1;
        self.cur = ((u16::from(self.cur) << 1) & 0xFF) as u8;
        self.left -= 1;
        if self.left == 0 {
            self.idx += 1;
            if self.idx < self.data.len() {
                self.cur = self.data[self.idx];
                self.left = 8;
            }
        }
        Some(bit)
    }

    fn read_unary(&mut self) -> Option<i32> {
        let mut q = 0;
        loop {
            let b = self.read_bit()?;
            if b == 1 {
                q += 1;
            } else {
                break;
            }
        }
        Some(q)
    }

    fn read_bits(&mut self, count: usize) -> Option<u64> {
        let mut v = 0u64;
        for _ in 0..count {
            let b = self.read_bit()? as u64;
            v = (v << 1) | b;
        }
        Some(v)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_filter_roundtrip() {
        let params = build_filter(&[], 400, 0.01);
        assert_eq!(params.m, 1);
        assert!(params.data.is_empty());
        let set = decode_to_sorted_set(params.p, params.m, &params.data);
        assert!(set.is_empty());
    }

    #[test]
    fn membership_roundtrip() {
        let ids = [[1u8; 16], [2u8; 16], [3u8; 16], [9u8; 16]];
        let params = build_filter(&ids, 400, 0.01);
        assert!(params.included_count > 0);
        let set = decode_to_sorted_set(params.p, params.m, &params.data);
        for id in &ids[..params.included_count] {
            let b = bucket(id, params.m);
            assert!(contains(&set, b), "missing bucket for id");
        }
    }
}
