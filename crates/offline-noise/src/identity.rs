//! Long-term device identity: Noise static X25519 + Ed25519 signing key.

use ed25519_dalek::{Signature, Signer, SigningKey, Verifier, VerifyingKey};
use offline_packet::{PeerId, SIGNATURE_SIZE};
use rand::rngs::OsRng;
use sha2::{Digest, Sha256};
use thiserror::Error;
use x25519_dalek::{PublicKey as X25519Public, StaticSecret};
use zeroize::{Zeroize, ZeroizeOnDrop};

#[derive(Debug, Error)]
pub enum IdentityError {
    #[error("invalid key length")]
    InvalidKeyLength,
    #[error("invalid signature")]
    InvalidSignature,
    #[error("ed25519 error: {0}")]
    Ed25519(String),
}

/// Device identity held in secure storage.
#[derive(Zeroize, ZeroizeOnDrop)]
pub struct Identity {
    noise_secret: [u8; 32],
    #[zeroize(skip)]
    noise_public: [u8; 32],
    signing_secret: [u8; 32],
    #[zeroize(skip)]
    signing_public: [u8; 32],
    #[zeroize(skip)]
    peer_id: PeerId,
}

impl Identity {
    pub fn generate() -> Self {
        let mut rng = OsRng;
        let noise_secret = StaticSecret::random_from_rng(&mut rng);
        let noise_public = X25519Public::from(&noise_secret);
        let signing = SigningKey::generate(&mut rng);
        Self::from_parts(
            noise_secret.to_bytes(),
            noise_public.to_bytes(),
            signing.to_bytes(),
            signing.verifying_key().to_bytes(),
        )
    }

    pub fn from_parts(
        noise_secret: [u8; 32],
        noise_public: [u8; 32],
        signing_secret: [u8; 32],
        signing_public: [u8; 32],
    ) -> Self {
        let peer_id = peer_id_from_noise_public(&noise_public);
        Self {
            noise_secret,
            noise_public,
            signing_secret,
            signing_public,
            peer_id,
        }
    }

    pub fn peer_id(&self) -> PeerId {
        self.peer_id
    }

    pub fn noise_public_key(&self) -> &[u8; 32] {
        &self.noise_public
    }

    pub fn noise_secret_key(&self) -> &[u8; 32] {
        &self.noise_secret
    }

    pub fn signing_public_key(&self) -> &[u8; 32] {
        &self.signing_public
    }

    pub fn sign(&self, message: &[u8]) -> [u8; SIGNATURE_SIZE] {
        let signing = SigningKey::from_bytes(&self.signing_secret);
        signing.sign(message).to_bytes()
    }

    pub fn verify(
        signing_public: &[u8; 32],
        message: &[u8],
        signature: &[u8; SIGNATURE_SIZE],
    ) -> Result<(), IdentityError> {
        let vk = VerifyingKey::from_bytes(signing_public)
            .map_err(|e| IdentityError::Ed25519(e.to_string()))?;
        let sig = Signature::from_bytes(signature);
        vk.verify(message, &sig)
            .map_err(|_| IdentityError::InvalidSignature)
    }

    /// Export for secure persistence (caller must protect these bytes).
    pub fn export_secrets(&self) -> IdentitySecrets {
        IdentitySecrets {
            noise_secret: self.noise_secret,
            signing_secret: self.signing_secret,
        }
    }

    pub fn from_secrets(secrets: &IdentitySecrets) -> Self {
        let noise_secret = StaticSecret::from(secrets.noise_secret);
        let noise_public = X25519Public::from(&noise_secret);
        let signing = SigningKey::from_bytes(&secrets.signing_secret);
        Self::from_parts(
            secrets.noise_secret,
            noise_public.to_bytes(),
            secrets.signing_secret,
            signing.verifying_key().to_bytes(),
        )
    }
}

#[derive(Clone, Zeroize, ZeroizeOnDrop)]
pub struct IdentitySecrets {
    pub noise_secret: [u8; 32],
    pub signing_secret: [u8; 32],
}

/// BitChat binding: `hex(SHA-256(noiseStaticPublicKey)[0..<8])`.
pub fn peer_id_from_noise_public(noise_public: &[u8; 32]) -> PeerId {
    let digest = Sha256::digest(noise_public);
    let mut id = [0u8; 8];
    id.copy_from_slice(&digest[..8]);
    PeerId::from_bytes(id)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn peer_id_stable() {
        let id = Identity::generate();
        let again = peer_id_from_noise_public(id.noise_public_key());
        assert_eq!(id.peer_id(), again);
        assert_eq!(id.peer_id().to_hex().len(), 16);
    }

    #[test]
    fn sign_verify() {
        let id = Identity::generate();
        let msg = b"announce payload";
        let sig = id.sign(msg);
        Identity::verify(id.signing_public_key(), msg, &sig).unwrap();
    }
}
