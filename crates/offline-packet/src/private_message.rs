//! BitChat PrivateMessagePacket TLV inside Noise (messageID + content).

/// TLV tags matching BitChat `PrivateMessagePacket`.
pub mod private_tlv {
    pub const MESSAGE_ID: u8 = 0x00;
    pub const CONTENT: u8 = 0x01;
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PrivateMessagePayload {
    pub message_id: String,
    pub content: String,
}

pub fn encode_private_message(message_id: &str, content: &str) -> Option<Vec<u8>> {
    let id = message_id.as_bytes();
    let body = content.as_bytes();
    if id.len() > 255 || body.len() > 255 {
        return None;
    }
    let mut out = Vec::with_capacity(2 + id.len() + 2 + body.len());
    out.push(private_tlv::MESSAGE_ID);
    out.push(id.len() as u8);
    out.extend_from_slice(id);
    out.push(private_tlv::CONTENT);
    out.push(body.len() as u8);
    out.extend_from_slice(body);
    Some(out)
}

pub fn decode_private_message(data: &[u8]) -> Option<PrivateMessagePayload> {
    let mut offset = 0;
    let mut message_id: Option<String> = None;
    let mut content: Option<String> = None;

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
            private_tlv::MESSAGE_ID => {
                message_id = Some(String::from_utf8_lossy(value).to_string());
            }
            private_tlv::CONTENT => {
                content = Some(String::from_utf8_lossy(value).to_string());
            }
            _ => return None,
        }
    }

    Some(PrivateMessagePayload {
        message_id: message_id?,
        content: content?,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn roundtrip() {
        let bytes = encode_private_message("abc-1", "secret hi").unwrap();
        let parsed = decode_private_message(&bytes).unwrap();
        assert_eq!(parsed.message_id, "abc-1");
        assert_eq!(parsed.content, "secret hi");
    }
}
