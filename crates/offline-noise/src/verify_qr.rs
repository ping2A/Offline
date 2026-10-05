//! BitChat identity verification QR (`bitchat://verify?…`).
//!
//! Matches `VerificationService.VerificationQR` in BitChat iOS/Android:
//! signed URL with Noise + Ed25519 pubs, nick, timestamp, nonce.

use crate::identity::{Identity, IdentityError};
use rand::RngCore;

const CONTEXT: &str = "bitchat-verify-v1";
const VERSION: u8 = 1;

/// Parsed / buildable BitChat verification QR payload.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct VerificationQr {
    pub version: u8,
    pub noise_key_hex: String,
    pub sign_key_hex: String,
    pub npub: Option<String>,
    pub nickname: String,
    pub ts: i64,
    pub nonce_b64: String,
    pub sig_hex: String,
}

impl VerificationQr {
    /// Canonical bytes signed by the device Ed25519 key (BitChat `canonicalBytes()`).
    pub fn canonical_bytes(&self) -> Vec<u8> {
        let mut out = Vec::with_capacity(256);
        append_field(&mut out, CONTEXT);
        append_field(&mut out, &self.version.to_string());
        append_field(&mut out, &self.noise_key_hex.to_lowercase());
        append_field(&mut out, &self.sign_key_hex.to_lowercase());
        append_field(&mut out, self.npub.as_deref().unwrap_or(""));
        append_field(&mut out, &self.nickname);
        append_field(&mut out, &self.ts.to_string());
        append_field(&mut out, &self.nonce_b64);
        out
    }

    /// `bitchat://verify?v=…&noise=…&sign=…&nick=…&ts=…&nonce=…&sig=…` (+ optional `npub`).
    pub fn to_url_string(&self) -> String {
        let mut url = format!(
            "bitchat://verify?v={}&noise={}&sign={}&nick={}&ts={}&nonce={}&sig={}",
            self.version,
            self.noise_key_hex,
            self.sign_key_hex,
            percent_encode_query(&self.nickname),
            self.ts,
            self.nonce_b64,
            self.sig_hex,
        );
        if let Some(npub) = &self.npub {
            url.push_str("&npub=");
            url.push_str(&percent_encode_query(npub));
        }
        url
    }

    /// Parse a BitChat verify URL (percent-decoded query values).
    pub fn from_url(url: &str) -> Option<Self> {
        let rest = url.strip_prefix("bitchat://verify?")?;
        let mut v = None::<u8>;
        let mut noise = None::<String>;
        let mut sign = None::<String>;
        let mut nick = None::<String>;
        let mut ts = None::<i64>;
        let mut nonce = None::<String>;
        let mut sig = None::<String>;
        let mut npub = None::<String>;
        for part in rest.split('&') {
            let (k, raw) = part.split_once('=')?;
            let val = percent_decode(raw);
            match k {
                "v" => v = val.parse().ok(),
                "noise" => noise = Some(val),
                "sign" => sign = Some(val),
                "nick" => nick = Some(val),
                "ts" => ts = val.parse().ok(),
                "nonce" => nonce = Some(val),
                "sig" => sig = Some(val),
                "npub" => npub = Some(val),
                _ => {}
            }
        }
        Some(Self {
            version: v?,
            noise_key_hex: noise?,
            sign_key_hex: sign?,
            npub,
            nickname: nick?,
            ts: ts?,
            nonce_b64: nonce?,
            sig_hex: sig?,
        })
    }

    /// Check Ed25519 signature over canonical bytes using the embedded `sign` key.
    pub fn verify_signature(&self) -> Result<(), IdentityError> {
        let pk = parse_hex32(&self.sign_key_hex)?;
        let sig = parse_hex64(&self.sig_hex)?;
        Identity::verify(&pk, &self.canonical_bytes(), &sig)
    }

    /// Freshness: reject if older than `max_age_secs` (BitChat default is 300).
    pub fn is_fresh(&self, now_unix: i64, max_age_secs: i64) -> bool {
        now_unix.saturating_sub(self.ts) <= max_age_secs && self.ts <= now_unix + 60
    }
}

