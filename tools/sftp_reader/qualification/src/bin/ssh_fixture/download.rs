//! Generated body bytes only; no filesystem or personal server endpoint.
use super::*;
pub const LENGTH:u64=1024*1024+17;
pub fn generated(offset:u64)->u8{((offset*31+7)%251)as u8}
pub async fn serve(mut stream:ChannelStream<server::Msg>,scenario:String,counts:Arc<Counts>){
    let size=if scenario=="download-empty"{0}else{LENGTH};let mut fstats=0;let mut offset=0;
    loop{
        let Ok(length)=stream.read_u32().await else{return};assert!((1..=8192+32).contains(&length));
        let mut body=vec![0;length as usize];if stream.read_exact(&mut body).await.is_err(){return}
        counts.requests.fetch_add(1,Ordering::SeqCst);
        let kind=body[0];let id=if kind==1{0}else{u32::from_be_bytes(body[1..5].try_into().unwrap())};
        let reply=match kind{
            1=>{assert_eq!(body,[1,0,0,0,3]);vec![2,0,0,0,3]},
            7|8=>{
                let count=u32::from_be_bytes(body[5..9].try_into().unwrap())as usize;let value=&body[9..9+count];assert_eq!(body.len(),9+count);
                if kind==7{assert_eq!(value,b"/generated/Requested.bin")}else{assert_eq!(value,b"opaque\0\xff");fstats+=1}
                let mut b=head(105,id);word(&mut b,13);b.extend(size.to_be_bytes());word(&mut b,0o100644);word(&mut b,0);
                word(&mut b,if scenario=="download-changed"&&fstats==2{20}else{19});b
            },
            3=>{
                let count=u32::from_be_bytes(body[5..9].try_into().unwrap())as usize;
                assert_eq!(&body[9..9+count],b"/generated/Requested.bin");assert_eq!(&body[9+count..],&[0,0,0,1,0,0,0,0]);
                if scenario=="download-denied"{status(id,3)}else{let mut b=head(102,id);text(&mut b,b"opaque\0\xff");b}
            },
            5=>{
                counts.file_reads.fetch_add(1,Ordering::SeqCst);
                let count=u32::from_be_bytes(body[5..9].try_into().unwrap())as usize;assert_eq!(&body[9..9+count],b"opaque\0\xff");
                let rest=&body[9+count..];assert_eq!(rest.len(),12);assert_eq!(u64::from_be_bytes(rest[..8].try_into().unwrap()),offset);
                let wanted=u32::from_be_bytes(rest[8..].try_into().unwrap())as u64;assert!((1..=32768).contains(&wanted));
                if scenario=="download-stop"{let mut byte=[0];let _=stream.read(&mut byte).await;return}
                if offset==size{status(id,1)}else{
                    let end=(offset+wanted).min(size);let bytes=(offset..end).map(generated).collect::<Vec<_>>();offset=end;
                    let mut b=head(103,if scenario=="download-wrong-id"{id+1}else{id});text(&mut b,&bytes);b
                }
            },
            4=>{
                counts.closes.fetch_add(1,Ordering::SeqCst);
                if scenario=="download-lost-close"{let mut byte=[0];let _=stream.read(&mut byte).await;return}status(id,0)
            },
            _=>panic!("Generated body peer received prohibited operation"),
        };
        if stream.write_u32(reply.len()as u32).await.is_err()||stream.write_all(&reply).await.is_err(){return}
    }
}
