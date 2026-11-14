//! Narrow, metadata-only authenticated qualification policy. No crypto implementation.
pub const FRAME_CAP: usize = 256 * 1024;

fn u16_at(bytes: &[u8], offset: usize) -> Result<u16, ()> {
    Ok(u16::from_le_bytes(bytes.get(offset..offset + 2).ok_or(())?.try_into().map_err(|_| ())?))
}
fn u32_at(bytes: &[u8], offset: usize) -> Result<u32, ()> {
    Ok(u32::from_le_bytes(bytes.get(offset..offset + 4).ok_or(())?.try_into().map_err(|_| ())?))
}

/// Validate raw extents before the library allocates/parses selected contexts.
/// Return whether the one offered cipher (AES-128-GCM) was selected.
pub fn negotiate_response(raw: &[u8], encryption_required: bool) -> Result<bool, ()> {
    if !(128..=FRAME_CAP).contains(&raw.len()) || !raw.starts_with(b"\xfeSMB")
        || u16_at(raw, 64)? != 65 || u16_at(raw, 68)? != 0x0311
        || u16_at(raw, 66)? & 1 == 0 || u16_at(raw, 66)? & !3 != 0
        || u32_at(raw, 20)? != 0 { return Err(()); }
    let count = u16_at(raw, 70)? as usize;
    let security_start = u16_at(raw, 120)? as usize;
    let security_len = u16_at(raw, 122)? as usize;
    // The pinned parser consumes the security buffer immediately after its
    // fixed structure. Refuse a different extent instead of reinterpreting it.
    if security_len != 0 && security_start != 128 { return Err(()); }
    let security_end = 128usize.checked_add(security_len).ok_or(())?;
    let mut position = u32_at(raw, 124)? as usize;
    if count == 0 || count > 16 || security_end > raw.len()
        || position < security_end || position % 8 != 0 { return Err(()); }
    let mut preauth = false;
    let mut encryption = None;
    let mut signing = false;
    for index in 0..count {
        if position % 8 != 0 { return Err(()); }
        let kind = u16_at(raw, position)?;
        let length = u16_at(raw, position + 2)? as usize;
        if u32_at(raw, position + 4)? != 0 { return Err(()); }
        let start = position.checked_add(8).ok_or(())?;
        let end = start.checked_add(length).ok_or(())?;
        let data = raw.get(start..end).ok_or(())?;
        match kind {
            1 => {
                if preauth || length < 6 || u16_at(data, 0)? != 1 || u16_at(data, 4)? != 1
                    || length != 6 + u16_at(data, 2)? as usize { return Err(()); }
                preauth = true;
            }
            2 => {
                if encryption.is_some() || length != 4 || u16_at(data, 0)? != 1 { return Err(()); }
                encryption = Some(match u16_at(data, 2)? { 2 => true, 0 => false, _ => return Err(()) });
            }
            8 => {
                if signing || length != 4 || u16_at(data, 0)? != 1 || u16_at(data, 2)? != 1 { return Err(()); }
                signing = true;
            }
            3 => return Err(()), // Compression was not offered.
            _ => {}, // Structurally bounded unknown contexts do not change policy.
        }
        if index + 1 < count { position = end.checked_add(7).ok_or(())? & !7; }
        else if raw.len() > (end.checked_add(7).ok_or(())? & !7) { return Err(()); }
    }
    if !preauth || (encryption_required && encryption != Some(true)) { return Err(()); }
    // No signing context is the specified CMAC default, not a downgrade.
    Ok(encryption == Some(true))
}

/// Check the entire authenticated transform header before invoking AEAD.
pub fn transform(raw: &[u8], session: u64) -> Result<usize, ()> {
    if !(116..=FRAME_CAP).contains(&raw.len()) || !raw.starts_with(b"\xfdSMB")
        || session == 0 || u16_at(raw, 40)? != 0 || u16_at(raw, 42)? != 1
        || raw[32..36] != [0; 4]
        || u64::from_le_bytes(raw[44..52].try_into().map_err(|_| ())?) != session { return Err(()); }
    let length = u32_at(raw, 36)? as usize;
    if length != raw.len() - 52 { return Err(()); }
    Ok(length)
}

