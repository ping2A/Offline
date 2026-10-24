//! FRB-free wasm-bindgen bindings for the Offline mesh + optical core.
//!
//! See `docs/WASM_JS_PACKAGE.md`. Host supplies transport bytes; this crate
//! never touches I/O.

use offline_core::{MeshController as CoreMesh, MeshEvent, OpticalReceiver as CoreOpticalRx, OpticalSender as CoreOpticalTx};
use offline_packet::VoiceBurstPacket;
use offline_fountain::fnv1a;
use offline_noise::{
    build_verify_qr as build_verify_qr_core, Identity as CoreIdentity, IdentitySecrets,
};
use rand::RngCore;
use serde::Serialize;
use std::sync::atomic::{AtomicBool, Ordering};
use wasm_bindgen::prelude::*;

#[wasm_bindgen]
extern "C" {
    #[wasm_bindgen(js_namespace = console)]
    fn log(s: &str);
    #[wasm_bindgen(js_namespace = console)]
    fn warn(s: &str);
}

/// Verbose `[offline-wasm]` console logging (on by default in the browser).
static WASM_LOG: AtomicBool = AtomicBool::new(true);

fn wasm_log(msg: impl AsRef<str>) {
    if WASM_LOG.load(Ordering::Relaxed) {
        log(&format!("[offline-wasm] {}", msg.as_ref()));
    }
}

fn wasm_warn(msg: impl AsRef<str>) {
    // Warnings always surface — useful when diagnosing silent ingest drops.
    warn(&format!("[offline-wasm] {}", msg.as_ref()));
}

fn pkt_type_name(t: u8) -> &'static str {
    match t {
        0x01 => "announce",
        0x02 => "message",
        0x03 => "leave",
        0x10 => "noiseHandshake",
        0x11 => "noiseEncrypted",
        0x20 => "fragment",
        0x21 => "requestSync",
        0x22 => "fileTransfer",
        0x29 => "voiceBurst",
        _ => "other",
    }
}

#[wasm_bindgen(start)]
pub fn start() {
    #[cfg(feature = "panic-hook")]
    console_error_panic_hook::set_once();
    wasm_log(format!(
        "module start · {} · {}",
        offline_core::CLIENT_VERSION,
        offline_core::protocol_label()
    ));
}

/// Enable/disable `[offline-wasm]` console logging (default: on).
#[wasm_bindgen]
pub fn set_wasm_log_enabled(enabled: bool) {
    WASM_LOG.store(enabled, Ordering::Relaxed);
    log(&format!(
        "[offline-wasm] logging {}",
        if enabled { "enabled" } else { "disabled" }
    ));
}

/// Whether `[offline-wasm]` console logging is currently on.
#[wasm_bindgen]
pub fn wasm_log_enabled() -> bool {
    WASM_LOG.load(Ordering::Relaxed)
}

/// App release version (e.g. `0.1.0`).
#[wasm_bindgen]
pub fn client_version() -> String {
    offline_core::CLIENT_VERSION.to_string()
}

/// Wire protocol label (e.g. `bitchat-mesh/1`).
#[wasm_bindgen]
pub fn protocol_version() -> String {
    offline_core::protocol_label()
}

/// Combined label for UI footers (e.g. `0.1.0 · bitchat-mesh/1`).
#[wasm_bindgen]
pub fn version_label() -> String {
    offline_core::version_label()
}

// ---- Identity ---------------------------------------------------------------

#[wasm_bindgen]
pub struct Identity(CoreIdentity);

#[wasm_bindgen]
impl Identity {
    #[wasm_bindgen(constructor)]
    pub fn generate() -> Identity {
        Identity(CoreIdentity::generate())
    }

