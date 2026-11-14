//! Generated-only experiment admission. Not a product provider interface.

pub const FRAME_CAP: usize = 256 * 1024;
pub const QUERY_CAP: u32 = 64 * 1024;
pub const NAME_CAP: usize = 4096;

/// Validate the actual outgoing command before it reaches the socket.
pub fn permitted_frame(data: &[u8]) -> bool {
    if !(64..=FRAME_CAP).contains(&data.len()) || !data.starts_with(b"\xfeSMB") {
        return false;
    }
    if u32::from_le_bytes(data[20..24].try_into().unwrap()) != 0 {
        return false; // No compounds hide another command in this experiment.
    }
    let command = u16::from_le_bytes(data[12..14].try_into().unwrap());
    match command {
        0..=4 | 6 | 12 | 13 => true, // negotiate, guest, logoff, tree, close/cancel/echo
        5 => {
            if data.len() < 120 { return false; }
            let body = &data[64..];
            let access = u32::from_le_bytes(body[24..28].try_into().unwrap());
            let disposition = u32::from_le_bytes(body[36..40].try_into().unwrap());
            let options = u32::from_le_bytes(body[40..44].try_into().unwrap());
            // FILE_OPEN, directory only, LIST_DIRECTORY/READ_ATTRIBUTES/SYNCHRONIZE.
            let contexts = u32::from_le_bytes(body[52..56].try_into().unwrap());
            disposition == 1 && options == 0x0020_0001 && access & !0x0010_0081 == 0 && contexts == 0
        }
        14 => {
            if data.len() < 96 { return false; }
            let requested = u32::from_le_bytes(data[92..96].try_into().unwrap());
            requested > 0 && requested <= QUERY_CAP
        }
        _ => false, // No file-body READ/WRITE, IOCTL, locks or metadata mutation.
    }
}

/// Exact admitted child spelling; no lossy/normalizing repair or path authority.
pub fn permitted_name(name: &str) -> bool {
    !name.is_empty() && name.len() <= NAME_CAP && name != "." && name != ".."
        && !name.chars().any(|c| c == '/' || c == '\\' || c == '\0' || c.is_control())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn outbound_profile_refuses_body_io_compounds_and_writable_opens() {
        let mut frame = vec![0; 120];
        frame[..4].copy_from_slice(b"\xfeSMB");
        for command in [0u16, 1, 2, 3, 4, 6, 12, 13] {
            frame[12..14].copy_from_slice(&command.to_le_bytes());
            assert!(permitted_frame(&frame));
        }
        for command in [7u16, 8, 9, 10, 11, 15, 16, 17, 18, u16::MAX] {
            frame[12..14].copy_from_slice(&command.to_le_bytes());
            assert!(!permitted_frame(&frame));
        }
        frame[12..14].copy_from_slice(&5u16.to_le_bytes());
        frame[88..92].copy_from_slice(&0x0010_0081u32.to_le_bytes());
        frame[100..104].copy_from_slice(&1u32.to_le_bytes());
        frame[104..108].copy_from_slice(&0x0020_0001u32.to_le_bytes());
        assert!(permitted_frame(&frame));
        frame[88] |= 2;
        assert!(!permitted_frame(&frame));
        frame[88] &= !2;
        frame[100] = 2;
        assert!(!permitted_frame(&frame));
        frame[100] = 1;
        frame[105] |= 0x10; // Delete-on-close must never escape through directory CREATE.
        assert!(!permitted_frame(&frame));
        frame[105] &= !0x10;
        frame[20] = 64;
        assert!(!permitted_frame(&frame));
        frame[20] = 0;
        frame[12..14].copy_from_slice(&14u16.to_le_bytes());
        frame[92..96].copy_from_slice(&QUERY_CAP.to_le_bytes());
        assert!(permitted_frame(&frame));
        frame[92..96].copy_from_slice(&(QUERY_CAP + 1).to_le_bytes());
        assert!(!permitted_frame(&frame));
    }

    #[test]
    fn child_names_preserve_composition_and_refuse_path_ambiguity() {
        for name in ["Café 文件.txt", "Cafe\u{301} 文件.txt", "File with spaces", ".hidden"] {
            assert!(permitted_name(name));
        }
        for name in ["", ".", "..", "a/b", "a\\b", "bad\0name", "bad\nname"] {
            assert!(!permitted_name(name));
        }
        assert!(!permitted_name(&"a".repeat(NAME_CAP + 1)));
    }
}
