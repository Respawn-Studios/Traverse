//! Identity bookkeeping for the full-scope result catalog. The scanner keeps
//! only prepared statements and one observation in memory, not growing maps.
//! Opening/admitting a file-backed store belongs to the session authority owner.
//! This module is not selected by the ordinary worker until integration gates pass.
use std::ffi::{c_char, c_int, c_void, CStr, CString};
use std::rc::Rc;

#[link(name = "sqlite3")]
unsafe extern "C" {
    fn sqlite3_open_v2(path: *const c_char, db: *mut *mut c_void, flags: c_int, vfs: *const c_char) -> c_int;
    fn sqlite3_close(db: *mut c_void) -> c_int;
    fn sqlite3_exec(db: *mut c_void, sql: *const c_char, callback: *const c_void, argument: *mut c_void, error: *mut *mut c_char) -> c_int;
    fn sqlite3_prepare_v2(db: *mut c_void, sql: *const c_char, size: c_int, statement: *mut *mut c_void, tail: *mut *const c_char) -> c_int;
    fn sqlite3_finalize(statement: *mut c_void) -> c_int;
    fn sqlite3_reset(statement: *mut c_void) -> c_int;
    fn sqlite3_clear_bindings(statement: *mut c_void) -> c_int;
    fn sqlite3_bind_blob(statement: *mut c_void, index: c_int, bytes: *const c_void, count: c_int, destructor: isize) -> c_int;
    fn sqlite3_bind_null(statement: *mut c_void, index: c_int) -> c_int;
    fn sqlite3_step(statement: *mut c_void) -> c_int;
    fn sqlite3_column_type(statement: *mut c_void, column: c_int) -> c_int;
    fn sqlite3_column_bytes(statement: *mut c_void, column: c_int) -> c_int;
    fn sqlite3_column_blob(statement: *mut c_void, column: c_int) -> *const c_void;
    fn sqlite3_column_int64(statement: *mut c_void, column: c_int) -> i64;
    fn sqlite3_changes(db: *mut c_void) -> c_int;
    fn sqlite3_get_autocommit(db: *mut c_void) -> c_int;
}

#[derive(Debug, PartialEq, Eq)]
pub enum Error { Sqlite(i32), InvalidRow, Overflow }
pub type Result<T> = std::result::Result<T, Error>;
#[cfg(b06_reference_index)]
pub(crate) unsafe fn changed_rows(db:*mut c_void)->i32 {unsafe{sqlite3_changes(db)}}
fn check(value: i32) -> Result<()> {
    if value == 0 { Ok(()) } else { Err(Error::Sqlite(value)) }
}

/// Construct only after the session's file/parent/lease admission. No CREATE
/// flag: a missing/replaced named database is never silently made here.
pub struct Connection { raw: *mut c_void }
impl Connection {
    pub(crate) fn in_transaction(&self) -> bool { unsafe { sqlite3_get_autocommit(self.raw) == 0 } }
    // Other catalog statements retain the same Rc owner. This is deliberately
    // crate-private: no borrowed handle or statement may outlive that owner.
    #[allow(dead_code)]
    pub(crate) fn handle(&self) -> *mut c_void { self.raw }
    #[allow(dead_code)]
    pub(crate) fn open_read_only(path: &CStr) -> Result<Rc<Self>> {
        Self::open(path, 1 | 0x01000000 | 0x00010000 | 0x00040000)
    }
    /// Only an inherited, caller-pinned read-only descriptor is admitted here.
    /// The immutable URI prevents SQLite sidecars; the source is an app-owned
    /// sealed catalog, never a selected user's file or a writable live store.
    pub(crate) fn open_inherited_read_only(fd: i32) -> Result<Rc<Self>> {
        if fd != 7 { return Err(Error::InvalidRow); }
        let path = CString::new(format!("file:/dev/fd/{fd}?mode=ro&immutable=1"))
            .map_err(|_| Error::InvalidRow)?;
        Self::open(&path, 1 | 0x40 | 0x00010000 | 0x00040000)
    }
    pub fn open_existing(path: &CStr) -> Result<Rc<Self>> {
        Self::open(path, 2 | 0x01000000 | 0x00010000 | 0x00040000)
    }
    fn open(path: &CStr, flags: i32) -> Result<Rc<Self>> {
        let mut raw = std::ptr::null_mut();
        let code = unsafe { sqlite3_open_v2(path.as_ptr(), &mut raw, flags, std::ptr::null()) };
        if code != 0 {
            if !raw.is_null() { unsafe { sqlite3_close(raw); } }
            return Err(Error::Sqlite(code));
        }
        Ok(Rc::new(Self { raw }))
    }
    pub fn execute(&self, sql: &str) -> Result<()> {
        let text = CString::new(sql).map_err(|_| Error::InvalidRow)?;
        check(unsafe { sqlite3_exec(self.raw, text.as_ptr(), std::ptr::null(), std::ptr::null_mut(), std::ptr::null_mut()) })
    }
    pub fn install_identity_schema(&self) -> Result<()> {
        self.execute("CREATE TABLE object_facts(identity BLOB PRIMARY KEY CHECK(length(identity)=24),metrics BLOB NOT NULL CHECK(length(metrics)=36),links BLOB CHECK(links IS NULL OR length(links)=8),flags BLOB CHECK(flags IS NULL OR length(flags)=4),edges BLOB NOT NULL CHECK(length(edges)=8)) WITHOUT ROWID,STRICT;CREATE TABLE visited_directories(identity BLOB PRIMARY KEY CHECK(length(identity)=24)) WITHOUT ROWID,STRICT;")
    }
    #[cfg(test)]
    fn memory() -> Rc<Self> {
        let value = Self::open(c":memory:", 2 | 4 | 0x00040000).unwrap();
        value.execute("PRAGMA cache_size=-1024;PRAGMA temp_store=MEMORY;").unwrap();
        value.install_identity_schema().unwrap(); value
    }
}
impl Drop for Connection {
    fn drop(&mut self) {
        // Every statement retains this owner. The final reference cannot drop
        // until statements and their active binding guards are already gone.
        let result = unsafe { sqlite3_close(self.raw) };
        debug_assert_eq!(result, 0);
    }
}