    /// Restore from the two 32-byte secrets (host keeps them in secure storage).
    pub fn from_secrets(noise_secret: &[u8], signing_secret: &[u8]) -> Result<Identity, JsError> {
        let n: [u8; 32] = noise_secret
            .try_into()
            .map_err(|_| JsError::new("noise secret must be 32 bytes"))?;
        let s: [u8; 32] = signing_secret
            .try_into()
            .map_err(|_| JsError::new("signing secret must be 32 bytes"))?;
        Ok(Identity(CoreIdentity::from_secrets(&IdentitySecrets {
            noise_secret: n,
            signing_secret: s,
        })))
    }

    #[wasm_bindgen(getter)]
    pub fn peer_id(&self) -> String {
        self.0.peer_id().to_hex()
    }

    #[wasm_bindgen(getter)]
    pub fn noise_public_key(&self) -> Vec<u8> {
        self.0.noise_public_key().to_vec()
    }

    #[wasm_bindgen(getter)]
    pub fn signing_public_key(&self) -> Vec<u8> {
        self.0.signing_public_key().to_vec()
    }

    /// Export secrets for the host to persist. SECURITY: never store in clear
    /// `localStorage` / IndexedDB — see docs/WASM_JS_PACKAGE.md §7.
    pub fn export_secrets(&self) -> ExportedSecrets {
        let s = self.0.export_secrets();
        ExportedSecrets {
            noise_secret: s.noise_secret.to_vec(),
            signing_secret: s.signing_secret.to_vec(),
        }
    }
}

#[wasm_bindgen(getter_with_clone)]
pub struct ExportedSecrets {
    pub noise_secret: Vec<u8>,
    pub signing_secret: Vec<u8>,
}

// ---- Mesh controller --------------------------------------------------------

#[wasm_bindgen]
pub struct MeshController(CoreMesh);

#[wasm_bindgen]
impl MeshController {
    /// Borrow `identity` (do not move/destroy the JS handle). The mesh session
    /// gets its own copy of the key material via `export_secrets`.
    #[wasm_bindgen(constructor)]
    pub fn new(identity: &Identity, nickname: String) -> MeshController {
        let nick = if nickname.trim().is_empty() {
            identity.0.peer_id().to_hex()[..8].to_string()
        } else {
            nickname
        };
        let secrets = identity.0.export_secrets();
        let owned = CoreIdentity::from_secrets(&secrets);
        let peer = owned.peer_id().to_hex();
        wasm_log(format!(
            "MeshController.new peer={}… nick={nick}",
            &peer[..peer.len().min(8)]
        ));
        MeshController(CoreMesh::new(owned, nick))
    }

    pub fn peer_id(&self) -> String {
        self.0.peer_id_hex()
    }

    pub fn nickname(&self) -> String {
        self.0.nickname().to_string()
    }

    pub fn set_nickname(&mut self, nickname: String) {
        wasm_log(format!("set_nickname → {nickname}"));
        self.0.set_nickname(nickname);
    }

    pub fn set_link_count(&mut self, count: u32) {
        wasm_log(format!("set_link_count → {count}"));
        self.0.set_link_count(count as usize);
    }

    pub fn queue_announce(&mut self) -> Result<(), JsError> {
        wasm_log("queue_announce");
        self.0.queue_announce().map_err(mesh_err)
    }

    pub fn queue_public_message(&mut self, text: String) -> Result<(), JsError> {
        wasm_log(format!("queue_public_message len={}", text.len()));
        self.0.queue_public_message(&text).map_err(mesh_err)
    }

    pub fn queue_private_message(&mut self, peer_id: String, text: String) -> Result<(), JsError> {
        wasm_log(format!(
            "queue_private_message → {}… len={}",
            &peer_id[..peer_id.len().min(8)],
            text.len()
        ));
        self.0
            .queue_private_message(&peer_id, &text)
            .map_err(mesh_err)
    }

