//! BitChat message / noise payload type constants.

use serde::{Deserialize, Serialize};
use thiserror::Error;

pub const SENDER_ID_SIZE: usize = 8;
pub const SIGNATURE_SIZE: usize = 64;
pub const DEFAULT_TTL: u8 = 7;

/// Broadcast recipient: eight `0xFF` bytes.
pub const BROADCAST_RECIPIENT: [u8; SENDER_ID_SIZE] = [0xFF; SENDER_ID_SIZE];

/// Wire message types (BitChat `MessageType`).
#[repr(u8)]
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum MessageType {
    Announce = 0x01,
    Message = 0x02,
    Leave = 0x03,
    CourierEnvelope = 0x04,
    NoiseHandshake = 0x10,
    NoiseEncrypted = 0x11,
    Fragment = 0x20,
    RequestSync = 0x21,
    FileTransfer = 0x22,
    BoardPost = 0x23,
    PrekeyBundle = 0x24,
    GroupMessage = 0x25,
    Ping = 0x26,
    Pong = 0x27,
    NostrCarrier = 0x28,
    VoiceFrame = 0x29,
}

impl MessageType {
    pub fn from_u8(v: u8) -> Option<Self> {
        Some(match v {
            0x01 => Self::Announce,
            0x02 => Self::Message,
            0x03 => Self::Leave,
            0x04 => Self::CourierEnvelope,
            0x10 => Self::NoiseHandshake,
            0x11 => Self::NoiseEncrypted,
            0x20 => Self::Fragment,
            0x21 => Self::RequestSync,
            0x22 => Self::FileTransfer,
            0x23 => Self::BoardPost,
            0x24 => Self::PrekeyBundle,
            0x25 => Self::GroupMessage,
            0x26 => Self::Ping,
            0x27 => Self::Pong,
            0x28 => Self::NostrCarrier,
            0x29 => Self::VoiceFrame,
            _ => return None,
        })
    }

    /// Types that BitChat pads on the wire (Noise frames only).
    pub fn should_pad(self) -> bool {
        matches!(self, Self::NoiseHandshake | Self::NoiseEncrypted)
    }
}

/// First byte inside a decrypted Noise payload.
#[repr(u8)]
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum NoisePayloadType {
    PrivateMessage = 0x01,
    ReadReceipt = 0x02,
    Delivered = 0x03,
    GroupInvite = 0x06,
    GroupKeyUpdate = 0x07,
    VoiceFrame = 0x08,
    VerifyChallenge = 0x10,
    VerifyResponse = 0x11,
    Vouch = 0x12,
    PrivateFile = 0x20,
    AuthenticatedPeerState = 0x21,
}

impl NoisePayloadType {
    pub fn from_u8(v: u8) -> Option<Self> {
        // BitChat accepts prerelease private-file alias 0x09 as PrivateFile.
        if v == 0x09 {
            return Some(Self::PrivateFile);
        }
        Some(match v {
            0x01 => Self::PrivateMessage,
            0x02 => Self::ReadReceipt,
            0x03 => Self::Delivered,
            0x06 => Self::GroupInvite,
            0x07 => Self::GroupKeyUpdate,
            0x08 => Self::VoiceFrame,
            0x10 => Self::VerifyChallenge,
            0x11 => Self::VerifyResponse,
            0x12 => Self::Vouch,
            0x20 => Self::PrivateFile,
            0x21 => Self::AuthenticatedPeerState,
            _ => return None,
        })
    }
}

pub struct PacketFlags;

impl PacketFlags {
    pub const HAS_RECIPIENT: u8 = 0x01;
    pub const HAS_SIGNATURE: u8 = 0x02;
    pub const IS_COMPRESSED: u8 = 0x04;
    pub const HAS_ROUTE: u8 = 0x08;
    pub const IS_RSR: u8 = 0x10;
}

/// 8-byte mesh peer ID = first 8 bytes of SHA-256(Noise static public key).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct PeerId([u8; SENDER_ID_SIZE]);

#[derive(Debug, Error, PartialEq, Eq)]
pub enum PeerIdError {
    #[error("peer id hex must be 16 lowercase hex characters")]
    InvalidHex,
}

impl PeerId {
    pub const fn from_bytes(bytes: [u8; SENDER_ID_SIZE]) -> Self {
        Self(bytes)
    }

    pub fn as_bytes(&self) -> &[u8; SENDER_ID_SIZE] {
        &self.0
    }

    pub fn to_hex(&self) -> String {
        hex_encode(&self.0)
    }

    pub fn from_hex(s: &str) -> Result<Self, PeerIdError> {
        if s.len() != 16 || !s.bytes().all(|c| c.is_ascii_hexdigit()) {
            return Err(PeerIdError::InvalidHex);
        }
        let mut out = [0u8; SENDER_ID_SIZE];
        for i in 0..SENDER_ID_SIZE {
            out[i] = u8::from_str_radix(&s[i * 2..i * 2 + 2], 16)
                .map_err(|_| PeerIdError::InvalidHex)?;
        }
        Ok(Self(out))
    }

    pub fn is_broadcast(&self) -> bool {
        self.0 == BROADCAST_RECIPIENT
    }
}

fn hex_encode(bytes: &[u8]) -> String {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    let mut s = String::with_capacity(bytes.len() * 2);
    for &b in bytes {
        s.push(HEX[(b >> 4) as usize] as char);
        s.push(HEX[(b & 0xf) as usize] as char);
    }
    s
}