struct Statement { raw: *mut c_void, owner: Rc<Connection> }
impl Statement {
    fn new(owner: Rc<Connection>, sql: &str) -> Result<Self> {
        let text = CString::new(sql).map_err(|_| Error::InvalidRow)?;
        let mut raw = std::ptr::null_mut();
        let code = unsafe { sqlite3_prepare_v2(owner.raw, text.as_ptr(), -1, &mut raw, std::ptr::null_mut()) };
        if code != 0 {
            if !raw.is_null() { unsafe { sqlite3_finalize(raw); } }
            return Err(Error::Sqlite(code));
        }
        Ok(Self { raw, owner })
    }
    fn use_statement(&self) -> Result<Bindings<'_>> {
        check(unsafe { sqlite3_reset(self.raw) })?;
        check(unsafe { sqlite3_clear_bindings(self.raw) })?;
        Ok(Bindings { statement: self })
    }
}
impl Drop for Statement { fn drop(&mut self) { unsafe { sqlite3_finalize(self.raw); } } }
struct Bindings<'a> { statement: &'a Statement }
impl Bindings<'_> {
    fn blob(&self, index: i32, value: Option<&[u8]>) -> Result<()> {
        check(unsafe { match value {
            Some(bytes) => sqlite3_bind_blob(self.statement.raw, index, bytes.as_ptr().cast(), bytes.len() as i32, -1),
            None => sqlite3_bind_null(self.statement.raw, index),
        } })
    }
    fn step(&self) -> Result<bool> {
        match unsafe { sqlite3_step(self.statement.raw) } {
            100 => Ok(true), 101 => Ok(false), code => Err(Error::Sqlite(code)),
        }
    }
    fn fixed<const N: usize>(&self, column: i32) -> Result<Option<[u8; N]>> {
        let kind = unsafe { sqlite3_column_type(self.statement.raw, column) };
        if kind == 5 { return Ok(None); }
        if kind != 4 || unsafe { sqlite3_column_bytes(self.statement.raw, column) } != N as i32 {
            return Err(Error::InvalidRow);
        }
        let pointer = unsafe { sqlite3_column_blob(self.statement.raw, column) };
        if pointer.is_null() { return Err(Error::InvalidRow); }
        let mut bytes = [0; N];
        bytes.copy_from_slice(unsafe { std::slice::from_raw_parts(pointer.cast::<u8>(), N) });
        Ok(Some(bytes))
    }
}
impl Drop for Bindings<'_> {
    fn drop(&mut self) { unsafe { sqlite3_reset(self.statement.raw); sqlite3_clear_bindings(self.statement.raw); } }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ObjectFacts {
    pub values: [Option<u64>; 4], pub links: Option<u64>, pub flags: Option<u32>,
}
impl ObjectFacts {
    fn metrics(self) -> [u8; 36] {
        let mut result = [0; 36];
        for (index, value) in self.values.into_iter().enumerate() {
            let offset = index * 9;
            if let Some(value) = value {
                result[offset] = 1; result[offset + 1..offset + 9].copy_from_slice(&value.to_be_bytes());
            }
        }
        result
    }
}
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ObjectAdmission { pub fresh: bool, pub changed: bool }

