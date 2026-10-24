//! Client + wire-protocol identity shared by native, WASM, and docs.

/// App / crate release version (`Cargo.toml` workspace package).
pub const CLIENT_VERSION: &str = env!("CARGO_PKG_VERSION");

/// BitChat-compatible BLE mesh family Offline speaks.
pub const PROTOCOL_ID: &str = "bitchat-mesh";

/// Offline's compatibility generation for that family (packet v1+v2, Noise XX, …).
/// Bump when wire behaviour changes in a way peers must know about.
pub const PROTOCOL_VERSION: &str = "1";

/// e.g. `bitchat-mesh/1`
pub fn protocol_label() -> String {
    format!("{PROTOCOL_ID}/{PROTOCOL_VERSION}")
}

/// e.g. `0.1.0 · bitchat-mesh/1`
pub fn version_label() -> String {
    format!("{CLIENT_VERSION} · {}", protocol_label())
}
