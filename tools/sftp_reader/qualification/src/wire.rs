//! Allocation-free SFTP-v3 metadata admission before the library decoder.
//! This is an experimental boundary, never file authority or a general SFTP API.
pub const MAX_PACKET: usize = 256 * 1024;
const MAX_STRING: usize = 8192;
const MAX_HANDLE: usize = 1024;
const MAX_NAMES: u32 = 1024;
const MAX_EXTENSIONS: u32 = 64;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Failure { Length, Truncated, Count, Flags, Trailing, Kind, Version, Busy, Order, Correlation, Encoding, Name, NameLimit }
type Result<T> = std::result::Result<T, Failure>;

pub fn frame_length(length: u32) -> Result<usize> {
    let length = length as usize;
    if length == 0 || length > MAX_PACKET { Err(Failure::Length) } else { Ok(length) }
}

struct Cursor<'a> { bytes: &'a [u8], index: usize }

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Metadata { pub size: Option<u64>, pub modified: Option<u32>, pub permissions: Option<u32> }
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Entry { pub name: String, pub metadata: Metadata }

impl<'a> Cursor<'a> {
    fn take(&mut self, size: usize) -> Result<&'a [u8]> {
        let end = self.index.checked_add(size).ok_or(Failure::Length)?;
        let value = self.bytes.get(self.index..end).ok_or(Failure::Truncated)?;
        self.index = end;
        Ok(value)
    }
    fn u32(&mut self) -> Result<u32> { Ok(u32::from_be_bytes(self.take(4)?.try_into().map_err(|_| Failure::Truncated)?)) }
    fn u64(&mut self) -> Result<u64> { Ok(u64::from_be_bytes(self.take(8)?.try_into().map_err(|_| Failure::Truncated)?)) }
    fn string(&mut self, maximum: usize) -> Result<&'a [u8]> {
        let count = self.u32()? as usize;
        if count > maximum { return Err(Failure::Length); }
        self.take(count)
    }
    fn remaining(&self) -> usize { self.bytes.len() - self.index }
    fn finish(&self) -> Result<()> { if self.remaining() == 0 { Ok(()) } else { Err(Failure::Trailing) } }
    fn attrs(&mut self) -> Result<Metadata> {
        let flags = self.u32()?;
        if flags & !0x8000_000f != 0 { return Err(Failure::Flags); }
        let size = if flags & 1 != 0 { Some(self.u64()?) } else { None };
        if flags & 2 != 0 { self.take(8)?; }
        let permissions = if flags & 4 != 0 { Some(self.u32()?) } else { None };
        let modified = if flags & 8 != 0 { self.take(4)?; Some(self.u32()?) } else { None };
        if flags & 0x8000_0000 != 0 {
            let count = self.u32()?;
            if count > MAX_EXTENSIONS || count as usize > self.remaining()/8 { return Err(Failure::Count); }
            for _ in 0..count { self.string(MAX_STRING)?; self.string(MAX_STRING)?; }
        }
        Ok(Metadata { size, permissions, modified })
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Request { pub kind: u8, pub id: Option<u32> }
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ReplyKind { Version, Status(u32), Handle, Names(u32), Attrs }
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Reply { pub kind: ReplyKind, pub id: Option<u32> }

pub fn outgoing(bytes: &[u8]) -> Result<Request> {
    if bytes.is_empty() || bytes.len() > MAX_PACKET { return Err(Failure::Length); }
    let mut data = Cursor { bytes, index: 0 };
    let kind = data.take(1)?[0];
    if kind == 1 {
        if data.u32()? != 3 { return Err(Failure::Version); }
        data.finish()?;
        return Ok(Request { kind, id: None });
    }
    // INIT, CLOSE, LSTAT/FSTAT, OPENDIR/READDIR, REALPATH and STAT only.
    // The ordinary metadata gate remains byte-for-byte read-only.
    if ![4, 7, 8, 11, 12, 16, 17].contains(&kind) { return Err(Failure::Kind); }
    let id = data.u32()?;
    data.string(if [4, 8, 12].contains(&kind) { MAX_HANDLE } else { MAX_STRING })?;
    data.finish()?;
    Ok(Request { kind, id: Some(id) })
}

/// O/P's distinct, explicitly enabled admission. Old reader instances still
/// call `outgoing` and reject every mutation kind.
#[cfg(feature="remote-action-qualification")]
pub fn outgoing_action(bytes:&[u8])->Result<Request>{
    if bytes.first().is_none_or(|kind|![13,14,15,18].contains(kind)){return outgoing(bytes)}
    if bytes.len()>MAX_PACKET{return Err(Failure::Length)}
    let mut data=Cursor{bytes,index:1};let kind=bytes[0];
    let id=data.u32()?;let old=data.string(MAX_STRING)?;
    if old.is_empty()||old[0]!=b'/'||old.contains(&0){return Err(Failure::Name)}
    if kind==14{if data.u32()?!=0{return Err(Failure::Flags)}}
    if kind==18{let new=data.string(MAX_STRING)?;if new.is_empty()||new[0]!=b'/'||new.contains(&0){return Err(Failure::Name)}}
    data.finish()?;Ok(Request{kind,id:Some(id)})
}

pub fn incoming(bytes: &[u8]) -> Result<Reply> {
    if bytes.is_empty() || bytes.len() > MAX_PACKET { return Err(Failure::Length); }
    let mut data = Cursor { bytes, index: 0 };
    let kind = data.take(1)?[0];
    if kind == 2 {
        if data.u32()? != 3 { return Err(Failure::Version); }
        let mut count = 0;
        while data.remaining() > 0 {
            count += 1;
            if count > MAX_EXTENSIONS { return Err(Failure::Count); }
            data.string(MAX_STRING)?; data.string(MAX_STRING)?;
        }
        return Ok(Reply { kind: ReplyKind::Version, id: None });
    }
    if ![101, 102, 104, 105].contains(&kind) { return Err(Failure::Kind); }
    let id = Some(data.u32()?);
    let kind = match kind {
        101 => { let code = data.u32()?; data.string(MAX_STRING)?; data.string(MAX_STRING)?; ReplyKind::Status(code) }
        102 => { data.string(MAX_HANDLE)?; ReplyKind::Handle }
        104 => {
            let count = data.u32()?;
            // Serde must never see an unbounded peer sequence size hint.
            if count > MAX_NAMES || count as usize > data.remaining()/12 { return Err(Failure::Count); }
            for _ in 0..count { data.string(MAX_STRING)?; data.string(MAX_STRING)?; data.attrs()?; }
            ReplyKind::Names(count)
        }
        105 => { data.attrs()?; ReplyKind::Attrs }
        _ => return Err(Failure::Kind),
    };
    data.finish()?;
    Ok(Reply { kind, id })
}

/// A capability is session evidence only when all required extension names
/// are unique and advertise the exact v1 value on this SFTP channel.
#[cfg(feature="remote-action-qualification")]
pub fn server_copy_capability(bytes: &[u8]) -> Result<bool> {
    if incoming(bytes)?.kind != ReplyKind::Version { return Err(Failure::Kind); }
    let mut data = Cursor { bytes, index: 5 };
    let mut copy = None;
    let mut link = None;
    let mut sync = None;
    while data.remaining() > 0 {
        let name = data.string(MAX_STRING)?;
        let value = data.string(MAX_STRING)?;
        let selected = match name {
            b"copy-data" => &mut copy,
            b"hardlink@openssh.com" => &mut link,
            b"fsync@openssh.com" => &mut sync,
            _ => continue,
        };
        if selected.replace(value == b"1").is_some() { return Ok(false); }
    }
    Ok(copy == Some(true) && link == Some(true) && sync == Some(true))
}

#[cfg(all(test,feature="remote-action-qualification"))]
mod server_copy_tests {
    use super::*;
    fn version(pairs:&[(&[u8],&[u8])])->Vec<u8>{
        let mut bytes=vec![2,0,0,0,3];
        for (name,value) in pairs { for field in [*name,*value] {
            bytes.extend((field.len() as u32).to_be_bytes());bytes.extend(field);
        }}
        bytes
    }
    #[test] fn all_three_exact_unique_ads_are_required(){
        let required=[(b"copy-data".as_slice(),b"1".as_slice()),
            (b"hardlink@openssh.com".as_slice(),b"1".as_slice()),
            (b"fsync@openssh.com".as_slice(),b"1".as_slice())];
        assert_eq!(server_copy_capability(&version(&required)),Ok(true));
        assert_eq!(server_copy_capability(&version(&required[..2])),Ok(false));
        let mut wrong=required;wrong[1].1=b"2";
        assert_eq!(server_copy_capability(&version(&wrong)),Ok(false));
        let mut duplicate=required.to_vec();duplicate.push(required[0]);
        assert_eq!(server_copy_capability(&version(&duplicate)),Ok(false));
        let mut malformed=version(&required);malformed.push(0);
        assert!(server_copy_capability(&malformed).is_err());
    }
}