/// Plain responses cannot become nested transforms or hidden compounds.
pub fn response(raw: &[u8]) -> Result<(), ()> {
    if !(64..=FRAME_CAP).contains(&raw.len()) || !raw.starts_with(b"\xfeSMB")
        || u16_at(raw, 4)? != 64 || u32_at(raw, 16)? & 1 == 0
        || u32_at(raw, 20)? != 0 { return Err(()); }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    fn context(kind: u16, data: &[u8]) -> Vec<u8> {
        let mut bytes = vec![];
        bytes.extend(kind.to_le_bytes()); bytes.extend((data.len() as u16).to_le_bytes());
        bytes.extend([0; 4]); bytes.extend(data); bytes
    }
    fn negotiate(contexts: Vec<Vec<u8>>) -> Vec<u8> {
        let mut bytes = vec![0; 128]; bytes[..4].copy_from_slice(b"\xfeSMB");
        bytes[64..66].copy_from_slice(&65u16.to_le_bytes()); bytes[66] = 3;
        bytes[68..70].copy_from_slice(&0x0311u16.to_le_bytes());
        bytes[70..72].copy_from_slice(&(contexts.len() as u16).to_le_bytes());
        bytes[124..128].copy_from_slice(&128u32.to_le_bytes());
        for ctx in contexts { while bytes.len() % 8 != 0 { bytes.push(0); } bytes.extend(ctx); }
        bytes
    }
    fn preauth() -> Vec<u8> { context(1, &[1, 0, 2, 0, 1, 0, 42, 43]) }
    fn gcm() -> Vec<u8> { context(2, &[1, 0, 2, 0]) }
    #[test]
    fn bounded_selections_and_legitimate_absent_cmac_context() {
        for contexts in [vec![preauth(), gcm()], vec![preauth(), gcm(), context(8, &[1, 0, 1, 0])],
            vec![preauth(), context(0x101, &[42]), gcm()]] {
            assert_eq!(negotiate_response(&negotiate(contexts), true), Ok(true));
        }
        assert_eq!(negotiate_response(&negotiate(vec![preauth()]), false), Ok(false));
        assert!(negotiate_response(&negotiate(vec![preauth()]), true).is_err());
        assert!(negotiate_response(&negotiate(vec![preauth(), context(2, &[1, 0, 0, 0])]), true).is_err());
    }
    #[test]
    fn context_count_algorithm_salt_duplicates_and_extents_refuse() {
        for contexts in [vec![gcm()], vec![preauth(), preauth(), gcm()], vec![preauth(), gcm(), gcm()],
            vec![preauth(), gcm(), context(8, &[1, 0, 1, 0]), context(8, &[1, 0, 1, 0])],
            vec![preauth(), context(2, &[1, 0, 1, 0])], vec![preauth(), gcm(), context(8, &[1, 0, 2, 0])],
            vec![context(1, &[2, 0, 0, 0, 1, 0, 1, 0]), gcm()],
            vec![context(1, &[1, 0, 3, 0, 1, 0, 42]), gcm()],
            vec![preauth(), context(2, &[2, 0, 2, 0, 2, 0])],
            vec![preauth(), gcm(), context(3, &[0; 8])]] {
            assert!(negotiate_response(&negotiate(contexts), true).is_err());
        }
        let good = negotiate(vec![preauth(), gcm()]);
        for (offset, bytes) in [(68, vec![2, 3]), (124, 120u32.to_le_bytes().to_vec()),
            (124, 129u32.to_le_bytes().to_vec()), (70, vec![17, 0]), (138, vec![0xff, 0xff]) ] {
            let mut bad = good.clone(); bad[offset..offset + bytes.len()].copy_from_slice(&bytes);
            assert!(negotiate_response(&bad, true).is_err());
        }
        for length in 0..good.len() { assert!(negotiate_response(&good[..length], true).is_err()); }
    }
    #[test]
    fn authenticated_transform_extents_and_session_are_exact() {
        let mut bytes = vec![0; 116]; bytes[..4].copy_from_slice(b"\xfdSMB"); bytes[42] = 1;
        bytes[44..52].copy_from_slice(&42u64.to_le_bytes()); bytes[36..40].copy_from_slice(&64u32.to_le_bytes());
        assert_eq!(transform(&bytes, 42), Ok(64));
        assert!(transform(&bytes, 43).is_err()); assert!(transform(&bytes, 0).is_err());
        for offset in [0, 32, 36, 40, 42, 44] {
            let mut bad = bytes.clone(); bad[offset] ^= 1; assert!(transform(&bad, 42).is_err());
        }
        for length in 0..116 { assert!(transform(&bytes[..length], 42).is_err()); }
        assert!(transform(&vec![0; FRAME_CAP + 1], 42).is_err());
    }
    #[test]
    fn decoded_response_cannot_nest_transform_or_compound() {
        let mut bytes = vec![0; 64]; bytes[..4].copy_from_slice(b"\xfeSMB"); bytes[4] = 64; bytes[16] = 1;
        assert!(response(&bytes).is_ok());
        for offset in [0, 4, 16, 20] { let mut bad = bytes.clone(); bad[offset] ^= 1; assert!(response(&bad).is_err()); }
    }
}
