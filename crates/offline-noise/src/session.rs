//! Noise XX session handshake and transport encryption.
//!
//! Transport ciphertext matches BitChat (`useExtractedNonce`):
//! `nonce_u32_be (4) || ciphertext || poly1305_tag (16)`.

use crate::identity::Identity;
use crate::NOISE_PATTERN;
use offline_packet::PeerId;
use snow::{Builder, HandshakeState, TransportState};
use thiserror::Error;

/// BitChat Android/iOS sliding-window size for extracted-nonce replay checks.
const REPLAY_WINDOW_SIZE: u64 = 1024;
const NONCE_SIZE: usize = 4;

#[derive(Debug, Error)]
pub enum NoiseError {
    #[error("snow error: {0}")]
    Snow(String),
    #[error("session not ready for transport")]
    NotReady,
    #[error("handshake already finished")]
    HandshakeFinished,
    #[error("remote static key missing")]
    MissingRemoteKey,
    #[error("peer id binding mismatch: claimed {claimed}, derived {derived}")]
    PeerIdMismatch { claimed: String, derived: String },
    #[error("ciphertext too short for BitChat nonce prefix")]
    TruncatedCiphertext,
    #[error("nonce exceeds 4-byte BitChat limit")]
    NonceExceeded,
    #[error("replayed or invalid nonce")]
    Replay,
}

