//! Optical (QR) fountain transfer API.

use offline_core::{OpticalReceiver, OpticalSender};
use offline_fountain::fnv1a;
use rand::RngCore;
use std::sync::Mutex;

/// Outbound QR stream.
pub struct OpticalSendSession {
    inner: Mutex<OpticalSender>,
    session_id: u16,
    block_len: u16,
    total_len: u32,
    payload_fnv: u32,
}

/// Inbound QR reassembly.
pub struct OpticalReceiveSession {
    inner: Mutex<OpticalReceiver>,
}

pub struct OpticalProgress {
    pub frames_collected: u64,
    pub frames_target: u64,
    pub complete_payload: Option<Vec<u8>>,
}

#[flutter_rust_bridge::frb(sync)]
pub fn optical_start_send(payload: Vec<u8>, block_len: u16) -> OpticalSendSession {
    let block_len = if block_len == 0 { 200 } else { block_len };
    let session_id = (rand::thread_rng().next_u32() & 0xffff) as u16;
    let payload_fnv = fnv1a(&payload);
    let total_len = payload.len() as u32;
    let sender = OpticalSender::start(&payload, block_len, session_id);
    OpticalSendSession {
        inner: Mutex::new(sender),
        session_id,
        block_len,
        total_len,
        payload_fnv,
    }
}

impl OpticalSendSession {
    /// Next self-describing frame (header + fountain block) to encode as a QR.
    #[flutter_rust_bridge::frb(sync)]
    pub fn next_frame(&self) -> Vec<u8> {
        self.inner.lock().expect("optical sender").next_frame()
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn session_id(&self) -> u16 {
        self.session_id
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn block_len(&self) -> u16 {
        self.block_len
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn total_len(&self) -> u32 {
        self.total_len
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn payload_fnv(&self) -> u32 {
        self.payload_fnv
    }
}

#[flutter_rust_bridge::frb(sync)]
pub fn optical_start_receive() -> OpticalReceiveSession {
    OpticalReceiveSession {
        inner: Mutex::new(OpticalReceiver::new()),
    }
}

impl OpticalReceiveSession {
    /// Feed one decoded QR binary payload. Returns progress + file when complete.
    #[flutter_rust_bridge::frb(sync)]
    pub fn ingest_frame(&self, frame: Vec<u8>) -> Result<OpticalProgress, String> {
        let mut rx = self.inner.lock().expect("optical receiver");
        let complete = rx.ingest(&frame).map_err(|e| e.to_string())?;
        let (collected, target) = rx.progress_hint();
        Ok(OpticalProgress {
            frames_collected: collected as u64,
            frames_target: target as u64,
            complete_payload: complete,
        })
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn frames_collected(&self) -> u64 {
        self.inner.lock().expect("optical receiver").frames_collected() as u64
    }
}

/// Default fountain block size (bytes inside each QR frame after the 20-byte header).
#[flutter_rust_bridge::frb(sync)]
pub fn optical_default_block_len() -> u16 {
    200
}
