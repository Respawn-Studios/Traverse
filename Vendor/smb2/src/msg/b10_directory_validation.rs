//! B10 experimental prevalidation for MS-FSCC directory classes 3 and 37.
//! Padding/reserved bytes are ignored; only structural boundaries confer data.

#[derive(Debug, PartialEq, Eq)]
pub enum Failure { Class, ReplySize, Header, Chain, NameLength, Encoding, Numeric, Trailing }

/// Validate without allocating strings or records, before the upstream decoder.
pub fn validate(data: &[u8], fixed: usize) -> Result<usize, Failure> {
    if fixed != 94 && fixed != 104 { return Err(Failure::Class); }
    if data.is_empty() || data.len() > 64 * 1024 { return Err(Failure::ReplySize); }
    let mut offset = 0usize;
    let mut count = 0usize;
    loop {
        let remaining = data.get(offset..).ok_or(Failure::Chain)?;
        if remaining.len() < fixed { return Err(Failure::Header); }
        let next = u32::from_le_bytes(remaining[0..4].try_into().unwrap()) as usize;
        let name_len = u32::from_le_bytes(remaining[60..64].try_into().unwrap()) as usize;
        if name_len == 0 || name_len > 4096 || name_len % 2 != 0 {
            return Err(Failure::NameLength);
        }
        let name_end = fixed.checked_add(name_len).ok_or(Failure::NameLength)?;
        let name = remaining.get(fixed..name_end).ok_or(Failure::NameLength)?;
        let short_len = remaining[68] as usize;
        if short_len > 24 || short_len % 2 != 0 { return Err(Failure::NameLength); }
        let mut utf8_bytes = 0usize;
        for value in char::decode_utf16(name.chunks_exact(2).map(|pair| u16::from_le_bytes([pair[0], pair[1]]))) {
            let value = value.map_err(|_| Failure::Encoding)?;
            if value == '\0' { return Err(Failure::Encoding); }
            utf8_bytes += value.len_utf8();
            if utf8_bytes > 4096 { return Err(Failure::NameLength); }
        }
        // Four FILETIME fields and the two signed size fields cannot be negative.
        for start in [8, 16, 24, 32, 40, 48] {
            if i64::from_le_bytes(remaining[start..start + 8].try_into().unwrap()) < 0 {
                return Err(Failure::Numeric);
            }
        }
        count += 1;
        if next == 0 {
            // Some servers pad the last record to eight bytes. Ignore its value,
            // as the specification requires, but refuse another unexplained tail.
            let aligned = name_end.checked_add(7).ok_or(Failure::Trailing)? & !7;
            if remaining.len() != name_end && remaining.len() != aligned {
                return Err(Failure::Trailing);
            }
            return Ok(count);
        }
        if next % 8 != 0 || next < name_end { return Err(Failure::Chain); }
        let following = offset.checked_add(next).ok_or(Failure::Chain)?;
        if following.checked_add(fixed).ok_or(Failure::Chain)? > data.len() {
            return Err(Failure::Chain);
        }
        offset = following;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn record(fixed: usize, name: &str) -> Vec<u8> {
        let bytes: Vec<_> = name.encode_utf16().flat_map(u16::to_le_bytes).collect();
        let mut result = vec![0; fixed];
        result[40..48].copy_from_slice(&123u64.to_le_bytes());
        result[60..64].copy_from_slice(&(bytes.len() as u32).to_le_bytes());
        result.extend(bytes);
        result
    }

    #[test]
    fn both_classes_accept_exact_names_padding_and_ignore_reserved_values() {
        for fixed in [94, 104] {
            for name in ["One", "Café 文件.txt", "Cafe\u{301} 文件.txt", ".", "..", "🦀"] {
                let first = record(fixed, name);
                assert_eq!(validate(&first, fixed), Ok(1));
                let mut padded = first.clone(); padded.resize((padded.len() + 7) & !7, 0xf7);
                assert_eq!(validate(&padded, fixed), Ok(1));
                let second = record(fixed, "Two");
                let next = padded.len() as u32;
                padded[..4].copy_from_slice(&next.to_le_bytes());
                padded[69] = 0xff; // Reserved: receivers must ignore it.
                if fixed == 104 { padded[94..96].copy_from_slice(&[0xff, 0xff]); }
                padded.extend(second);
                assert_eq!(validate(&padded, fixed), Ok(2));
            }
        }
    }

    #[test]
    fn fixed_header_chain_name_and_reply_limits_refuse() {
        for fixed in [94, 104] {
            for length in 0..fixed { assert!(validate(&vec![0; length], fixed).is_err()); }
            let original = record(fixed, "One");
            for next in [1u32, (fixed as u32) - 2, 96, 104, 128, u32::MAX] {
                let mut broken = original.clone(); broken[..4].copy_from_slice(&next.to_le_bytes());
                assert!(validate(&broken, fixed).is_err());
            }
            for length in [0u32, 1, 5, 4098, u32::MAX] {
                let mut broken = original.clone(); broken[60..64].copy_from_slice(&length.to_le_bytes());
                assert!(validate(&broken, fixed).is_err());
            }
            let mut trailing = original.clone(); trailing.extend([0; 32]);
            assert_eq!(validate(&trailing, fixed), Err(Failure::Trailing));
            let mut invalid = record(fixed, "a"); invalid[fixed..].copy_from_slice(&0xd800u16.to_le_bytes());
            assert_eq!(validate(&invalid, fixed), Err(Failure::Encoding));
            let mut negative = original; negative[47] = 0x80;
            assert_eq!(validate(&negative, fixed), Err(Failure::Numeric));
            assert!(validate(&record(fixed, &"a".repeat(2049)), fixed).is_err());
            assert_eq!(validate(&vec![0; 65537], fixed), Err(Failure::ReplySize));
        }
    }

    #[test]
    fn deterministic_mutations_never_panic_and_only_preserve_bounded_records() {
        let mut seed = 0x62a7_095du32;
        for fixed in [94, 104] {
            for _ in 0..10_000 {
                seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5;
                let mut bytes = record(fixed, "Generated");
                let position = (seed as usize) % bytes.len();
                bytes[position] ^= (seed >> 8) as u8;
                if let Ok(count) = validate(&bytes, fixed) { assert_eq!(count, 1); }
            }
        }
    }
}
