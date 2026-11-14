//! Generated metadata only. A nonzero exit is the retained candidate defect.
use bytes::Bytes;
use russh_sftp::protocol::Packet;

fn word(bytes: &mut Vec<u8>, value: u32) { bytes.extend(value.to_be_bytes()); }
fn text(bytes: &mut Vec<u8>, value: &[u8]) { word(bytes,value.len() as u32);bytes.extend(value); }

fn main() {
    let mut body=vec![104];word(&mut body,1);word(&mut body,2);
    text(&mut body,b"first");text(&mut body,b"");word(&mut body,0x8000_0000);word(&mut body,0);
    text(&mut body,b"second");text(&mut body,b"");word(&mut body,0);
    let mut data=Bytes::from(body);
    let (decoded,count,first,second,second_empty)=match Packet::try_from(&mut data) {
        Ok(Packet::Name(names)) => (true,names.files.len(),names.files.first().is_some_and(|v|v.filename=="first"),
            names.files.get(1).is_some_and(|v|v.filename=="second"),names.files.get(1).is_some_and(|v|v.filename.is_empty())),
        _ => (false,0,false,false,false),
    };
    let correct=decoded && count==2 && first && second;
    println!("{{\"passed\":{correct},\"generatedMetadataOnly\":true,\"publishedVersion\":\"3.0.1\",\"decoded\":{decoded},\"count\":{count},\"firstNameCorrect\":{first},\"secondNameCorrect\":{second},\"secondNameEmpty\":{second_empty},\"networkRequests\":0}}");
    if !correct { std::process::exit(1); }
}
