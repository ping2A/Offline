//! Noise XX identity and sessions compatible with BitChat.
//!
//! Protocol: `Noise_XX_25519_ChaChaPoly_SHA256`
//! Peer ID: first 8 bytes of SHA-256(Noise static public key), hex-encoded as 16 chars.

mod identity;
mod session;

pub use identity::{peer_id_from_noise_public, Identity, IdentityError, IdentitySecrets};
pub use session::{HandshakeRole, NoiseError, NoiseSession, SessionState};

/// BitChat Noise protocol name.
pub const NOISE_PATTERN: &str = "Noise_XX_25519_ChaChaPoly_SHA256";
