//! A bounded single SQLite owner thread with explicit post-runtime join.
//! Dropping an async wait never claims that its actual SQL work has ended.
use crate::catalog::{Catalog,Entry,Error,Find,Result,Snapshot,Sort,State};
use std::sync::{Arc,atomic::AtomicBool};
use tokio::sync::{mpsc,oneshot};

type Job=Box<dyn FnOnce(&mut Catalog)+Send>;
pub struct Writer{sender:mpsc::Sender<Job>}
#[must_use]pub struct ThreadOwner{thread:std::thread::JoinHandle<bool>}
impl ThreadOwner{
    /// Call only outside the connection runtime, after all Writer values have
    /// dropped. An OS-stalled join is contained by the native child owner.
    pub fn join(self)->bool{self.thread.join().unwrap_or(false)}
}
pub struct Authority{pub path:String,pub directory:i32,pub database:i32,pub lease:i32,pub quota:u64}
impl Writer{
    pub fn spawn(authority:Authority,stop:Arc<AtomicBool>)->Result<(Self,ThreadOwner,oneshot::Receiver<Result<()>>)>{
        let(sender,mut receiver)=mpsc::channel::<Job>(2);let(ready,answer)=oneshot::channel();
        let thread=std::thread::Builder::new().name("mex-sftp-catalog".into()).spawn(move||{
            let mut catalog=match Catalog::create(&authority.path,authority.directory,authority.database,authority.lease,authority.quota,stop,None){
                Ok(c)=>c,Err(e)=>{let _=ready.send(Err(e));return false},
            };
            if ready.send(Ok(())).is_err(){return catalog.drain().is_ok()}
            while let Some(job)=receiver.blocking_recv(){job(&mut catalog)}
            catalog.drain().is_ok()
        }).map_err(|_|Error::Invalid)?;Ok((Self{sender},ThreadOwner{thread},answer))
    }
    async fn ask<T:Send+'static>(&self,work:impl FnOnce(&mut Catalog)->Result<T>+Send+'static)->Result<T>{
        let(sender,receiver)=oneshot::channel();
        self.sender.send(Box::new(move|catalog|{let _=sender.send(work(catalog));})).await.map_err(|_|Error::Stopped)?;
        receiver.await.map_err(|_|Error::Stopped)?
    }
    pub async fn start(&self,generation:[u8;16],path:String)->Result<Snapshot>{self.ask(move|c|c.start(generation,&path)).await}
    /// Bound both queued jobs and each job's names before transferring ownership.
    /// Publication always describes a committed prefix, never pending SQL rows.
    pub async fn append(&self,rows:Vec<Entry>,read:i64)->Result<Snapshot>{
        let bytes=rows.iter().try_fold(0usize,|n,e|n.checked_add(e.name.len()+128)).ok_or(Error::Invalid)?;
        if rows.len()>1024||bytes>512<<10{return Err(Error::Invalid)}
        self.ask(move|c|{for row in rows{c.append(&row)?;}c.checkpoint()?;c.snapshot(read)}).await
    }
    pub async fn finish(&self,state:State)->Result<Snapshot>{self.ask(move|c|c.finish(state)).await}
    pub async fn page(&self,snapshot:Snapshot,offset:i64,limit:usize,sort:Sort,descending:bool)->Result<Vec<crate::catalog::Row>>{
        self.ask(move|c|c.page(snapshot,offset,limit,sort,descending)).await
    }
    pub async fn find(&self,snapshot:Snapshot,query:String)->Result<Find>{
        self.ask(move|c|c.find(snapshot,&query)).await
    }
    pub async fn find_page(&self,find:Find,offset:i64,limit:usize,sort:Sort,descending:bool)->Result<Vec<crate::catalog::Row>>{
        self.ask(move|c|c.find_page(&find,offset,limit,sort,descending)).await
    }
    pub async fn retire(&self,read:i64)->Result<()>{self.ask(move|c|c.retire(read)).await}
    #[cfg(feature="download-qualification")]
    pub async fn selected_file(&self,snapshot:Snapshot,observation:i64)->Result<(String,Entry)>{self.ask(move|c|c.selected_file(snapshot,observation)).await}
}
