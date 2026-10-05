//! Mesh FFI for Flutter / native BLE.

use crate::api::identity::IdentityBundle;
use offline_core::{MeshController, MeshEvent, MeshPeer, OutboundFrame};
use offline_noise::{Identity, IdentitySecrets};
use std::sync::Mutex;

pub struct MeshSession {
    inner: Mutex<MeshController>,
}

pub struct MeshPeerInfo {
    pub peer_id: String,
    pub nickname: String,
    pub last_seen_ms: u64,
    pub noise_state: String,
    pub has_noise_key: bool,
    pub verified: bool,
}

pub struct MeshOutbound {
    pub to_peer_id: Option<String>,
    pub bytes: Vec<u8>,
}

/// Flattened UI event (avoids freezed enum codegen dependency).
pub struct MeshUiEvent {
    /// `announce` | `message` | `leave` | `noise` | `dm` | `file`
    pub kind: String,
    pub peer_id: String,
    pub nickname: String,
    pub text: String,
    pub timestamp_ms: u64,
    /// For `noise`: none|handshaking|ready|failed. For `dm`: message id. For `file`: mime type.
    pub detail: String,
    pub is_private: bool,
    /// File transfer bytes (empty for non-file events).
    pub file_name: String,
    pub file_bytes: Vec<u8>,
}

#[flutter_rust_bridge::frb(sync)]
pub fn mesh_start(bundle: IdentityBundle, nickname: String) -> Result<MeshSession, String> {
    let noise: [u8; 32] = bundle
        .noise_secret_key
        .as_slice()
        .try_into()
        .map_err(|_| "bad noise secret")?;
    let signing: [u8; 32] = bundle
        .signing_secret_key
        .as_slice()
        .try_into()
        .map_err(|_| "bad signing secret")?;
    let id = Identity::from_secrets(&IdentitySecrets {
        noise_secret: noise,
        signing_secret: signing,
    });
    let nick = if nickname.trim().is_empty() {
        id.peer_id().to_hex()[..8].to_string()
    } else {
        nickname
    };
    Ok(MeshSession {
        inner: Mutex::new(MeshController::new(id, nick)),
    })
}

