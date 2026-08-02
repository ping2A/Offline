#[flutter_rust_bridge::frb(sync)]
pub fn greet(name: String) -> String {
    format!("Offline ready, {name}!")
}

#[flutter_rust_bridge::frb(init, sync)]
pub fn init_app() {
    flutter_rust_bridge::setup_default_user_utils();
}
