// Read-only replay of one sealed baseline into the ordinary new-result writer.
// Namespace rows are paged by parent; no full tree or second writer is retained.
struct DirtyDirectory { path: Vec<u8>, recursive: bool }
pub(super) struct RefreshBaseline {
    dirty: Vec<DirtyDirectory>,
    children: Statement,
    child: Statement,
    pub(super) reused: u64,
    pub(super) reused_directories: u64,
}
impl RefreshBaseline {
    pub(super) fn open(device: u64, inode: u64) -> Result<Self> {
        let mut request = Vec::new();
        let mut bytes = [0u8; 4096];
        loop {
            let count = unsafe { super::read(8, bytes.as_mut_ptr().cast(), bytes.len()) };
            if count == 0 { break; }
            if count < 0 || request.len() + count as usize > 65_536 { return Err("refresh_request"); }
            request.extend_from_slice(&bytes[..count as usize]);
        }
        if request.len() < 48 || request.get(..8) != Some(b"TRVREF2\n") { return Err("refresh_request"); }
        let session = request.get(8..44).ok_or("refresh_request")?;
        let count = u32::from_be_bytes(request.get(44..48).ok_or("refresh_request")?
            .try_into().map_err(|_| "refresh_request")?) as usize;
        if count > 256 { return Err("refresh_request"); }
        let mut dirty = Vec::with_capacity(count); let mut offset = 48;
        for _ in 0..count {
            let recursive = match request.get(offset) { Some(&0) => false, Some(&1) => true, _ => return Err("refresh_request") };
            offset += 1;
            let size = u32::from_be_bytes(request.get(offset..offset + 4).ok_or("refresh_request")?
                .try_into().map_err(|_| "refresh_request")?) as usize;
            offset += 4;
            if size > 8192 { return Err("refresh_request"); }
            let path = request.get(offset..offset + size).ok_or("refresh_request")?;
            if !path.is_empty() && path.split(|v| *v == b'/').any(|p|
                p.is_empty() || p.len() > 255 || p == b"." || p == b".." || p.contains(&0)) {
                return Err("refresh_request");
            }
            dirty.push(DirtyDirectory { path: path.to_vec(), recursive }); offset += size;
        }
        if offset != request.len() { return Err("refresh_request"); }
        let owner = Connection::open_inherited_read_only(7).map_err(|_| "refresh_catalog")?;
        owner.execute("PRAGMA cache_size=-1024;PRAGMA temp_store=MEMORY;PRAGMA query_only=ON;")
            .map_err(|_| "refresh_catalog")?;
        let profile = Statement::new(Rc::clone(&owner), "SELECT revision,session FROM profile WHERE id=1")?;
        if !profile.row()? || profile.integer(0)? != PROFILE || profile.bytes(1,36)?.as_deref() != Some(session)
            || profile.row()? { return Err("refresh_profile"); }
        let state = Statement::new(Rc::clone(&owner), "SELECT state,projected FROM scan_state WHERE id=1")?;
        if !state.row()? || state.integer(0)? != 1 || state.integer(1)? != 1 || state.row()? {
            return Err("refresh_partial");
        }
        let root = Statement::new(Rc::clone(&owner), "SELECT identity FROM nodes WHERE id=0 AND kind=1")?;
        let identity = [device.to_be_bytes(), inode.to_be_bytes()].concat();
        if !root.row()? || root.bytes(0,16)?.as_deref() != Some(identity.as_slice()) || root.row()? {
            return Err("refresh_root");
        }
        // Shared-object refresh needs alias closure. Initially choose the
        // ordinary full scan rather than mix old and fresh hardlink facts.
        let shared = Statement::new(Rc::clone(&owner),
            "SELECT 1 FROM nodes WHERE kind=0 AND (links IS NULL OR links<>x'0000000000000001' OR identity IS NULL) LIMIT 1")?;
        if shared.row()? { return Err("refresh_shared_objects"); }
        Ok(Self {
            children: Statement::new(Rc::clone(&owner),
                "SELECT id,name,kind,identity,links,flags,payload FROM nodes WHERE parent=? AND id>? ORDER BY id LIMIT 1")?,
            child: Statement::new(Rc::clone(&owner), "SELECT id,identity FROM nodes WHERE parent=? AND name=? AND kind=1")?,
            dirty, reused: 0, reused_directories: 0,
        })
    }
    pub(super) fn reusable_directory(&mut self, path: &[u8], device: u64, inode: u64) -> Result<Option<u64>> {
        if self.dirty.iter().any(|dirty| path == dirty.path.as_slice() || dirty.recursive && (dirty.path.is_empty()
            || path.strip_prefix(dirty.path.as_slice()).is_some_and(|tail| tail.first() == Some(&b'/')))) {
            return Ok(None);
        }
        let mut parent = 0;
        let expected_identity = [device.to_be_bytes(), inode.to_be_bytes()].concat();
        let mut identity = None;
        for component in path.split(|v| *v == b'/').filter(|v| !v.is_empty()) {
            self.child.number(1,parent)?; self.child.blob(2,Some(component))?;
            if !self.child.row()? { self.child.reset()?; return Ok(None); }
            parent = self.child.integer(0)?;
            identity = self.child.bytes(1,16)?;
            if self.child.row()? { return Err("refresh_catalog"); }
            self.child.reset()?;
        }
        // A fresh parent listing can find a different object at an old name.
        // Never borrow that old subtree merely because its spelling survived.
        if !path.is_empty() && identity.as_deref() != Some(expected_identity.as_slice()) { return Ok(None); }
        self.reused_directories = self.reused_directories.checked_add(1).ok_or("store_overflow")?;
        Ok(Some(parent))
    }
    pub(super) fn next(&mut self, parent: u64, after: u64) -> Result<Option<(u64, Observation)>> {
        self.children.number(1,parent)?; self.children.number(2,after)?;
        if !self.children.row()? { self.children.reset()?; return Ok(None); }
        let id = self.children.integer(0)?;
        let name = self.children.bytes(1,255)?.ok_or("refresh_catalog")?;
        let kind = self.children.integer(2)?;
        let identity = self.children.bytes(3,16)?.ok_or("refresh_catalog")?;
        if identity.len() != 16 { return Err("refresh_catalog"); }
        let device = u64::from_be_bytes(identity[..8].try_into().map_err(|_| "refresh_catalog")?);
        let inode = u64::from_be_bytes(identity[8..].try_into().map_err(|_| "refresh_catalog")?);
        let links = self.children.bytes(4,8)?.map(|v| v.try_into().map(u64::from_be_bytes)
            .map_err(|_| "refresh_catalog")).transpose()?;
        let flags = self.children.bytes(5,4)?.map(|v| v.try_into().map(u32::from_be_bytes)
            .map_err(|_| "refresh_catalog")).transpose()?;
        let payload = decode_payload(&self.children.bytes(6,52)?.ok_or("refresh_catalog")?)?;
        let mut values = [None;4];
        for (index,value) in values.iter_mut().enumerate() {
            *value = match payload[index*13] {0=>None,1=>Some(u64_at(&payload,index*13+1)),_=>return Err("refresh_partial")};
        }
        if self.children.row()? { return Err("refresh_catalog"); }
        self.children.reset()?;
        self.reused = self.reused.checked_add(1).ok_or("store_overflow")?;
        Ok(Some((id,Observation{name,dev:Some(device),ino:Some(inode),links,flags,
            object_type:Some(match kind {0=>1,1=>2,2=>5,3=>3,_=>return Err("refresh_partial")}),
            mount:Some(0),values,..Default::default()})))
    }
}
