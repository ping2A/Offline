//! Luby transform fountain codes for one-way optical (QR) transfer.
//!
//! Port of decimen-optical-transfer `shared/fountain.ts` + `protocol.ts`,
//! including the deterministic `dlog` so encoder/decoder stay bit-identical
//! across platforms.

mod protocol;
mod soliton;

pub use protocol::{
    fnv1a, pack_frame, parse_frame, FrameHeader, HEADER_LEN, MAGIC0, MAGIC1,
    MAX_OPTICAL_BLOCK_LEN, MAX_OPTICAL_BYTES, MAX_OPTICAL_K,
};
pub use soliton::{LTDecoder, LTEncoder};

use thiserror::Error;

#[derive(Debug, Error, PartialEq, Eq)]
pub enum FountainError {
    #[error("invalid frame")]
    InvalidFrame,
    #[error("transfer incomplete")]
    Incomplete,
    #[error("payload hash mismatch")]
    HashMismatch,
}
