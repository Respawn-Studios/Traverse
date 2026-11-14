// Isolated experiment only. Inserted into a pinned copy of the current worker.
// Neither this traversal nor its higher-limit lanes are routed by the app.
struct DfsFrame {
    directory: Descriptor,
    pending: Pending,
    before: Identity,
    buffer: Vec<u8>,
    offset: usize,
    remaining: usize,
}

impl Scanner {
    fn dfs_frame(&mut self, root: i32, pending: Pending) -> Result<DfsFrame> {
        let directory = self.open_pending(root, &pending)?;
        let before = self.identity(directory.0)?;
        Ok(DfsFrame { directory, pending, before, buffer: Vec::new(), offset: 0, remaining: 0 })
    }

    fn dfs_next(&mut self, frame: &mut DfsFrame) -> Result<Option<Observation>> {
        if frame.remaining == 0 {
            if frame.buffer.is_empty() { frame.buffer.resize(EXPERIMENT_BUFFER, 0); }
            self.bulk_calls += 1; self.calls += 1;
            let count = unsafe { b06_bulk(frame.directory.0, frame.buffer.as_mut_ptr().cast(), frame.buffer.len()) };
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
        let observation = parse(bytes, 1, true)?.remove(0);
        frame.offset = frame.offset.checked_add(length).ok_or("record_length")?;
        frame.remaining -= 1;
        Ok(Some(observation))
    }

    fn dfs_close(&mut self, root: i32, path: &CString, frame: DfsFrame) -> Result<()> {
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

    fn dfs_walk(&mut self, root: i32, path: &CString) -> Result<()> {
        let initial = Pending { path: Vec::new(), dev: self.options.dev, ino: self.options.ino, depth: 0 };
        let mut frames = vec![self.dfs_frame(root, initial)?];
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
                        Ok(child) => frames.push(child),
                        Err(_) => self.issue("directory_open", errno()),
                    }
                }
            } else {
                let finished = frames.pop().ok_or("frame_state")?;
                self.dfs_close(root, path, finished)?;
            }
        }
        // Cancellation does not release the actual directory ownership early.
        // Validate and close every held frame before the process terminates.
        while let Some(frame) = frames.pop() { self.dfs_close(root, path, frame)?; }
        Ok(())
    }
}

#[cfg(test)]
mod dfs_controls {
    use super::*;
    fn scanner() -> Scanner {
        let mut s = Scanner::new(Options { root_fd: -1, session: "00000000-0000-0000-0000-000000000000".into(),
            dev: 1, ino: 1, maximum_depth: EXPERIMENT_DEPTH, maximum_queue: 4096 });
        s.root_identity.dev = 1; s.root_namespace = b"/Generated".to_vec(); s
    }
    fn child(index: u64) -> Observation {
        Observation { name: format!("d{index}").into_bytes(), dev: Some(1), ino: Some(index + 2),
            links: Some(1), flags: Some(0), object_type: Some(2), mount: Some(0), ..Default::default() }
    }
    #[test] fn wide_directory_has_no_pending_sibling_limit() {
        let pending = Pending { path: vec![], dev: 1, ino: 1, depth: 0 };
        let mut baseline = scanner(); let mut queue = vec![];
        for i in 0..4096 { assert!(baseline.receive(&child(i), &pending, &mut queue, 0).is_ok()); }
        assert_eq!(baseline.receive(&child(4096), &pending, &mut queue, 0), Err("queue_limit"));
        let mut candidate = scanner();
        for i in 0..8193 { assert!(candidate.receive_child(&child(i), &pending).unwrap().is_some()); }
        assert_eq!(candidate.entries, 8193);
    }
    #[test] fn depth_policy_boundary_and_duplicate_guards_remain() {
        let root = Pending { path: vec![], dev: 1, ino: 1, depth: 0 };
        let mut s = scanner();
        let mut excluded = child(0); excluded.name = b".ssh".to_vec();
        assert!(s.receive_child(&excluded, &root).unwrap().is_none());
        let mut boundary = child(1); boundary.flags = Some(0x0080_0000);
        assert!(s.receive_child(&boundary, &root).unwrap().is_none());
        let mut mount = child(2); mount.mount = Some(1);
        assert!(s.receive_child(&mount, &root).unwrap().is_none());
        let mut dataless = child(3); dataless.flags = Some(0x4000_0000);
        assert!(s.receive_child(&dataless, &root).unwrap().is_none());
        assert!(s.receive_child(&child(4), &root).unwrap().is_some());
        assert!(s.receive_child(&child(4), &root).unwrap().is_none());
        let deep = Pending { path: b"a".to_vec(), dev: 1, ino: 1, depth: EXPERIMENT_DEPTH - 1 };
        assert!(s.receive_child(&child(5), &deep).unwrap().is_none());
        let before = s.entries;
        let closed = Pending { depth: EXPERIMENT_DEPTH, ..deep };
        assert!(s.receive_child(&child(6), &closed).unwrap().is_none());
        assert_eq!(s.entries, before);
    }
}
