//! Immutable generated SFTP metadata workload. No disk corpus or SSH endpoint.
use macexplorer_sftp_reader_qualification::{reader::Reader,wire};
use russh_sftp::{client::{Config,RawSftpSession},protocol::StatusCode};
use std::{sync::{Arc,atomic::{AtomicUsize,Ordering}},time::{Duration,Instant}};
use tokio::io::{AsyncReadExt,AsyncWriteExt,DuplexStream};

fn word(b:&mut Vec<u8>,v:u32){b.extend(v.to_be_bytes());}
fn text(b:&mut Vec<u8>,v:&[u8]){word(b,v.len()as u32);b.extend(v);}
fn head(kind:u8,id:u32)->Vec<u8>{let mut b=vec![kind];word(&mut b,id);b}
async fn send(s:&mut DuplexStream,b:&[u8]){s.write_u32(b.len()as u32).await.unwrap();s.write_all(b).await.unwrap();}
async fn fixture(mut s:DuplexStream,mut total:usize,observed:Arc<AtomicUsize>){
    let mut index=0usize;
    loop {
        let Ok(length)=s.read_u32().await else{return};assert!(length as usize<=wire::MAX_PACKET);
        let mut body=vec![0;length as usize];s.read_exact(&mut body).await.unwrap();
        let request=wire::outgoing(&body).unwrap();let id=request.id.unwrap_or(0);
        let reply=match request.kind {
            1=>vec![2,0,0,0,3],
            11=>{let mut b=head(102,id);text(&mut b,b"generated-handle");b},
            12 if total>0=>{
                let count=total.min(256);total-=count;let mut b=head(104,id);word(&mut b,count as u32);
                for _ in 0..count {
                    let name=format!("Generated file {index:06}.txt");text(&mut b,name.as_bytes());text(&mut b,b"");word(&mut b,13);
                    b.extend((1000+index as u64).to_be_bytes());word(&mut b,0o100644);word(&mut b,0);word(&mut b,index as u32);index+=1;
                }b
            }
            12|4=>{let mut b=head(101,id);word(&mut b,if request.kind==4{0}else{1});text(&mut b,b"");text(&mut b,b"");b},
            _=>panic!("Unexpected generated request"),
        };
        observed.fetch_add(1,Ordering::SeqCst);send(&mut s,&reply).await;
        if request.kind==4{return}
    }
}
fn accumulate(name:&str,size:u64,mode:u32,modified:u32,count:&mut usize,total:&mut u64,checksum:&mut u64){
    *count+=1;*total=total.checked_add(size).unwrap();
    for b in name.as_bytes().iter().copied().chain(size.to_be_bytes()).chain(mode.to_be_bytes()).chain(modified.to_be_bytes()){
        *checksum=checksum.wrapping_mul(1099511628211)^b as u64;
    }
}
fn main(){
    let lane=std::env::args().nth(1).unwrap_or_default();assert!(["reference","serial"].contains(&lane.as_str()));
    let runtime=tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
    let handle=runtime.handle().clone();let start=Instant::now();
    let(count,total,checksum,requests)=runtime.block_on(async{
        let(client,server)=tokio::io::duplex(32768);let observed=Arc::new(AtomicUsize::new(0));
        let fixture=tokio::spawn(fixture(server,100000,observed.clone()));
        let(mut count,mut total,mut checksum)=(0usize,0u64,1469598103934665603u64);
        if lane=="serial"{
            let mut reader=Reader::new(client,Duration::from_secs(2));reader.initialize().await.unwrap();reader.open_directory(".").await.unwrap();
            while let Some(items)=reader.next_batch().await.unwrap(){for item in items{
                accumulate(&item.name,item.metadata.size.unwrap(),item.metadata.permissions.unwrap(),item.metadata.modified.unwrap(),
                    &mut count,&mut total,&mut checksum);
            }}
            let drain=reader.close().await;assert!(drain.directory_close_acknowledged&&drain.stream_released);
        }else{
            let raw=RawSftpSession::new_with_config(client,Config{request_timeout_secs:2,max_concurrent_reads:1,max_concurrent_writes:1,..Default::default()});
            raw.init().await.unwrap();let directory=raw.opendir(".").await.unwrap().handle;
            loop{
                match raw.readdir(directory.clone()).await{
                    Ok(names)=>for item in names.files{
                        accumulate(&item.filename,item.attrs.size.unwrap(),item.attrs.permissions.unwrap(),item.attrs.mtime.unwrap(),
                            &mut count,&mut total,&mut checksum);
                    },
                    Err(russh_sftp::client::error::Error::Status(status))if status.status_code==StatusCode::Eof=>break,
                    _=>panic!("Generated reference failed"),
                }
            }
            raw.close(directory).await.unwrap();raw.close_session().unwrap();drop(raw);
        }
        fixture.await.unwrap();
        let deadline=Instant::now()+Duration::from_secs(1);
        while tokio::runtime::Handle::current().metrics().num_alive_tasks()>0{
            assert!(Instant::now()<deadline,"Generated tasks did not drain");tokio::task::yield_now().await;
        }
        (count,total,checksum,observed.load(Ordering::SeqCst))
    });
    let seconds=start.elapsed().as_secs_f64();drop(runtime);
    let tasks=handle.metrics().num_alive_tasks();assert_eq!(tasks,0);
    println!("{{\"lane\":\"{lane}\",\"records\":{count},\"totalBytes\":{total},\"checksum\":{checksum},\"requests\":{requests},\"seconds\":{seconds},\"tasksAfterDrain\":{tasks},\"networkRequests\":0,\"nativePipeline\":false}}");
}
