use super::{catalog::{Catalog,Snapshot,Sort,State},channel::Stop,store::{self,Command,Event,Metadata},wire::{Issue,Page,Find,FolderSizeSelection}};
use std::{fs::{self,File,OpenOptions},os::unix::{fs::{DirBuilderExt,OpenOptionsExt},io::AsRawFd},path::PathBuf,sync::{Arc,atomic::{AtomicBool,Ordering}},time::{Duration,Instant}};
use tokio::sync::oneshot;

#[test]
fn locked_smb_signing_accepts_the_generated_message_and_refuses_an_edit() {
    use smb2::crypto::signing::{sign_message, verify_signature, SigningAlgorithm};

    let key = [0x42; 16];
    let message_id = 9_u64;
    for algorithm in [SigningAlgorithm::HmacSha256, SigningAlgorithm::AesCmac] {
        let mut message = [0_u8; 68];
        message[..4].copy_from_slice(b"\xfeSMB");
        message[12] = 13; // Echo
        message[24..32].copy_from_slice(&message_id.to_le_bytes());
        sign_message(&mut message, &key, algorithm, message_id, false).unwrap();
        verify_signature(&message, &key, algorithm, message_id, false).unwrap();

        message[67] ^= 1;
        assert!(matches!(verify_signature(&message, &key, algorithm, message_id, false),
            Err(smb2::Error::SignatureInvalid { .. })));
    }
}