/// Must be used on the connection's single worker, inside its bounded writer
/// transaction. Rollback rolls back bookkeeping and observations together.
pub struct IdentityIndex {
    find: Statement, insert: Statement, update: Statement,
    directory: Statement, counts: Statement,
    source: [u8; 8],
}
impl IdentityIndex {
    pub fn new(owner: Rc<Connection>) -> Result<Self> {
        Self::for_source(owner, 1)
    }
    pub fn for_source(owner: Rc<Connection>, source: u64) -> Result<Self> {
        if source == 0 { return Err(Error::InvalidRow); }
        Ok(Self {
            find: Statement::new(Rc::clone(&owner), "SELECT metrics,links,flags,edges FROM object_facts WHERE identity=?")?,
            insert: Statement::new(Rc::clone(&owner), "INSERT INTO object_facts VALUES(?,?,?,?,?) ON CONFLICT(identity) DO NOTHING")?,
            update: Statement::new(Rc::clone(&owner), "UPDATE object_facts SET edges=? WHERE identity=?")?,
            directory: Statement::new(Rc::clone(&owner), "INSERT INTO visited_directories VALUES(?) ON CONFLICT(identity) DO NOTHING")?,
            counts: Statement::new(owner, "SELECT count(*),coalesce(sum(CASE WHEN links>edges THEN 1 ELSE 0 END),0) FROM object_facts WHERE identity>=? AND identity<=?")?,
            source: source.to_be_bytes(),
        })
    }
    fn key(&self, identity: [u64; 2]) -> [u8; 24] {
        let mut key = [0; 24]; key[..8].copy_from_slice(&self.source);
        key[8..16].copy_from_slice(&identity[0].to_be_bytes());
        key[16..].copy_from_slice(&identity[1].to_be_bytes()); key
    }
    pub fn object(&self, identity: [u64; 2], facts: ObjectFacts) -> Result<ObjectAdmission> {
        let key = self.key(identity);
        // Most namespace entries name a new object. Insert-first avoids an
        // otherwise redundant lookup, retaining exact first-observation facts.
        // A conflict is still fully checked; nothing treats nlink1 as unique.
        let insert = self.insert.use_statement()?;
        insert.blob(1, Some(&key))?; insert.blob(2, Some(&facts.metrics()))?;
        let links = facts.links.map(u64::to_be_bytes); let flags = facts.flags.map(u32::to_be_bytes);
        insert.blob(3, links.as_ref().map(|v| v.as_slice()))?;
        insert.blob(4, flags.as_ref().map(|v| v.as_slice()))?;
        insert.blob(5, Some(&1_u64.to_be_bytes()))?;
        if insert.step()? { return Err(Error::InvalidRow); }
        let inserted = unsafe { sqlite3_changes(self.insert.owner.raw) };
        drop(insert);
        if inserted == 1 { return Ok(ObjectAdmission { fresh: true, changed: facts.links == Some(0) }); }
        if inserted != 0 { return Err(Error::InvalidRow); }
        let query = self.find.use_statement()?; query.blob(1, Some(&key))?;
        if query.step()? {
            let metrics = query.fixed::<36>(0)?.ok_or(Error::InvalidRow)?;
            let links = query.fixed::<8>(1)?.map(u64::from_be_bytes);
            let flags = query.fixed::<4>(2)?.map(u32::from_be_bytes);
            let edges = u64::from_be_bytes(query.fixed::<8>(3)?.ok_or(Error::InvalidRow)?)
                .checked_add(1).ok_or(Error::Overflow)?;
            if query.step()? { return Err(Error::InvalidRow); }
            drop(query);
            let change = self.update.use_statement()?;
            change.blob(1, Some(&edges.to_be_bytes()))?; change.blob(2, Some(&key))?;
            if change.step()? || unsafe { sqlite3_changes(self.update.owner.raw) } != 1 { return Err(Error::InvalidRow); }
            Ok(ObjectAdmission { fresh: false, changed: facts.links == Some(0) || metrics != facts.metrics()
                || links != facts.links || flags != facts.flags || links.is_some_and(|count| edges > count) })
        } else {
            Err(Error::InvalidRow)
        }
    }
    pub fn directory(&self, identity: [u64; 2]) -> Result<bool> {
        let key = self.key(identity);
        let insert = self.directory.use_statement()?; insert.blob(1, Some(&key))?;
        if insert.step()? { return Err(Error::InvalidRow); }
        match unsafe { sqlite3_changes(self.directory.owner.raw) } { 0 => Ok(false), 1 => Ok(true), _ => Err(Error::InvalidRow) }
    }
    pub fn object_counts(&self) -> Result<(u64, u64)> {
        let query = self.counts.use_statement()?;
        query.blob(1, Some(&self.key([0, 0])))?;
        query.blob(2, Some(&self.key([u64::MAX, u64::MAX])))?;
        if !query.step()? { return Err(Error::InvalidRow); }
        let count = unsafe { sqlite3_column_int64(query.statement.raw, 0) };
        let outside = unsafe { sqlite3_column_int64(query.statement.raw, 1) };
        if count < 0 || outside < 0 || outside > count || query.step()? { return Err(Error::InvalidRow); }
        Ok((count as u64, outside as u64))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::{HashMap, HashSet};
    fn facts(value: u64, links: Option<u64>) -> ObjectFacts {
        ObjectFacts { values: [Some(value), Some(value), None, Some(0)], links, flags: Some(0) }
    }
    #[test]
    fn preserves_unsigned_identity_values_zero_and_unknown_fields() {
        let database = Connection::memory(); let index = IdentityIndex::new(Rc::clone(&database)).unwrap();
        let identity = [u64::MAX, u64::MAX]; let value = facts(u64::MAX, Some(u64::MAX));
        assert_eq!(index.object(identity, value).unwrap(), ObjectAdmission { fresh: true, changed: false });
        assert_eq!(index.object(identity, value).unwrap(), ObjectAdmission { fresh: false, changed: false });
        assert_eq!(index.object_counts().unwrap(), (1, 1));
        let mut missing = value; missing.values[0] = None;
        assert!(index.object(identity, missing).unwrap().changed);
        assert!(index.object([0, 0], facts(0, Some(0))).unwrap().changed);
        assert!(index.directory(identity).unwrap()); assert!(!index.directory(identity).unwrap());
        assert!(index.directory([0, u64::MAX]).unwrap());
    }
    #[test]
    fn rollback_does_not_leave_identity_authority_or_a_false_duplicate() {
        let database = Connection::memory(); let index = IdentityIndex::new(Rc::clone(&database)).unwrap();
        database.execute("BEGIN IMMEDIATE").unwrap();
        assert!(index.object([1, 2], facts(7, Some(1))).unwrap().fresh);
        assert!(index.directory([1, 3]).unwrap());
        database.execute("ROLLBACK").unwrap();
        assert_eq!(index.object_counts().unwrap(), (0, 0));
        assert!(index.object([1, 2], facts(7, Some(1))).unwrap().fresh);
        assert!(index.directory([1, 3]).unwrap());
    }
    #[test]
    fn source_members_do_not_share_inode_authority_or_link_counts() {
        let database = Connection::memory();
        let system = IdentityIndex::for_source(Rc::clone(&database), 1).unwrap();
        let data = IdentityIndex::for_source(Rc::clone(&database), 2).unwrap();
        assert!(IdentityIndex::for_source(Rc::clone(&database), 0).is_err());
        let identity = [1, 2];
        assert!(system.object(identity, facts(7, Some(2))).unwrap().fresh);
        assert!(data.object(identity, facts(9, Some(1))).unwrap().fresh);
        assert!(system.directory(identity).unwrap()); assert!(data.directory(identity).unwrap());
        assert_eq!(system.object_counts().unwrap(), (1, 1));
        assert_eq!(data.object_counts().unwrap(), (1, 0));
        assert!(!system.object(identity, facts(7, Some(2))).unwrap().changed);
        assert_eq!(system.object_counts().unwrap(), (1, 0));
        assert_eq!(data.object_counts().unwrap(), (1, 0));
    }
    #[test]
    fn agrees_with_reference_maps_for_changes_duplicates_and_link_edges() {
        for seed in 0..128_u64 {
            let database = Connection::memory(); let index = IdentityIndex::new(Rc::clone(&database)).unwrap();
            let mut objects: HashMap<[u64; 2], (ObjectFacts, u64)> = HashMap::new();
            let mut directories = HashSet::new(); let mut random = seed + 1;
            database.execute("BEGIN IMMEDIATE").unwrap();
            for _ in 0..256 {
                random = random.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
                let key = [random % 3, (random >> 16) % 41];
                let mut observation = facts(random % 5, Some((random >> 8) % 4));
                if random & 8 == 0 { observation.flags = None; }
                if random & 16 == 0 { observation.values[2] = Some(u64::MAX); }
                if random & 32 == 0 { observation.links = None; }
                let expected = if let Some((previous, edges)) = objects.get_mut(&key) {
                    *edges += 1;
                    ObjectAdmission { fresh: false, changed: observation.links == Some(0) || *previous != observation
                        || previous.links.is_some_and(|count| *edges > count) }
                } else {
                    objects.insert(key, (observation, 1));
                    ObjectAdmission { fresh: true, changed: observation.links == Some(0) }
                };
                assert_eq!(index.object(key, observation).unwrap(), expected);
                assert_eq!(index.directory(key).unwrap(), directories.insert(key));
            }
            database.execute("COMMIT").unwrap();
            assert_eq!(index.object_counts().unwrap(), (objects.len() as u64,
                objects.values().filter(|(value, edges)| value.links.is_some_and(|links| links > *edges)).count() as u64));
        }
    }
}
