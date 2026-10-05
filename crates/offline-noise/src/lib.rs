//! Noise XX identity and sessions compatible with BitChat.
//!
//! Protocol: `Noise_XX_25519_ChaChaPoly_SHA256`
//! Peer ID: first 8 bytes of SHA-256(Noise static public key), hex-encoded as 16 chars.

mod identity;
mod session;
mod verify_qr;

pub use identity::{peer_id_from_noise_public, Identity, IdentityError, IdentitySecrets};
pub use session::{HandshakeRole, NoiseError, NoiseSession, SessionState};
pub use verify_qr::{
    build_verify_challenge_tlv, build_verify_qr, build_verify_qr_with_nonce,
    build_verify_response_tlv, parse_verify_challenge, parse_verify_response,
    verify_response_signature, VerificationQr,
};

/// BitChat Noise protocol name.
pub const NOISE_PATTERN: &str = "Noise_XX_25519_ChaChaPoly_SHA256";