/// Allocate only after the complete packet has passed the count/field checks.
/// Directory names stay literal; no normalization can change a remote path.
pub fn decode_names(bytes: &[u8], canonical: bool) -> Result<Vec<Entry>> {
    decode_names_limited(bytes,canonical,MAX_STRING)
}
pub fn decode_names_limited(bytes: &[u8], canonical: bool, maximum_name_bytes:usize) -> Result<Vec<Entry>> {
    let reply = incoming(bytes)?;
    let ReplyKind::Names(count) = reply.kind else { return Err(Failure::Kind); };
    if canonical && count != 1 { return Err(Failure::Count); }
    let mut data = Cursor { bytes, index: 9 };
    let mut entries = Vec::with_capacity(count as usize);
    for _ in 0..count {
        let raw=data.string(MAX_STRING)?;
        let name = std::str::from_utf8(raw).map_err(|_| Failure::Encoding)?;
        // Strict UTF-8 is a byte-exact round trip; the folder-size policy is
        // checked before allocating an Entry for this name.
        if !canonical && raw.len()>maximum_name_bytes{return Err(Failure::NameLimit)}
        if name.is_empty() || name.contains('\0') || (canonical && !name.starts_with('/'))
            || (!canonical && name.contains('/')) { return Err(Failure::Name); }
        data.string(MAX_STRING)?; // Long-name presentation is not trusted or retained.
        let metadata = data.attrs()?;
        if canonical || (name != "." && name != "..") { entries.push(Entry { name: name.to_owned(), metadata }); }
    }
    data.finish()?;
    Ok(entries)
}

