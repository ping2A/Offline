#[flutter_rust_bridge::frb(sync)]
pub fn greet(name: String) -> String {
    format!("Offline ready, {name}!")
}

/// App release version (matches Cargo workspace / `VERSION` file).
#[flutter_rust_bridge::frb(sync)]
pub fn client_version() -> String {
    offline_core::CLIENT_VERSION.to_string()
}

/// Wire protocol label (e.g. `bitchat-mesh/1`).
#[flutter_rust_bridge::frb(sync)]
pub fn protocol_version() -> String {
    offline_core::protocol_label()
}

/// Combined UI label (e.g. `0.1.0 · bitchat-mesh/1`).
#[flutter_rust_bridge::frb(sync)]
pub fn version_label() -> String {
    offline_core::version_label()
}

#[flutter_rust_bridge::frb(init, sync)]
pub fn init_app() {
    flutter_rust_bridge::setup_default_user_utils();
}
