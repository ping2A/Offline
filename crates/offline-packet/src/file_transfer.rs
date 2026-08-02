//! BitChat `BitchatFilePacket` TLV (v2 canonical).
//!
//! Tags use 2-byte lengths except CONTENT, which uses a 4-byte length.
//! FILE_SIZE value is always 4 bytes (u32 BE) in the canonical encoding;
//! decode also accepts legacy 8-byte sizes and 2-byte CONTENT lengths.

/// Absolute ceiling matching BitChat `FileTransferLimits.maxPayloadBytes`.
pub const MAX_FILE_PAYLOAD_BYTES: usize = 1 * 1024 * 1024;
/// Practical mesh photo budget (BitChat `ImageUtils.targetImageBytes` ≈ 45 KiB).
/// Protocol ceiling remains [`MAX_FILE_PAYLOAD_BYTES`]; keep sends small so the
/// BLE fragment train stays ≤ 256 pieces (Android BitChat contract).
pub const MAX_IMAGE_BYTES: usize = 45 * 1024;
/// Voice notes stay under this budget (BitChat `maxVoiceNoteBytes`).
pub const MAX_VOICE_NOTE_BYTES: usize = 512 * 1024;

pub mod file_tlv {
    pub const FILE_NAME: u8 = 0x01;
    pub const FILE_SIZE: u8 = 0x02;
    pub const MIME_TYPE: u8 = 0x03;
    pub const CONTENT: u8 = 0x04;
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FileTransferPayload {
    pub file_name: Option<String>,
    pub file_size: u64,
    pub mime_type: Option<String>,
    pub content: Vec<u8>,
}

impl FileTransferPayload {
    pub fn new(
        file_name: impl Into<String>,
        mime_type: impl Into<String>,
        content: Vec<u8>,
    ) -> Self {
        let size = content.len() as u64;
        Self {
            file_name: Some(file_name.into()),
            file_size: size,
            mime_type: Some(mime_type.into()),
            content,
        }
    }

    pub fn is_valid_size(len: usize) -> bool {
        len > 0 && len <= MAX_FILE_PAYLOAD_BYTES
    }
}

/// Encode canonical v2 TLVs. Returns `None` when content exceeds protocol limits.
pub fn encode_file_transfer(packet: &FileTransferPayload) -> Option<Vec<u8>> {
    if !FileTransferPayload::is_valid_size(packet.content.len()) {
        return None;
    }
    let resolved_size = if packet.file_size == 0 {
        packet.content.len() as u64
    } else {
        packet.file_size
    };
    if resolved_size > u32::MAX as u64 || resolved_size > MAX_FILE_PAYLOAD_BYTES as u64 {
        return None;
    }

    let mut out = Vec::with_capacity(32 + packet.content.len());

    if let Some(name) = &packet.file_name {
        let bytes = name.as_bytes();
        if bytes.len() <= u16::MAX as usize {
            out.push(file_tlv::FILE_NAME);
            out.extend_from_slice(&(bytes.len() as u16).to_be_bytes());
            out.extend_from_slice(bytes);
        }
    }

    out.push(file_tlv::FILE_SIZE);
    out.extend_from_slice(&4u16.to_be_bytes());
    out.extend_from_slice(&(resolved_size as u32).to_be_bytes());

    if let Some(mime) = &packet.mime_type {
        let bytes = mime.as_bytes();
        if bytes.len() <= u16::MAX as usize {
            out.push(file_tlv::MIME_TYPE);
            out.extend_from_slice(&(bytes.len() as u16).to_be_bytes());
            out.extend_from_slice(bytes);
        }
    }

    out.push(file_tlv::CONTENT);
    out.extend_from_slice(&(packet.content.len() as u32).to_be_bytes());
    out.extend_from_slice(&packet.content);

    Some(out)
}

/// Decode TLV payloads, tolerating legacy FILE_SIZE len=8 and CONTENT len=2.
pub fn decode_file_transfer(data: &[u8]) -> Option<FileTransferPayload> {
    let mut offset = 0;
    let mut file_name: Option<String> = None;
    let mut file_size: Option<u64> = None;
    let mut mime_type: Option<String> = None;
    let mut content = Vec::new();

    while offset < data.len() {
        let tag = data[offset];
        offset += 1;

        let length = if tag == file_tlv::CONTENT {
            let snapshot = offset;
            if let Some(canonical) = read_be_len(data, &mut offset, 4) {
                if canonical <= data.len().saturating_sub(offset) {
                    canonical
                } else {
                    offset = snapshot;
                    read_be_len(data, &mut offset, 2)?
                }
            } else {
                offset = snapshot;
                read_be_len(data, &mut offset, 2)?
            }
        } else {
            read_be_len(data, &mut offset, 2)?
        };

        if offset + length > data.len() {
            return None;
        }
        let value = &data[offset..offset + length];
        offset += length;

        match tag {
            file_tlv::FILE_NAME => {
                file_name = Some(String::from_utf8_lossy(value).to_string());
            }
            file_tlv::FILE_SIZE => {
                if length == 4 || length == 8 {
                    let mut size: u64 = 0;
                    for &b in value {
                        size = (size << 8) | u64::from(b);
                    }
                    if size > MAX_FILE_PAYLOAD_BYTES as u64 {
                        return None;
                    }
                    file_size = Some(size);
                }
            }
            file_tlv::MIME_TYPE => {
                mime_type = Some(String::from_utf8_lossy(value).to_string());
            }
            file_tlv::CONTENT => {
                if content.len() + value.len() > MAX_FILE_PAYLOAD_BYTES {
                    return None;
                }
                content.extend_from_slice(value);
            }
            _ => {}
        }
    }

    if !FileTransferPayload::is_valid_size(content.len()) {
        return None;
    }

    Some(FileTransferPayload {
        file_name,
        file_size: file_size.unwrap_or(content.len() as u64),
        mime_type: Some(normalize_mime(
            mime_type.as_deref(),
            &content,
        )),
        content,
    })
}

/// Normalize MIME aliases and fall back to magic-byte sniffing (BitChat `MimeType`).
pub fn normalize_mime(declared: Option<&str>, content: &[u8]) -> String {
    if let Some(raw) = declared {
        let m = raw.trim().to_ascii_lowercase();
        let canonical = match m.as_str() {
            "image/jpg" => "image/jpeg",
            "audio/x-wav" => "audio/wav",
            // BitChat voice notes use `audio/mp4` for AAC-in-M4A.
            "audio/x-m4a" | "audio/m4a" => "audio/mp4",
            other => other,
        };
        if is_allowed_mime(canonical) {
            return canonical.to_string();
        }
    }
    sniff_mime(content)
        .unwrap_or("application/octet-stream")
        .to_string()
}

/// BitChat `MimeType.allowed` allow-list (plus common aliases already normalized).
pub fn is_allowed_mime(mime: &str) -> bool {
    matches!(
        mime,
        "image/jpeg"
            | "image/png"
            | "image/gif"
            | "image/webp"
            | "audio/mp4"
            | "audio/m4a"
            | "audio/aac"
            | "audio/mpeg"
            | "audio/mp3"
            | "audio/wav"
            | "audio/ogg"
            | "application/pdf"
            | "application/octet-stream"
    )
}

/// BitChat-style magic sniff for unlabeled / odd MIME payloads.
pub fn sniff_mime(content: &[u8]) -> Option<&'static str> {
    if content.len() >= 3 && content[0] == 0xFF && content[1] == 0xD8 && content[2] == 0xFF {
        return Some("image/jpeg");
    }
    if content.len() >= 8
        && content[0] == 0x89
        && content[1] == b'P'
        && content[2] == b'N'
        && content[3] == b'G'
    {
        return Some("image/png");
    }
    if content.len() >= 12
        && &content[0..4] == b"RIFF"
        && &content[8..12] == b"WAVE"
    {
        return Some("audio/wav");
    }
    if content.len() >= 12
        && &content[0..4] == b"RIFF"
        && &content[8..12] == b"WEBP"
    {
        return Some("image/webp");
    }
    if content.len() >= 4 && &content[0..4] == b"OggS" {
        return Some("audio/ogg");
    }
    if content.len() >= 4 && &content[0..4] == b"%PDF" {
        return Some("application/pdf");
    }
    // AAC-in-MP4 / m4a: BitChat accepts any payload >100 B for these MIMEs.
    if content.len() > 100 {
        // ftyp box often appears near the start of MP4/M4A.
        if content.windows(4).take(32).any(|w| w == b"ftyp") {
            return Some("audio/mp4");
        }
    }
    None
}

