//! BitChat live PTT `VoiceBurstPacket` (public `0x29` / Noise inner `0x08`).

/// AAC-LC 16 kHz mono — sole v1 codec.
pub const VOICE_CODEC_AAC_LC_16KHZ_MONO: u8 = 0x01;
/// Max encoded `VoiceBurstPacket` size (keeps Noise+BLE under one frame).
pub const VOICE_BURST_MAX_BYTES: usize = 210;

#[repr(u8)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum VoiceBurstFlags {
    Data = 0x00,
    Start = 0x01,
    End = 0x02,
    Canceled = 0x04,
}

impl VoiceBurstFlags {
    pub fn from_u8(v: u8) -> Option<Self> {
        Some(match v {
            0x00 => Self::Data,
            0x01 => Self::Start,
            0x02 => Self::End,
            0x04 => Self::Canceled,
            _ => return None,
        })
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum VoiceBurstPayload {
    Start { codec: u8 },
    Data { frames: Vec<Vec<u8>> },
    End {
        total_data_packets: u16,
        duration_ms: u32,
    },
    Canceled,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct VoiceBurstPacket {
    pub burst_id: [u8; 8],
    pub sequence: u16,
    pub payload: VoiceBurstPayload,
}

impl VoiceBurstPacket {
    pub fn flags(&self) -> VoiceBurstFlags {
        match self.payload {
            VoiceBurstPayload::Data { .. } => VoiceBurstFlags::Data,
            VoiceBurstPayload::Start { .. } => VoiceBurstFlags::Start,
            VoiceBurstPayload::End { .. } => VoiceBurstFlags::End,
            VoiceBurstPayload::Canceled => VoiceBurstFlags::Canceled,
        }
    }

    pub fn encode(&self) -> Option<Vec<u8>> {
        let mut out = Vec::with_capacity(32);
        out.extend_from_slice(&self.burst_id);
        out.extend_from_slice(&self.sequence.to_be_bytes());
        out.push(self.flags() as u8);
        match &self.payload {
            VoiceBurstPayload::Start { codec } => out.push(*codec),
            VoiceBurstPayload::Data { frames } => {
                if frames.is_empty() || frames.len() > 8 {
                    return None;
                }
                for frame in frames {
                    if frame.is_empty() || frame.len() > u16::MAX as usize {
                        return None;
                    }
                    out.extend_from_slice(&(frame.len() as u16).to_be_bytes());
                    out.extend_from_slice(frame);
                }
            }
            VoiceBurstPayload::End {
                total_data_packets,
                duration_ms,
            } => {
                out.extend_from_slice(&total_data_packets.to_be_bytes());
                out.extend_from_slice(&duration_ms.to_be_bytes());
            }
            VoiceBurstPayload::Canceled => {}
        }
        if out.len() > VOICE_BURST_MAX_BYTES {
            return None;
        }
        Some(out)
    }

    pub fn decode(data: &[u8]) -> Option<Self> {
        if data.len() < 11 {
            return None;
        }
        let mut burst_id = [0u8; 8];
        burst_id.copy_from_slice(&data[..8]);
        let sequence = u16::from_be_bytes([data[8], data[9]]);
        let flags = VoiceBurstFlags::from_u8(data[10])?;
        let rest = &data[11..];
        let payload = match flags {
            VoiceBurstFlags::Start => {
                if rest.len() != 1 {
                    return None;
                }
                VoiceBurstPayload::Start { codec: rest[0] }
            }
            VoiceBurstFlags::Data => {
                let mut frames = Vec::new();
                let mut off = 0;
                while off < rest.len() {
                    if off + 2 > rest.len() {
                        return None;
                    }
                    let len = u16::from_be_bytes([rest[off], rest[off + 1]]) as usize;
                    off += 2;
                    if len == 0 || off + len > rest.len() {
                        return None;
                    }
                    frames.push(rest[off..off + len].to_vec());
                    off += len;
                    if frames.len() > 8 {
                        return None;
                    }
                }
                if frames.is_empty() {
                    return None;
                }
                VoiceBurstPayload::Data { frames }
            }
            VoiceBurstFlags::End => {
                if rest.len() != 6 {
                    return None;
                }
                VoiceBurstPayload::End {
                    total_data_packets: u16::from_be_bytes([rest[0], rest[1]]),
                    duration_ms: u32::from_be_bytes([rest[2], rest[3], rest[4], rest[5]]),
                }
            }
            VoiceBurstFlags::Canceled => {
                if !rest.is_empty() {
                    return None;
                }
                VoiceBurstPayload::Canceled
            }
        };
        Some(Self {
            burst_id,
            sequence,
            payload,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn golden_vectors_from_live_voice_v1() {
        // START
        let start = VoiceBurstPacket {
            burst_id: [1, 2, 3, 4, 5, 6, 7, 8],
            sequence: 0,
            payload: VoiceBurstPayload::Start {
                codec: VOICE_CODEC_AAC_LC_16KHZ_MONO,
            },
        };
        assert_eq!(
            start.encode().unwrap(),
            hex::decode("010203040506070800000101").unwrap()
        );

        // Data: one 3-byte frame
        let data = VoiceBurstPacket {
            burst_id: [1, 2, 3, 4, 5, 6, 7, 8],
            sequence: 1,
            payload: VoiceBurstPayload::Data {
                frames: vec![vec![0xDE, 0xAD, 0xBE]],
            },
        };
        assert_eq!(
            data.encode().unwrap(),
            hex::decode("01020304050607080001000003deadbe").unwrap()
        );

        // END
        let end = VoiceBurstPacket {
            burst_id: [1, 2, 3, 4, 5, 6, 7, 8],
            sequence: 42,
            payload: VoiceBurstPayload::End {
                total_data_packets: 41,
                duration_ms: 2688,
            },
        };
        assert_eq!(
            end.encode().unwrap(),
            hex::decode("0102030405060708002a02002900000a80").unwrap()
        );

        // CANCELED
        let canceled = VoiceBurstPacket {
            burst_id: [1, 2, 3, 4, 5, 6, 7, 8],
            sequence: 3,
            payload: VoiceBurstPayload::Canceled,
        };
        assert_eq!(
            canceled.encode().unwrap(),
            hex::decode("0102030405060708000304").unwrap()
        );

        assert_eq!(VoiceBurstPacket::decode(&start.encode().unwrap()), Some(start));
        assert_eq!(VoiceBurstPacket::decode(&data.encode().unwrap()), Some(data));
        assert_eq!(VoiceBurstPacket::decode(&end.encode().unwrap()), Some(end));
        assert_eq!(
            VoiceBurstPacket::decode(&canceled.encode().unwrap()),
            Some(canceled)
        );
    }
}