/// Build a signed BitChat verification QR URL for `identity`.
pub fn build_verify_qr(
    identity: &Identity,
    nickname: &str,
    npub: Option<&str>,
    now_unix: i64,
) -> VerificationQr {
    let mut nonce = [0u8; 16];
    rand::thread_rng().fill_bytes(&mut nonce);
    build_verify_qr_with_nonce(identity, nickname, npub, now_unix, nonce)
}

/// Deterministic builder (tests).
pub fn build_verify_qr_with_nonce(
    identity: &Identity,
    nickname: &str,
    npub: Option<&str>,
    now_unix: i64,
    nonce: [u8; 16],
) -> VerificationQr {
    let nick = truncate_utf8(nickname.trim(), 32);
    let mut draft = VerificationQr {
        version: VERSION,
        noise_key_hex: hex::encode(identity.noise_public_key()),
        sign_key_hex: hex::encode(identity.signing_public_key()),
        npub: npub.map(|s| s.to_string()).filter(|s| !s.is_empty()),
        nickname: nick,
        ts: now_unix,
        nonce_b64: base64_url_nopad(&nonce),
        sig_hex: String::new(),
    };
    let sig = identity.sign(&draft.canonical_bytes());
    draft.sig_hex = hex::encode(sig);
    draft
}

fn append_field(out: &mut Vec<u8>, s: &str) {
    let bytes = s.as_bytes();
    let n = bytes.len().min(255);
    out.push(n as u8);
    out.extend_from_slice(&bytes[..n]);
}

fn truncate_utf8(s: &str, max_chars: usize) -> String {
    s.chars().take(max_chars).collect()
}

fn parse_hex32(s: &str) -> Result<[u8; 32], IdentityError> {
    let v = hex::decode(s.trim()).map_err(|_| IdentityError::InvalidKeyLength)?;
    v.as_slice()
        .try_into()
        .map_err(|_| IdentityError::InvalidKeyLength)
}

fn parse_hex64(s: &str) -> Result<[u8; 64], IdentityError> {
    let v = hex::decode(s.trim()).map_err(|_| IdentityError::InvalidKeyLength)?;
    v.as_slice()
        .try_into()
        .map_err(|_| IdentityError::InvalidKeyLength)
}

/// Base64 URL-safe, no padding (BitChat nonce encoding).
fn base64_url_nopad(data: &[u8]) -> String {
    const T: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    let mut out = String::with_capacity((data.len() + 2) / 3 * 4);
    let mut i = 0;
    while i + 3 <= data.len() {
        let n = ((data[i] as u32) << 16) | ((data[i + 1] as u32) << 8) | data[i + 2] as u32;
        out.push(T[((n >> 18) & 63) as usize] as char);
        out.push(T[((n >> 12) & 63) as usize] as char);
        out.push(T[((n >> 6) & 63) as usize] as char);
        out.push(T[(n & 63) as usize] as char);
        i += 3;
    }
    let rem = data.len() - i;
    if rem == 1 {
        let n = (data[i] as u32) << 16;
        out.push(T[((n >> 18) & 63) as usize] as char);
        out.push(T[((n >> 12) & 63) as usize] as char);
    } else if rem == 2 {
        let n = ((data[i] as u32) << 16) | ((data[i + 1] as u32) << 8);
        out.push(T[((n >> 18) & 63) as usize] as char);
        out.push(T[((n >> 12) & 63) as usize] as char);
        out.push(T[((n >> 6) & 63) as usize] as char);
    }
    out
}

fn percent_encode_query(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for b in s.bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(b as char);
            }
            _ => out.push_str(&format!("%{b:02X}")),
        }
    }
    out
}

fn percent_decode(s: &str) -> String {
    let bytes = s.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            if let (Ok(h), Ok(l)) = (
                u8::from_str_radix(std::str::from_utf8(&bytes[i + 1..i + 2]).unwrap_or(""), 16),
                u8::from_str_radix(std::str::from_utf8(&bytes[i + 2..i + 3]).unwrap_or(""), 16),
            ) {
                out.push((h << 4) | l);
                i += 3;
                continue;
            }
        }
        if bytes[i] == b'+' {
            out.push(b' ');
        } else {
            out.push(bytes[i]);
        }
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

