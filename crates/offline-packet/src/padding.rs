//! PKCS#7-style message padding matching BitChat `MessagePadding`.

pub const BLOCK_SIZES: [usize; 4] = [256, 512, 1024, 2048];

pub struct MessagePadding;

impl MessagePadding {
    pub fn pad(data: &[u8], target_size: usize) -> Vec<u8> {
        if data.len() >= target_size {
            return data.to_vec();
        }
        let padding_needed = target_size - data.len();
        if padding_needed == 0 || padding_needed > 255 {
            return data.to_vec();
        }
        let mut padded = data.to_vec();
        padded.extend(std::iter::repeat_n(padding_needed as u8, padding_needed));
        padded
    }

    pub fn unpad(data: &[u8]) -> Vec<u8> {
        if data.is_empty() {
            return data.to_vec();
        }
        let last = *data.last().unwrap();
        let padding_length = last as usize;
        if padding_length == 0 || padding_length > data.len() {
            return data.to_vec();
        }
        let start = data.len() - padding_length;
        if data[start..].iter().any(|&b| b != last) {
            return data.to_vec();
        }
        data[..start].to_vec()
    }

    pub fn optimal_block_size(data_size: usize) -> usize {
        let total_size = data_size + 16;
        for &block_size in &BLOCK_SIZES {
            if total_size <= block_size {
                return block_size;
            }
        }
        data_size
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pad_unpad_roundtrip() {
        let data = vec![1, 2, 3, 4];
        let padded = MessagePadding::pad(&data, 16);
        assert_eq!(padded.len(), 16);
        assert_eq!(MessagePadding::unpad(&padded), data);
    }
}
