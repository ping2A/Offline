/// Client / protocol identity for Flutter UI.
///
/// Keep in sync with the repo root `VERSION` file and
/// `crates/offline-core/src/version.rs` (Cargo workspace version).
library;

const String kClientVersion = '0.1.0';
const String kProtocolId = 'bitchat-mesh';
const String kProtocolVersion = '1';

String get kProtocolLabel => '$kProtocolId/$kProtocolVersion';

String get kVersionLabel => '$kClientVersion · $kProtocolLabel';