    /// BitChat Noise read receipt for a private message id.
    pub fn queue_read_receipt(
        &mut self,
        peer_id: String,
        message_id: String,
    ) -> Result<(), JsError> {
        wasm_log(format!(
            "queue_read_receipt → {}… id={}",
            &peer_id[..peer_id.len().min(8)],
            message_id
        ));
        self.0
            .queue_read_receipt(&peer_id, &message_id)
            .map_err(mesh_err)
    }

    pub fn queue_file(
        &mut self,
        name: String,
        mime: String,
        content: Vec<u8>,
        to: Option<String>,
        allow_legacy: Option<bool>,
    ) -> Result<(), JsError> {
        let allow = allow_legacy.unwrap_or(false);
        wasm_log(format!(
            "queue_file name={name} mime={mime} bytes={} to={} legacy={allow}",
            content.len(),
            to.as_deref()
                .map(|p| format!("{}…", &p[..p.len().min(8)]))
                .unwrap_or_else(|| "broadcast".into())
        ));
        self.0
            .queue_file_ex(&name, &mime, content, to.as_deref(), allow)
            .map_err(|e| {
                wasm_warn(format!("queue_file failed: {e}"));
                mesh_err(e)
            })
    }

    /// Live PTT: `burst` is an encoded BitChat `VoiceBurstPacket`.
    /// `to = None` → signed public `0x29`; otherwise Noise inner `0x08`.
    pub fn queue_voice_burst(
        &mut self,
        burst: Vec<u8>,
        to: Option<String>,
    ) -> Result<(), JsError> {
        wasm_log(format!(
            "queue_voice_burst bytes={} to={}",
            burst.len(),
            to.as_deref()
                .map(|p| format!("{}…", &p[..p.len().min(8)]))
                .unwrap_or_else(|| "public".into())
        ));
        let packet = VoiceBurstPacket::decode(&burst)
            .ok_or_else(|| JsError::new("invalid voice burst"))?;
        self.0
            .queue_voice_frame(packet, to.as_deref())
            .map_err(mesh_err)
    }

    /// True when Noise `0x21` proved `PRIVATE_MEDIA` for this peer.
    pub fn private_media_ready(&self, peer_id: String) -> bool {
        self.0
            .peers()
            .iter()
            .find(|p| p.peer_id == peer_id)
            .map(|p| p.private_media_ready())
            .unwrap_or(false)
    }

    pub fn queue_leave(&mut self) -> Result<(), JsError> {
        wasm_log("queue_leave");
        self.0.queue_leave().map_err(mesh_err)
    }

    pub fn start_noise_handshake(&mut self, peer_id: String) -> Result<(), JsError> {
        wasm_log(format!(
            "start_noise_handshake → {}…",
            &peer_id[..peer_id.len().min(8)]
        ));
        self.0.start_noise_handshake(&peer_id).map_err(mesh_err)
    }

    pub fn start_qr_verification(&mut self, peer_id: String) -> Result<(), JsError> {
        wasm_log(format!(
            "start_qr_verification → {}…",
            &peer_id[..peer_id.len().min(8)]
        ));
        self.0.start_qr_verification(&peer_id).map_err(mesh_err)
    }

    pub fn maintain_gossip_sync(&mut self) -> Result<(), JsError> {
        // Periodic (UI timer) — skip spam; outbound/events still log when non-empty.
        self.0.maintain_gossip_sync().map_err(mesh_err)
    }

    pub fn queue_request_sync(&mut self, to_peer_id: Option<String>) -> Result<(), JsError> {
        wasm_log(format!(
            "queue_request_sync to={}",
            to_peer_id
                .as_deref()
                .map(|p| format!("{}…", &p[..p.len().min(8)]))
                .unwrap_or_else(|| "broadcast".into())
        ));
        self.0
            .queue_request_sync(to_peer_id.as_deref())
            .map_err(mesh_err)
    }

    pub fn noise_state(&self, peer_id: String) -> String {
        self.0.noise_state(&peer_id).as_str().to_string()
    }

