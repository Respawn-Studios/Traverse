//! Generated, offline-only signature interoperability probe. Not bundled.
use std::io::{Read,Write};
use russh::{Signer,keys::{HashAlg,agent::AgentIdentity}};
use macexplorer_sftp_reader_qualification::key_auth::{PreparedKey,MAXIMUM_KEY_BYTES,MAXIMUM_PASSPHRASE_BYTES};
use zeroize::Zeroizing;
fn take<'a>(bytes:&mut &'a[u8],cap:usize)->Result<&'a[u8],()>{
    if bytes.len()<4{return Err(())}let size=u32::from_be_bytes(bytes[..4].try_into().map_err(|_|())?)as usize;
    *bytes=&bytes[4..];if size>cap||bytes.len()<size{return Err(())}let result=&bytes[..size];*bytes=&bytes[size..];Ok(result)
}
#[tokio::main(flavor="current_thread")]
async fn main()->std::process::ExitCode{
    if std::env::args().collect::<Vec<_>>().get(1).map(String::as_str)!=Some("--generated-signature")||std::env::args().count()!=2{return std::process::ExitCode::from(2)}
    let mut data=Zeroizing::new(Vec::new());if std::io::stdin().take(40961).read_to_end(&mut data).is_err()||data.len()>40960{return std::process::ExitCode::from(3)}
    let result=async{
        let mut cursor=&data[..];let key=Zeroizing::new(take(&mut cursor,MAXIMUM_KEY_BYTES)?.to_vec());
        let pass=Zeroizing::new(std::str::from_utf8(take(&mut cursor,MAXIMUM_PASSPHRASE_BYTES)?).map_err(|_|())?.to_owned());
        let message=take(&mut cursor,4096)?.to_vec();let hash=match cursor{[0]=>None,[1]=>Some(HashAlg::Sha256),[2]=>Some(HashAlg::Sha512),_=>return Err(())};
        let mut key=PreparedKey::decode(key,pass).map_err(|_|())?;
        let public=key.public().to_bytes().map_err(|_|())?;
        let signed=key.auth_sign(&AgentIdentity::from(key.public().clone()),hash,message).await.map_err(|_|())?;
        let mut out=std::io::stdout().lock();out.write_all(&(public.len()as u32).to_be_bytes()).map_err(|_|())?;out.write_all(&public).map_err(|_|())?;
        out.write_all(&(signed.len()as u32).to_be_bytes()).map_err(|_|())?;out.write_all(&signed).map_err(|_|())?;Ok::<_,()>(())
    }.await;
    if result.is_err(){std::process::ExitCode::from(4)}else{std::process::ExitCode::SUCCESS}
}