/// Build verifyChallenge TLV body (Noise payload type already separate).
pub fn build_verify_challenge_tlv(noise_key_hex: &str, nonce_a: &[u8]) -> Vec<u8> {
    let nk = noise_key_hex.as_bytes();
    let n_len = nk.len().min(255);
    let nonce_len = nonce_a.len().min(255);
    let mut tlv = Vec::with_capacity(2 + n_len + 2 + nonce_len);
    tlv.push(0x01);
    tlv.push(n_len as u8);
    tlv.extend_from_slice(&nk[..n_len]);
    tlv.push(0x02);
    tlv.push(nonce_len as u8);
    tlv.extend_from_slice(&nonce_a[..nonce_len]);
    tlv
}

/// Parse verifyResponse TLV → (noise_key_hex, nonce_a, signature).
pub fn parse_verify_response(tlv: &[u8]) -> Option<(String, Vec<u8>, [u8; 64])> {
    let mut i = 0;
    let t1 = *tlv.get(i)?;
    i += 1;
    if t1 != 0x01 {
        return None;
    }
    let l1 = *tlv.get(i)? as usize;
    i += 1;
    let noise = std::str::from_utf8(tlv.get(i..i + l1)?).ok()?.to_string();
    i += l1;

    let t2 = *tlv.get(i)?;
    i += 1;
    if t2 != 0x02 {
        return None;
    }
    let l2 = *tlv.get(i)? as usize;
    i += 1;
    let nonce = tlv.get(i..i + l2)?.to_vec();
    i += l2;

    let t3 = *tlv.get(i)?;
    i += 1;
    if t3 != 0x03 {
        return None;
    }
    let l3 = *tlv.get(i)? as usize;
    i += 1;
    if l3 != 64 {
        return None;
    }
    let mut sig = [0u8; 64];
    sig.copy_from_slice(tlv.get(i..i + 64)?);
    Some((noise, nonce, sig))
}

const RESPONSE_CONTEXT: &[u8] = b"bitchat-verify-resp-v1";

/// Parse BitChat verifyChallenge TLV (Noise payload body, type byte already stripped).
pub fn parse_verify_challenge(tlv: &[u8]) -> Option<(String, Vec<u8>)> {
    let mut i = 0;
    let t1 = *tlv.get(i)?;
    i += 1;
    if t1 != 0x01 {
        return None;
    }
    let l1 = *tlv.get(i)? as usize;
    i += 1;
    let noise = tlv.get(i..i + l1)?;
    i += l1;
    let noise_hex = std::str::from_utf8(noise).ok()?.to_string();

    let t2 = *tlv.get(i)?;
    i += 1;
    if t2 != 0x02 {
        return None;
    }
    let l2 = *tlv.get(i)? as usize;
    i += 1;
    let nonce = tlv.get(i..i + l2)?.to_vec();
    Some((noise_hex, nonce))
}

/// Build verifyResponse TLV body for an inbound challenge (BitChat `buildVerifyResponse`).
pub fn build_verify_response_tlv(
    identity: &Identity,
    noise_key_hex: &str,
    nonce_a: &[u8],
) -> Vec<u8> {
    let noise_bytes = noise_key_hex.as_bytes();
    let n_len = noise_bytes.len().min(255);
    let nonce_len = nonce_a.len().min(255);

    let mut msg = Vec::with_capacity(RESPONSE_CONTEXT.len() + 1 + n_len + nonce_len);
    msg.extend_from_slice(RESPONSE_CONTEXT);
    msg.push(n_len as u8);
    msg.extend_from_slice(&noise_bytes[..n_len]);
    msg.extend_from_slice(&nonce_a[..nonce_len]);
    let sig = identity.sign(&msg);

    let mut tlv = Vec::with_capacity(3 + n_len + nonce_len + sig.len());
    tlv.push(0x01);
    tlv.push(n_len as u8);
    tlv.extend_from_slice(&noise_bytes[..n_len]);
    tlv.push(0x02);
    tlv.push(nonce_len as u8);
    tlv.extend_from_slice(&nonce_a[..nonce_len]);
    tlv.push(0x03);
    tlv.push(sig.len() as u8); // Ed25519 sig is 64 ≤ 255
    tlv.extend_from_slice(&sig);
    tlv
}

