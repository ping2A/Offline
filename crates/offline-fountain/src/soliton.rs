//! Robust-soliton LT encoder/decoder with deterministic log.

use crate::protocol::splitmix32;
use std::collections::{HashMap, HashSet};

const LN2: f64 = 0.6931471805599453;
const SOLITON_C: f64 = 0.1;
const SOLITON_DELTA: f64 = 0.5;

/// Deterministic natural log: exact-ops range reduction + atanh series.
fn dlog(x: f64) -> f64 {
    let mut e = 0i32;
    let mut m = x;
    while m >= 1.5 {
        m /= 2.0;
        e += 1;
    }
    while m < 0.75 {
        m *= 2.0;
        e -= 1;
    }
    let z = (m - 1.0) / (m + 1.0);
    let z2 = z * z;
    let mut term = z;
    let mut sum = 0.0;
    let mut n = 1i32;
    while n <= 21 {
        sum += term / f64::from(n);
        term *= z2;
        n += 2;
    }
    f64::from(e) * LN2 + 2.0 * sum
}

fn soliton_cdf(k: usize) -> Vec<f64> {
    let mut cdf = vec![0.0; k];
    if k == 1 {
        cdf[0] = 1.0;
        return cdf;
    }
    let r = (SOLITON_C * dlog(k as f64 / SOLITON_DELTA) * (k as f64).sqrt()).max(1.0);
    let spike = k.min((k as f64 / r).ceil() as usize);
    let mut total = 0.0;
    for d in 1..=k {
        let rho = if d == 1 {
            1.0 / k as f64
        } else {
            1.0 / (d * (d - 1)) as f64
        };
        let tau = if d < spike {
            r / (d as f64 * k as f64)
        } else if d == spike {
            (r * dlog(r / SOLITON_DELTA).max(0.0)) / k as f64
        } else {
            0.0
        };
        total += rho + tau;
        cdf[d - 1] = total;
    }
    for i in 0..k {
        cdf[i] /= total;
    }
    cdf[k - 1] = 1.0;
    cdf
}

fn frame_seed(session_id: u16, seq: u32) -> u32 {
    let mut h = ((session_id as u32).wrapping_add(1).wrapping_mul(0x9e37_79b1))
        ^ (seq.wrapping_add(0x85eb_ca6b));
    h = (h ^ (h >> 13)).wrapping_mul(0xc2b2_ae35);
    h ^ (h >> 16)
}

fn frame_indices(k: usize, cdf: &[f64], session_id: u16, seq: u32) -> Vec<usize> {
    let mut rnd = splitmix32(frame_seed(session_id, seq));
    let u = (rnd() as f64) * 2f64.powi(-32);
    let mut lo = 0usize;
    let mut hi = k - 1;
    while lo < hi {
        let mid = (lo + hi) >> 1;
        if cdf[mid] >= u {
            hi = mid;
        } else {
            lo = mid + 1;
        }
    }
    let d = k.min(lo + 1);
    if d > k >> 3 {
        let mut scratch: Vec<usize> = (0..k).collect();
        let mut out = Vec::with_capacity(d);
        for i in 0..d {
            let j = i + (rnd() as usize % (k - i));
            scratch.swap(i, j);
            out.push(scratch[i]);
        }
        return out;
    }
    let mut set = HashSet::with_capacity(d);
    while set.len() < d {
        set.insert(rnd() as usize % k);
    }
    set.into_iter().collect()
}

fn xor_into(dst: &mut [u32], src: &[u32]) {
    for (d, s) in dst.iter_mut().zip(src.iter()) {
        *d ^= *s;
    }
}

pub struct LTEncoder {
    pub k: usize,
    pub block_len: usize,
    pub session_id: u16,
    words: usize,
    blocks: Vec<u32>,
    cdf: Vec<f64>,
}

impl LTEncoder {
    pub fn new(payload: &[u8], block_len: usize, session_id: u16) -> Self {
        let k = 1.max(payload.len().div_ceil(block_len));
        let words = block_len.div_ceil(4);
        let mut blocks = vec![0u32; k * words];
        {
            let bytes = unsafe {
                std::slice::from_raw_parts_mut(blocks.as_mut_ptr() as *mut u8, blocks.len() * 4)
            };
            for b in 0..k {
                let start = b * block_len;
                let end = (start + block_len).min(payload.len());
                if start < payload.len() {
                    let dst_off = b * words * 4;
                    bytes[dst_off..dst_off + (end - start)]
                        .copy_from_slice(&payload[start..end]);
                }
            }
        }
        let cdf = soliton_cdf(k);
        Self {
            k,
            block_len,
            session_id,
            words,
            blocks,
            cdf,
        }
    }

    pub fn encode(&self, seq: u32) -> Vec<u8> {
        let idx = frame_indices(self.k, &self.cdf, self.session_id, seq);
        let mut out = vec![0u32; self.words];
        for &b in &idx {
            let off = b * self.words;
            xor_into(&mut out, &self.blocks[off..off + self.words]);
        }
        let bytes = unsafe {
            std::slice::from_raw_parts(out.as_ptr() as *const u8, self.words * 4)
        };
        bytes[..self.block_len].to_vec()
    }
}

struct PendingFrame {
    idx: HashSet<usize>,
    words: Vec<u32>,
}

pub struct LTDecoder {
    pub k: usize,
    pub block_len: usize,
    pub session_id: u16,
    pub total_len: usize,
    words: usize,
    cdf: Vec<f64>,
    solved: Vec<Option<Vec<u32>>>,
    by_block: HashMap<usize, Vec<usize>>,
    pending: Vec<Option<PendingFrame>>,
    seen: HashSet<u32>,
    pub solved_count: usize,
    pub frames_new: usize,
    pub frames_dup: usize,
}

