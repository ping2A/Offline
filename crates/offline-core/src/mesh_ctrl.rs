//! Mesh controller: announce TLV, public chat, files, gossip sync, Noise DMs.

use offline_mesh::{MeshRouter, RelayDecision};
use offline_noise::{
    build_verify_challenge_tlv, build_verify_response_tlv, parse_verify_challenge,
    parse_verify_response, peer_id_from_noise_public, verify_response_signature, HandshakeRole,
    Identity, NoiseSession, SessionState,
};
use offline_packet::{
    build_request_sync_payload, compute_packet_id, decode_file_transfer, decode_fragment_id_filter,
    decode_private_message, decode_request_sync, encode_announce_tlv, encode_file_transfer,
    encode_private_message, encode_request_sync, gcs_bucket, gcs_contains, decode_to_sorted_set,
    maybe_fragment, maybe_fragment_sized, parse_announce_payload, FileTransferPayload,
    FragmentReassembler, MessageType, NoisePayloadType, Packet, PacketError, PeerId,
    SyncCandidate, SyncTypeFlags, BITCHAT_COMPAT_MAX_FRAGMENTS, DEFAULT_TTL,
    MAX_FILE_PAYLOAD_BYTES,
};
use rand::RngCore;
use std::collections::{HashMap, HashSet, VecDeque};
use thiserror::Error;
use web_time::{SystemTime, UNIX_EPOCH};

/// BitChat `GossipSyncManager.Config` defaults (public chat / media).
const GOSSIP_MESSAGE_CAPACITY: usize = 1000;
const GOSSIP_FRAGMENT_CAPACITY: usize = 600;
const GOSSIP_FILE_CAPACITY: usize = 200;
const GOSSIP_SHORT_AGE_MS: u64 = 900 * 1000; // 15 min (announces / fragments / files)
const GOSSIP_MESSAGE_MAX_AGE_MS: u64 = 900 * 1000; // BitChat publicMessageMaxAgeSeconds
const MAX_SYNC_REPLY_PACKETS: usize = 64;
const SYNC_RESPONSE_MAX: usize = 8;
const SYNC_RESPONSE_WINDOW_MS: u64 = 30_000;
const INITIAL_SYNC_DELAY_MS: u64 = 5_000;
const MESSAGE_SYNC_INTERVAL_MS: u64 = 15_000;
const FILE_SYNC_INTERVAL_MS: u64 = 60_000;

#[derive(Debug, Error)]
pub enum MeshError {
    #[error(transparent)]
    Packet(#[from] PacketError),
    #[error("invalid peer id: {0}")]
    PeerId(String),
    #[error("noise: {0}")]
    Noise(String),
    #[error("no noise session with {0}")]
    NoSession(String),
    #[error("noise session with {0} is not ready")]
    SessionNotReady(String),
    #[error("file transfer rejected: {0}")]
    File(String),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NoiseLinkState {
    None,
    Handshaking,
    Ready,
    Failed,
}

impl NoiseLinkState {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::None => "none",
            Self::Handshaking => "handshaking",
            Self::Ready => "ready",
            Self::Failed => "failed",
        }
    }
}

#[derive(Debug, Clone)]
pub struct MeshPeer {
    pub peer_id: String,
    pub nickname: String,
    pub last_seen_ms: u64,
    pub noise_public_key: Option<Vec<u8>>,
    pub signing_public_key: Option<Vec<u8>>,
    pub noise_state: NoiseLinkState,
}

#[derive(Debug, Clone)]
pub enum MeshEvent {
    PeerAnnounce { peer_id: String, nickname: String },
    PublicMessage {
        from_peer_id: String,
        text: String,
        timestamp_ms: u64,
    },
    PeerLeave { peer_id: String },
    NoiseState {
        peer_id: String,
        state: NoiseLinkState,
        detail: String,
    },
    PrivateMessage {
        from_peer_id: String,
        text: String,
        timestamp_ms: u64,
        message_id: String,
        is_local: bool,
    },
    /// BitChat `fileTransfer` (0x22) — photos/files on the mesh.
    FileTransfer {
        from_peer_id: String,
        file_name: String,
        mime_type: String,
        content: Vec<u8>,
        timestamp_ms: u64,
        is_private: bool,
        is_local: bool,
    },
    /// BitChat Noise `delivered` / `readReceipt` ack for a private message id.
    DeliveryAck {
        peer_id: String,
        message_id: String,
        /// `delivered` or `read`.
        kind: String,
    },
    /// QR / Noise verify completed for this peer (BitChat-compatible).
    PeerVerified {
        peer_id: String,
        nickname: String,
    },
}

#[derive(Debug, Clone)]
pub struct OutboundFrame {
    /// Empty = broadcast to all links; otherwise 16-char hex peer id hint.
    pub to_peer_id: Option<String>,
    pub bytes: Vec<u8>,
}

/// Stateful mesh logic (no BLE). Platform drains `drain_outbound` and feeds `ingest_frame`.
pub struct MeshController {
    identity: Identity,
    nickname: String,
    router: MeshRouter,
    fragments: FragmentReassembler,
    peers: HashMap<String, MeshPeer>,
    sessions: HashMap<String, NoiseSession>,
    outbound: VecDeque<OutboundFrame>,
    events: VecDeque<MeshEvent>,
    dm_counter: u32,
    /// Recent public chat packets for BitChat gossip sync (newest at back).
    gossip_messages: VecDeque<Packet>,
    gossip_fragments: VecDeque<Packet>,
    gossip_files: VecDeque<Packet>,
    /// Latest announce packet per peer (for sync replies).
    gossip_announces: HashMap<String, Packet>,
    /// Timestamps of REQUEST_SYNC responses sent to each peer (rate limit).
    sync_reply_times: HashMap<String, VecDeque<u64>>,
    /// Last REQUEST_SYNC we sent to a peer (dedupe join).
    sync_request_at: HashMap<String, u64>,
    /// Peer → announce-seen time; initial sync fires after INITIAL_SYNC_DELAY_MS.
    pending_initial_sync: HashMap<String, u64>,
    last_message_sync_ms: u64,
    last_file_sync_ms: u64,
    /// Last time we queued our own announce (avoid flooding before every photo).
    last_announce_ms: u64,
    /// BitChat-style: queue private texts until Noise transport is ready.
    /// Entries are `(message_id, text)`.
    pending_private_messages: HashMap<String, VecDeque<(String, String)>>,
    /// Ciphertext that arrived before transport was ready (msg3 / race).
    deferred_noise_encrypted: HashMap<String, VecDeque<Packet>>,
    /// Outbound QR verifications awaiting verifyResponse.
    pending_verifications: HashMap<String, PendingVerification>,
    /// Peer IDs successfully verified via QR challenge.
    verified_peers: HashSet<String>,
}

#[derive(Debug, Clone)]
struct PendingVerification {
    noise_key_hex: String,
    sign_key_hex: String,
    nonce: Vec<u8>,
    sent: bool,
}

impl MeshController {
    pub fn new(identity: Identity, nickname: String) -> Self {
        let router = MeshRouter::new(identity.peer_id());
        Self {
            identity,
            nickname,
            router,
            fragments: FragmentReassembler::new(128),
            peers: HashMap::new(),
            sessions: HashMap::new(),
            outbound: VecDeque::new(),
            events: VecDeque::new(),
            dm_counter: 0,
            gossip_messages: VecDeque::new(),
            gossip_fragments: VecDeque::new(),
            gossip_files: VecDeque::new(),
            gossip_announces: HashMap::new(),
            sync_reply_times: HashMap::new(),
            sync_request_at: HashMap::new(),
            pending_initial_sync: HashMap::new(),
            last_message_sync_ms: 0,
            last_file_sync_ms: 0,
            last_announce_ms: 0,
            pending_private_messages: HashMap::new(),
            deferred_noise_encrypted: HashMap::new(),
            pending_verifications: HashMap::new(),
            verified_peers: HashSet::new(),
        }
    }

    pub fn peer_id_hex(&self) -> String {
        self.identity.peer_id().to_hex()
    }

    pub fn nickname(&self) -> &str {
        &self.nickname
    }

    pub fn set_nickname(&mut self, nickname: String) {
        self.nickname = nickname;
    }

    pub fn set_link_count(&mut self, n: usize) {
        self.router.link_count = n;
    }

    pub fn peers(&self) -> Vec<MeshPeer> {
        let mut v: Vec<_> = self.peers.values().cloned().collect();
        v.sort_by(|a, b| a.nickname.cmp(&b.nickname));
        v
    }

    pub fn noise_state(&self, peer_id_hex: &str) -> NoiseLinkState {
        self.peers
            .get(peer_id_hex)
            .map(|p| p.noise_state)
            .unwrap_or(NoiseLinkState::None)
    }

    pub fn is_verified(&self, peer_id_hex: &str) -> bool {
        self.verified_peers.contains(peer_id_hex)
    }