impl MeshSession {
    #[flutter_rust_bridge::frb(sync)]
    pub fn peer_id(&self) -> String {
        self.inner.lock().expect("mesh").peer_id_hex()
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn peer_id_bytes(&self) -> Vec<u8> {
        self.inner.lock().expect("mesh").peer_id_bytes().to_vec()
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn nickname(&self) -> String {
        self.inner.lock().expect("mesh").nickname().to_string()
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn set_nickname(&self, nickname: String) {
        self.inner.lock().expect("mesh").set_nickname(nickname);
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn set_link_count(&self, count: u32) {
        self.inner.lock().expect("mesh").set_link_count(count as usize);
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn queue_announce(&self) -> Result<(), String> {
        self.inner
            .lock()
            .expect("mesh")
            .queue_announce()
            .map_err(|e| e.to_string())
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn queue_public_message(&self, text: String) -> Result<(), String> {
        self.inner
            .lock()
            .expect("mesh")
            .queue_public_message(&text)
            .map_err(|e| e.to_string())
    }

    /// Pull recent public channel messages (BitChat `requestSync`).
    #[flutter_rust_bridge::frb(sync)]
    pub fn queue_request_sync(&self, to_peer_id: Option<String>) -> Result<(), String> {
        self.inner
            .lock()
            .expect("mesh")
            .queue_request_sync(to_peer_id.as_deref())
            .map_err(|e| e.to_string())
    }

    /// Periodic gossip maintenance (initial + typed sync rounds).
    #[flutter_rust_bridge::frb(sync)]
    pub fn maintain_gossip_sync(&self) -> Result<(), String> {
        self.inner
            .lock()
            .expect("mesh")
            .maintain_gossip_sync()
            .map_err(|e| e.to_string())
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn queue_file(
        &self,
        file_name: String,
        mime_type: String,
        content: Vec<u8>,
        to_peer_id: Option<String>,
    ) -> Result<(), String> {
        self.inner
            .lock()
            .expect("mesh")
            .queue_file(
                &file_name,
                &mime_type,
                content,
                to_peer_id.as_deref(),
            )
            .map_err(|e| e.to_string())
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn start_noise_handshake(&self, peer_id: String) -> Result<(), String> {
        self.inner
            .lock()
            .expect("mesh")
            .start_noise_handshake(&peer_id)
            .map_err(|e| e.to_string())
    }

    /// Start BitChat QR verification challenge toward a mesh peer.
    #[flutter_rust_bridge::frb(sync)]
    pub fn start_qr_verification(&self, peer_id: String) -> Result<(), String> {
        self.inner
            .lock()
            .expect("mesh")
            .start_qr_verification(&peer_id)
            .map_err(|e| e.to_string())
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn queue_private_message(&self, peer_id: String, text: String) -> Result<(), String> {
        self.inner
            .lock()
            .expect("mesh")
            .queue_private_message(&peer_id, &text)
            .map_err(|e| e.to_string())
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn noise_state(&self, peer_id: String) -> String {
        self.inner
            .lock()
            .expect("mesh")
            .noise_state(&peer_id)
            .as_str()
            .to_string()
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn queue_leave(&self) -> Result<(), String> {
        self.inner
            .lock()
            .expect("mesh")
            .queue_leave()
            .map_err(|e| e.to_string())
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn ingest_frame(&self, bytes: Vec<u8>) -> Result<Vec<MeshOutbound>, String> {
        let relay = self
            .inner
            .lock()
            .expect("mesh")
            .ingest_frame(&bytes)
            .map_err(|e| e.to_string())?;
        Ok(relay.into_iter().map(map_out).collect())
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn drain_outbound(&self) -> Vec<MeshOutbound> {
        self.inner
            .lock()
            .expect("mesh")
            .drain_outbound()
            .into_iter()
            .map(map_out)
            .collect()
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn drain_events(&self) -> Vec<MeshUiEvent> {
        self.inner
            .lock()
            .expect("mesh")
            .drain_events()
            .into_iter()
            .map(map_event)
            .collect()
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn list_peers(&self) -> Vec<MeshPeerInfo> {
        let mesh = self.inner.lock().expect("mesh");
        mesh.peers()
            .into_iter()
            .map(|p: MeshPeer| MeshPeerInfo {
                peer_id: p.peer_id.clone(),
                nickname: p.nickname,
                last_seen_ms: p.last_seen_ms,
                noise_state: p.noise_state.as_str().to_string(),
                has_noise_key: p.noise_public_key.is_some(),
                verified: mesh.is_verified(&p.peer_id),
            })
            .collect()
    }
}

fn map_out(o: OutboundFrame) -> MeshOutbound {
    MeshOutbound {
        to_peer_id: o.to_peer_id,
        bytes: o.bytes,
    }
}

fn map_event(e: MeshEvent) -> MeshUiEvent {
    match e {
        MeshEvent::PeerAnnounce { peer_id, nickname } => MeshUiEvent {
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
        } => MeshUiEvent {
            kind: "message".into(),
            peer_id: from_peer_id,
            nickname: String::new(),
            text,
            timestamp_ms,
            detail: String::new(),
            is_private: false,
            file_name: String::new(),
            file_bytes: Vec::new(),
        },
        MeshEvent::PeerLeave { peer_id } => MeshUiEvent {
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
        } => MeshUiEvent {
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
        } => MeshUiEvent {
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
        } => MeshUiEvent {
            kind: "file".into(),
            peer_id: from_peer_id,
            nickname: String::new(),
            text: file_name.clone(),
            timestamp_ms,
            detail: mime_type,
            is_private,
            file_name,
            file_bytes: content,
        },
        MeshEvent::DeliveryAck {
            peer_id,
            message_id,
            kind,
        } => MeshUiEvent {
            kind: kind, // "delivered" | "read"
            peer_id,
            nickname: String::new(),
            text: String::new(),
            timestamp_ms: 0,
            detail: message_id,
            is_private: true,
            file_name: String::new(),
            file_bytes: Vec::new(),
        },
        MeshEvent::PeerVerified { peer_id, nickname } => MeshUiEvent {
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
    }
}

#[flutter_rust_bridge::frb(sync)]
pub fn mesh_service_uuid() -> String {
    "F47B5E2D-4A9E-4C5A-9B3F-8E1D2C3A4B5C".into()
}

#[flutter_rust_bridge::frb(sync)]
pub fn mesh_characteristic_uuid() -> String {
    "A1B2C3D4-E5F6-4A5B-8C9D-0E1F2A3B4C5D".into()
}