impl From<snow::Error> for NoiseError {
    fn from(e: snow::Error) -> Self {
        NoiseError::Snow(e.to_string())
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HandshakeRole {
    Initiator,
    Responder,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SessionState {
    Handshaking,
    Transport,
}

/// One Noise XX session with a peer.
pub struct NoiseSession {
    role: HandshakeRole,
    state: SessionState,
    handshake: Option<HandshakeState>,
    transport: Option<TransportState>,
    remote_static: Option<[u8; 32]>,
    claimed_peer_id: PeerId,
    handshake_hash: Option<[u8; 32]>,
    /// BitChat sliding-window replay state for extracted receive nonces.
    highest_rx_nonce: Option<u64>,
    replay_window: u64,
}

impl NoiseSession {
    pub fn start(
        identity: &Identity,
        role: HandshakeRole,
        claimed_peer_id: PeerId,
    ) -> Result<Self, NoiseError> {
        let params = NOISE_PATTERN.parse()?;
        let builder = Builder::new(params).local_private_key(identity.noise_secret_key());
        let handshake = match role {
            HandshakeRole::Initiator => builder.build_initiator()?,
            HandshakeRole::Responder => builder.build_responder()?,
        };
        Ok(Self {
            role,
            state: SessionState::Handshaking,
            handshake: Some(handshake),
            transport: None,
            remote_static: None,
            claimed_peer_id,
            handshake_hash: None,
            highest_rx_nonce: None,
            replay_window: 0,
        })
    }

    pub fn role(&self) -> HandshakeRole {
        self.role
    }

    pub fn state(&self) -> SessionState {
        self.state
    }

    pub fn claimed_peer_id(&self) -> PeerId {
        self.claimed_peer_id
    }

    pub fn remote_static(&self) -> Option<&[u8; 32]> {
        self.remote_static.as_ref()
    }

    /// Session token = Noise handshake hash (BitChat generation token).
    pub fn handshake_hash(&self) -> Option<&[u8; 32]> {
        self.handshake_hash.as_ref()
    }

    /// Write the next handshake message. `payload` is typically empty.
    pub fn write_handshake_message(&mut self, payload: &[u8]) -> Result<Vec<u8>, NoiseError> {
        let hs = self.handshake.as_mut().ok_or(NoiseError::HandshakeFinished)?;
        let mut buf = vec![0u8; 65535];
        let len = hs.write_message(payload, &mut buf)?;
        buf.truncate(len);
        self.complete_handshake_if_ready()?;
        Ok(buf)
    }

    /// Read a handshake message; returns any payload (usually empty).
    pub fn read_handshake_message(&mut self, message: &[u8]) -> Result<Vec<u8>, NoiseError> {
        let hs = self.handshake.as_mut().ok_or(NoiseError::HandshakeFinished)?;
        let mut buf = vec![0u8; 65535];
        let len = hs.read_message(message, &mut buf)?;
        buf.truncate(len);
        self.complete_handshake_if_ready()?;
        Ok(buf)
    }

    fn complete_handshake_if_ready(&mut self) -> Result<(), NoiseError> {
        // Bind peer ID as soon as the remote static key is known (XX msg 2).
        if let Some(hs) = self.handshake.as_ref() {
            if let Some(remote_slice) = hs.get_remote_static() {
                let mut remote = [0u8; 32];
                remote.copy_from_slice(remote_slice);
                let derived = crate::identity::peer_id_from_noise_public(&remote);
                if derived != self.claimed_peer_id {
                    return Err(NoiseError::PeerIdMismatch {
                        claimed: self.claimed_peer_id.to_hex(),
                        derived: derived.to_hex(),
                    });
                }
            }
        }

        let finished = self
            .handshake
            .as_ref()
            .map(|h| h.is_handshake_finished())
            .unwrap_or(false);
        if !finished {
            return Ok(());
        }

        let hs = self.handshake.take().ok_or(NoiseError::HandshakeFinished)?;

        let mut hash = [0u8; 32];
        hash.copy_from_slice(hs.get_handshake_hash());

        let remote_slice = hs.get_remote_static().ok_or(NoiseError::MissingRemoteKey)?;
        let mut remote = [0u8; 32];
        remote.copy_from_slice(remote_slice);

        let transport = hs.into_transport_mode()?;
        self.remote_static = Some(remote);
        self.handshake_hash = Some(hash);
        self.transport = Some(transport);
        self.state = SessionState::Transport;
        Ok(())
    }

    /// Encrypt plaintext into BitChat transport form: `nonce_be_u32 || ct || tag`.
    pub fn encrypt(&mut self, plaintext: &[u8]) -> Result<Vec<u8>, NoiseError> {
        let ts = self.transport.as_mut().ok_or(NoiseError::NotReady)?;
        let nonce = ts.sending_nonce();
        if nonce > u32::MAX as u64 {
            return Err(NoiseError::NonceExceeded);
        }
        let mut body = vec![0u8; plaintext.len() + 16 + 32];
        let len = ts.write_message(plaintext, &mut body)?;
        body.truncate(len);

        let mut out = Vec::with_capacity(NONCE_SIZE + body.len());
        out.extend_from_slice(&(nonce as u32).to_be_bytes());
        out.extend_from_slice(&body);
        Ok(out)
    }

    /// Decrypt BitChat transport form: peel 4-byte BE nonce, set receiving nonce, decrypt.
    pub fn decrypt(&mut self, combined: &[u8]) -> Result<Vec<u8>, NoiseError> {
        if combined.len() < NONCE_SIZE + 16 {
            return Err(NoiseError::TruncatedCiphertext);
        }
        let mut nonce_bytes = [0u8; 4];
        nonce_bytes.copy_from_slice(&combined[..NONCE_SIZE]);
        let nonce = u32::from_be_bytes(nonce_bytes) as u64;
        let ciphertext = &combined[NONCE_SIZE..];

        if !is_valid_nonce(nonce, self.highest_rx_nonce, self.replay_window) {
            return Err(NoiseError::Replay);
        }

        let ts = self.transport.as_mut().ok_or(NoiseError::NotReady)?;
        ts.set_receiving_nonce(nonce);
        let mut buf = vec![0u8; ciphertext.len()];
        let len = ts.read_message(ciphertext, &mut buf)?;
        buf.truncate(len);

        let (highest, window) =
            mark_nonce_seen(nonce, self.highest_rx_nonce, self.replay_window);
        self.highest_rx_nonce = Some(highest);
        self.replay_window = window;
        Ok(buf)
    }
}

/// BitChat Android `isValidNonce` — sliding window over the last 1024 nonces.
fn is_valid_nonce(nonce: u64, highest: Option<u64>, window: u64) -> bool {
    let Some(highest) = highest else {
        return true;
    };
    if nonce + REPLAY_WINDOW_SIZE <= highest {
        return false; // too old
    }
    if nonce > highest {
        return true;
    }
    let offset = highest - nonce;
    if offset >= REPLAY_WINDOW_SIZE {
        return false;
    }
    (window & (1u64 << offset)) == 0
}

fn mark_nonce_seen(nonce: u64, highest: Option<u64>, window: u64) -> (u64, u64) {
    // Bit 0 always tracks the current highest nonce as seen.
    let Some(highest) = highest else {
        return (nonce, 1);
    };
    if nonce > highest {
        let shift = nonce - highest;
        let new_window = if shift >= REPLAY_WINDOW_SIZE {
            1
        } else {
            (window << shift) | 1
        };
        (nonce, new_window)
    } else {
        let offset = highest - nonce;
        (highest, window | (1u64 << offset))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::identity::peer_id_from_noise_public;

    fn handshake_pair() -> (NoiseSession, NoiseSession) {
        let alice = Identity::generate();
        let bob = Identity::generate();

        let mut initiator =
            NoiseSession::start(&alice, HandshakeRole::Initiator, bob.peer_id()).unwrap();
        let mut responder =
            NoiseSession::start(&bob, HandshakeRole::Responder, alice.peer_id()).unwrap();

        let m1 = initiator.write_handshake_message(&[]).unwrap();
        responder.read_handshake_message(&m1).unwrap();
        let m2 = responder.write_handshake_message(&[]).unwrap();
        initiator.read_handshake_message(&m2).unwrap();
        let m3 = initiator.write_handshake_message(&[]).unwrap();
        responder.read_handshake_message(&m3).unwrap();
        (initiator, responder)
    }

    #[test]
    fn xx_handshake_and_encrypt_with_bitchat_nonce_prefix() {
        let (mut initiator, mut responder) = handshake_pair();
        assert_eq!(initiator.state(), SessionState::Transport);
        assert_eq!(responder.state(), SessionState::Transport);
        assert_eq!(
            peer_id_from_noise_public(initiator.remote_static().unwrap()),
            initiator.claimed_peer_id()
        );

        let ct = initiator.encrypt(b"hello bitchat").unwrap();
        assert!(ct.len() >= 4 + 16);
        assert_eq!(&ct[..4], &0u32.to_be_bytes());
        let pt = responder.decrypt(&ct).unwrap();
        assert_eq!(pt, b"hello bitchat");

        let ct2 = responder.encrypt(b"ack").unwrap();
        assert_eq!(&ct2[..4], &0u32.to_be_bytes());
        assert_eq!(initiator.decrypt(&ct2).unwrap(), b"ack");

        let ct3 = initiator.encrypt(b"second").unwrap();
        assert_eq!(&ct3[..4], &1u32.to_be_bytes());
        assert_eq!(responder.decrypt(&ct3).unwrap(), b"second");
    }

    #[test]
    fn rejects_replayed_nonce() {
        let (mut initiator, mut responder) = handshake_pair();
        let ct = initiator.encrypt(b"once").unwrap();
        assert_eq!(responder.decrypt(&ct).unwrap(), b"once");
        assert!(matches!(responder.decrypt(&ct), Err(NoiseError::Replay)));
    }

    #[test]
    fn rejects_wrong_claimed_peer_id() {
        let alice = Identity::generate();
        let bob = Identity::generate();
        let impostor = Identity::generate().peer_id();

        let mut initiator =
            NoiseSession::start(&alice, HandshakeRole::Initiator, impostor).unwrap();
        let mut responder =
            NoiseSession::start(&bob, HandshakeRole::Responder, alice.peer_id()).unwrap();

        let m1 = initiator.write_handshake_message(&[]).unwrap();
        responder.read_handshake_message(&m1).unwrap();
        let m2 = responder.write_handshake_message(&[]).unwrap();
        let err = initiator.read_handshake_message(&m2).unwrap_err();
        assert!(matches!(err, NoiseError::PeerIdMismatch { .. }));
    }

    #[test]
    fn replay_window_helpers() {
        assert!(is_valid_nonce(0, None, 0));
        let (h, w) = mark_nonce_seen(5, None, 0);
        assert_eq!((h, w), (5, 1));
        assert!(!is_valid_nonce(5, Some(h), w));
        assert!(is_valid_nonce(6, Some(h), w));
        let (h2, w2) = mark_nonce_seen(3, Some(h), w);
        assert_eq!(h2, 5);
        assert!(!is_valid_nonce(3, Some(h2), w2));
    }
}