    /// Start BitChat-style QR verification toward a known mesh peer (sends Noise challenge).
    pub fn start_qr_verification(&mut self, peer_id_hex: &str) -> Result<(), MeshError> {
        if self.verified_peers.contains(peer_id_hex) {
            return Ok(());
        }
        let (noise_hex, sign_hex) = {
            let peer = self
                .peers
                .get(peer_id_hex)
                .ok_or_else(|| MeshError::PeerId(format!("unknown peer {peer_id_hex}")))?;
            let noise = peer
                .noise_public_key
                .as_ref()
                .ok_or_else(|| MeshError::Noise("peer has no Noise key yet (wait for announce)".into()))?;
            let sign = peer
                .signing_public_key
                .as_ref()
                .ok_or_else(|| {
                    MeshError::Noise("peer has no signing key yet (wait for announce)".into())
                })?;
            (hex::encode(noise), hex::encode(sign))
        };

        if let Some(existing) = self.pending_verifications.get(peer_id_hex) {
            if existing.sent {
                return Ok(());
            }
        }

        let mut nonce = vec![0u8; 16];
        rand::thread_rng().fill_bytes(&mut nonce);
        let pending = PendingVerification {
            noise_key_hex: noise_hex.clone(),
            sign_key_hex: sign_hex,
            nonce: nonce.clone(),
            sent: false,
        };
        self.pending_verifications
            .insert(peer_id_hex.to_string(), pending);

        let ready = self
            .sessions
            .get(peer_id_hex)
            .map(|s| s.state() == SessionState::Transport)
            .unwrap_or(false);
        if ready {
            self.send_pending_verify_challenge(peer_id_hex)?;
        } else {
            let _ = self.start_noise_handshake(peer_id_hex);
        }
        Ok(())
    }

    fn send_pending_verify_challenge(&mut self, peer_id_hex: &str) -> Result<(), MeshError> {
        let Some(pending) = self.pending_verifications.get_mut(peer_id_hex) else {
            return Ok(());
        };
        if pending.sent {
            return Ok(());
        }
        let tlv = build_verify_challenge_tlv(&pending.noise_key_hex, &pending.nonce);
        pending.sent = true;
        self.queue_noise_payload(peer_id_hex, NoisePayloadType::VerifyChallenge, &tlv)
    }

