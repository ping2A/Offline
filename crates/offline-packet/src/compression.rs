//! Compression helpers matching BitChat `CompressionUtil`.
//!
//! BitChat iOS uses Apple `COMPRESSION_ZLIB`, which emits **raw DEFLATE**
//! (RFC 1951) — not the zlib wrapper (RFC 1950). Android BitChat documents the
//! same and uses `Deflater(nowrap=true)`. Offline previously used flate2's
//! zlib wrapper, which caused `Packet::decode` / ingest failures on BitChat
//! voice notes and any other compressible `fileTransfer`.

use flate2::read::{DeflateDecoder, DeflateEncoder, ZlibDecoder};
use flate2::Compression;
use std::io::Read;

use crate::PacketError;

/// BitChat `Constants.compressionThresholdBytes`.
const COMPRESSION_THRESHOLD: usize = 100;

/// BitChat `CompressionUtil.shouldCompress`: unique bytes over the **entire**
/// buffer, ratio = unique / min(len, 256).
pub fn should_compress(data: &[u8]) -> bool {
    if data.len() < COMPRESSION_THRESHOLD {
        return false;
    }
    let mut seen = [false; 256];
    let mut unique = 0usize;
    for &b in data {
        if !seen[b as usize] {
            seen[b as usize] = true;
            unique += 1;
            let sample_size = data.len().min(256);
            if unique as f64 / sample_size as f64 >= 0.9 {
                return false;
            }
        }
    }
    let sample_size = data.len().min(256);
    let ratio = unique as f64 / sample_size as f64;
    ratio < 0.9
}

/// Compress with raw DEFLATE (BitChat / Apple `COMPRESSION_ZLIB` wire format).
pub fn compress_zlib(data: &[u8]) -> Option<Vec<u8>> {
    if data.len() < COMPRESSION_THRESHOLD {
        return None;
    }
    let mut encoder = DeflateEncoder::new(data, Compression::default());
    let mut out = Vec::new();
    encoder.read_to_end(&mut out).ok()?;
    if out.is_empty() || out.len() >= data.len() {
        return None;
    }
    Some(out)
}

/// Decompress BitChat payload bytes. Prefer zlib-wrapper when the header looks
/// like RFC 1950 (legacy Offline / accidental wrappers), otherwise raw DEFLATE.
/// Always require an exact `original_size` match like BitChat Android.
pub fn decompress_zlib(data: &[u8], original_size: usize) -> Result<Vec<u8>, PacketError> {
    if data.is_empty() || original_size == 0 {
        return Err(PacketError::Compression);
    }
    if looks_like_zlib(data) {
        if let Ok(out) = inflate_exact(ZlibDecoder::new(data), original_size) {
            return Ok(out);
        }
        // Header can coincidentally look like zlib; fall back to raw.
        return inflate_exact(DeflateDecoder::new(data), original_size);
    }
    inflate_exact(DeflateDecoder::new(data), original_size)
}

fn inflate_exact<R: Read>(decoder: R, original_size: usize) -> Result<Vec<u8>, PacketError> {
    // Cap reads at claimed size + 1 so a lying `original_size` cannot amplify into
    // gigabytes before the length check (SECURITY_IMPROVEMENTS S-2).
    let mut out = Vec::with_capacity(original_size);
    let mut limited = decoder.take(original_size as u64 + 1);
    limited
        .read_to_end(&mut out)
        .map_err(|_| PacketError::Compression)?;
    if out.len() != original_size {
        return Err(PacketError::Compression);
    }
    Ok(out)
}

/// RFC 1950 CMF/FLG check (same heuristic as BitChat Android `looksLikeZlib`).
fn looks_like_zlib(data: &[u8]) -> bool {
    if data.len() < 2 {
        return false;
    }
    let cmf = data[0] as u16;
    let flg = data[1] as u16;
    (cmf & 0x0f) == 8 && (cmf >> 4) <= 7 && ((cmf << 8) | flg) % 31 == 0
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bitchat_unique_over_full_buffer() {
        let mut data = vec![0u8; 1000];
        for i in 0..256 {
            data[256 + i] = i as u8;
        }
        assert!(!should_compress(&data));
    }

    #[test]
    fn compressible_repeated_payload_raw_deflate() {
        let data = vec![7u8; 500];
        assert!(should_compress(&data));
        let c = compress_zlib(&data).unwrap();
        // Raw DEFLATE must NOT start with zlib CMF/FLG 0x78xx.
        assert!(c[0] != 0x78, "expected raw DEFLATE, got zlib wrapper");
        let out = decompress_zlib(&c, data.len()).unwrap();
        assert_eq!(out, data);
    }

    #[test]
    fn decompress_accepts_legacy_zlib_wrapper() {
        use flate2::write::ZlibEncoder as ZlibEnc;
        use std::io::Write;
        let data = vec![9u8; 400];
        let mut enc = ZlibEnc::new(Vec::new(), Compression::default());
        enc.write_all(&data).unwrap();
        let wrapped = enc.finish().unwrap();
        assert!(looks_like_zlib(&wrapped));
        let out = decompress_zlib(&wrapped, data.len()).unwrap();
        assert_eq!(out, data);
    }

    #[test]
    fn decompress_apple_style_raw_deflate() {
        let data = vec![0x41u8; 5000];
        let c = compress_zlib(&data).unwrap();
        assert!(!looks_like_zlib(&c), "BitChat wire uses raw DEFLATE, not zlib");
        assert_eq!(decompress_zlib(&c, data.len()).unwrap(), data);
    }

    #[test]
    fn decompress_rejects_size_mismatch_without_full_inflate() {
        let data = vec![7u8; 500];
        let c = compress_zlib(&data).unwrap();
        // Claim a tiny original size while the stream expands further — must fail
        // without buffering the whole inflated stream beyond the claim.
        assert!(decompress_zlib(&c, 8).is_err());
    }
}
