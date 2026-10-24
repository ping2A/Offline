//! BitChat authenticated peer state (Noise payload type `0x21`).

use crate::capabilities::PeerCapabilities;

const VERSION: u8 = 0x01;
const TLV_CAPABILITIES: u8 = 0x01;
const TLV_SIGNING_KEY: u8 = 0x02;

/// Canonical payload inside Noise `AuthenticatedPeerState` (`0x21`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AuthenticatedPeerState {
    pub capabilities: PeerCapabilities,
    pub signing_public_key: [u8; 32],
}

impl AuthenticatedPeerState {
    pub fn new(capabilities: PeerCapabilities, signing_public_key: [u8; 32]) -> Self {
        Self {
            capabilities,
            signing_public_key,
        }
    }

    pub fn encode(&self) -> Vec<u8> {
        let caps = self.capabilities.encode();
        let mut out = Vec::with_capacity(1 + 2 + caps.len() + 2 + 32);
        out.push(VERSION);
        out.push(TLV_CAPABILITIES);
        out.push(caps.len() as u8);
        out.extend_from_slice(&caps);
        out.push(TLV_SIGNING_KEY);
        out.push(32);
        out.extend_from_slice(&self.signing_public_key);
        out
    }

    pub fn decode(data: &[u8]) -> Option<Self> {
        if data.first().copied() != Some(VERSION) {
            return None;
        }
        let mut offset = 1;
        let mut capabilities: Option<PeerCapabilities> = None;
        let mut signing: Option<[u8; 32]> = None;

        while offset < data.len() {
            if offset + 2 > data.len() {
                return None;
            }
            let ty = data[offset];
            let len = data[offset + 1] as usize;
            offset += 2;
            if offset + len > data.len() {
                return None;
            }
            let value = &data[offset..offset + len];
            offset += len;

            match ty {
                TLV_CAPABILITIES => {
                    if capabilities.is_some() || !(1..=8).contains(&len) {
                        return None;
                    }
                    if !PeerCapabilities::is_canonical(value) {
                        return None;
                    }
                    capabilities = Some(PeerCapabilities::decode(value));
                }
                TLV_SIGNING_KEY => {
                    if signing.is_some() || len != 32 {
                        return None;
                    }
                    let mut k = [0u8; 32];
                    k.copy_from_slice(value);
                    signing = Some(k);
                }
                _ => {}
            }
        }

        Some(Self {
            capabilities: capabilities?,
            signing_public_key: signing?,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn roundtrip_peer_state() {
        let state = AuthenticatedPeerState::new(PeerCapabilities::PRIVATE_MEDIA, [7u8; 32]);
        let bytes = state.encode();
        // version + caps TLV (2+2) + signing TLV (2+32) = 1+4+34 = 39 for PRIVATE_MEDIA
        assert_eq!(bytes[0], 0x01);
        assert_eq!(AuthenticatedPeerState::decode(&bytes), Some(state));
    }
}