pub fn decode_handle(bytes: &[u8]) -> Result<Vec<u8>> {
    if incoming(bytes)?.kind != ReplyKind::Handle { return Err(Failure::Kind); }
    let mut data = Cursor { bytes, index: 5 };
    Ok(data.string(MAX_HANDLE)?.to_vec())
}

pub fn decode_attrs(bytes: &[u8]) -> Result<Metadata> {
    if incoming(bytes)?.kind != ReplyKind::Attrs { return Err(Failure::Kind); }
    Cursor { bytes, index: 5 }.attrs()
}

pub fn encode_request(kind: u8, id: u32, field: &[u8]) -> Result<Vec<u8>> {
    let maximum = if [4,8,12].contains(&kind) { MAX_HANDLE } else { MAX_STRING };
    if field.len() > maximum { return Err(Failure::Length); }
    let mut bytes = Vec::with_capacity(9+field.len());
    bytes.push(kind);bytes.extend(id.to_be_bytes());bytes.extend((field.len() as u32).to_be_bytes());bytes.extend(field);
    outgoing(&bytes)?;
    Ok(bytes)
}

#[derive(Default)]
pub struct Gate { initialized: bool, pending: Option<Request>, allow_actions: bool }
impl Gate {
    #[cfg(feature="remote-action-qualification")]
    pub fn enable_actions(&mut self){self.allow_actions=true}
    pub fn sent(&mut self, bytes: &[u8]) -> Result<Request> {
        if self.pending.is_some() { return Err(Failure::Busy); }
        #[cfg(feature="remote-action-qualification")]
        let request = if self.allow_actions{outgoing_action(bytes)?}else{outgoing(bytes)?};
        #[cfg(not(feature="remote-action-qualification"))]
        let request = outgoing(bytes)?;
        if (request.kind == 1) == self.initialized { return Err(Failure::Order); }
        self.pending = Some(request);
        Ok(request)
    }
    pub fn received(&mut self, bytes: &[u8]) -> Result<Reply> {
        let request = self.pending.ok_or(Failure::Order)?;
        let reply = incoming(bytes)?;
        if request.id != reply.id { return Err(Failure::Correlation); }
        let allowed = match (request.kind, reply.kind) {
            (1, ReplyKind::Version) | (7 | 8 | 17, ReplyKind::Attrs) | (11, ReplyKind::Handle)
                | (12, ReplyKind::Names(_)) | (16, ReplyKind::Names(1)) => true,
            (4 | 7 | 8 | 11 | 12 | 16 | 17, ReplyKind::Status(_)) => true,
            #[cfg(feature="remote-action-qualification")]
            (13 | 14 | 15 | 18, ReplyKind::Status(_)) if self.allow_actions => true,
            _ => false,
        };
        if !allowed { return Err(Failure::Kind); }
        if request.kind == 1 { self.initialized = true; }
        self.pending = None;
        Ok(reply)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn word(bytes: &mut Vec<u8>, value: u32) { bytes.extend(value.to_be_bytes()); }
    fn text(bytes: &mut Vec<u8>, value: &[u8]) { word(bytes, value.len() as u32); bytes.extend(value); }
    fn request(kind: u8, id: u32) -> Vec<u8> { let mut b=vec![kind];word(&mut b,id);text(&mut b,b".");b }
    fn names(id: u32, count: u32) -> Vec<u8> {
        let mut b=vec![104];word(&mut b,id);word(&mut b,count);
        for _ in 0..count { text(&mut b,b"name");text(&mut b,b"");word(&mut b,0); } b
    }
    fn initialized() -> Gate { let mut g=Gate::default();g.sent(&[1,0,0,0,3]).unwrap();g.received(&[2,0,0,0,3]).unwrap();g }

    #[test] fn frame_bounds_precede_allocation() {
        assert_eq!(frame_length(0),Err(Failure::Length));
        assert_eq!(frame_length(u32::MAX),Err(Failure::Length));
        assert_eq!(frame_length(MAX_PACKET as u32+1),Err(Failure::Length));
        assert_eq!(frame_length(MAX_PACKET as u32),Ok(MAX_PACKET));
    }
    #[test] fn all_body_and_mutation_opcodes_are_refused() {
        for kind in 0..=255 { if ![1,4,7,8,11,12,16,17].contains(&kind) {
            assert_eq!(outgoing(&request(kind,1)),Err(Failure::Kind));
        }}
        assert_eq!(incoming(&[103,0,0,0,1,0,0,0,0]),Err(Failure::Kind));
        assert_eq!(incoming(&[201,0,0,0,1]),Err(Failure::Kind));
    }
    #[test] fn hostile_name_count_never_reaches_a_sequence_decoder() {
        for count in [1025,1_000_000,u32::MAX] {
            let mut b=vec![104];word(&mut b,1);word(&mut b,count);
            assert_eq!(incoming(&b),Err(Failure::Count));
        }
        assert_eq!(incoming(&names(1,1024)).unwrap().kind,ReplyKind::Names(1024));
    }
    #[test] fn truncated_names_strings_and_attributes_refuse() {
        let b=names(1,2);
        for end in 0..b.len() { assert!(incoming(&b[..end]).is_err()); }
        let mut b=vec![102];word(&mut b,1);word(&mut b,u32::MAX);
        assert_eq!(incoming(&b),Err(Failure::Length));
    }
    #[test] fn trailing_bytes_unknown_flags_and_extensions_refuse() {
        let mut b=names(1,1);b.push(0);assert_eq!(incoming(&b),Err(Failure::Trailing));
        let mut b=vec![105];word(&mut b,1);word(&mut b,16);assert_eq!(incoming(&b),Err(Failure::Flags));
        let mut b=vec![105];word(&mut b,1);word(&mut b,0x8000_0000);word(&mut b,u32::MAX);
        assert_eq!(incoming(&b),Err(Failure::Count));
    }
    #[test] fn exact_request_reply_correlation_and_single_inflight() {
        let mut g=initialized();g.sent(&request(12,7)).unwrap();
        assert_eq!(g.sent(&request(12,8)),Err(Failure::Busy));
        assert_eq!(g.received(&names(8,1)),Err(Failure::Correlation));
        assert!(g.received(&names(7,1)).is_ok());
        assert_eq!(g.received(&names(7,1)),Err(Failure::Order));
    }
    #[test] fn initialization_cannot_repeat_or_skip() {
        let mut g=Gate::default();assert_eq!(g.sent(&request(11,1)),Err(Failure::Order));
        assert_eq!(g.received(&[2,0,0,0,3]),Err(Failure::Order));
        assert_eq!(outgoing(&[1,0,0,0,4]),Err(Failure::Version));
        assert_eq!(incoming(&[2,0,0,0,4]),Err(Failure::Version));
        let mut g=initialized();assert_eq!(g.sent(&[1,0,0,0,3]),Err(Failure::Order));
    }
    #[test] fn response_kind_is_bound_to_request() {
        let mut g=initialized();g.sent(&request(11,7)).unwrap();
        assert_eq!(g.received(&names(7,1)),Err(Failure::Kind));
        let mut b=vec![102];word(&mut b,7);text(&mut b,b"opaque");g.received(&b).unwrap();
        g.sent(&request(16,8)).unwrap();assert_eq!(g.received(&names(8,2)),Err(Failure::Kind));
        assert!(g.received(&names(8,1)).is_ok());
    }
    #[test] fn bounded_status_handle_and_full_attributes_parse() {
        let mut b=vec![101];word(&mut b,7);word(&mut b,1);text(&mut b,b"");text(&mut b,b"");
        assert_eq!(incoming(&b).unwrap().kind,ReplyKind::Status(1));
        let mut b=vec![105];word(&mut b,7);word(&mut b,0x8000_000f);b.extend([0;28]);word(&mut b,1);
        text(&mut b,b"generated");text(&mut b,b"metadata");assert_eq!(incoming(&b).unwrap().kind,ReplyKind::Attrs);
        let mut b=vec![102];word(&mut b,7);text(&mut b,&vec![b'x';1025]);assert_eq!(incoming(&b),Err(Failure::Length));
    }
    #[test] fn deterministic_short_inputs_do_not_panic() {
        let mut seed=0x34f0_11ce_7719_982du64;
        for length in 0..128 { for _ in 0..128 {
            let mut b=Vec::with_capacity(length);
            for _ in 0..length { seed^=seed<<13;seed^=seed>>7;seed^=seed<<17;b.push(seed as u8); }
            let _=incoming(&b);let _=outgoing(&b);
        }}
    }
}