pub fn fixture(name:&str)->(String,[File;3]){
    let root=PathBuf::from(std::env::var_os("MEX_SMB_BROWSER_FIXTURES").expect("Explicit generated fixture root required"));
    let repo=PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../..").canonicalize().unwrap();
    let parent=root.canonicalize().unwrap();let development=parent.parent().is_some_and(|case|{
        case.parent()==Some(repo.join(".build/traverse-development").as_path())
            &&std::fs::read(case.join("reservation.json")).ok().and_then(|v|String::from_utf8(v).ok())
                .is_some_and(|v|v.contains("\"action\": \"smb-directory-recovery-rust-tests\""))
    });
    assert!((development||[".build/b10-browser-qualification",".build/b10-completion-qualification"].iter()
        .any(|scope|parent.starts_with(repo.join(scope))))&&parent.file_name().unwrap()=="stores");
    assert!(name.bytes().all(|c|c.is_ascii_alphanumeric()||c==b'-'));
    let path=parent.join(name);fs::DirBuilder::new().mode(0o700).create(&path).unwrap();
    let dir=File::open(&path).unwrap();let db=OpenOptions::new().read(true).write(true).create_new(true).mode(0o600).open(path.join("catalog.sqlite")).unwrap();
    let lease=OpenOptions::new().read(true).write(true).create_new(true).mode(0o600).open(path.join("owner.lock")).unwrap();
    unsafe extern "C"{fn flock(fd:i32,operation:i32)->i32;}
    assert_eq!(unsafe{flock(lease.as_raw_fd(),2|4)},0);
    (path.join("catalog.sqlite").to_str().unwrap().into(),[dir,db,lease])
}
#[test]
fn sealed_class37_directory_action_does_not_admit_a_file_action(){
    let(path,files)=fixture("selected-directory-action");
    let mut catalog=Catalog::create(&path,files[0].as_raw_fd(),files[1].as_raw_fd(),files[2].as_raw_fd(),
        8<<20,Arc::new(AtomicBool::new(false)),None).unwrap();
    let generation=[7u8;16];
    catalog.start(generation,&[]).unwrap();catalog.observe_parent(41).unwrap();
    catalog.append_with_identity(&"Folder".encode_utf16().collect::<Vec<_>>(),0x10,0,300,42).unwrap();
    let snapshot=catalog.finish(State::Complete).unwrap();
    let row=catalog.page(snapshot,0,1,Sort::Name,false).unwrap().remove(0);
    let selected=catalog.selected_action(snapshot,generation,row.observation,true).unwrap();
    assert_eq!(selected.item.object,42);assert_eq!(selected.item.parent,41);
    assert!(catalog.selected_action(snapshot,generation,row.observation,false).is_err());
}
fn uuid(number:u64)->String{format!("77777777-7777-4777-8777-{number:012X}")}
fn row(number:u64)->Metadata{Metadata{wire:format!("Item {number}").encode_utf16().collect(),attributes:if number<16{16}else{0},size:number*17,modified:number*23,object:0}}
struct Driver{owner:store::Owner,stop:Arc<AtomicBool>,snapshot:Option<Snapshot>,number:u64,pages:usize,snapshots:usize}
impl Driver{
    async fn new(name:&str,quota:u64)->Self{
        let(path,files)=fixture(name);let stop=Arc::new(AtomicBool::new(false));let mut owner=store::Owner::start(path,files,quota,stop.clone());
        assert!(matches!(owner.events.recv().await,Some(Event::Ready)));Self{owner,stop,snapshot:None,number:0,pages:0,snapshots:0}
    }
    fn observe(&mut self,event:Event){match event{
        Event::Began{number,..}=>{assert!(number>self.number);self.number=number;self.snapshot=None;},
        Event::Snapshot{number,generation,value}=>{
            assert_eq!(number,self.number);assert_eq!(generation,uuid(number));
            if let Some(old)=self.snapshot{assert!(value.revision>old.revision);assert!(value.count>=old.count);assert_eq!(old.state,State::Loading);}
            self.snapshot=Some(value);self.snapshots+=1;
        },Event::Failed(_)=>{},_=>panic!("Unexpected store event"),
    }}
    async fn ack(&mut self,command:Command,mut reply:oneshot::Receiver<Result<(),Issue>>)->Result<(),Issue>{
        self.owner.commands.send(command).await.unwrap();
        loop{tokio::select!{biased;
            event=self.owner.events.recv()=>match event{
                Some(value)=>self.observe(value),
                None=>return reply.await.unwrap_or(Err(Issue::Storage)),
            },
            result=&mut reply=>return result.unwrap(),
        }}
    }
    async fn start(&mut self,number:u64){let(tx,rx)=oneshot::channel();self.ack(Command::Start{number,generation:uuid(number),path:vec![],reply:tx},rx).await.unwrap();}
    async fn batch(&mut self,rows:Vec<Metadata>)->Result<(),Issue>{let(tx,rx)=oneshot::channel();self.ack(Command::Batch{number:self.number,rows,reply:tx},rx).await}
    async fn finish(&mut self){let(tx,rx)=oneshot::channel();self.ack(Command::Finish{number:self.number,state:State::Complete,reply:tx},rx).await.unwrap();}
    async fn page(&mut self,offset:i64,sort:Sort,descending:bool)->Vec<super::catalog::Row>{
        let snapshot=self.snapshot.unwrap();let token=uuid(999);let number=self.number;
        self.owner.commands.send(Command::Page(Page{token:token.clone(),number,generation:uuid(number),revision:snapshot.revision,offset,sort,descending,find:None})).await.unwrap();
        match self.owner.events.recv().await.unwrap(){Event::Page{request,rows}=>{assert_eq!(request.token,token);self.pages+=1;rows},_=>panic!("Expected a bounded sealed page")}
    }
    async fn drain(self){self.stop.store(true,Ordering::Release);assert!(self.owner.drain().await);}
}
async fn send_size_selection(selection:FolderSizeSelection,owner:&store::Owner)->Result<super::catalog::SelectedRow,Issue>{
    let(tx,rx)=oneshot::channel();owner.commands.send(Command::SelectedFolderSize{selection,reply:tx}).await.unwrap();rx.await.unwrap()
}
#[tokio::test(flavor="current_thread")]
async fn selected_folder_size_binds_full_completed_snapshot(){
    let mut driver=Driver::new(&format!("size-selected-snapshot-{}",std::process::id()),8<<20).await;
    driver.start(1).await;
    driver.batch(vec![Metadata{wire:"Folder".encode_utf16().collect(),attributes:0x10,size:0,modified:7,object:42}]).await.unwrap();
    driver.finish().await;
    let snapshot=driver.snapshot.unwrap();let observation=driver.page(0,Sort::Name,false).await[0].observation;
    let selected=FolderSizeSelection{request:uuid(998),number:1,generation:uuid(1),revision:snapshot.revision,
        count:snapshot.count,folders:snapshot.folders,state:1,observation};
    assert_eq!(send_size_selection(selected.clone(),&driver.owner).await.unwrap().item.object,42);
    for changed in [FolderSizeSelection{revision:selected.revision+1,..selected.clone()},
        FolderSizeSelection{count:selected.count+1,..selected.clone()},
        FolderSizeSelection{folders:0,..selected.clone()},
        FolderSizeSelection{state:2,..selected.clone()},
        FolderSizeSelection{number:2,..selected.clone()},
        FolderSizeSelection{observation:selected.observation+1,..selected.clone()},
        FolderSizeSelection{generation:uuid(2),..selected.clone()}]{
        assert!(matches!(send_size_selection(changed.clone(),&driver.owner).await,Err(Issue::Invalid)),"{changed:?}");
    }
    driver.drain().await;
}
#[tokio::test(flavor="current_thread")]
async fn fifty_thousand_rows_are_paged_then_retired_across_seventy_reads(){
    let began=Instant::now();let mut driver=Driver::new("scale-retire",32<<20).await;
    driver.start(1).await;
    for base in (0..50_000).step_by(500){driver.batch((base..base+500).map(row).collect()).await.unwrap();}
    driver.finish().await;assert_eq!(driver.snapshot.unwrap().count,50_000);
    for sort in [Sort::Name,Sort::Size,Sort::Modified]{for descending in [false,true]{
        for offset in [0,16,24_832,49_920]{
            let page=driver.page(offset,sort,descending).await;assert_eq!(page.len(),256.min(50_000-offset as usize));
            for (i,item)in page.iter().enumerate(){
                let rank=offset as u64+i as u64;
                let n=if rank<16{if descending{15-rank}else{rank}}else if descending{50_015-rank}else{rank};
                assert_eq!(String::from_utf16(&item.wire).unwrap(),format!("Item {n}"));assert_eq!(item.size,n*17);assert_eq!(item.modified,n*23);
            }
        }
    }}
    // The old harness's64-read limit is absent. Each terminal result is retired
    // before a new generation, so old observations cannot be served as current.
    for number in 2..=70{driver.start(number).await;driver.batch((0..3).map(row).collect()).await.unwrap();driver.finish().await;
        assert_eq!(driver.page(0,Sort::Name,false).await.len(),3);}
    assert_eq!(driver.number,70);assert!(driver.snapshots>=210);
    println!("B10 bounded writer:50000 rows,70 reads,{} exact pages,{} snapshots,{:.3}s",driver.pages,driver.snapshots,began.elapsed().as_secs_f64());
    driver.drain().await;
}
#[tokio::test(flavor="current_thread")]
async fn old_read_and_revision_requests_are_drained_as_stale(){
    let mut d=Driver::new("stale-reads",2<<20).await;d.start(1).await;d.batch(vec![row(1)]).await.unwrap();let old=d.snapshot.unwrap();
    d.finish().await;d.start(2).await;d.batch(vec![row(2)]).await.unwrap();d.finish().await;
    for (number,generation,revision)in [(1,uuid(1),old.revision),(2,uuid(2),0)]{
        d.owner.commands.send(Command::Page(Page{token:uuid(999),number,generation,revision,offset:0,sort:Sort::Name,descending:false,find:None})).await.unwrap();
        assert!(matches!(d.owner.events.recv().await,Some(Event::Stale{number:n,..})if n==number));
    }d.drain().await;
}
#[tokio::test(flavor="current_thread")]
async fn filtered_catalog_owner_pages_beyond_512_and_reuses_the_session(){
    let mut d=Driver::new("find-owner",8<<20).await;d.start(1).await;
    for base in [0,400]{d.batch((base..base+400).map(row).collect()).await.unwrap();}
    d.finish().await;let snapshot=d.snapshot.unwrap();assert_eq!((snapshot.count,snapshot.folders),(800,16));
    let id=uuid(901);let find=Find{token:id.clone(),number:1,generation:uuid(1),revision:snapshot.revision,
        count:snapshot.count,folders:snapshot.folders,state:snapshot.state as u8,query:"item".into()};
    d.owner.commands.send(Command::Find(find)).await.unwrap();
    assert!(matches!(d.owner.events.recv().await,Some(Event::FindResult{count:800,folders:16,..})));
    let page=Page{token:uuid(902),number:1,generation:uuid(1),revision:snapshot.revision,offset:512,
        sort:Sort::Name,descending:false,find:Some(id.clone())};
    d.owner.commands.send(Command::Page(page)).await.unwrap();
    let Some(Event::FindPage{rows,count,folders,..})=d.owner.events.recv().await else{panic!("filtered PAGE")};
    assert_eq!((rows.len(),count,folders),(256,800,16));
    assert_eq!(String::from_utf16(&rows[0].wire).unwrap(),"Item 512");
    let next=Find{token:uuid(903),number:1,generation:uuid(1),revision:snapshot.revision,
        count:snapshot.count,folders:snapshot.folders,state:snapshot.state as u8,query:"Item 7".into()};
    d.owner.commands.send(Command::Find(next)).await.unwrap();
    assert!(matches!(d.owner.events.recv().await,Some(Event::FindResult{count,..})if count>0&&count<800));
    d.owner.commands.send(Command::Page(Page{token:uuid(904),number:1,generation:uuid(1),revision:snapshot.revision,
        offset:0,sort:Sort::Name,descending:false,find:Some(id.clone())})).await.unwrap();
    assert!(matches!(d.owner.events.recv().await,Some(Event::FindPageStale{find,..})if find==id));
    d.start(2).await;d.finish().await;
    d.owner.commands.send(Command::Find(Find{token:uuid(905),number:1,generation:uuid(1),revision:snapshot.revision,
        count:snapshot.count,folders:snapshot.folders,state:snapshot.state as u8,query:"item".into()})).await.unwrap();
    assert!(matches!(d.owner.events.recv().await,Some(Event::FindStale{number:1,..})));
    d.drain().await;
}
#[tokio::test(flavor="current_thread")]
async fn duplicate_names_fail_without_sealing_the_catalog(){
    let mut d=Driver::new("duplicate-failure",2<<20).await;d.start(1).await;d.batch(vec![row(1)]).await.unwrap();
    assert_eq!(d.batch(vec![row(1)]).await,Err(Issue::Invalid));d.drain().await;
}
#[tokio::test(flavor="current_thread")]
async fn bounded_store_backpressure_and_stop_join_the_actual_thread(){
    let(path,files)=fixture("stop-backpressure");let stop=Arc::new(AtomicBool::new(false));let mut owner=store::Owner::start(path,files,2<<20,stop.clone());
    assert!(matches!(owner.events.recv().await,Some(Event::Ready)));
    let(tx,rx)=oneshot::channel();owner.commands.send(Command::Start{number:1,generation:uuid(1),path:vec![],reply:tx}).await.unwrap();assert!(rx.await.unwrap().is_ok());
    // Stop must drain even when publication is deliberately not consumed.
    let(tx,_)=oneshot::channel();owner.commands.send(Command::Batch{number:1,rows:(0..600).map(row).collect(),reply:tx}).await.unwrap();
    stop.store(true,Ordering::Release);assert!(tokio::time::timeout(Duration::from_secs(2),owner.drain()).await.unwrap());
}
#[tokio::test(flavor="current_thread")]
async fn stop_notification_is_sticky_for_late_waiters(){
    let stop=Stop::new();stop.set();tokio::time::timeout(Duration::from_millis(50),stop.wait()).await.unwrap();
    let live=Stop::new();let copy=live.clone();let task=tokio::spawn(async move{copy.wait().await;});tokio::task::yield_now().await;live.set();task.await.unwrap();
}