    pub fn is_verified(&self, peer_id: String) -> bool {
        self.0.is_verified(&peer_id)
    }

    /// Feed one inbound frame (bytes from BLE / BroadcastChannel / WS).
    pub fn ingest_frame(&mut self, bytes: &[u8]) -> Result<(), JsError> {
        let ty = bytes.get(1).copied().unwrap_or(0);
        let ver = bytes.first().copied().unwrap_or(0);
        wasm_log(format!(
            "ingest_frame {}B v{ver} type=0x{ty:02x} ({})",
            bytes.len(),
            pkt_type_name(ty)
        ));
        match self.0.ingest_frame(bytes) {
            Ok(relay) => {
                if !relay.is_empty() {
                    wasm_log(format!("ingest_frame relayed {} frame(s)", relay.len()));
                }
                Ok(())
            }
            Err(e) => {
                wasm_warn(format!("ingest_frame soft-fail: {e}"));
                Err(mesh_err(e))
            }
        }
    }

    /// Pull frames to transmit; each is `{ toPeerId?: string, bytes: Uint8Array }`.
    pub fn drain_outbound(&mut self) -> Result<JsValue, JsError> {
        let frames: Vec<JsOutbound> = self
            .0
            .drain_outbound()
            .into_iter()
            .map(|f| JsOutbound {
                to_peer_id: f.to_peer_id,
                bytes: f.bytes,
            })
            .collect();
        if !frames.is_empty() {
            let summary: Vec<String> = frames
                .iter()
                .take(8)
                .map(|f| {
                    let ty = f.bytes.get(1).copied().unwrap_or(0);
                    format!("{}B/{}", f.bytes.len(), pkt_type_name(ty))
                })
                .collect();
            let more = if frames.len() > 8 {
                format!(" +{} more", frames.len() - 8)
            } else {
                String::new()
            };
            wasm_log(format!(
                "drain_outbound n={} [{}{}]",
                frames.len(),
                summary.join(", "),
                more
            ));
        }
        serde_wasm_bindgen::to_value(&frames).map_err(|e| JsError::new(&e.to_string()))
    }

    /// Pull UI events; shape matches FRB `MeshUiEvent` (kind string + fields).
    pub fn drain_events(&mut self) -> Result<JsValue, JsError> {
        let events: Vec<JsMeshEvent> = self.0.drain_events().into_iter().map(map_event).collect();
        for ev in &events {
            let peer = if ev.peer_id.len() >= 8 {
                &ev.peer_id[..8]
            } else {
                &ev.peer_id
            };
            wasm_log(format!(
                "event kind={} peer={}… detail={} private={} file={} ({}B)",
                ev.kind,
                peer,
                if ev.detail.len() > 48 {
                    format!("{}…", &ev.detail[..48])
                } else {
                    ev.detail.clone()
                },
                ev.is_private,
                ev.file_name,
                ev.file_bytes.len()
            ));
        }
        serde_wasm_bindgen::to_value(&events).map_err(|e| JsError::new(&e.to_string()))
    }

