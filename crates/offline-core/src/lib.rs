//! Offline core façade: identity, mesh packets, optical transfers.

mod mesh_ctrl;

pub use mesh_ctrl::{
    MeshController, MeshError, MeshEvent, MeshPeer, NoiseLinkState, OutboundFrame,
};

use offline_fountain::{
    fnv1a, pack_frame, parse_frame, FrameHeader, LTDecoder, LTEncoder, FountainError,
};
use offline_mesh::{MeshRouter, RelayDecision};
use offline_noise::{HandshakeRole, Identity, NoiseError, NoiseSession};
use offline_packet::{MessageType, NoisePayloadType, Packet, PacketError, PeerId};
use thiserror::Error;

#[derive(Debug, Error)]
pub enum CoreError {
    #[error(transparent)]
    Packet(#[from] PacketError),
    #[error(transparent)]
    Noise(#[from] NoiseError),
    #[error(transparent)]
    Fountain(#[from] FountainError),
    #[error("no active optical session")]
    NoOpticalSession,
}

/// Application-facing node state (crypto + routing; no BLE).
pub struct OfflineNode {
    pub identity: Identity,
    pub router: MeshRouter,
}

impl OfflineNode {
    pub fn new() -> Self {
        let identity = Identity::generate();
        let router = MeshRouter::new(identity.peer_id());
        Self { identity, router }
    }

    pub fn from_identity(identity: Identity) -> Self {
        let router = MeshRouter::new(identity.peer_id());
        Self { identity, router }
    }

    pub fn peer_id(&self) -> PeerId {
        self.identity.peer_id()
    }

    pub fn build_public_message(&self, content: &[u8], timestamp_ms: u64) -> Result<Vec<u8>, CoreError> {
        let mut pkt = Packet::new(MessageType::Message, self.peer_id(), content.to_vec())
            .with_timestamp(timestamp_ms)
            .with_ttl(7);
        let signing = pkt.signing_bytes()?;
        let sig = self.identity.sign(&signing);
        pkt = pkt.with_signature(sig);
        Ok(pkt.encode(false)?)
    }

    pub fn handle_inbound(&mut self, bytes: &[u8]) -> Result<Option<(Packet, RelayDecision)>, CoreError> {
        let packet = Packet::decode(bytes)?;
        let decision = self.router.decide(&packet);
        if decision == RelayDecision::Drop {
            return Ok(None);
        }
        Ok(Some((packet, decision)))
    }

    pub fn begin_noise(
        &self,
        role: HandshakeRole,
        remote_peer: PeerId,
    ) -> Result<NoiseSession, CoreError> {
        Ok(NoiseSession::start(&self.identity, role, remote_peer)?)
    }

    pub fn wrap_noise_payload(payload_type: NoisePayloadType, body: &[u8]) -> Vec<u8> {
        let mut out = Vec::with_capacity(1 + body.len());
        out.push(payload_type as u8);
        out.extend_from_slice(body);
        out
    }
}

impl Default for OfflineNode {
    fn default() -> Self {
        Self::new()
    }
}

/// Optical (QR) send session.
pub struct OpticalSender {
    encoder: LTEncoder,
    header_template: FrameHeader,
    pub next_seq: u32,
}

impl OpticalSender {
    pub fn start(payload: &[u8], block_len: u16, session_id: u16) -> Self {
        let encoder = LTEncoder::new(payload, block_len as usize, session_id);
        let header_template = FrameHeader {
            session_id,
            seq: 0,
            k: encoder.k as u16,
            block_len,
            total_len: payload.len() as u32,
            payload_fnv: fnv1a(payload),
        };
        Self {
            encoder,
            header_template,
            next_seq: 0,
        }
    }

    /// Next self-describing QR payload bytes.
    pub fn next_frame(&mut self) -> Vec<u8> {
        let seq = self.next_seq;
        self.next_seq = self.next_seq.wrapping_add(1);
        let block = self.encoder.encode(seq);
        let mut h = self.header_template;
        h.seq = seq;
        pack_frame(&h, &block)
    }
}

/// Optical (QR) receive session — locks onto mid-stream frames.
pub struct OpticalReceiver {
    decoder: Option<LTDecoder>,
    expected_fnv: Option<u32>,
}

impl OpticalReceiver {
    pub fn new() -> Self {
        Self {
            decoder: None,
            expected_fnv: None,
        }
    }

    /// Feed one decoded QR binary payload. Returns completed file when ready.
    pub fn ingest(&mut self, frame_bytes: &[u8]) -> Result<Option<Vec<u8>>, CoreError> {
        let (header, block) = parse_frame(frame_bytes).ok_or(FountainError::InvalidFrame)?;

        match &self.decoder {
            Some(d)
                if d.session_id != header.session_id
                    || d.k != header.k as usize
                    || d.block_len != header.block_len as usize =>
            {
                // New session id → reset
                self.decoder = Some(LTDecoder::new(
                    header.k as usize,
                    header.block_len as usize,
                    header.session_id,
                    header.total_len as usize,
                ));
                self.expected_fnv = Some(header.payload_fnv);
            }
            None => {
                self.decoder = Some(LTDecoder::new(
                    header.k as usize,
                    header.block_len as usize,
                    header.session_id,
                    header.total_len as usize,
                ));
                self.expected_fnv = Some(header.payload_fnv);
            }
            _ => {}
        }

        let dec = self.decoder.as_mut().unwrap();
        dec.add_frame(header.seq, block);
        if !dec.is_complete() {
            return Ok(None);
        }
        let out = dec.assemble().ok_or(FountainError::Incomplete)?;
        let expected = self.expected_fnv.unwrap_or(header.payload_fnv);
        if fnv1a(&out) != expected {
            return Err(FountainError::HashMismatch.into());
        }
        Ok(Some(out))
    }

    pub fn frames_collected(&self) -> usize {
        self.decoder.as_ref().map(|d| d.frames_new).unwrap_or(0)
    }

    pub fn progress_hint(&self) -> (usize, usize) {
        // Progress UX: frames collected vs ~k * 1.15
        match &self.decoder {
            Some(d) => (d.frames_new, ((d.k as f64) * 1.15).ceil() as usize),
            None => (0, 0),
        }
    }
}

impl Default for OpticalReceiver {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn optical_end_to_end() {
        let data = b"file bytes for offline optical path".repeat(50);
        let mut sender = OpticalSender::start(&data, 64, 99);
        let mut receiver = OpticalReceiver::new();
        for _ in 0..2000 {
            let frame = sender.next_frame();
            if let Some(out) = receiver.ingest(&frame).unwrap() {
                assert_eq!(out, data);
                return;
            }
        }
        panic!("optical transfer did not complete");
    }
}