impl LTDecoder {
    pub fn new(k: usize, block_len: usize, session_id: u16, total_len: usize) -> Self {
        let words = block_len.div_ceil(4);
        Self {
            k,
            block_len,
            session_id,
            total_len,
            words,
            cdf: soliton_cdf(k),
            solved: vec![None; k],
            by_block: HashMap::new(),
            pending: Vec::new(),
            seen: HashSet::new(),
            solved_count: 0,
            frames_new: 0,
            frames_dup: 0,
        }
    }

    pub fn is_complete(&self) -> bool {
        self.solved_count >= self.k
    }

    pub fn add_frame(&mut self, seq: u32, block: &[u8]) {
        if self.seen.contains(&seq) {
            self.frames_dup += 1;
            return;
        }
        self.seen.insert(seq);
        self.frames_new += 1;
        if self.is_complete() {
            return;
        }

        let mut idx: HashSet<usize> =
            frame_indices(self.k, &self.cdf, self.session_id, seq).into_iter().collect();
        let mut words = vec![0u32; self.words];
        {
            let bytes = unsafe {
                std::slice::from_raw_parts_mut(words.as_mut_ptr() as *mut u8, self.words * 4)
            };
            let n = block.len().min(self.block_len);
            bytes[..n].copy_from_slice(&block[..n]);
        }

        for b in idx.clone() {
            if let Some(s) = &self.solved[b] {
                xor_into(&mut words, s);
                idx.remove(&b);
            }
        }
        if idx.is_empty() {
            return;
        }
        if idx.len() == 1 {
            let b0 = *idx.iter().next().unwrap();
            self.resolve(b0, words);
            return;
        }

        let pf_idx = self.pending.len();
        for &b in &idx {
            self.by_block.entry(b).or_default().push(pf_idx);
        }
        self.pending.push(Some(PendingFrame { idx, words }));
    }

    fn resolve(&mut self, b0: usize, w0: Vec<u32>) {
        let mut queue = vec![(b0, w0)];
        while let Some((b, w)) = queue.pop() {
            if self.solved[b].is_some() {
                continue;
            }
            self.solved[b] = Some(w.clone());
            self.solved_count += 1;
            let waiting = match self.by_block.remove(&b) {
                Some(w) => w,
                None => continue,
            };
            for pf_idx in waiting {
                let Some(pf) = self.pending[pf_idx].as_mut() else {
                    continue;
                };
                xor_into(&mut pf.words, &w);
                pf.idx.remove(&b);
                if pf.idx.len() == 1 {
                    let r = *pf.idx.iter().next().unwrap();
                    if let Some(set) = self.by_block.get_mut(&r) {
                        set.retain(|&i| i != pf_idx);
                    }
                    if self.solved[r].is_none() {
                        let words = pf.words.clone();
                        queue.push((r, words));
                    }
                }
            }
        }
    }

    pub fn assemble(&self) -> Option<Vec<u8>> {
        if !self.is_complete() {
            return None;
        }
        let mut out = vec![0u8; self.total_len];
        for b in 0..self.k {
            let start = b * self.block_len;
            let len = self.block_len.min(self.total_len.saturating_sub(start));
            if len == 0 {
                continue;
            }
            let words = self.solved[b].as_ref()?;
            let bytes =
                unsafe { std::slice::from_raw_parts(words.as_ptr() as *const u8, self.words * 4) };
            out[start..start + len].copy_from_slice(&bytes[..len]);
        }
        Some(out)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::{fnv1a, pack_frame, parse_frame, FrameHeader};

    #[test]
    fn fountain_recovers_payload() {
        let payload = (0u8..200).cycle().take(4096).collect::<Vec<_>>();
        let block_len = 200usize;
        let session_id = 0x42u16;
        let enc = LTEncoder::new(&payload, block_len, session_id);
        let mut dec = LTDecoder::new(enc.k, block_len, session_id, payload.len());

        let mut seq = 0u32;
        while !dec.is_complete() && seq < 10_000 {
            let block = enc.encode(seq);
            dec.add_frame(seq, &block);
            seq += 1;
            // Simulate 30% loss
            if seq % 3 == 0 {
                seq += 1;
            }
        }
        assert!(dec.is_complete(), "frames_new={}", dec.frames_new);
        let out = dec.assemble().unwrap();
        assert_eq!(out, payload);
    }

    #[test]
    fn framed_transfer() {
        let payload = b"optical transfer works".to_vec();
        let block_len = 16usize;
        let session_id = 7u16;
        let enc = LTEncoder::new(&payload, block_len, session_id);
        let hash = fnv1a(&payload);
        let mut dec: Option<LTDecoder> = None;
        for seq in 0..500u32 {
            let block = enc.encode(seq);
            let frame = pack_frame(
                &FrameHeader {
                    session_id,
                    seq,
                    k: enc.k as u16,
                    block_len: block_len as u16,
                    total_len: payload.len() as u32,
                    payload_fnv: hash,
                },
                &block,
            );
            let (h, blk) = parse_frame(&frame).unwrap();
            let d = dec.get_or_insert_with(|| {
                LTDecoder::new(h.k as usize, h.block_len as usize, h.session_id, h.total_len as usize)
            });
            d.add_frame(h.seq, blk);
            if d.is_complete() {
                let out = d.assemble().unwrap();
                assert_eq!(fnv1a(&out), hash);
                assert_eq!(out, payload);
                return;
            }
        }
        panic!("did not complete");
    }
}