    fn now_ms() -> u64 {
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_millis() as u64)
            .unwrap_or(0)
    }

    fn neighbor_ids(&self) -> Vec<PeerId> {
        self.peers
            .keys()
            .filter_map(|hex| PeerId::from_hex(hex).ok())
            .take(10)
            .collect()
    }

    /// Build and queue a signed BitChat announce TLV (keys + nickname + neighbors).
    pub fn queue_announce(&mut self) -> Result<(), MeshError> {
        let mut ts = Self::now_ms();
        // Monotonic per peer so a same-millisecond rename is not ignored as a tie.
        if let Some(prev) = self.gossip_announces.get(&self.peer_id_hex()) {
            if ts <= prev.timestamp {
                ts = prev.timestamp.saturating_add(1);
            }
        }
        let payload = encode_announce_tlv(
            &self.nickname,
            self.identity.noise_public_key(),
            self.identity.signing_public_key(),
            &self.neighbor_ids(),
        );
        let mut pkt = Packet::new(MessageType::Announce, self.identity.peer_id(), payload)
            .with_timestamp(ts)
            .with_ttl(DEFAULT_TTL);
        let signing = pkt.signing_bytes()?;
        pkt = pkt.with_signature(self.identity.sign(&signing));
        self.remember_gossip_announce(&pkt);
        self.enqueue_packet(pkt, None)?;
        self.last_announce_ms = ts;
        Ok(())
    }

    /// Announce at most once per 15s so a photo send does not starve BLE fragments.
    fn ensure_announce_fresh(&mut self) -> Result<(), MeshError> {
        let now = Self::now_ms();
        if now.saturating_sub(self.last_announce_ms) < 15_000 && self.last_announce_ms != 0 {
            return Ok(());
        }
        self.queue_announce()
    }

    pub fn queue_public_message(&mut self, text: &str) -> Result<(), MeshError> {
        let ts = Self::now_ms();
        let mut pkt = Packet::new(
            MessageType::Message,
            self.identity.peer_id(),
            text.as_bytes().to_vec(),
        )
        .with_timestamp(ts)
        .with_ttl(DEFAULT_TTL);
        let signing = pkt.signing_bytes()?;
        pkt = pkt.with_signature(self.identity.sign(&signing));
        self.remember_gossip_message(&pkt);
        self.enqueue_packet(pkt, None)?;
        self.events.push_back(MeshEvent::PublicMessage {
            from_peer_id: self.peer_id_hex(),
            text: text.to_string(),
            timestamp_ms: ts,
        });
        Ok(())
    }

    /// Ask peers for recent public messages (BitChat `requestSync` / join catch-up).
    pub fn queue_request_sync(&mut self, to_peer_id_hex: Option<&str>) -> Result<(), MeshError> {
        self.queue_request_sync_typed(to_peer_id_hex, SyncTypeFlags::join_catchup(), None)
    }

    /// Periodic / typed sync (BitChat `GossipSyncManager` schedules).
    pub fn maintain_gossip_sync(&mut self) -> Result<(), MeshError> {
        let now = Self::now_ms();

        let due: Vec<String> = self
            .pending_initial_sync
            .iter()
            .filter(|(_, t)| now.saturating_sub(**t) >= INITIAL_SYNC_DELAY_MS)
            .map(|(k, _)| k.clone())
            .collect();
        for peer in due {
            self.pending_initial_sync.remove(&peer);
            let _ = self.queue_request_sync_typed(
                Some(&peer),
                SyncTypeFlags::join_catchup(),
                None,
            );
        }

        if now.saturating_sub(self.last_message_sync_ms) >= MESSAGE_SYNC_INTERVAL_MS {
            self.last_message_sync_ms = now;
            let _ = self.queue_request_sync_typed(None, SyncTypeFlags::public_messages(), None);
        }
        // Skip periodic fragment-only rounds — they flood BLE and rarely recover
        // multi-hundred-fragment media. File-store sync re-sends whole transfers.
        if now.saturating_sub(self.last_file_sync_ms) >= FILE_SYNC_INTERVAL_MS {
            self.last_file_sync_ms = now;
            let _ = self.queue_request_sync_typed(None, SyncTypeFlags::file_transfer_only(), None);
        }
        Ok(())
    }

    fn queue_request_sync_typed(
        &mut self,
        to_peer_id_hex: Option<&str>,
        types: SyncTypeFlags,
        fragment_id_filter: Option<String>,
    ) -> Result<(), MeshError> {
        let now = Self::now_ms();
        let (candidates, cap) = self.collect_sync_candidates(types, now);
        let payload =
            build_request_sync_payload(&candidates, types, cap, fragment_id_filter);
        let body = encode_request_sync(&payload);

        let targets: Vec<PeerId> = match to_peer_id_hex {
            Some(hex) => {
                vec![PeerId::from_hex(hex).map_err(|e| MeshError::PeerId(e.to_string()))?]
            }
            None => self
                .peers
                .keys()
                .filter_map(|h| PeerId::from_hex(h).ok())
                .collect(),
        };
        if targets.is_empty() {
            return Ok(());
        }

        let ts = Self::now_ms();
        for remote in targets {
            let hex = remote.to_hex();
            self.sync_request_at.insert(hex.clone(), ts);
            let mut pkt = Packet::new(
                MessageType::RequestSync,
                self.identity.peer_id(),
                body.clone(),
            )
            .with_timestamp(ts)
            .with_ttl(0)
            .with_recipient(remote);
            let signing = pkt.signing_bytes()?;
            pkt = pkt.with_signature(self.identity.sign(&signing));
            self.enqueue_packet(pkt, Some(hex))?;
        }
        Ok(())
    }

    fn collect_sync_candidates(
        &self,
        types: SyncTypeFlags,
        now: u64,
    ) -> (Vec<SyncCandidate>, usize) {
        let mut candidates: Vec<(u64, [u8; 16])> = Vec::new();
        let cap = if types == SyncTypeFlags::fragment_only() {
            GOSSIP_FRAGMENT_CAPACITY
        } else if types == SyncTypeFlags::file_transfer_only() {
            GOSSIP_FILE_CAPACITY
        } else {
            GOSSIP_MESSAGE_CAPACITY
        };

        if types.contains_announce() {
            for pkt in self.gossip_announces.values() {
                if Self::is_gossip_fresh(pkt, now) {
                    candidates.push((pkt.timestamp, compute_packet_id(pkt)));
                }
            }
        }
        if types.contains_message() {
            for pkt in &self.gossip_messages {
                if Self::is_gossip_fresh(pkt, now) {
                    candidates.push((pkt.timestamp, compute_packet_id(pkt)));
                }
            }
        }
        if types.contains_fragment() {
            for pkt in &self.gossip_fragments {
                if Self::is_gossip_fresh(pkt, now) {
                    candidates.push((pkt.timestamp, compute_packet_id(pkt)));
                }
            }
        }
        if types.contains_file_transfer() {
            for pkt in &self.gossip_files {
                if Self::is_gossip_fresh(pkt, now) {
                    candidates.push((pkt.timestamp, compute_packet_id(pkt)));
                }
            }
        }

        // Newest first.
        candidates.sort_by(|a, b| b.0.cmp(&a.0));
        let out = candidates
            .into_iter()
            .map(|(timestamp, id)| SyncCandidate { id, timestamp })
            .collect();
        (out, cap)
    }

    pub fn queue_leave(&mut self) -> Result<(), MeshError> {
        let ts = Self::now_ms();
        let mut pkt = Packet::new(MessageType::Leave, self.identity.peer_id(), Vec::new())
            .with_timestamp(ts)
            .with_ttl(DEFAULT_TTL);
        let signing = pkt.signing_bytes()?;
        pkt = pkt.with_signature(self.identity.sign(&signing));
        self.enqueue_packet(pkt, None)?;
        Ok(())
    }

    /// Start a Noise XX handshake as initiator toward `peer_id_hex`.
    pub fn start_noise_handshake(&mut self, peer_id_hex: &str) -> Result<(), MeshError> {
        let remote = PeerId::from_hex(peer_id_hex).map_err(|e| MeshError::PeerId(e.to_string()))?;
        if peer_id_hex == self.peer_id_hex() {
            return Err(MeshError::PeerId("cannot handshake with self".into()));
        }
        if let Some(existing) = self.sessions.get(peer_id_hex) {
            if existing.state() == SessionState::Transport {
                self.set_peer_noise_state(peer_id_hex, NoiseLinkState::Ready, "already ready");
                self.flush_pending_private_messages(peer_id_hex);
                return Ok(());
            }
            if existing.state() == SessionState::Handshaking {
                return Ok(());
            }
        }

        let mut session = NoiseSession::start(&self.identity, HandshakeRole::Initiator, remote)
            .map_err(|e| MeshError::Noise(e.to_string()))?;
        let msg = session
            .write_handshake_message(&[])
            .map_err(|e| MeshError::Noise(e.to_string()))?;
        self.sessions.insert(peer_id_hex.to_string(), session);
        self.set_peer_noise_state(peer_id_hex, NoiseLinkState::Handshaking, "initiator sent msg1");
        self.enqueue_noise_handshake(remote, msg)?;
        Ok(())
    }

    /// Queue a BitChat `fileTransfer` (0x22) broadcast, or directed "private" file when
    /// `to_peer_id_hex` is set. Matches BitChat: signed v2 packet, content not Noise-wrapped.
    pub fn queue_file(
        &mut self,
        file_name: &str,
        mime_type: &str,
        content: Vec<u8>,
        to_peer_id_hex: Option<&str>,
    ) -> Result<(), MeshError> {
        if content.is_empty() {
            return Err(MeshError::File("empty file".into()));
        }
        if content.len() > MAX_FILE_PAYLOAD_BYTES {
            return Err(MeshError::File(format!(
                "file exceeds {MAX_FILE_PAYLOAD_BYTES} byte limit"
            )));
        }
        // BitChat rejects broadcast files unless it can verify our Ed25519
        // signature against the signing key from announce — keep identity fresh
        // without flooding announce on every photo.
        self.ensure_announce_fresh()?;

        let mime = offline_packet::normalize_mime(Some(mime_type), &content);
        let payload = FileTransferPayload::new(file_name, mime.clone(), content.clone());
        let encoded = encode_file_transfer(&payload)
            .ok_or_else(|| MeshError::File("failed to encode file TLV".into()))?;

        let recipient = match to_peer_id_hex {
            Some(hex) => {
                Some(PeerId::from_hex(hex).map_err(|e| MeshError::PeerId(e.to_string()))?)
            }
            None => None,
        };
        if let Some(r) = recipient {
            if r == self.identity.peer_id() {
                return Err(MeshError::PeerId("cannot send file to self".into()));
            }
        }

        let ts = Self::now_ms();
        let mut pkt = Packet::new(
            MessageType::FileTransfer,
            self.identity.peer_id(),
            encoded,
        )
        .with_timestamp(ts)
        .with_ttl(DEFAULT_TTL)
        .with_version(2);
        if let Some(r) = recipient {
            pkt = pkt.with_recipient(r);
        }
        let signing = pkt.signing_bytes()?;
        pkt = pkt.with_signature(self.identity.sign(&signing));
        if recipient.is_none() {
            self.remember_gossip_file(&pkt);
        }
        self.enqueue_packet(pkt, to_peer_id_hex.map(|s| s.to_string()))?;

        let is_private = recipient.is_some();
        self.events.push_back(MeshEvent::FileTransfer {
            from_peer_id: self.peer_id_hex(),
            file_name: file_name.to_string(),
            mime_type: mime,
            content,
            timestamp_ms: ts,
            is_private,
            is_local: true,
        });
        Ok(())
    }

    /// Encrypt and queue a BitChat private message. If Noise is not ready yet,
    /// queue the text and start a handshake (BitChat-style deferred send).
    pub fn queue_private_message(
        &mut self,
        peer_id_hex: &str,
        text: &str,
    ) -> Result<(), MeshError> {
        let _ = PeerId::from_hex(peer_id_hex).map_err(|e| MeshError::PeerId(e.to_string()))?;
        if peer_id_hex == self.peer_id_hex() {
            return Err(MeshError::PeerId("cannot DM self".into()));
        }
        if text.is_empty() {
            return Err(MeshError::Noise("empty private message".into()));
        }

        self.dm_counter = self.dm_counter.wrapping_add(1);
        let message_id = format!("{:016x}-{:04x}", Self::now_ms(), self.dm_counter);
        let ts = Self::now_ms();

        let ready = self
            .sessions
            .get(peer_id_hex)
            .map(|s| s.state() == SessionState::Transport)
            .unwrap_or(false);

        if !ready {
            self.pending_private_messages
                .entry(peer_id_hex.to_string())
                .or_default()
                .push_back((message_id.clone(), text.to_string()));
            let handshaking = self
                .sessions
                .get(peer_id_hex)
                .map(|s| s.state() == SessionState::Handshaking)
                .unwrap_or(false);
            if !handshaking {
                self.start_noise_handshake(peer_id_hex)?;
            }
            self.events.push_back(MeshEvent::PrivateMessage {
                from_peer_id: self.peer_id_hex(),
                text: text.to_string(),
                timestamp_ms: ts,
                message_id,
                is_local: true,
            });
            return Ok(());
        }

        self.encrypt_and_send_private(peer_id_hex, &message_id, text)?;
        self.events.push_back(MeshEvent::PrivateMessage {
            from_peer_id: self.peer_id_hex(),
            text: text.to_string(),
            timestamp_ms: ts,
            message_id,
            is_local: true,
        });
        Ok(())
    }

    fn encrypt_and_send_private(
        &mut self,
        peer_id_hex: &str,
        message_id: &str,
        text: &str,
    ) -> Result<(), MeshError> {
        let remote = PeerId::from_hex(peer_id_hex).map_err(|e| MeshError::PeerId(e.to_string()))?;
        let body = encode_private_message(message_id, text)
            .ok_or_else(|| MeshError::Noise("private message too long".into()))?;
        let mut plain = Vec::with_capacity(1 + body.len());
        plain.push(NoisePayloadType::PrivateMessage as u8);
        plain.extend_from_slice(&body);

        let ciphertext = {
            let session = self
                .sessions
                .get_mut(peer_id_hex)
                .ok_or_else(|| MeshError::NoSession(peer_id_hex.to_string()))?;
            session
                .encrypt(&plain)
                .map_err(|e| MeshError::Noise(e.to_string()))?
        };

        let pkt = Packet::new(
            MessageType::NoiseEncrypted,
            self.identity.peer_id(),
            ciphertext,
        )
        .with_timestamp(Self::now_ms())
        .with_ttl(DEFAULT_TTL)
        .with_recipient(remote);
        self.enqueue_packet(pkt, Some(peer_id_hex.to_string()))
    }

    fn flush_pending_private_messages(&mut self, peer_id_hex: &str) {
        let Some(queue) = self.pending_private_messages.remove(peer_id_hex) else {
            return;
        };
        let mut failed: VecDeque<(String, String)> = VecDeque::new();
        let mut skipping = false;
        for (message_id, text) in queue {
            if skipping {
                failed.push_back((message_id, text));
                continue;
            }
            if let Err(e) = self.encrypt_and_send_private(peer_id_hex, &message_id, &text) {
                let _ = e;
                failed.push_back((message_id, text));
                skipping = true;
            }
        }
        if !failed.is_empty() {
            self.pending_private_messages
                .insert(peer_id_hex.to_string(), failed);
        }
    }

    fn queue_noise_payload(
        &mut self,
        peer_id_hex: &str,
        ty: NoisePayloadType,
        body: &[u8],
    ) -> Result<(), MeshError> {
        let remote = PeerId::from_hex(peer_id_hex).map_err(|e| MeshError::PeerId(e.to_string()))?;
        let mut plain = Vec::with_capacity(1 + body.len());
        plain.push(ty as u8);
        plain.extend_from_slice(body);
        let ciphertext = {
            let session = self
                .sessions
                .get_mut(peer_id_hex)
                .ok_or_else(|| MeshError::NoSession(peer_id_hex.to_string()))?;
            if session.state() != SessionState::Transport {
                return Err(MeshError::SessionNotReady(peer_id_hex.to_string()));
            }
            session
                .encrypt(&plain)
                .map_err(|e| MeshError::Noise(e.to_string()))?
        };
        let pkt = Packet::new(
            MessageType::NoiseEncrypted,
            self.identity.peer_id(),
            ciphertext,
        )
        .with_timestamp(Self::now_ms())
        .with_ttl(DEFAULT_TTL)
        .with_recipient(remote);
        self.enqueue_packet(pkt, Some(peer_id_hex.to_string()))
    }

    fn enqueue_noise_handshake(
        &mut self,
        recipient: PeerId,
        payload: Vec<u8>,
    ) -> Result<(), MeshError> {
        let ts = Self::now_ms();
        let pkt = Packet::new(
            MessageType::NoiseHandshake,
            self.identity.peer_id(),
            payload,
        )
        .with_timestamp(ts)
        .with_ttl(DEFAULT_TTL)
        .with_recipient(recipient);
        self.enqueue_packet(pkt, Some(recipient.to_hex()))
    }

    fn enqueue_packet(&mut self, packet: Packet, to: Option<String>) -> Result<(), MeshError> {
        let pad = MessageType::from_u8(packet.packet_type)
            .map(|t| t.should_pad())
            .unwrap_or(false);
        let encoded = packet.encode(false)?;
        // Chrome Web Bluetooth rejects characteristic writes > 512 bytes.
        const BLE_WRITE_MAX: usize = 512;
        let mut frames = if encoded.len() > offline_packet::FRAGMENT_SIZE_THRESHOLD {
            maybe_fragment(&encoded, &packet)?
        } else if pad {
            let padded = packet.encode(true)?;
            // Noise padding can jump 512 → 1024; never emit that over BLE.
            if padded.len() <= BLE_WRITE_MAX {
                vec![padded]
            } else if encoded.len() <= BLE_WRITE_MAX {
                vec![encoded.clone()]
            } else {
                maybe_fragment(&encoded, &packet)?
            }
        } else {
            vec![encoded.clone()]
        };
        if frames.iter().any(|f| f.len() > BLE_WRITE_MAX) {
            frames = maybe_fragment_sized(&encoded, &packet, 400)?;
        }
        if frames.iter().any(|f| f.len() > BLE_WRITE_MAX) {
            return Err(MeshError::File(format!(
                "BLE frame exceeds {BLE_WRITE_MAX} bytes after fragmentation"
            )));
        }
        // BitChat Android rejects fragment trains above 256 (private media v1
        // contract). Refuse oversized mesh media instead of sending a train
        // that peers will never reassemble.
        if packet.packet_type == MessageType::FileTransfer as u8
            && frames.len() > BITCHAT_COMPAT_MAX_FRAGMENTS
        {
            return Err(MeshError::File(format!(
                "file needs {} fragments (BitChat limit {BITCHAT_COMPAT_MAX_FRAGMENTS}); shrink the photo/voice note",
                frames.len()
            )));
        }
        for bytes in frames {
            self.outbound.push_back(OutboundFrame {
                to_peer_id: to.clone(),
                bytes,
            });
        }
        let _ = self.router.is_duplicate(&packet);
        Ok(())
    }

    pub fn drain_outbound(&mut self) -> Vec<OutboundFrame> {
        self.outbound.drain(..).collect()
    }

    pub fn drain_events(&mut self) -> Vec<MeshEvent> {
        self.events.drain(..).collect()
    }

    /// Ingest one BLE frame. Returns frames to relay (already encoded).
    ///
    /// Malformed / non-BitChat notifications must not fail the whole session —
    /// BitChat drops bad frames silently; surfacing every decode glitch as
    /// `ingest error` hid real fileTransfer failures and broke the UI mid-transfer.
    pub fn ingest_frame(&mut self, bytes: &[u8]) -> Result<Vec<OutboundFrame>, MeshError> {
        let packet = match Packet::decode(bytes) {
            Ok(p) => p,
            Err(_) => return Ok(Vec::new()),
        };

        if packet.packet_type == MessageType::Fragment as u8 {
            if Self::is_broadcast_packet(&packet) {
                self.remember_gossip_fragment(&packet);
            }
            match self.fragments.ingest(&packet) {
                Some(assembled) => match self.ingest_frame(&assembled) {
                    Ok(frames) => return Ok(frames),
                    // Reassembled bytes that still fail decode (e.g. lost chunk
                    // corruption) — drop like BitChat, don't poison the session.
                    Err(_) => return Ok(Vec::new()),
                },
                None => return self.maybe_relay(&packet),
            }
        }

        let decision = self.router.decide(&packet);
        // BitChat never drops announces as duplicates for local handling —
        // nickname/key updates must always be applied (Android PR #502).
        let is_announce = packet.packet_type == MessageType::Announce as u8;
        if decision == RelayDecision::Drop && !is_announce {
            return Ok(Vec::new());
        }

        if decision != RelayDecision::Drop || is_announce {
            self.handle_local(&packet)?;
        }

        match decision {
            RelayDecision::Relay { new_ttl } => {
                let mut relay = packet.clone();
                relay.ttl = new_ttl;
                // Native BLE notifies can exceed Web Bluetooth's 512-byte write
                // cap. Route through enqueue_packet so oversize frames fragment
                // (and Noise padding never jumps to 1024 on the wire).
                match self.enqueue_packet(relay, None) {
                    Ok(()) => Ok(Vec::new()),
                    Err(_) => Ok(Vec::new()),
                }
            }
            RelayDecision::LocalOnly | RelayDecision::Drop => Ok(Vec::new()),
        }
    }

    fn maybe_relay(&mut self, packet: &Packet) -> Result<Vec<OutboundFrame>, MeshError> {
        let decision = self.router.decide(packet);
        match decision {
            RelayDecision::Relay { new_ttl } => {
                let mut relay = packet.clone();
                relay.ttl = new_ttl;
                let _ = self.enqueue_packet(relay, None);
                Ok(Vec::new())
            }
            _ => Ok(Vec::new()),
        }
    }

    fn handle_local(&mut self, packet: &Packet) -> Result<(), MeshError> {
        let from = packet.sender_id.to_hex();
        if from == self.peer_id_hex() {
            return Ok(());
        }
        let now = Self::now_ms();
        let for_us = packet
            .recipient_id
            .map(|r| r == self.identity.peer_id() || r.is_broadcast())
            .unwrap_or(true);

        match MessageType::from_u8(packet.packet_type) {
            Some(MessageType::Announce) => {
                self.handle_announce(packet, &from, now);
            }
            Some(MessageType::Message) => {
                let text = String::from_utf8_lossy(&packet.payload).to_string();
                self.touch_peer(&from, now, None, None, None);
                self.remember_gossip_message(packet);
                self.events.push_back(MeshEvent::PublicMessage {
                    from_peer_id: from,
                    text,
                    timestamp_ms: packet.timestamp,
                });
            }
            Some(MessageType::RequestSync) if for_us => {
                self.handle_request_sync(packet, &from)?;
            }
            Some(MessageType::FileTransfer) => {
                self.handle_file_transfer(packet, &from, now, for_us);
            }
            Some(MessageType::Leave) => {
                self.peers.remove(&from);
                self.sessions.remove(&from);
                self.events.push_back(MeshEvent::PeerLeave { peer_id: from });
            }
            Some(MessageType::NoiseHandshake) if for_us => {
                self.handle_noise_handshake(packet, &from)?;
            }
            Some(MessageType::NoiseEncrypted) if for_us => {
                self.handle_noise_encrypted(packet, &from)?;
            }
            _ => {}
        }
        Ok(())
    }

    fn handle_file_transfer(
        &mut self,
        packet: &Packet,
        from: &str,
        now: u64,
        for_us: bool,
    ) {
        let is_directed = packet
            .recipient_id
            .map(|r| !r.is_broadcast())
            .unwrap_or(false);
        if is_directed && !for_us {
            return;
        }
        let Some(file) = decode_file_transfer(&packet.payload) else {
            return;
        };
        // Prefer verifying broadcast signatures when we know the peer's signing key
        // (BitChat requires this for broadcast media).
        if !is_directed {
            if let (Some(sig), Some(peer)) = (packet.signature, self.peers.get(from)) {
                if let Some(spk) = peer.signing_public_key.as_ref() {
                    if spk.len() == 32 {
                        let mut key = [0u8; 32];
                        key.copy_from_slice(spk);
                        if let Ok(signing_bytes) = packet.signing_bytes() {
                            if Identity::verify(&key, &signing_bytes, &sig).is_err() {
                                return;
                            }
                        }
                    }
                }
            } else if packet.signature.is_none() {
                // BitChat drops unsigned broadcasts; mirror that once we care about spoofing.
                return;
            }
        }
        let mime = file
            .mime_type
            .unwrap_or_else(|| offline_packet::normalize_mime(None, &file.content));
        if !offline_packet::is_allowed_mime(&mime) {
            return;
        }
        // BitChat MimeType.matches — reject JPEG/WAV/etc. that fail magic checks.
        if !mime_magic_ok(&mime, &file.content) {
            return;
        }
        if Self::is_broadcast_packet(packet) {
            self.remember_gossip_file(packet);
        }
        self.touch_peer(from, now, None, None, None);
        self.events.push_back(MeshEvent::FileTransfer {
            from_peer_id: from.to_string(),
            file_name: file
                .file_name
                .unwrap_or_else(|| default_file_name_for_mime(&mime)),
            mime_type: mime,
            content: file.content,
            timestamp_ms: packet.timestamp,
            is_private: is_directed,
            is_local: false,
        });
    }

    fn handle_announce(&mut self, packet: &Packet, from: &str, now: u64) {
        let parsed = parse_announce_payload(&packet.payload);

        if let Some(npk) = parsed.noise_public_key {
            let derived = peer_id_from_noise_public(&npk);
            if derived != packet.sender_id {
                // Ignore announces whose Noise key does not bind to sender peer ID.
                return;
            }
        }

        // Ignore stale/replayed announces so gossip sync cannot roll a nickname
        // back after BitChat force-sends a rename. Require a strictly newer
        // timestamp (identical retransmits only refresh last-seen).
        if let Some(prev) = self.gossip_announces.get(from) {
            if packet.timestamp < prev.timestamp {
                return;
            }
            if packet.timestamp == prev.timestamp {
                if packet.payload == prev.payload {
                    self.touch_peer(from, now, None, None, None);
                }
                return;
            }
        }

        let existing = self.peers.get(from);
        let sig_ok = match (packet.signature, parsed.signing_public_key) {
            (Some(sig), Some(spk)) => match packet.signing_bytes() {
                Ok(bytes) => Identity::verify(&spk, &bytes, &sig).is_ok(),
                // If we cannot rebuild signing bytes, fall through to identity continuity.
                Err(_) => false,
            },
            // Unsigned announce: only accept when we have no prior crypto binding yet.
            (None, _) => existing.and_then(|p| p.noise_public_key.as_ref()).is_none(),
            _ => false,
        };

        if !sig_ok {
            // BitChat→Offline re-encode verify can fail when compression encodings
            // diverge. Still accept a nickname change when the Noise/signing keys
            // continue the already-trusted identity.
            let Some(prev) = existing else {
                return;
            };
            let Some(prev_noise) = prev.noise_public_key.as_ref() else {
                return;
            };
            let Some(announced_noise) = parsed.noise_public_key.as_ref() else {
                return;
            };
            if prev_noise.as_slice() != announced_noise.as_slice() {
                return;
            }
            if let (Some(prev_spk), Some(announced_spk)) =
                (prev.signing_public_key.as_ref(), parsed.signing_public_key.as_ref())
            {
                if prev_spk.as_slice() != announced_spk.as_slice() {
                    return;
                }
            }
        }

        let nickname = if parsed.nickname.is_empty() {
            from.to_string()
        } else {
            parsed.nickname.clone()
        };
        let noise_key = parsed.noise_public_key.map(|k| k.to_vec());
        let signing_key = parsed.signing_public_key.map(|k| k.to_vec());
        let nick_changed = existing
            .map(|p| p.nickname != nickname)
            .unwrap_or(true);
        self.touch_peer(from, now, Some(nickname.clone()), noise_key, signing_key);
        self.remember_gossip_announce(packet);
        if nick_changed {
            self.events.push_back(MeshEvent::PeerAnnounce {
                peer_id: from.to_string(),
                nickname,
            });
        }
        // BitChat scheduleInitialSyncToPeer — fire after ~5s via maintain_gossip_sync.
        self.pending_initial_sync
            .entry(from.to_string())
            .or_insert(now);
    }

    fn handle_request_sync(&mut self, packet: &Packet, from: &str) -> Result<(), MeshError> {
        let now = Self::now_ms();
        if !self.allow_sync_reply(from, now) {
            return Ok(());
        }
        let Some(req) = decode_request_sync(&packet.payload) else {
            return Ok(());
        };
        let types = req.types.unwrap_or_else(SyncTypeFlags::public_messages);
        let sorted = decode_to_sorted_set(req.p, req.m, &req.data);
        let might_contain = |id: &[u8; 16]| -> bool {
            let b = gcs_bucket(id, req.m);
            gcs_contains(&sorted, b)
        };
        let fragment_filter = decode_fragment_id_filter(req.fragment_id_filter.as_deref());

        let remote = PeerId::from_hex(from).map_err(|e| MeshError::PeerId(e.to_string()))?;
        let mut replies: Vec<Packet> = Vec::new();

        // Announces are exempt from the since-cursor (BitChat).
        if types.contains_announce() {
            for pkt in self.gossip_announces.values() {
                if replies.len() >= MAX_SYNC_REPLY_PACKETS {
                    break;
                }
                if !Self::is_gossip_fresh(pkt, now) {
                    continue;
                }
                let id = compute_packet_id(pkt);
                if might_contain(&id) {
                    continue;
                }
                replies.push(pkt.clone());
            }
        }

        if types.contains_message() {
            for pkt in self.gossip_messages.iter().rev() {
                if replies.len() >= MAX_SYNC_REPLY_PACKETS {
                    break;
                }
                if !Self::is_gossip_fresh(pkt, now) {
                    continue;
                }
                if let Some(since) = req.since_timestamp {
                    if pkt.timestamp < since {
                        continue;
                    }
                }
                let id = compute_packet_id(pkt);
                if might_contain(&id) {
                    continue;
                }
                replies.push(pkt.clone());
            }
        }

        if types.contains_fragment() {
            for pkt in self.gossip_fragments.iter().rev() {
                if replies.len() >= MAX_SYNC_REPLY_PACKETS {
                    break;
                }
                if !Self::is_gossip_fresh(pkt, now) {
                    continue;
                }
                if let Some(ref filter) = fragment_filter {
                    if pkt.payload.len() < 8 {
                        continue;
                    }
                    let mut stream = [0u8; 8];
                    stream.copy_from_slice(&pkt.payload[..8]);
                    if !filter.iter().any(|id| *id == stream) {
                        continue;
                    }
                } else if let Some(since) = req.since_timestamp {
                    if pkt.timestamp < since {
                        continue;
                    }
                }
                let id = compute_packet_id(pkt);
                if might_contain(&id) {
                    continue;
                }
                replies.push(pkt.clone());
            }
        }

        if types.contains_file_transfer() {
            for pkt in self.gossip_files.iter().rev() {
                if replies.len() >= MAX_SYNC_REPLY_PACKETS {
                    break;
                }
                if !Self::is_gossip_fresh(pkt, now) {
                    continue;
                }
                if let Some(since) = req.since_timestamp {
                    if pkt.timestamp < since {
                        continue;
                    }
                }
                let id = compute_packet_id(pkt);
                if might_contain(&id) {
                    continue;
                }
                replies.push(pkt.clone());
            }
        }

        for pkt in replies {
            self.enqueue_sync_reply(&pkt, remote)?;
        }
        Ok(())
    }

    fn allow_sync_reply(&mut self, peer: &str, now: u64) -> bool {
        let q = self
            .sync_reply_times
            .entry(peer.to_string())
            .or_default();
        while q
            .front()
            .is_some_and(|t| now.saturating_sub(*t) > SYNC_RESPONSE_WINDOW_MS)
        {
            q.pop_front();
        }
        if q.len() >= SYNC_RESPONSE_MAX {
            return false;
        }
        q.push_back(now);
        true
    }

    fn enqueue_sync_reply(&mut self, packet: &Packet, to: PeerId) -> Result<(), MeshError> {
        let mut reply = packet.clone();
        reply.ttl = 0;
        reply.is_rsr = true;
        self.enqueue_packet(reply, Some(to.to_hex()))
    }

    fn is_broadcast_packet(packet: &Packet) -> bool {
        packet
            .recipient_id
            .map(|r| r.is_broadcast())
            .unwrap_or(true)
    }

    fn remember_gossip_store(store: &mut VecDeque<Packet>, packet: &Packet, capacity: usize) {
        let id = compute_packet_id(packet);
        if store.iter().any(|p| compute_packet_id(p) == id) {
            return;
        }
        store.push_back(packet.clone());
        while store.len() > capacity {
            store.pop_front();
        }
    }

    fn remember_gossip_message(&mut self, packet: &Packet) {
        Self::remember_gossip_store(
            &mut self.gossip_messages,
            packet,
            GOSSIP_MESSAGE_CAPACITY,
        );
        let now = Self::now_ms();
        self.gossip_messages
            .retain(|p| Self::is_gossip_fresh(p, now));
    }

    fn remember_gossip_fragment(&mut self, packet: &Packet) {
        Self::remember_gossip_store(
            &mut self.gossip_fragments,
            packet,
            GOSSIP_FRAGMENT_CAPACITY,
        );
        let now = Self::now_ms();
        self.gossip_fragments
            .retain(|p| Self::is_gossip_fresh(p, now));
    }

    fn remember_gossip_file(&mut self, packet: &Packet) {
        Self::remember_gossip_store(&mut self.gossip_files, packet, GOSSIP_FILE_CAPACITY);
        let now = Self::now_ms();
        self.gossip_files.retain(|p| Self::is_gossip_fresh(p, now));
    }

    fn remember_gossip_announce(&mut self, packet: &Packet) {
        let key = packet.sender_id.to_hex();
        self.gossip_announces.insert(key, packet.clone());
    }

    fn is_gossip_fresh(packet: &Packet, now_ms: u64) -> bool {
        let max_age = match MessageType::from_u8(packet.packet_type) {
            Some(MessageType::Message) => GOSSIP_MESSAGE_MAX_AGE_MS,
            _ => GOSSIP_SHORT_AGE_MS,
        };
        if now_ms < max_age {
            return true;
        }
        packet.timestamp >= now_ms - max_age
    }

    fn handle_noise_handshake(&mut self, packet: &Packet, from: &str) -> Result<(), MeshError> {
        let remote = packet.sender_id;
        let mut reply: Option<Vec<u8>> = None;
        let mut became_ready = false;
        let mut fail_detail: Option<String> = None;

        // BitChat XX msg1 is a bare 32-byte ephemeral. Crossed initiations resolve
        // by peer-id order: the lexicographically smaller peer keeps initiator.
        const XX_MSG1_SIZE: usize = 32;
        let is_fresh_msg1 = packet.payload.len() == XX_MSG1_SIZE;
        if is_fresh_msg1 {
            if let Some(existing) = self.sessions.get(from) {
                if existing.state() == SessionState::Handshaking
                    && existing.role() == HandshakeRole::Initiator
                {
                    let ours = self.peer_id_hex();
                    if ours.as_str() < from {
                        // Keep our initiator role; ignore their crossed msg1.
                        return Ok(());
                    }
                    // Yield: drop our initiator and accept their initiation as responder.
                    self.sessions.remove(from);
                } else if existing.state() == SessionState::Transport {
                    // Peer restarted — accept a new handshake.
                    self.sessions.remove(from);
                } else if existing.state() == SessionState::Handshaking
                    && existing.role() == HandshakeRole::Responder
                {
                    // Fresh msg1 while we are already responding — reset responder.
                    self.sessions.remove(from);
                }
            }
        }

        if !self.sessions.contains_key(from) {
            match NoiseSession::start(&self.identity, HandshakeRole::Responder, remote) {
                Ok(session) => {
                    self.sessions.insert(from.to_string(), session);
                    self.set_peer_noise_state(from, NoiseLinkState::Handshaking, "responder created");
                }
                Err(e) => {
                    self.set_peer_noise_state(from, NoiseLinkState::Failed, &e.to_string());
                    return Ok(());
                }
            }
        }

        {
            let session = self.sessions.get_mut(from).unwrap();
            match session.read_handshake_message(&packet.payload) {
                Ok(_) => {
                    if session.state() == SessionState::Handshaking {
                        match session.write_handshake_message(&[]) {
                            Ok(msg) => reply = Some(msg),
                            Err(e) => fail_detail = Some(e.to_string()),
                        }
                    }
                    if session.state() == SessionState::Transport {
                        became_ready = true;
                    }
                }
                Err(e) => fail_detail = Some(e.to_string()),
            }
        }

        if let Some(detail) = fail_detail {
            self.sessions.remove(from);
            self.deferred_noise_encrypted.remove(from);
            self.set_peer_noise_state(from, NoiseLinkState::Failed, &detail);
            return Ok(());
        }

        if let Some(msg) = reply {
            self.enqueue_noise_handshake(remote, msg)?;
            // After writing our response, check if transport is ready (responder finishes on msg3 read).
            if self
                .sessions
                .get(from)
                .map(|s| s.state() == SessionState::Transport)
                .unwrap_or(false)
            {
                became_ready = true;
            } else {
                self.set_peer_noise_state(from, NoiseLinkState::Handshaking, "handshake in progress");
            }
        }

        if became_ready {
            self.set_peer_noise_state(from, NoiseLinkState::Ready, "transport ready");
            self.flush_pending_private_messages(from);
            let _ = self.send_pending_verify_challenge(from);
            self.drain_deferred_noise_encrypted(from)?;
        }
        Ok(())
    }

    fn defer_noise_encrypted(&mut self, from: &str, packet: &Packet) {
        const MAX_DEFERRED: usize = 4;
        let q = self
            .deferred_noise_encrypted
            .entry(from.to_string())
            .or_default();
        if q.len() >= MAX_DEFERRED {
            return;
        }
        q.push_back(packet.clone());
    }

    fn drain_deferred_noise_encrypted(&mut self, from: &str) -> Result<(), MeshError> {
        let Some(q) = self.deferred_noise_encrypted.remove(from) else {
            return Ok(());
        };
        for pkt in q {
            self.handle_noise_encrypted(&pkt, from)?;
        }
        Ok(())
    }

    fn handle_noise_encrypted(&mut self, packet: &Packet, from: &str) -> Result<(), MeshError> {
        let ready = self
            .sessions
            .get(from)
            .map(|s| s.state() == SessionState::Transport)
            .unwrap_or(false);
        if !ready {
            self.defer_noise_encrypted(from, packet);
            if !self.sessions.contains_key(from) {
                let _ = self.start_noise_handshake(from);
            }
            return Ok(());
        }

        let plain = {
            let session = self.sessions.get_mut(from).expect("ready session");
            match session.decrypt(&packet.payload) {
                Ok(p) => p,
                // BitChat: forged / replayed / truncated ciphertext must not
                // tear down a working session — drop the packet only.
                Err(_) => return Ok(()),
            }
        };
        if plain.is_empty() {
            return Ok(());
        }
        let payload_type = NoisePayloadType::from_u8(plain[0]);
        let body = &plain[1..];
        match payload_type {
            Some(NoisePayloadType::PrivateMessage) => {
                let Some(pm) = decode_private_message(body) else {
                    return Ok(());
                };
                self.touch_peer(from, Self::now_ms(), None, None, None);
                let message_id = pm.message_id.clone();
                self.events.push_back(MeshEvent::PrivateMessage {
                    from_peer_id: from.to_string(),
                    text: pm.content,
                    timestamp_ms: packet.timestamp,
                    message_id: message_id.clone(),
                    is_local: false,
                });
                // BitChat sends Noise `delivered` (0x03) with the message id as body.
                let _ = self.queue_noise_payload(
                    from,
                    NoisePayloadType::Delivered,
                    message_id.as_bytes(),
                );
            }
            Some(NoisePayloadType::PrivateFile) => {
                let Some(file) = decode_file_transfer(body) else {
                    return Ok(());
                };
                if file.content.is_empty() || file.content.len() > MAX_FILE_PAYLOAD_BYTES {
                    return Ok(());
                }
                let mime = file
                    .mime_type
                    .unwrap_or_else(|| offline_packet::normalize_mime(None, &file.content));
                if !mime_magic_ok(&mime, &file.content) {
                    return Ok(());
                }
                self.touch_peer(from, Self::now_ms(), None, None, None);
                self.events.push_back(MeshEvent::FileTransfer {
                    from_peer_id: from.to_string(),
                    file_name: file
                        .file_name
                        .unwrap_or_else(|| default_file_name_for_mime(&mime)),
                    mime_type: mime,
                    content: file.content,
                    timestamp_ms: packet.timestamp,
                    is_private: true,
                    is_local: false,
                });
            }
            Some(NoisePayloadType::Delivered) => {
                let message_id = String::from_utf8_lossy(body).to_string();
                if !message_id.is_empty() {
                    self.events.push_back(MeshEvent::DeliveryAck {
                        peer_id: from.to_string(),
                        message_id,
                        kind: "delivered".into(),
                    });
                }
            }
            Some(NoisePayloadType::ReadReceipt) => {
                let message_id = String::from_utf8_lossy(body).to_string();
                if !message_id.is_empty() {
                    self.events.push_back(MeshEvent::DeliveryAck {
                        peer_id: from.to_string(),
                        message_id,
                        kind: "read".into(),
                    });
                }
            }
            Some(NoisePayloadType::VerifyChallenge) => {
                // BitChat QR verify: prove possession of the Noise key in the QR.
                let Some((noise_hex, nonce)) = parse_verify_challenge(body) else {
                    return Ok(());
                };
                let my_hex = hex::encode(self.identity.noise_public_key());
                if !noise_hex.eq_ignore_ascii_case(&my_hex) {
                    return Ok(());
                }
                let tlv = build_verify_response_tlv(&self.identity, &noise_hex, &nonce);
                let _ = self.queue_noise_payload(from, NoisePayloadType::VerifyResponse, &tlv);
            }
            Some(NoisePayloadType::VerifyResponse) => {
                let Some((noise_hex, nonce, sig)) = parse_verify_response(body) else {
                    return Ok(());
                };
                let Some(pending) = self.pending_verifications.get(from).cloned() else {
                    return Ok(());
                };
                if !noise_hex.eq_ignore_ascii_case(&pending.noise_key_hex)
                    || nonce != pending.nonce
                {
                    return Ok(());
                }
                if verify_response_signature(
                    &noise_hex,
                    &nonce,
                    &sig,
                    &pending.sign_key_hex,
                )
                .is_err()
                {
                    return Ok(());
                }
                self.pending_verifications.remove(from);
                self.verified_peers.insert(from.to_string());
                let nickname = self
                    .peers
                    .get(from)
                    .map(|p| p.nickname.clone())
                    .unwrap_or_else(|| from.to_string());
                self.events.push_back(MeshEvent::PeerVerified {
                    peer_id: from.to_string(),
                    nickname,
                });
            }
            _ => {}
        }
        Ok(())
    }

    fn touch_peer(
        &mut self,
        peer_id: &str,
        now: u64,
        nickname: Option<String>,
        noise_public_key: Option<Vec<u8>>,
        signing_public_key: Option<Vec<u8>>,
    ) {
        let entry = self.peers.entry(peer_id.to_string()).or_insert_with(|| MeshPeer {
            peer_id: peer_id.to_string(),
            nickname: peer_id.to_string(),
            last_seen_ms: now,
            noise_public_key: None,
            signing_public_key: None,
            noise_state: NoiseLinkState::None,
        });
        entry.last_seen_ms = now;
        if let Some(n) = nickname {
            entry.nickname = n;
        }
        if let Some(k) = noise_public_key {
            entry.noise_public_key = Some(k);
        }
        if let Some(k) = signing_public_key {
            entry.signing_public_key = Some(k);
        }
        if let Some(session) = self.sessions.get(peer_id) {
            entry.noise_state = match session.state() {
                SessionState::Transport => NoiseLinkState::Ready,
                SessionState::Handshaking => NoiseLinkState::Handshaking,
            };
        }
    }

    fn set_peer_noise_state(&mut self, peer_id: &str, state: NoiseLinkState, detail: &str) {
        self.touch_peer(peer_id, Self::now_ms(), None, None, None);
        if let Some(p) = self.peers.get_mut(peer_id) {
            p.noise_state = state;
        }
        self.events.push_back(MeshEvent::NoiseState {
            peer_id: peer_id.to_string(),
            state,
            detail: detail.to_string(),
        });
    }

    pub fn peer_id_bytes(&self) -> [u8; 8] {
        *self.identity.peer_id().as_bytes()
    }
}

