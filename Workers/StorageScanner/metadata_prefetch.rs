//! Isolated bounded bulk-metadata readahead. Root-relative opens, descent,
//! admission, SQLite, namespace and source transitions stay on the DFS owner.
//! A directory descriptor is MOVED into one reader and returned with its batch;
//! no concurrent enumeration or borrowed descriptor can outlive a frame.
use super::*;
use std::sync::{Arc,atomic::{AtomicBool,Ordering},mpsc::{self,Receiver,SyncSender}};
use std::thread::JoinHandle;

struct Job { directory:Descriptor, buffer:Vec<u8>, physical:bool }
struct Batch { directory:Descriptor, buffer:Vec<u8>, count:i32, error:i32, elapsed_ns:u64 }
struct Reader {
    sender:Option<SyncSender<Job>>, receiver:Receiver<Batch>, handle:Option<JoinHandle<bool>>,
    pending:bool, ready:Option<Batch>, depth:usize,
}
struct Readers { readers:Vec<Reader>, stopped:Arc<AtomicBool>, joined:bool }

impl Readers {
    fn start()->Result<Self> {
        let mut pool=Self{readers:Vec::with_capacity(2),stopped:Arc::new(AtomicBool::new(false)),joined:false};
        for _ in 0..2 {
            let (sender,input)=mpsc::sync_channel::<Job>(1);
            let (output,receiver)=mpsc::sync_channel::<Batch>(1);
            let (ready,started)=mpsc::sync_channel::<bool>(1);
            let stopped=Arc::clone(&pool.stopped);
            let handle=std::thread::Builder::new().name("metadata-reader".into()).spawn(move|| {
                if unsafe{b06_set_utility_qos()}!=0 {let _=ready.send(false);return false;}
                let policy=match Policy::establish(){Ok(value)=>value,Err(_)=>{let _=ready.send(false);return false;}};
                if ready.send(true).is_err(){return policy.restore();}
                while let Ok(mut job)=input.recv() {
                    if job.buffer.len()!=EXPERIMENT_BUFFER {job.buffer.resize(EXPERIMENT_BUFFER,0);}
                    #[cfg(b06_stage_profile)] let began=Instant::now();
                    let count=if stopped.load(Ordering::Acquire){-1}else{unsafe{if job.physical {
                        b06_bulk_physical(job.directory.0,job.buffer.as_mut_ptr().cast(),job.buffer.len())
                    }else{b06_bulk(job.directory.0,job.buffer.as_mut_ptr().cast(),job.buffer.len())}}};
                    let error=if count<0 {errno()}else{0};
                    #[cfg(b06_stage_profile)] let elapsed_ns=began.elapsed().as_nanos().min(u64::MAX as u128) as u64;
                    #[cfg(not(b06_stage_profile))] let elapsed_ns=0;
                    if output.send(Batch{directory:job.directory,buffer:job.buffer,count,error,elapsed_ns}).is_err(){break;}
                }
                policy.restore()
            }).map_err(|_|"prefetch_start")?;
            pool.readers.push(Reader{sender:Some(sender),receiver,handle:Some(handle),pending:false,ready:None,depth:0});
            if started.recv()!=Ok(true){return Err("materialization_policy");}
        }
        Ok(pool)
    }
    fn available(&self)->Option<usize> {self.readers.iter().position(|reader|!reader.pending)}
    fn submit(&mut self,index:usize,depth:usize,job:Job)->Result<()> {
        let reader=self.readers.get_mut(index).ok_or("prefetch_state")?;
        if reader.pending || reader.ready.is_some(){return Err("prefetch_state");}
        reader.pending=true;reader.depth=depth;
        reader.sender.as_ref().ok_or("prefetch_state")?.send(job).map_err(|_|"prefetch_reader")
    }
    fn take(&mut self,index:usize)->Result<Batch> {
        let reader=self.readers.get_mut(index).ok_or("prefetch_state")?;
        if !reader.pending{return Err("prefetch_state");}
        let value=if let Some(value)=reader.ready.take(){value}else{reader.receiver.recv().map_err(|_|"prefetch_reader")?};
        reader.pending=false;Ok(value)
    }
    /// An EOF has no observation-order effect. Harvesting it releases its slot
    /// before descending, so small ancestor directories cannot starve children.
    /// Positive batches/errors remain bounded in their original reader slot.
    fn eof(&mut self,index:usize)->Result<Option<Batch>> {
        let reader=self.readers.get_mut(index).ok_or("prefetch_state")?;
        if !reader.pending{return Err("prefetch_state");}
        if reader.ready.is_none() {
            match reader.receiver.try_recv() {
                Ok(value)=>reader.ready=Some(value),
                Err(mpsc::TryRecvError::Empty)=>return Ok(None),
                Err(mpsc::TryRecvError::Disconnected)=>return Err("prefetch_reader"),
            }
        }
        if reader.ready.as_ref().is_some_and(|value|value.count==0){self.take(index).map(Some)}else{Ok(None)}
    }
    fn stop(&self){self.stopped.store(true,Ordering::Release);}
    fn finish(&mut self)->Result<()> {
        if self.joined{return Ok(());}
        self.stop();
        for reader in &mut self.readers {reader.sender.take();}
        let mut good=true;
        for reader in &mut self.readers {
            // At most one result per reader; send cannot block on a second
            // result while joining. Dropping it closes any unused descriptor.
            reader.ready.take();
            if let Some(handle)=reader.handle.take(){good &=handle.join().unwrap_or(false);}
            while reader.receiver.try_recv().is_ok(){}
            reader.pending=false;
        }
        self.joined=true;
        if good{Ok(())}else{Err("prefetch_policy_restore")}
    }
}
impl Drop for Readers {fn drop(&mut self){let _=self.finish();}}