fn read_be_len(data: &[u8], offset: &mut usize, bytes: usize) -> Option<usize> {
    if data.len().saturating_sub(*offset) < bytes {
        return None;
    }
    let mut result: u64 = 0;
    for _ in 0..bytes {
        result = (result << 8) | u64::from(data[*offset]);
        *offset += 1;
    }
    usize::try_from(result).ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn roundtrip_image() {
        let jpeg = vec![0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3, 4];
        let pkt = FileTransferPayload::new("shot.jpg", "image/jpeg", jpeg.clone());
        let enc = encode_file_transfer(&pkt).unwrap();
        let dec = decode_file_transfer(&enc).unwrap();
        assert_eq!(dec.file_name.as_deref(), Some("shot.jpg"));
        assert_eq!(dec.mime_type.as_deref(), Some("image/jpeg"));
        assert_eq!(dec.file_size, jpeg.len() as u64);
        assert_eq!(dec.content, jpeg);
    }

    #[test]
    fn rejects_empty_and_oversized() {
        assert!(encode_file_transfer(&FileTransferPayload::new("a", "image/jpeg", vec![])).is_none());
        let big = vec![0u8; MAX_FILE_PAYLOAD_BYTES + 1];
        assert!(encode_file_transfer(&FileTransferPayload::new("a", "image/jpeg", big)).is_none());
    }

    #[test]
    fn content_tlv_uses_u32_length() {
        let pkt = FileTransferPayload::new("a.bin", "application/octet-stream", vec![9, 8, 7]);
        let enc = encode_file_transfer(&pkt).unwrap();
        // Find CONTENT tag and assert 4-byte length field.
        let mut i = 0;
        while i < enc.len() {
            let tag = enc[i];
            i += 1;
            if tag == file_tlv::CONTENT {
                let len = u32::from_be_bytes([enc[i], enc[i + 1], enc[i + 2], enc[i + 3]]);
                assert_eq!(len, 3);
                return;
            }
            // Skip non-content TLVs (u16 length).
            let len = u16::from_be_bytes([enc[i], enc[i + 1]]) as usize;
            i += 2 + len;
        }
        panic!("CONTENT TLV missing");
    }

    #[test]
    fn normalize_mime_aliases_and_magic() {
        assert_eq!(
            normalize_mime(Some("image/jpg"), &[0xFF, 0xD8, 0xFF, 0x00]),
            "image/jpeg"
        );
        assert_eq!(
            normalize_mime(None, &[0xFF, 0xD8, 0xFF, 0xE0]),
            "image/jpeg"
        );
        let mut wav = b"RIFF".to_vec();
        wav.extend_from_slice(&[0, 0, 0, 0]);
        wav.extend_from_slice(b"WAVE");
        wav.extend(std::iter::repeat_n(0u8, 20));
        assert_eq!(normalize_mime(Some("audio/x-wav"), &wav), "audio/wav");
    }
}
