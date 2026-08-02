//! Deterministic packet ID for gossip sync (BitChat `PacketIdUtil`).
//!
//! ID = first 16 bytes of SHA-256 over `[type | senderID | timestamp BE | payload]`.

use crate::Packet;
use sha2::{Digest, Sha256};

pub fn compute_packet_id(packet: &Packet) -> [u8; 16] {
    let mut hasher = Sha256::new();
    hasher.update([packet.packet_type]);
    hasher.update(packet.sender_id.as_bytes());
    hasher.update(packet.timestamp.to_be_bytes());
    hasher.update(&packet.payload);
    let digest = hasher.finalize();
    let mut out = [0u8; 16];
    out.copy_from_slice(&digest[..16]);
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{MessageType, PeerId, SENDER_ID_SIZE};

    #[test]
    fn stable_id() {
        let pkt = Packet::new(
            MessageType::Message,
            PeerId::from_bytes([1; SENDER_ID_SIZE]),
            b"hi".to_vec(),
        )
        .with_timestamp(12345);
        let a = compute_packet_id(&pkt);
        let b = compute_packet_id(&pkt);
        assert_eq!(a, b);
        assert_ne!(a, [0u8; 16]);
    }
}
