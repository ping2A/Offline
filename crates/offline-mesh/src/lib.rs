//! Mesh routing policy: TTL flood, dedupe, duty-cycle knobs.
//!
//! Platform code owns BLE I/O; this crate decides *whether* and *how* to relay.

use offline_packet::{MessageType, Packet, PeerId, DEFAULT_TTL};
use serde::{Deserialize, Serialize};
use std::collections::{HashSet, VecDeque};
use std::time::Duration;
use web_time::Instant;

/// Default origin TTL (BitChat whitepaper §4.2).
pub const ORIGIN_TTL: u8 = DEFAULT_TTL;

/// Seen-set capacity (BitChat: 1000 entries, 5-minute expiry).
pub const SEEN_CAPACITY: usize = 1000;
pub const SEEN_TTL: Duration = Duration::from_secs(5 * 60);

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DutyCycleConfig {
    /// Max simultaneous BLE connections.
    pub max_connections: usize,
    /// Scan window when connected (ms).
    pub scan_window_ms: u64,
    /// Scan interval when connected (ms).
    pub scan_interval_ms: u64,
    /// Announce interval when isolated (ms).
    pub announce_isolated_ms: u64,
    /// Announce interval when connected (ms), before jitter.
    pub announce_connected_ms: u64,
}

impl Default for DutyCycleConfig {
    fn default() -> Self {
        Self {
            max_connections: 8,
            scan_window_ms: 100,
            scan_interval_ms: 1000,
            announce_isolated_ms: 4_000,
            announce_connected_ms: 20_000,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RelayDecision {
    /// Deliver locally only (TTL exhausted or addressed to us).
    LocalOnly,
    /// Flood / forward after decrementing TTL.
    Relay { new_ttl: u8 },
    /// Drop (duplicate or invalid).
    Drop,
}

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
struct SeenKey {
    sender: [u8; 8],
    timestamp: u64,
    packet_type: u8,
    payload_digest: u64,
}

/// In-memory dedupe + relay policy.
pub struct MeshRouter {
    local_id: PeerId,
    seen: HashSet<SeenKey>,
    seen_order: VecDeque<(SeenKey, Instant)>,
    pub duty: DutyCycleConfig,
    pub link_count: usize,
}

impl MeshRouter {
    pub fn new(local_id: PeerId) -> Self {
        Self {
            local_id,
            seen: HashSet::new(),
            seen_order: VecDeque::new(),
            duty: DutyCycleConfig::default(),
            link_count: 0,
        }
    }

    pub fn local_id(&self) -> PeerId {
        self.local_id
    }

    fn payload_digest(payload: &[u8]) -> u64 {
        // FNV-1a 64-bit over payload for dedupe key.
        let mut h: u64 = 0xcbf2_9ce4_8422_2325;
        for &b in payload {
            h ^= u64::from(b);
            h = h.wrapping_mul(0x100_0000_01b3);
        }
        h
    }

    fn purge_expired(&mut self, now: Instant) {
        while let Some((_, t)) = self.seen_order.front() {
            if now.duration_since(*t) < SEEN_TTL && self.seen.len() <= SEEN_CAPACITY {
                break;
            }
            if let Some((key, _)) = self.seen_order.pop_front() {
                self.seen.remove(&key);
            }
        }
        while self.seen.len() > SEEN_CAPACITY {
            if let Some((key, _)) = self.seen_order.pop_front() {
                self.seen.remove(&key);
            } else {
                break;
            }
        }
    }

    /// Returns whether this packet was already seen; records it if new.
    pub fn is_duplicate(&mut self, packet: &Packet) -> bool {
        let now = Instant::now();
        self.purge_expired(now);
        let key = SeenKey {
            sender: *packet.sender_id.as_bytes(),
            timestamp: packet.timestamp,
            packet_type: packet.packet_type,
            payload_digest: Self::payload_digest(&packet.payload),
        };
        if self.seen.contains(&key) {
            return true;
        }
        self.seen.insert(key.clone());
        self.seen_order.push_back((key, now));
        false
    }

    /// Clamp TTL based on local degree (BitChat dense/thin heuristics).
    pub fn clamp_ttl(&self, incoming_ttl: u8) -> u8 {
        if incoming_ttl == 0 {
            return 0;
        }
        let mut ttl = incoming_ttl.saturating_sub(1);
        if self.link_count >= 6 {
            ttl = ttl.min(5);
        }
        ttl
    }

    pub fn decide(&mut self, packet: &Packet) -> RelayDecision {
        if self.is_duplicate(packet) {
            return RelayDecision::Drop;
        }

        let for_us = packet
            .recipient_id
            .map(|r| r == self.local_id || r.is_broadcast())
            .unwrap_or(true);

        if packet.ttl == 0 {
            return if for_us {
                RelayDecision::LocalOnly
            } else {
                RelayDecision::Drop
            };
        }

        // Directed Noise / handshake: always relay with TTL-1 when not for us.
        let directed = matches!(
            MessageType::from_u8(packet.packet_type),
            Some(MessageType::NoiseHandshake | MessageType::NoiseEncrypted)
        ) && packet.recipient_id.is_some()
            && !packet
                .recipient_id
                .map(|r| r.is_broadcast())
                .unwrap_or(false);

        if packet.recipient_id == Some(self.local_id) {
            return RelayDecision::LocalOnly;
        }

        let new_ttl = if directed {
            packet.ttl.saturating_sub(1)
        } else {
            self.clamp_ttl(packet.ttl)
        };

        if new_ttl == 0 && !for_us {
            return RelayDecision::Drop;
        }
        if for_us && new_ttl == 0 {
            return RelayDecision::LocalOnly;
        }
        RelayDecision::Relay { new_ttl }
    }

    pub fn can_accept_connection(&self, current: usize) -> bool {
        current < self.duty.max_connections
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use offline_packet::Packet;

    #[test]
    fn dedupe_drops_second() {
        let local = PeerId::from_bytes([1; 8]);
        let mut router = MeshRouter::new(local);
        let pkt = Packet::new(
            MessageType::Message,
            PeerId::from_bytes([2; 8]),
            b"hi".to_vec(),
        )
        .with_timestamp(1)
        .with_ttl(7);
        assert!(matches!(
            router.decide(&pkt),
            RelayDecision::Relay { .. }
        ));
        assert_eq!(router.decide(&pkt), RelayDecision::Drop);
    }
}
