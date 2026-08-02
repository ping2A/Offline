//! Local BitChat-compatible identity exposed to Flutter.

use offline_noise::Identity;

/// Public view of a device identity (secrets stay in Rust until explicitly exported).
pub struct IdentityView {
    pub peer_id: String,
    pub noise_public_key: Vec<u8>,
    pub signing_public_key: Vec<u8>,
}

/// Full identity material for secure storage on the Flutter side.
pub struct IdentityBundle {
    pub peer_id: String,
    pub noise_public_key: Vec<u8>,
    pub signing_public_key: Vec<u8>,
    pub noise_secret_key: Vec<u8>,
    pub signing_secret_key: Vec<u8>,
}

#[flutter_rust_bridge::frb(sync)]
pub fn generate_identity() -> IdentityBundle {
    let id = Identity::generate();
    let secrets = id.export_secrets();
    IdentityBundle {
        peer_id: id.peer_id().to_hex(),
        noise_public_key: id.noise_public_key().to_vec(),
        signing_public_key: id.signing_public_key().to_vec(),
        noise_secret_key: secrets.noise_secret.to_vec(),
        signing_secret_key: secrets.signing_secret.to_vec(),
    }
}

#[flutter_rust_bridge::frb(sync)]
pub fn identity_from_secrets(
    noise_secret_key: Vec<u8>,
    signing_secret_key: Vec<u8>,
) -> Result<IdentityView, String> {
    let noise: [u8; 32] = noise_secret_key
        .as_slice()
        .try_into()
        .map_err(|_| "noise secret must be 32 bytes".to_string())?;
    let signing: [u8; 32] = signing_secret_key
        .as_slice()
        .try_into()
        .map_err(|_| "signing secret must be 32 bytes".to_string())?;
    let secrets = offline_noise::IdentitySecrets {
        noise_secret: noise,
        signing_secret: signing,
    };
    let id = Identity::from_secrets(&secrets);
    Ok(IdentityView {
        peer_id: id.peer_id().to_hex(),
        noise_public_key: id.noise_public_key().to_vec(),
        signing_public_key: id.signing_public_key().to_vec(),
    })
}

#[flutter_rust_bridge::frb(sync)]
pub fn peer_id_from_noise_public(noise_public_key: Vec<u8>) -> Result<String, String> {
    let key: [u8; 32] = noise_public_key
        .as_slice()
        .try_into()
        .map_err(|_| "noise public key must be 32 bytes".to_string())?;
    Ok(offline_noise::peer_id_from_noise_public(&key).to_hex())
}