fn default_file_name_for_mime(mime: &str) -> String {
    match mime {
        "image/jpeg" => "photo.jpg".into(),
        "image/png" => "photo.png".into(),
        "image/gif" => "photo.gif".into(),
        "image/webp" => "photo.webp".into(),
        "audio/mp4" | "audio/m4a" | "audio/aac" => "voice.m4a".into(),
        "audio/wav" => "voice.wav".into(),
        "audio/ogg" => "voice.ogg".into(),
        "audio/mpeg" | "audio/mp3" => "voice.mp3".into(),
        "application/pdf" => "file.pdf".into(),
        _ => "file.bin".into(),
    }
}

/// BitChat `MimeType.matches` — content magic must agree with declared MIME.
fn mime_magic_ok(mime: &str, content: &[u8]) -> bool {
    match mime {
        "image/jpeg" => {
            content.len() >= 3 && content[0] == 0xFF && content[1] == 0xD8 && content[2] == 0xFF
        }
        "image/png" => {
            content.len() >= 8
                && content[0] == 0x89
                && content[1] == b'P'
                && content[2] == b'N'
                && content[3] == b'G'
                && content[4] == 0x0D
                && content[5] == 0x0A
                && content[6] == 0x1A
                && content[7] == 0x0A
        }
        "image/gif" => {
            content.len() >= 6
                && (&content[0..6] == b"GIF87a" || &content[0..6] == b"GIF89a")
        }
        "image/webp" => {
            content.len() >= 12 && &content[0..4] == b"RIFF" && &content[8..12] == b"WEBP"
        }
        "audio/wav" => {
            content.len() >= 12 && &content[0..4] == b"RIFF" && &content[8..12] == b"WAVE"
        }
        "audio/ogg" => content.len() >= 4 && &content[0..4] == b"OggS",
        "application/pdf" => content.len() >= 4 && &content[0..4] == b"%PDF",
        // BitChat MimeType.matches: AAC/MP4 containers are size-lenient.
        "audio/mp4" | "audio/m4a" | "audio/aac" => content.len() > 100,
        "audio/mpeg" | "audio/mp3" => {
            content.len() >= 3
                && ((content[0] == 0x49 && content[1] == 0x44 && content[2] == 0x33)
                    || (content[0] == 0xFF && (content[1] & 0xE0) == 0xE0))
        }
        "application/octet-stream" => !content.is_empty(),
        _ => true,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use offline_noise::Identity;

    #[test]
    fn announce_tlv_and_message_flow() {
        let mut a = MeshController::new(Identity::generate(), "alice".into());
        let mut b = MeshController::new(Identity::generate(), "bob".into());

        a.queue_announce().unwrap();
        for f in a.drain_outbound() {
            let _ = b.ingest_frame(&f.bytes).unwrap();
        }
        let ev = b.drain_events();
        assert!(ev.iter().any(|e| matches!(e, MeshEvent::PeerAnnounce { nickname, .. } if nickname == "alice")));
        let peer = b.peers().into_iter().find(|p| p.nickname == "alice").unwrap();
        assert!(peer.noise_public_key.is_some());
        assert!(peer.signing_public_key.is_some());

        a.queue_public_message("hello mesh").unwrap();
        let _ = a.drain_events();
        for f in a.drain_outbound() {
            let _ = b.ingest_frame(&f.bytes).unwrap();
        }
        let ev = b.drain_events();
        assert!(ev.iter().any(|e| matches!(
            e,
            MeshEvent::PublicMessage { text, .. } if text == "hello mesh"
        )));
    }

    #[test]
    fn noise_dm_end_to_end() {
        let mut a = MeshController::new(Identity::generate(), "alice".into());
        let mut b = MeshController::new(Identity::generate(), "bob".into());
        a.set_link_count(1);
        b.set_link_count(1);

        a.queue_announce().unwrap();
        b.queue_announce().unwrap();
        for f in a.drain_outbound() {
            let _ = b.ingest_frame(&f.bytes).unwrap();
        }
        for f in b.drain_outbound() {
            let _ = a.ingest_frame(&f.bytes).unwrap();
        }
        let _ = a.drain_events();
        let _ = b.drain_events();

        let bob_id = b.peer_id_hex();
        a.start_noise_handshake(&bob_id).unwrap();

        // Exchange handshake frames until both ready (XX = 3 messages).
        for _ in 0..6 {
            let a_out = a.drain_outbound();
            for f in a_out {
                let relay = b.ingest_frame(&f.bytes).unwrap();
                for r in relay {
                    let _ = a.ingest_frame(&r.bytes).unwrap();
                }
            }
            let b_out = b.drain_outbound();
            for f in b_out {
                let relay = a.ingest_frame(&f.bytes).unwrap();
                for r in relay {
                    let _ = b.ingest_frame(&r.bytes).unwrap();
                }
            }
            if a.noise_state(&bob_id) == NoiseLinkState::Ready
                && b.noise_state(&a.peer_id_hex()) == NoiseLinkState::Ready
            {
                break;
            }
        }
        assert_eq!(a.noise_state(&bob_id), NoiseLinkState::Ready);
        assert_eq!(b.noise_state(&a.peer_id_hex()), NoiseLinkState::Ready);

        a.queue_private_message(&bob_id, "secret hi").unwrap();
        let _ = a.drain_events();
        for f in a.drain_outbound() {
            let _ = b.ingest_frame(&f.bytes).unwrap();
        }
        let ev = b.drain_events();
        assert!(ev.iter().any(|e| matches!(
            e,
            MeshEvent::PrivateMessage { text, is_local: false, .. } if text == "secret hi"
        )));

        // BitChat: receiver emits Noise `delivered` for the message id.
        let delivered = b.drain_outbound();
        assert!(!delivered.is_empty());
        for f in delivered {
            let _ = a.ingest_frame(&f.bytes).unwrap();
        }
        let ack = a.drain_events();
        assert!(ack.iter().any(|e| matches!(
            e,
            MeshEvent::DeliveryAck { kind, .. } if kind == "delivered"
        )));
    }

    #[test]
    fn private_message_queues_until_noise_ready() {
        let mut a = MeshController::new(Identity::generate(), "alice".into());
        let mut b = MeshController::new(Identity::generate(), "bob".into());
        a.set_link_count(1);
        b.set_link_count(1);

        a.queue_announce().unwrap();
        b.queue_announce().unwrap();
        for f in a.drain_outbound() {
            let _ = b.ingest_frame(&f.bytes).unwrap();
        }
        for f in b.drain_outbound() {
            let _ = a.ingest_frame(&f.bytes).unwrap();
        }
        let _ = a.drain_events();
        let _ = b.drain_events();

        let bob_id = b.peer_id_hex();
        // Queue DM before handshake — should start Noise and hold the message.
        a.queue_private_message(&bob_id, "queued dm").unwrap();
        assert_eq!(a.noise_state(&bob_id), NoiseLinkState::Handshaking);
        let local = a.drain_events();
        assert!(local.iter().any(|e| matches!(
            e,
            MeshEvent::PrivateMessage { text, is_local: true, .. } if text == "queued dm"
        )));

        for _ in 0..8 {
            let a_out = a.drain_outbound();
            for f in a_out {
                let relay = b.ingest_frame(&f.bytes).unwrap();
                for r in relay {
                    let _ = a.ingest_frame(&r.bytes).unwrap();
                }
            }
            let b_out = b.drain_outbound();
            for f in b_out {
                let relay = a.ingest_frame(&f.bytes).unwrap();
                for r in relay {
                    let _ = b.ingest_frame(&r.bytes).unwrap();
                }
            }
            if a.noise_state(&bob_id) == NoiseLinkState::Ready
                && b.noise_state(&a.peer_id_hex()) == NoiseLinkState::Ready
            {
                break;
            }
        }
        assert_eq!(a.noise_state(&bob_id), NoiseLinkState::Ready);

        // After ready, pending DM should have been flushed onto the wire.
        for f in a.drain_outbound() {
            let _ = b.ingest_frame(&f.bytes).unwrap();
        }
        let ev = b.drain_events();
        assert!(ev.iter().any(|e| matches!(
            e,
            MeshEvent::PrivateMessage { text, is_local: false, .. } if text == "queued dm"
        )));
    }

    #[test]
    fn file_transfer_broadcast_and_directed() {
        let mut a = MeshController::new(Identity::generate(), "alice".into());
        let mut b = MeshController::new(Identity::generate(), "bob".into());
        a.set_link_count(1);
        b.set_link_count(1);

        a.queue_announce().unwrap();
        for f in a.drain_outbound() {
            let _ = b.ingest_frame(&f.bytes).unwrap();
        }
        let _ = b.drain_events();

        let jpeg = vec![0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3, 4, 5];
        a.queue_file("pic.jpg", "image/jpeg", jpeg.clone(), None)
            .unwrap();
        let _ = a.drain_events();
        for f in a.drain_outbound() {
            let _ = b.ingest_frame(&f.bytes).unwrap();
        }
        let ev = b.drain_events();
        assert!(ev.iter().any(|e| matches!(
            e,
            MeshEvent::FileTransfer {
                file_name,
                mime_type,
                content,
                is_private: false,
                is_local: false,
                ..
            } if file_name == "pic.jpg" && mime_type == "image/jpeg" && content == &jpeg
        )));

        let bob = b.peer_id_hex();
        let png = vec![
            0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3, 4,
        ];
        a.queue_file("secret.png", "image/png", png, Some(&bob))
            .unwrap();
        let _ = a.drain_events();
        for f in a.drain_outbound() {
            let _ = b.ingest_frame(&f.bytes).unwrap();
        }
        let ev = b.drain_events();
        assert!(ev.iter().any(|e| matches!(
            e,
            MeshEvent::FileTransfer {
                file_name,
                is_private: true,
                is_local: false,
                ..
            } if file_name == "secret.png"
        )));
    }

    #[test]
    fn wav_voice_note_roundtrip_uses_raw_deflate() {
        // BitChat compresses WAV with Apple raw DEFLATE — must survive Offline ingest.
        let mut a = MeshController::new(Identity::generate(), "alice".into());
        let mut b = MeshController::new(Identity::generate(), "bob".into());
        a.set_link_count(1);
        b.set_link_count(1);

        a.queue_announce().unwrap();
        for f in a.drain_outbound() {
            let _ = b.ingest_frame(&f.bytes).unwrap();
        }
        let _ = b.drain_events();

        let mut wav = b"RIFF".to_vec();
        wav.extend_from_slice(&(2048u32).to_le_bytes());
        wav.extend_from_slice(b"WAVE");
        wav.extend(std::iter::repeat_n(0u8, 8_000));
        a.queue_file("voice_test.wav", "audio/wav", wav.clone(), None)
            .unwrap();
        let _ = a.drain_events();
        for f in a.drain_outbound() {
            // Must not surface as Err (was "ingest error" with zlib wrapper).
            b.ingest_frame(&f.bytes).unwrap();
        }
        let ev = b.drain_events();
        assert!(ev.iter().any(|e| matches!(
            e,
            MeshEvent::FileTransfer {
                mime_type,
                content,
                is_local: false,
                ..
            } if mime_type == "audio/wav" && content == &wav
        )));
    }

    #[test]
    fn public_message_preserves_emoji_utf8() {
        let mut a = MeshController::new(Identity::generate(), "alice".into());
        let mut b = MeshController::new(Identity::generate(), "bob".into());
        a.set_link_count(1);
        b.set_link_count(1);

        a.queue_announce().unwrap();
        for f in a.drain_outbound() {
            let _ = b.ingest_frame(&f.bytes).unwrap();
        }
        let _ = b.drain_events();

        let msg = "hello 👋 🔥 ❤️";
        a.queue_public_message(msg).unwrap();
        let _ = a.drain_events();
        for f in a.drain_outbound() {
            b.ingest_frame(&f.bytes).unwrap();
        }
        let ev = b.drain_events();
        assert!(ev.iter().any(|e| matches!(
            e,
            MeshEvent::PublicMessage { text, .. } if text == msg
        )));
    }

    #[test]
    fn bitchat_aac_voice_note_audio_mp4_roundtrip() {
        // BitChat iOS/Android voice notes: AAC-in-M4A, MIME audio/mp4, file voice_*.m4a.
        let mut a = MeshController::new(Identity::generate(), "alice".into());
        let mut b = MeshController::new(Identity::generate(), "bob".into());
        a.set_link_count(1);
        b.set_link_count(1);

        a.queue_announce().unwrap();
        for f in a.drain_outbound() {
            let _ = b.ingest_frame(&f.bytes).unwrap();
        }
        let _ = b.drain_events();

        // Minimal ftyp-bearing payload (>100 B — BitChat MimeType.matches).
        let mut m4a = vec![0u8; 128];
        m4a[4..8].copy_from_slice(b"ftyp");
        m4a[8..12].copy_from_slice(b"M4A ");
        a.queue_file(
            "voice_20260801_120000_aabbccdd.m4a",
            "audio/mp4",
            m4a.clone(),
            None,
        )
        .unwrap();
        let _ = a.drain_events();
        for f in a.drain_outbound() {
            b.ingest_frame(&f.bytes).unwrap();
        }
        let ev = b.drain_events();
        assert!(ev.iter().any(|e| matches!(
            e,
            MeshEvent::FileTransfer {
                mime_type,
                content,
                file_name,
                is_local: false,
                ..
            } if mime_type == "audio/mp4"
                && content == &m4a
                && file_name.starts_with("voice_")
        )));
    }

    #[test]
    fn garbage_ble_frame_is_soft_dropped() {
        let mut a = MeshController::new(Identity::generate(), "alice".into());
        assert!(a.ingest_frame(&[0x00, 0x01, 0x02]).unwrap().is_empty());
        assert!(a.ingest_frame(&[]).unwrap().is_empty());
    }

    #[test]
    fn large_photo_fragments_and_reassembles() {
        let mut a = MeshController::new(Identity::generate(), "alice".into());
        let mut b = MeshController::new(Identity::generate(), "bob".into());
        a.set_link_count(1);
        b.set_link_count(1);

        a.queue_announce().unwrap();
        for f in a.drain_outbound() {
            let _ = b.ingest_frame(&f.bytes).unwrap();
        }
        let _ = b.drain_events();

        // ~40 KiB JPEG-like — under BitChat's 256-fragment private-media ceiling.
        let mut jpeg = vec![0xFF, 0xD8, 0xFF, 0xE0];
        for i in 0..40_000 {
            let x = (i as u32)
                .wrapping_mul(0x9E3779B9)
                .wrapping_add(0xA5A5A5A5 ^ (i as u32).rotate_left(5));
            jpeg.push(((x >> 16) ^ (x >> 8) ^ x ^ ((i >> 3) as u32)) as u8);
        }
        a.queue_file("big.jpg", "image/jpeg", jpeg.clone(), None)
            .unwrap();
        let _ = a.drain_events();
        let frames = a.drain_outbound();
        // Announce may also be in the drain; count fragments only.
        let frag_count = frames
            .iter()
            .filter(|f| f.bytes.len() > 1 && f.bytes[1] == 0x20)
            .count();
        assert!(
            frag_count > 10 && frag_count <= BITCHAT_COMPAT_MAX_FRAGMENTS,
            "expected BitChat-compatible fragment train, got {} (total frames {})",
            frag_count,
            frames.len()
        );
        for f in frames {
            let _ = b.ingest_frame(&f.bytes).unwrap();
        }
        let ev = b.drain_events();
        assert!(ev.iter().any(|e| matches!(
            e,
            MeshEvent::FileTransfer {
                file_name,
                content,
                is_local: false,
                ..
            } if file_name == "big.jpg" && content.len() == jpeg.len()
        )));
    }

    #[test]
    fn request_sync_catches_up_public_messages() {
        let mut a = MeshController::new(Identity::generate(), "alice".into());
        let mut b = MeshController::new(Identity::generate(), "bob".into());
        a.set_link_count(1);
        b.set_link_count(1);

        a.queue_public_message("hello channel").unwrap();
        a.queue_public_message("second").unwrap();
        let _ = a.drain_events();
        let _ = a.drain_outbound(); // drop live flood — bob was not on the mesh yet

        a.queue_announce().unwrap();
        for f in a.drain_outbound() {
            let _ = b.ingest_frame(&f.bytes).unwrap();
        }
        let _ = b.drain_events();

        // Explicit join catch-up (BitChat also delays ~5s via maintain).
        b.queue_request_sync(Some(&a.peer_id_hex())).unwrap();
        for f in b.drain_outbound() {
            let _ = a.ingest_frame(&f.bytes).unwrap();
        }
        for f in a.drain_outbound() {
            let _ = b.ingest_frame(&f.bytes).unwrap();
        }
        let ev = b.drain_events();
        assert!(
            ev.iter().any(|e| matches!(
                e,
                MeshEvent::PublicMessage { text, .. } if text == "hello channel"
            )),
            "expected catch-up message, got {ev:?}"
        );
        assert!(ev.iter().any(|e| matches!(
            e,
            MeshEvent::PublicMessage { text, .. } if text == "second"
        )));
    }

    #[test]
    fn announce_nickname_change_updates_peer() {
        let mut a = MeshController::new(Identity::generate(), "alice".into());
        let mut b = MeshController::new(Identity::generate(), "bob".into());
        a.set_link_count(3);
        b.set_link_count(3);

        a.queue_announce().unwrap();
        for f in a.drain_outbound() {
            let _ = b.ingest_frame(&f.bytes).unwrap();
        }
        let _ = b.drain_events();
        assert_eq!(
            b.peers()
                .into_iter()
                .find(|p| p.peer_id == a.peer_id_hex())
                .unwrap()
                .nickname,
            "alice"
        );

        a.set_nickname("alice-renamed".into());
        a.queue_announce().unwrap();
        for f in a.drain_outbound() {
            let _ = b.ingest_frame(&f.bytes).unwrap();
        }
        let ev = b.drain_events();
        assert!(
            ev.iter().any(|e| matches!(
                e,
                MeshEvent::PeerAnnounce { nickname, .. } if nickname == "alice-renamed"
            )),
            "expected PeerAnnounce with new nick, got: {ev:?}"
        );
        assert_eq!(
            b.peers()
                .into_iter()
                .find(|p| p.peer_id == a.peer_id_hex())
                .unwrap()
                .nickname,
            "alice-renamed"
        );
    }

    #[test]
    fn older_announce_does_not_roll_back_nickname() {
        let mut a = MeshController::new(Identity::generate(), "alice".into());
        let mut b = MeshController::new(Identity::generate(), "bob".into());

        a.queue_announce().unwrap();
        let old_frames = a.drain_outbound();
        for f in &old_frames {
            let _ = b.ingest_frame(&f.bytes).unwrap();
        }
        let _ = b.drain_events();

        a.set_nickname("renamed".into());
        a.queue_announce().unwrap();
        for f in a.drain_outbound() {
            let _ = b.ingest_frame(&f.bytes).unwrap();
        }
        let _ = b.drain_events();
        assert_eq!(
            b.peers()
                .into_iter()
                .find(|p| p.peer_id == a.peer_id_hex())
                .unwrap()
                .nickname,
            "renamed"
        );

        // Re-inject the older announce (gossip catch-up).
        for f in &old_frames {
            let _ = b.ingest_frame(&f.bytes).unwrap();
        }
        assert_eq!(
            b.peers()
                .into_iter()
                .find(|p| p.peer_id == a.peer_id_hex())
                .unwrap()
                .nickname,
            "renamed",
            "stale announce must not overwrite newer nickname"
        );
    }
    #[test]
    fn voice_outbound_frames_fit_ble_512() {
        let mut a = MeshController::new(Identity::generate(), "alice".into());
        // ~10s 8kHz mono PCM (incompressible) so zlib does not collapse size.
        let mut pcm = vec![0u8; 44 + 80_000];
        pcm[0..4].copy_from_slice(b"RIFF");
        pcm[8..12].copy_from_slice(b"WAVE");
        for i in 44..pcm.len() {
            pcm[i] = (i % 251) as u8;
        }
        a.queue_file("voice.wav", "audio/wav", pcm, None).unwrap();
        let frames = a.drain_outbound();
        let max = frames.iter().map(|f| f.bytes.len()).max().unwrap_or(0);
        let over: Vec<_> = frames
            .iter()
            .enumerate()
            .filter(|(_, f)| f.bytes.len() > 512)
            .map(|(i, f)| (i, f.bytes.len(), f.bytes.get(1).copied()))
            .collect();
        eprintln!("voice frames={} max={} over={over:?}", frames.len(), max);
        assert!(max <= 512, "max frame {max} > 512; over={over:?}");
    }
}
