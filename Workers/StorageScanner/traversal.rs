//! Bounded depth-first traversal:64 frames/16MiB, or the separate128/32MiB profile.
//! Siblings remain packed in their parent's buffer; no pending-sibling queue.
use super::*;
#[cfg(b06_parallel_metadata)]
#[path="metadata_prefetch.rs"]
mod prefetch;
const EXPERIMENT_BUFFER:usize=256*1024;
struct DfsFrame {
    directory: Descriptor,
    pending: Pending,
    before: Identity,
    buffer: Vec<u8>,
    offset: usize,
    remaining: usize,
    cached_parent: Option<u64>,
    cached_after: u64,
    #[cfg(b06_parallel_metadata)] future:Option<usize>,
    #[cfg(b06_parallel_metadata)] eof:bool,
}

impl Scanner {
    fn dfs_frame(&mut self, root: i32, pending: Pending) -> Result<DfsFrame> {
        if let Some(baseline) = self.refresh.as_mut() {
            if let Some(parent) = baseline.reusable_directory(&pending.path, pending.dev, pending.ino)? {
                return Ok(DfsFrame { directory: Descriptor(-1), pending,
                    before: Identity::default(), buffer: Vec::new(), offset: 0, remaining: 0,
                    cached_parent: Some(parent), cached_after: 0,
                    #[cfg(b06_parallel_metadata)] future:None,
                    #[cfg(b06_parallel_metadata)] eof:false });
            }
        }
        // Isolated candidate: use the image that just passed the root-relative
        // open guards. The unchanged close check covers this earlier instant.
        #[cfg(b06_verified_open_identity)]
        let (directory,before)=self.open_pending_observed(root,&pending)?;
        #[cfg(not(b06_verified_open_identity))]
        let directory = self.open_pending(root, &pending)?;
        #[cfg(not(b06_verified_open_identity))]
        let before = self.identity(directory.0)?;
        self.enumerated_directories = self.enumerated_directories.checked_add(1).ok_or("store_overflow")?;
        Ok(DfsFrame { directory, pending, before, buffer: Vec::new(), offset: 0, remaining: 0,
            cached_parent: None, cached_after: 0,
            #[cfg(b06_parallel_metadata)] future:None, #[cfg(b06_parallel_metadata)] eof:false })
    }

    fn dfs_next(&mut self, frame: &mut DfsFrame) -> Result<Option<Observation>> {
        if let Some(parent) = frame.cached_parent {
            let row = self.refresh.as_mut().ok_or("refresh_catalog")?.next(parent,frame.cached_after)?;
            return Ok(row.map(|(id,observation)| { frame.cached_after=id; observation }));
        }
        if frame.remaining == 0 {
            if frame.buffer.is_empty() { frame.buffer.resize(EXPERIMENT_BUFFER, 0); }
            self.bulk_calls += 1; self.calls += 1;
            let count = {
                #[cfg(b06_live_totals)] let _timer=profiling::measure(profiling::Stage::Bulk);
                unsafe { if self.startup_sources.is_some() {
                b06_bulk_physical(frame.directory.0,frame.buffer.as_mut_ptr().cast(),frame.buffer.len())
            }else {b06_bulk(frame.directory.0, frame.buffer.as_mut_ptr().cast(), frame.buffer.len())} } };
            if count < 0 {
                let error = errno();
                self.issue(if error == 11 { "materialization_denied" } else { "bulk_error" }, error);
                return Ok(None);
            }
            if count == 0 { return Ok(None); }
            // Same packed parser, one record at a time. Retain the unconsumed
            // bytes while descending, rather than a Vec of parsed siblings.
            frame.remaining = count as usize; frame.offset = 0;
        }
        let bytes = frame.buffer.get(frame.offset..).ok_or("record_length")?;
        let length = u32::from_le_bytes(bytes.get(..4).ok_or("record_length")?.try_into().map_err(|_| "record_length")?) as usize;
        let (observation, parsed_length) = {
            #[cfg(b06_live_totals)] let _timer=profiling::measure(profiling::Stage::Parse);
            parse_record(bytes, 0, true)?
        };
        if length != parsed_length {return Err("record_length");}
        frame.offset = frame.offset.checked_add(length).ok_or("record_length")?;
        frame.remaining -= 1;
        Ok(Some(observation))
    }

    fn dfs_close(&mut self, root: i32, path: &CString, frame: DfsFrame) -> Result<()> {
        if frame.cached_parent.is_some() {
            let current = self.identity(root)?;
            if !self.guarded(&current) { return Err("root_changed"); }
            return self.check_namespace(path);
        }
        let after = self.identity(frame.directory.0)?;
        let before = frame.before;
        if before.dev != after.dev || before.ino != after.ino
            || before.mtime_sec != after.mtime_sec || before.mtime_nsec != after.mtime_nsec
            || before.ctime_sec != after.ctime_sec || before.ctime_nsec != after.ctime_nsec {
            self.issue("directory_changed", 0);
        }
        let current = self.identity(root)?;
        if !self.guarded(&current) { return Err("root_changed"); }
        self.check_namespace(path)?;
        if self.last_flush.elapsed().as_millis() >= 100 { self.flush_rows(); }
        Ok(())
    }

    pub(super) fn dfs_walk(&mut self, root: i32, path: &CString) -> Result<()> {
        #[cfg(b06_parallel_metadata)]
        { self.prefetch_walk(root,path) }
        #[cfg(not(b06_parallel_metadata))]
        {
        let initial = Pending { path: Vec::new(), dev: self.root_identity.dev, ino: self.root_identity.ino, depth: 0 };
        let mut frames = vec![self.dfs_frame(root, initial)?];
        // Isolated candidate: reuse a closed sibling's bulk allocation. There
        // is still at most one buffer per reached depth, including this pool.
        #[cfg(b06_reuse_buffers)]
        let mut buffers: Vec<Vec<u8>> = Vec::new();
        while !frames.is_empty() && !self.stopped() {
            if frames.len() > self.options.maximum_depth { return Err("descriptor_bound"); }
            // root + all stack directories + one namespace check; stdin/stdout/
            // stderr are inherited streams, not directory descriptors.
            self.peak_fds = self.peak_fds.max(frames.len() + 2);
            self.peak_queue = self.peak_queue.max(frames.len());
            let frame = frames.last_mut().ok_or("frame_state")?;
            if let Some(observation) = self.dfs_next(frame)? {
                if let Some(child) = self.receive_child(&observation, &frame.pending)? {
                    match self.dfs_frame(root, child) {
                        Ok(mut child) => {
                            #[cfg(b06_reuse_buffers)]
                            { child.buffer = buffers.pop().unwrap_or_default(); }
                            #[cfg(not(b06_reuse_buffers))]
                            { let _ = &mut child; }
                            frames.push(child)
                        },
                        Err(_) => self.issue("directory_open", errno()),
                    }
                }
            } else {
                let mut finished = frames.pop().ok_or("frame_state")?;
                #[cfg(b06_reuse_buffers)]
                let buffer = std::mem::take(&mut finished.buffer);
                #[cfg(not(b06_reuse_buffers))]
                { let _ = &mut finished; }
                self.dfs_close(root, path, finished)?;
                #[cfg(b06_reuse_buffers)]
                if !buffer.is_empty() { buffers.push(buffer); }
            }
        }
        // Cancellation does not release the actual directory ownership early.
        // Validate and close every held frame before the process terminates.
        if self.startup_sources.is_some() && unsafe{b06_cancelled()}!=0 {self.emit("phase",vec![("stage",quote("draining_directories"))]);}
        while let Some(frame) = frames.pop() { self.dfs_close(root, path, frame)?; }
        if self.startup_sources.is_some() && unsafe{b06_cancelled()}!=0 {self.emit("phase",vec![("stage",quote("directories_drained"))]);}
        Ok(())
        }
    }
}


impl Scanner {
    fn receive_child(&mut self,o:&Observation,pending:&Pending) -> Result<Option<Pending>> {
        if self.stopped(){return Ok(None);}
        // The consumer's depth limit counts the final filename too. Never emit
        // component 65 and then ask Swift to reject an otherwise valid stream.
        if pending.depth>=self.options.maximum_depth{self.issue("depth_limit",0);return Ok(None);}
        if self.startup_sources.is_some() && self.startup_boundary(o,pending)? {return Ok(None);}
        if self.result.as_ref().is_some_and(|store|o.kind()=="directory" && store.excludes_store(o.dev,o.ino)) {
            self.issue("owned_store_excluded",0);return Ok(None);
        }
        self.accept(o,&pending.path)?;
        let mut absolute=self.root_namespace.clone();if !absolute.ends_with(b"/"){absolute.push(47);}
        if !pending.path.is_empty(){absolute.extend_from_slice(&pending.path);absolute.push(47);}absolute.extend_from_slice(&o.name);
        if policy::excludes_for(&absolute,o.kind()=="directory",self.options.metadata_policy){self.issue("policy_excluded",0);return Ok(None);}
        if o.kind()=="directory" && o.error==0 {
            let boundary=o.mount!=Some(0) || o.dev!=Some(self.root_identity.dev) || o.ino.is_none() || o.flags.is_none_or(|f|f&(0x0080_0000|0x4000_0000)!=0);
            if boundary{self.issue("boundary_excluded",0);return Ok(None);}
            // Keep the boundary directory's own metadata, but do not open its
            // children: their relative names would exceed the same limit.
            if pending.depth+1>=self.options.maximum_depth{self.issue("depth_limit",0);return Ok(None);}
            let dev=o.dev.unwrap();let ino=o.ino.unwrap();if !self.result.as_ref().ok_or("store_index")?.directory([dev,ino])?{self.issue("duplicate_directory",0);return Ok(None);}
            let mut path=pending.path.clone();if !path.is_empty(){path.push(47);}path.extend_from_slice(&o.name);return Ok(Some(Pending{path,dev,ino,depth:pending.depth+1}));
        }Ok(None)
    }
}

#[cfg(test)]
mod verified_open_native_tests {
    use super::*;
    use std::path::{Path,PathBuf};
    use std::os::unix::fs::DirBuilderExt;

    fn directory(path:&Path) {std::fs::DirBuilder::new().mode(0o700).create(path).unwrap();}
    fn fixture(label:&str)->(PathBuf,CString,Descriptor,Scanner) {
        let root=PathBuf::from(std::env::var("B06_OPEN_IDENTITY_CONTROL_ROOT").expect("explicit generated root"));
        let repo=Path::new(file!()).parent().unwrap().parent().unwrap().parent().unwrap();
        let owner=root.parent().unwrap();let name=owner.file_name().unwrap().to_str().unwrap();
        let suffix=name.strip_prefix("verified-open-controls-").expect("owned control namespace");
        assert!(suffix.len()==32 && suffix.bytes().all(|v|v.is_ascii_hexdigit()));
        assert_eq!(owner.parent().unwrap(),repo.join(".build/b06-analyzer"));
        assert_eq!(root.canonicalize().unwrap(),root);
        assert_eq!(std::fs::read(owner.join(".verified-open-control-v1")).unwrap(),
            format!("Traverse verified-open generated control v1\n{name}\n").as_bytes());
        let path=root.join(label);directory(&path);
        let text=CString::new(path.to_str().unwrap()).unwrap();
        let fd=unsafe{b06_open_root(text.as_ptr())};assert!(fd>=0);let held=Descriptor(fd);
        let mut identity=Identity::default();assert_eq!(unsafe{b06_identity(fd,&mut identity)},0);
        let mut scanner=Scanner::new(Options{root_fd:fd,session:"00000000-0000-0000-0000-000000000000".into(),
            dev:identity.dev,ino:identity.ino,maximum_depth:64,maximum_queue:4096,metadata_policy:policy::Profile::Standard});
        scanner.root_identity=identity;scanner.root_namespace=text.as_bytes().to_vec();
        (path,text,held,scanner)
    }

    #[test]
    #[ignore="requires a new marked generated-only root"]
    fn verified_open_call_count_retains_the_directory_change_window() {
        let (root,text,held,mut scanner)=fixture("change-window");
        let child=root.join("Child");directory(&child);
        let name=CString::new("Child").unwrap();let fd=unsafe{b06_open_directory(held.0,name.as_ptr())};assert!(fd>=0);
        let child_fd=Descriptor(fd);let expected=scanner.identity(fd).unwrap();drop(child_fd);
        let calls=scanner.calls;
        let frame=scanner.dfs_frame(held.0,Pending{path:b"Child".to_vec(),dev:expected.dev,ino:expected.ino,depth:1}).unwrap();
        assert_eq!(scanner.calls-calls,if cfg!(b06_verified_open_identity){1}else{2});
        assert_eq!((frame.before.dev,frame.before.ino,frame.before.ctime_sec,frame.before.ctime_nsec),
            (expected.dev,expected.ino,expected.ctime_sec,expected.ctime_nsec));
        directory(&child.join("Changed-after-open"));
        scanner.dfs_close(held.0,&text,frame).unwrap();
        assert_eq!(scanner.reason,"directory_changed");assert!(!scanner.complete);
    }

    #[test]
    #[ignore="requires a new marked generated-only root"]
    fn verified_open_refuses_substituted_directory_and_root() {
        let (root,text,held,mut scanner)=fixture("replacements");
        let child=root.join("Child");directory(&child);
        let name=CString::new("Child").unwrap();let fd=unsafe{b06_open_directory(held.0,name.as_ptr())};assert!(fd>=0);
        let child_fd=Descriptor(fd);let expected=scanner.identity(fd).unwrap();drop(child_fd);
        std::fs::rename(&child,root.join("Retained-child")).unwrap();directory(&child);
        let changed=scanner.dfs_frame(held.0,Pending{path:b"Child".to_vec(),dev:expected.dev,ino:expected.ino,depth:1});
        assert!(matches!(changed,Err("directory_changed")));
        scanner.check_namespace(&text).unwrap();
        std::fs::rename(&root,root.with_extension("retained")).unwrap();directory(&root);
        assert_eq!(scanner.check_namespace(&text),Err("root_replaced"));
    }
}