    pub fn list_peers(&self) -> Result<JsValue, JsError> {
        let peers: Vec<JsPeer> = self
            .0
            .peers()
            .into_iter()
            .map(|p| {
                let private_media_ready = p.private_media_ready();
                JsPeer {
                    peer_id: p.peer_id.clone(),
                    nickname: p.nickname,
                    last_seen_ms: p.last_seen_ms,
                    noise_state: p.noise_state.as_str().to_string(),
                    has_noise_key: p.noise_public_key.is_some(),
                    verified: self.0.is_verified(&p.peer_id),
                    private_media_ready,
                    announce_capabilities: p.announce_capabilities,
                }
            })
            .collect();
        serde_wasm_bindgen::to_value(&peers).map_err(|e| JsError::new(&e.to_string()))
    }
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct JsOutbound {
    to_peer_id: Option<String>,
    #[serde(with = "serde_bytes")]
    bytes: Vec<u8>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct JsPeer {
    peer_id: String,
    nickname: String,
    last_seen_ms: u64,
    noise_state: String,
    has_noise_key: bool,
    verified: bool,
    private_media_ready: bool,
    announce_capabilities: u64,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct JsMeshEvent {
    kind: String,
    peer_id: String,
    nickname: String,
    text: String,
    timestamp_ms: u64,
    detail: String,
    is_private: bool,
    file_name: String,
    #[serde(with = "serde_bytes")]
    file_bytes: Vec<u8>,
}

fn map_event(e: MeshEvent) -> JsMeshEvent {
    match e {
        MeshEvent::PeerAnnounce { peer_id, nickname } => JsMeshEvent {
            kind: "announce".into(),
            peer_id,
            nickname,
            text: String::new(),
            timestamp_ms: 0,
            detail: String::new(),
            is_private: false,
            file_name: String::new(),
            file_bytes: Vec::new(),
        },
        MeshEvent::PublicMessage {
            from_peer_id,
            text,
            timestamp_ms,
            signed,
        } => JsMeshEvent {
            kind: "message".into(),
            peer_id: from_peer_id,
            nickname: String::new(),
            text,
            timestamp_ms,
            detail: match signed {
                Some(true) => "signed".into(),
                Some(false) => "invalid_sig".into(),
                None => "unsigned".into(),
            },
            is_private: false,
            file_name: String::new(),
            file_bytes: Vec::new(),
        },
        MeshEvent::PeerLeave { peer_id } => JsMeshEvent {
            kind: "leave".into(),
            peer_id,
            nickname: String::new(),
            text: String::new(),
            timestamp_ms: 0,
            detail: String::new(),
            is_private: false,
            file_name: String::new(),
            file_bytes: Vec::new(),
        },
        MeshEvent::NoiseState {
            peer_id,
            state,
            detail,
        } => JsMeshEvent {
            kind: "noise".into(),
            peer_id,
            nickname: String::new(),
            text: String::new(),
            timestamp_ms: 0,
            detail: format!("{}:{}", state.as_str(), detail),
            is_private: true,
            file_name: String::new(),
            file_bytes: Vec::new(),
        },
        MeshEvent::PrivateMessage {
            from_peer_id,
            text,
            timestamp_ms,
            message_id,
            is_local: _,
        } => JsMeshEvent {
            kind: "dm".into(),
            peer_id: from_peer_id,
            nickname: String::new(),
            text,
            timestamp_ms,
            detail: message_id,
            is_private: true,
            file_name: String::new(),
            file_bytes: Vec::new(),
        },
        MeshEvent::FileTransfer {
            from_peer_id,
            file_name,
            mime_type,
            content,
            timestamp_ms,
            is_private,
            is_local: _,
            message_id,
        } => JsMeshEvent {
            kind: "file".into(),
            peer_id: from_peer_id,
            nickname: message_id,
            text: file_name.clone(),
            timestamp_ms,
            detail: mime_type,
            is_private,
            file_name,
            file_bytes: content,
        },
        MeshEvent::VoiceFrame {
            from_peer_id,
            is_private,
            burst_id_hex,
            sequence,
            kind,
            frames,
            codec,
            total_data_packets,
            duration_ms,
            timestamp_ms,
        } => {
            let joined: Vec<u8> = frames.into_iter().flatten().collect();
            JsMeshEvent {
                kind: "voice_frame".into(),
                peer_id: from_peer_id,
                nickname: burst_id_hex,
                text: format!("{kind}:{sequence}:{codec}:{total_data_packets}:{duration_ms}"),
                timestamp_ms,
                detail: kind,
                is_private,
                file_name: String::new(),
                file_bytes: joined,
            }
        },
        MeshEvent::DeliveryAck {
            peer_id,
            message_id,
            kind,
        } => JsMeshEvent {
            kind,
            peer_id,
            nickname: String::new(),
            text: String::new(),
            timestamp_ms: 0,
            detail: message_id,
            is_private: true,
            file_name: String::new(),
            file_bytes: Vec::new(),
        },
        MeshEvent::PeerVerified { peer_id, nickname } => JsMeshEvent {
            kind: "verified".into(),
            peer_id,
            nickname,
            text: String::new(),
            timestamp_ms: 0,
            detail: "verified".into(),
            is_private: true,
            file_name: String::new(),
            file_bytes: Vec::new(),
        },
        MeshEvent::PrivateMediaLegacy {
            peer_id,
            file_name,
            detail,
        } => JsMeshEvent {
            kind: "private_media_legacy".into(),
            peer_id,
            nickname: String::new(),
            text: file_name.clone(),
            timestamp_ms: 0,
            detail,
            is_private: true,
            file_name,
            file_bytes: Vec::new(),
        },
    }
}

fn mesh_err(e: impl std::fmt::Display) -> JsError {
    JsError::new(&e.to_string())
}

// ---- Optical (QR fountain) --------------------------------------------------

#[wasm_bindgen]
pub struct OpticalSender {
    inner: CoreOpticalTx,
}

#[wasm_bindgen]
impl OpticalSender {
    pub fn start(payload: &[u8], block_len: u16) -> OpticalSender {
        let block_len = if block_len == 0 { 200 } else { block_len };
        let session_id = (rand::thread_rng().next_u32() & 0xffff) as u16;
        OpticalSender {
            inner: CoreOpticalTx::start(payload, block_len, session_id),
        }
    }

    pub fn next_frame(&mut self) -> Vec<u8> {
        self.inner.next_frame()
    }
}

#[wasm_bindgen]
pub struct OpticalReceiver(CoreOpticalRx);

#[wasm_bindgen]
impl OpticalReceiver {
    #[wasm_bindgen(constructor)]
    pub fn new() -> OpticalReceiver {
        OpticalReceiver(CoreOpticalRx::new())
    }

    /// Returns `{ framesCollected, framesTarget, completePayload? }`.
    pub fn ingest_frame(&mut self, frame: &[u8]) -> Result<JsValue, JsError> {
        let complete = self
            .0
            .ingest(frame)
            .map_err(|e| JsError::new(&e.to_string()))?;
        let (collected, target) = self.0.progress_hint();
        let progress = OpticalProgress {
            frames_collected: collected as u64,
            frames_target: target as u64,
            complete_payload: complete,
        };
        serde_wasm_bindgen::to_value(&progress).map_err(|e| JsError::new(&e.to_string()))
    }
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct OpticalProgress {
    frames_collected: u64,
    frames_target: u64,
    #[serde(with = "serde_bytes")]
    complete_payload: Option<Vec<u8>>,
}

// ---- Stateless helpers ------------------------------------------------------

#[wasm_bindgen]
pub fn build_verify_qr(
    noise_secret: &[u8],
    signing_secret: &[u8],
    nickname: String,
    now_unix: f64,
) -> Result<String, JsError> {
    let n: [u8; 32] = noise_secret
        .try_into()
        .map_err(|_| JsError::new("noise secret must be 32 bytes"))?;
    let s: [u8; 32] = signing_secret
        .try_into()
        .map_err(|_| JsError::new("signing secret must be 32 bytes"))?;
    let id = CoreIdentity::from_secrets(&IdentitySecrets {
        noise_secret: n,
        signing_secret: s,
    });
    let nick = if nickname.trim().is_empty() {
        id.peer_id().to_hex()[..8].to_string()
    } else {
        nickname
    };
    Ok(build_verify_qr_core(&id, &nick, None, now_unix as i64).to_url_string())
}

#[wasm_bindgen]
pub fn fnv1a_hash(bytes: &[u8]) -> u32 {
    fnv1a(bytes)
}