impl Scanner {
    fn queue_metadata(&mut self,frame:&mut DfsFrame,readers:&mut Readers,buffer:Vec<u8>)->Result<()> {
        if frame.future.is_some() || frame.eof{return Ok(());}
        let Some(index)=readers.available() else{return Ok(());};
        let directory=std::mem::replace(&mut frame.directory,Descriptor(-1));
        if directory.0<0{return Err("prefetch_state");}
        frame.future=Some(index);
        readers.submit(index,frame.pending.depth,Job{directory,buffer,physical:self.startup_sources.is_some()})
    }
    fn metadata_returned(&mut self,frame:&mut DfsFrame,batch:Batch,consume:bool)->Result<Vec<u8>> {
        if frame.directory.0>=0{return Err("prefetch_state");}
        frame.directory=batch.directory;frame.future=None;
        self.bulk_calls+=1;self.calls+=1;
        #[cfg(b06_stage_profile)] profiling::add_elapsed(profiling::Stage::Bulk,batch.elapsed_ns);
        #[cfg(not(b06_stage_profile))] let _=batch.elapsed_ns;
        if batch.count<0 {
            if !self.stopped(){self.issue(if batch.error==11{"materialization_denied"}else{"bulk_error"},batch.error);}
            frame.eof=true;return Ok(batch.buffer);
        }
        if batch.count==0 {frame.eof=true;return Ok(batch.buffer);}
        if !consume{return Ok(batch.buffer);}
        if frame.remaining!=0{return Err("prefetch_state");}
        frame.remaining=batch.count as usize;frame.offset=0;
        Ok(std::mem::replace(&mut frame.buffer,batch.buffer))
    }
    pub(super) fn prefetch_walk(&mut self,root:i32,path:&CString)->Result<()> {
        let mut readers=Readers::start()?;
        let initial=Pending{path:vec![],dev:self.root_identity.dev,ino:self.root_identity.ino,depth:0};
        let mut frames=vec![self.dfs_frame(root,initial)?];
        self.queue_metadata(&mut frames[0],&mut readers,vec![])?;
        let outcome=(||->Result<()> {
            while !frames.is_empty() && !self.stopped() {
                if frames.len()>self.options.maximum_depth{return Err("descriptor_bound");}
                self.peak_fds=self.peak_fds.max(frames.len()+2);
                self.peak_queue=self.peak_queue.max(frames.len());
                // Poll two slots, independent of tree depth or file count.
                for index in 0..readers.readers.len() {
                    if readers.readers[index].pending {
                        let depth=readers.readers[index].depth;
                        if let Some(batch)=readers.eof(index)? {
                            let frame=frames.get_mut(depth).ok_or("prefetch_state")?;
                            if frame.future!=Some(index){return Err("prefetch_state");}
                            self.metadata_returned(frame,batch,false)?;
                        }
                    }
                }
                let frame=frames.last_mut().ok_or("frame_state")?;
                if frame.remaining==0 {
                    if let Some(index)=frame.future {
                        let spare=self.metadata_returned(frame,readers.take(index)?,true)?;
                        self.queue_metadata(frame,&mut readers,spare)?;
                    }
                }
                let observation=if frame.remaining==0 && frame.eof {None}else{self.dfs_next(frame)?};
                if let Some(observation)=observation {
                    self.queue_metadata(frame,&mut readers,vec![])?;
                    if let Some(child)=self.receive_child(&observation,&frame.pending)? {
                        match self.dfs_frame(root,child) {
                            Ok(mut child)=>{self.queue_metadata(&mut child,&mut readers,vec![])?;frames.push(child);},
                            Err(_)=>self.issue("directory_open",errno()),
                        }
                    }
                } else {
                    let mut finished=frames.pop().ok_or("frame_state")?;
                    if let Some(index)=finished.future {self.metadata_returned(&mut finished,readers.take(index)?,false)?;}
                    self.dfs_close(root,path,finished)?;
                }
            }Ok(())
        })();
        readers.stop();
        if self.startup_sources.is_some() && unsafe{b06_cancelled()}!=0 {self.emit("phase",vec![("stage",quote("draining_directories"))]);}
        let mut drain=Ok(());
        while let Some(mut frame)=frames.pop() {
            if let Some(index)=frame.future {
                match readers.take(index).and_then(|batch|self.metadata_returned(&mut frame,batch,false).map(|_|())) {
                    Ok(())=>{},Err(error)=>{drain=Err(error);continue;},
                }
            }
            if let Err(error)=self.dfs_close(root,path,frame){drain=Err(error);}
        }
        let joined=readers.finish();
        if self.startup_sources.is_some() && unsafe{b06_cancelled()}!=0 {self.emit("phase",vec![("stage",quote("directories_drained"))]);}
        outcome.and(drain).and(joined)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test] fn idle_readers_restore_policy_and_join(){let mut r=Readers::start().unwrap();assert_eq!(r.readers.len(),2);r.finish().unwrap();assert!(r.joined);}
    #[test] fn slots_are_bounded_and_return_failed_descriptor_ownership(){
        let mut r=Readers::start().unwrap();
        for _ in 0..2 {let i=r.available().unwrap();r.submit(i,0,Job{directory:Descriptor(-1),buffer:vec![],physical:false}).unwrap();}
        assert!(r.available().is_none());
        for i in 0..2 {let v=r.take(i).unwrap();assert!(v.count<0);assert_eq!(v.buffer.len(),EXPERIMENT_BUFFER);assert_eq!(v.directory.0,-1);}
        assert!(r.available().is_some());r.finish().unwrap();
    }
    #[test] fn stopping_pending_reads_still_drains_every_reader(){
        let mut r=Readers::start().unwrap();
        for i in 0..2 {r.submit(i,0,Job{directory:Descriptor(-1),buffer:vec![],physical:false}).unwrap();}
        r.stop();r.finish().unwrap();assert!(r.joined);assert!(r.readers.iter().all(|v|v.handle.is_none() && !v.pending));
    }
}
