//! BitChat `PrivateMediaMessageIdentity` — deterministic IDs for private-media receipts.

use sha2::{Digest, Sha256};

const DOMAIN: &[u8] = b"bitchat-private-media-message-v1";
const ID_PREFIX: &str = "media-";
const DIGEST_HEX_LEN: usize = 32;

/// True when `candidate` is a BitChat stable private-media message id (`media-` + 32 hex).
pub fn is_stable_private_media_id(candidate: &str) -> bool {
    let Some(digest) = candidate.strip_prefix(ID_PREFIX) else {
        return false;
    };
    digest.len() == DIGEST_HEX_LEN
        && digest
            .bytes()
            .all(|b| matches!(b, b'0'..=b'9' | b'a'..=b'f'))
}

/// BitChat-compatible stable id for encrypted private media receipts.
///
/// Only `img_<…>_<UUID>.jpg|jpeg` and `voice_<…>_<UUID|16hex>.m4a` leaf names qualify.
/// Peer IDs must be the short 16-hex form (lowercase). Returns `None` when the
/// filename is not receipt-eligible (legacy random-ID path).
pub fn private_media_stable_id(
    sender_peer_id_hex: &str,
    recipient_peer_id_hex: &str,
    file_name: &str,
) -> Option<String> {
    if file_name.is_empty() || file_name.contains('/') || file_name.contains('\\') {
        return None;
    }
    if !filename_has_receipt_entropy(file_name) {
        return None;
    }
    let sender = sender_peer_id_hex.to_ascii_lowercase();
    let recipient = recipient_peer_id_hex.to_ascii_lowercase();
    let mut input = Vec::with_capacity(
        DOMAIN.len() + 4 + sender.len() + 4 + recipient.len() + 4 + file_name.len(),
    );
    input.extend_from_slice(DOMAIN);
    append_length_prefixed(&mut input, sender.as_bytes())?;
    append_length_prefixed(&mut input, recipient.as_bytes())?;
    append_length_prefixed(&mut input, file_name.as_bytes())?;
    let digest = Sha256::digest(&input);
    let hex = hex::encode(digest);
    Some(format!("{ID_PREFIX}{}", &hex[..DIGEST_HEX_LEN]))
}

fn append_length_prefixed(out: &mut Vec<u8>, field: &[u8]) -> Option<()> {
    let len = u32::try_from(field.len()).ok()?;
    out.extend_from_slice(&len.to_be_bytes());
    out.extend_from_slice(field);
    Some(())
}

fn filename_has_receipt_entropy(file_name: &str) -> bool {
    let path = std::path::Path::new(file_name);
    let stem = path.file_stem().and_then(|s| s.to_str()).unwrap_or("");
    let ext = path
        .extension()
        .and_then(|s| s.to_str())
        .unwrap_or("")
        .to_ascii_lowercase();

    if let Some(rest) = stem.strip_prefix("img_") {
        if ext != "jpg" && ext != "jpeg" {
            return false;
        }
        return last_underscore_token(rest).is_some_and(is_uuid_string);
    }
    if let Some(rest) = stem.strip_prefix("voice_") {
        if ext != "m4a" {
            return false;
        }
        if last_underscore_token(rest).is_some_and(is_uuid_string) {
            return true;
        }
        // Live PTT final note: `voice_<16 hex burst id>.m4a`
        return rest.len() == 16 && rest.bytes().all(|b| b.is_ascii_hexdigit());
    }
    false
}

fn last_underscore_token(stem_without_prefix: &str) -> Option<&str> {
    stem_without_prefix.rsplit('_').next().filter(|t| !t.is_empty())
}

fn is_uuid_string(s: &str) -> bool {
    // RFC-4122 string form required by BitChat `UUID(uuidString:)`.
    if s.len() != 36 {
        return false;
    }
    let b = s.as_bytes();
    if b[8] != b'-' || b[13] != b'-' || b[18] != b'-' || b[23] != b'-' {
        return false;
    }
    for (i, c) in b.iter().enumerate() {
        if i == 8 || i == 13 || i == 18 || i == 23 {
            continue;
        }
        if !matches!(c, b'0'..=b'9' | b'a'..=b'f' | b'A'..=b'F') {
            return false;
        }
    }
    true
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rejects_plain_photo_name() {
        assert!(private_media_stable_id("aaaaaaaaaaaaaaaa", "bbbbbbbbbbbbbbbb", "photo.jpg").is_none());
    }

    #[test]
    fn img_uuid_roundtrip_shape() {
        let id = private_media_stable_id(
            "aabbccddeeff0011",
            "1122334455667788",
            "img_20261024_120000_550e8400-e29b-41d4-a716-446655440000.jpg",
        )
        .expect("stable");
        assert!(is_stable_private_media_id(&id));
        assert_eq!(&id[..6], "media-");
        assert_eq!(id.len(), 6 + 32);
    }

    #[test]
    fn deterministic_across_calls() {
        let name = "img_20260101_010101_550e8400-e29b-41d4-a716-446655440000.jpg";
        let a = private_media_stable_id("deadbeefcafebabe", "0123456789abcdef", name).unwrap();
        let b = private_media_stable_id("DEADBEEFCAFEBABE", "0123456789ABCDEF", name).unwrap();
        assert_eq!(a, b);
    }

    #[test]
    fn voice_burst_id_form() {
        let id = private_media_stable_id(
            "aaaaaaaaaaaaaaaa",
            "bbbbbbbbbbbbbbbb",
            "voice_0102030405060708.m4a",
        )
        .expect("burst");
        assert!(is_stable_private_media_id(&id));
    }
}