/// Verify a verifyResponse signature (for tests / future Offline scanner).
pub fn verify_response_signature(
    noise_key_hex: &str,
    nonce_a: &[u8],
    signature: &[u8; 64],
    signer_public_hex: &str,
) -> Result<(), IdentityError> {
    let noise_bytes = noise_key_hex.as_bytes();
    let n_len = noise_bytes.len().min(255);
    let mut msg = Vec::with_capacity(RESPONSE_CONTEXT.len() + 1 + n_len + nonce_a.len());
    msg.extend_from_slice(RESPONSE_CONTEXT);
    msg.push(n_len as u8);
    msg.extend_from_slice(&noise_bytes[..n_len]);
    msg.extend_from_slice(nonce_a);
    let pk = parse_hex32(signer_public_hex)?;
    Identity::verify(&pk, &msg, signature)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::Identity;

    #[test]
    fn round_trip_sign_verify_and_parse() {
        let id = Identity::generate();
        let qr = build_verify_qr_with_nonce(
            &id,
            "alice",
            None,
            1_700_000_000,
            [7u8; 16],
        );
        assert_eq!(qr.version, 1);
        assert_eq!(qr.nickname, "alice");
        qr.verify_signature().unwrap();
        assert!(qr.is_fresh(1_700_000_000, 300));
        assert!(!qr.is_fresh(1_700_000_000 + 301, 300));

        let url = qr.to_url_string();
        assert!(url.starts_with("bitchat://verify?"));
        assert!(url.contains("noise="));
        assert!(url.contains("sign="));
        assert!(url.contains("nick=alice"));
        assert!(url.contains("&sig="));

        let parsed = VerificationQr::from_url(&url).expect("parse");
        assert_eq!(parsed.nickname, "alice");
        assert_eq!(parsed.noise_key_hex, qr.noise_key_hex);
        parsed.verify_signature().unwrap();
    }

    #[test]
    fn nick_with_spaces_round_trips() {
        let id = Identity::generate();
        let qr = build_verify_qr_with_nonce(&id, "a b", None, 42, [1u8; 16]);
        let parsed = VerificationQr::from_url(&qr.to_url_string()).unwrap();
        assert_eq!(parsed.nickname, "a b");
        parsed.verify_signature().unwrap();
    }

    #[test]
    fn base64_url_16_bytes() {
        let s = base64_url_nopad(&[0u8; 16]);
        assert_eq!(s.len(), 22);
        assert!(!s.contains('='));
        assert!(!s.contains('+'));
        assert!(!s.contains('/'));
    }

    #[test]
    fn challenge_response_round_trip() {
        let id = Identity::generate();
        let noise_hex = hex::encode(id.noise_public_key());
        let nonce = [9u8; 16];

        // Challenge TLV as BitChat builds it.
        let mut challenge = Vec::new();
        let nk = noise_hex.as_bytes();
        challenge.push(0x01);
        challenge.push(nk.len() as u8);
        challenge.extend_from_slice(nk);
        challenge.push(0x02);
        challenge.push(nonce.len() as u8);
        challenge.extend_from_slice(&nonce);

        let (parsed_hex, parsed_nonce) = parse_verify_challenge(&challenge).unwrap();
        assert_eq!(parsed_hex, noise_hex);
        assert_eq!(parsed_nonce, nonce);

        let tlv = build_verify_response_tlv(&id, &parsed_hex, &parsed_nonce);
        // Extract sig from TLV 0x03
        let mut i = 0;
        assert_eq!(tlv[i], 0x01);
        i += 1;
        let l1 = tlv[i] as usize;
        i += 1 + l1;
        assert_eq!(tlv[i], 0x02);
        i += 1;
        let l2 = tlv[i] as usize;
        i += 1 + l2;
        assert_eq!(tlv[i], 0x03);
        i += 1;
        let l3 = tlv[i] as usize;
        i += 1;
        let mut sig = [0u8; 64];
        sig.copy_from_slice(&tlv[i..i + l3]);
        verify_response_signature(&noise_hex, &nonce, &sig, &hex::encode(id.signing_public_key()))
            .unwrap();
    }
}
