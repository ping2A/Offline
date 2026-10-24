//! BitChat announce / peer-state capability bitfield (minimal little-endian).

/// Feature bits advertised in IdentityAnnouncement TLV `0x05` and peer-state `0x21`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Hash)]
pub struct PeerCapabilities {
    pub raw: u64,
}

impl PeerCapabilities {
    pub const NONE: Self = Self { raw: 0 };
    pub const PRIVATE_MEDIA: Self = Self { raw: 1 << 8 };
    pub const PRIVATE_MEDIA_RECEIPTS: Self = Self { raw: 1 << 9 };

    /// Capabilities this Offline build implements and advertises.
    pub const LOCAL_SUPPORTED: Self = Self {
        raw: Self::PRIVATE_MEDIA.raw | Self::PRIVATE_MEDIA_RECEIPTS.raw,
    };

    pub fn contains(self, other: Self) -> bool {
        (self.raw & other.raw) == other.raw
    }

    pub fn union(self, other: Self) -> Self {
        Self {
            raw: self.raw | other.raw,
        }
    }

    /// Minimal little-endian encoding (at least one byte), matching BitChat/iOS.
    pub fn encode(self) -> Vec<u8> {
        let mut remaining = self.raw;
        let mut bytes = Vec::with_capacity(8);
        loop {
            bytes.push((remaining & 0xff) as u8);
            remaining >>= 8;
            if remaining == 0 {
                break;
            }
        }
        bytes
    }

    /// Decode low 64 bits; ignore any extension bytes beyond 8.
    pub fn decode(data: &[u8]) -> Self {
        let mut raw = 0u64;
        for (i, b) in data.iter().take(8).enumerate() {
            raw |= (*b as u64) << (8 * i);
        }
        Self { raw }
    }

    /// True when `encode()` round-trips to the same bytes (non-minimal rejected).
    pub fn is_canonical(data: &[u8]) -> bool {
        if data.is_empty() || data.len() > 8 {
            return false;
        }
        Self::decode(data).encode() == data
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn private_media_bit_encoding() {
        let bytes = PeerCapabilities::PRIVATE_MEDIA.encode();
        assert_eq!(bytes, vec![0x00, 0x01]);
        assert!(PeerCapabilities::decode(&bytes).contains(PeerCapabilities::PRIVATE_MEDIA));
        assert!(PeerCapabilities::is_canonical(&bytes));
        assert!(!PeerCapabilities::is_canonical(&[0x00, 0x01, 0x00]));
        let local = PeerCapabilities::LOCAL_SUPPORTED.encode();
        assert_eq!(local, vec![0x00, 0x03]); // bits 8 + 9
        assert!(PeerCapabilities::LOCAL_SUPPORTED.contains(PeerCapabilities::PRIVATE_MEDIA_RECEIPTS));
    }
}
