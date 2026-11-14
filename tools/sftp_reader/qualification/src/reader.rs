//! One serial metadata-only SFTP-v3 reader. It spawns no task and does not own
//! SSH cryptography, authentication, a filesystem catalog or native UI.
use crate::wire::{self, Entry, Gate, Metadata, ReplyKind};
use std::time::Duration;
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Failure { Closed, Busy, Path, Timeout, Io, Truncated, Protocol(wire::Failure), Status(u32), IdentifierLimit, NameLimit }
impl From<wire::Failure> for Failure { fn from(value: wire::Failure) -> Self { Self::Protocol(value) } }
type Result<T> = std::result::Result<T, Failure>;

/// Local stream release is distinct from SSH-task/socket shutdown or a server
/// CLOSE acknowledgement. The enclosing SSH worker must prove its own drain.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Drain { pub directory_close_acknowledged: bool, pub stream_released: bool, pub shutdown_completed: bool }

pub struct Reader<S> {
    stream: Option<S>,
    gate: Gate,
    next_id: u32,
    directory: Option<Vec<u8>>,
    deadline: Duration,
    last_close_acknowledged: bool,
    #[cfg(feature="remote-action-qualification")]
    supports_server_copy: bool,
}

impl<S: AsyncRead + AsyncWrite + Unpin> Reader<S> {
    pub fn new(stream: S, deadline: Duration) -> Self {
        Self { stream: Some(stream), gate: Gate::default(), next_id: 1, directory: None,
            deadline: deadline.min(Duration::from_secs(30)), last_close_acknowledged: false,
            #[cfg(feature="remote-action-qualification")]
            supports_server_copy: false }
    }
    pub fn is_open(&self) -> bool { self.stream.is_some() }
    #[cfg(feature="remote-action-qualification")]
    pub fn enable_actions(&mut self){self.gate.enable_actions()}
    #[cfg(feature="remote-action-qualification")]
    pub fn supports_server_copy(&self)->bool{self.supports_server_copy}

    async fn exchange(&mut self, body: Vec<u8>) -> Result<Vec<u8>> {
        // Move ownership out before the first await. Dropping this future or a
        // partial-frame timeout drops the stream; it can never be reused at a
        // shifted framing position. Only a fully validated reply restores it.
        let mut stream = self.stream.take().ok_or(Failure::Closed)?;
        self.gate.sent(&body)?;
        let transfer = async {
            stream.write_all(&(body.len() as u32).to_be_bytes()).await.map_err(|_| Failure::Io)?;
            stream.write_all(&body).await.map_err(|_| Failure::Io)?;
            let mut header = [0u8;4];
            stream.read_exact(&mut header).await.map_err(|e| if e.kind()==std::io::ErrorKind::UnexpectedEof {
                Failure::Truncated } else { Failure::Io })?;
            let size = wire::frame_length(u32::from_be_bytes(header))?;
            let mut reply = vec![0u8;size];
            stream.read_exact(&mut reply).await.map_err(|e| if e.kind()==std::io::ErrorKind::UnexpectedEof {
                Failure::Truncated } else { Failure::Io })?;
            self.gate.received(&reply)?;
            Ok(reply)
        };
        match tokio::time::timeout(self.deadline,transfer).await {
            Ok(Ok(reply)) => { self.stream=Some(stream); Ok(reply) }
            Ok(Err(error)) => { self.directory=None; Err(error) }
            Err(_) => { self.directory=None; Err(Failure::Timeout) }
        }
    }
    async fn request(&mut self, kind: u8, field: &[u8]) -> Result<Vec<u8>> {
        let id = self.next_id;
        self.next_id = id.checked_add(1).ok_or(Failure::IdentifierLimit)?;
        let body = wire::encode_request(kind,id,field)?;
        self.exchange(body).await
    }
    #[cfg(feature="remote-action-qualification")]
    async fn action_request(&mut self,kind:u8,payload:&[u8])->Result<Vec<u8>>{
        let id=self.next_id;self.next_id=id.checked_add(1).ok_or(Failure::IdentifierLimit)?;
        let mut body=Vec::with_capacity(5+payload.len());body.push(kind);body.extend(id.to_be_bytes());body.extend(payload);
        self.exchange(body).await
    }
    fn path(value: &str) -> Result<&[u8]> {
        if value.len()>8192 || value.contains('\0') { return Err(Failure::Path); }
        Ok(value.as_bytes())
    }
    fn expected(&mut self, reply: &[u8], accepted: fn(ReplyKind)->bool) -> Result<()> {
        let kind = wire::incoming(reply)?.kind;
        if accepted(kind) { return Ok(()); }
        if let ReplyKind::Status(status) = kind { return Err(Failure::Status(status)); }
        self.stop();Err(Failure::Protocol(wire::Failure::Kind))
    }
    pub async fn initialize(&mut self) -> Result<()> {
        let version=self.exchange(vec![1,0,0,0,3]).await?;
        #[cfg(feature="remote-action-qualification")]
        {self.supports_server_copy=wire::server_copy_capability(&version)?;}
        #[cfg(not(feature="remote-action-qualification"))]
        {let _=version;}
        Ok(())
    }
    pub async fn real_path(&mut self, path: &str) -> Result<String> {
        let body = self.request(16,Self::path(path)?).await?;
        self.expected(&body,|k|matches!(k,ReplyKind::Names(1)))?;
        let values = wire::decode_names(&body,true).map_err(|e| { self.stop(); Failure::Protocol(e) })?;
        Ok(values.into_iter().next().ok_or(Failure::Protocol(wire::Failure::Count))?.name)
    }
    pub async fn open_directory(&mut self, path: &str) -> Result<()> {
        if self.directory.is_some() { return Err(Failure::Busy); }
        self.last_close_acknowledged=false;
        let body = self.request(11,Self::path(path)?).await?;
        self.expected(&body,|k|k==ReplyKind::Handle)?;
        self.directory=Some(wire::decode_handle(&body)?);Ok(())
    }
    pub async fn open_location(&mut self,path:&str)->Result<String>{
        let canonical=self.real_path(path).await?;self.open_directory(&canonical).await?;Ok(canonical)
    }
    /// A complete validated STATUS leaves framing usable. No timeout, I/O,
    /// malformed reply or failed prior CLOSE can pass this request-only gate.
    pub fn directory_rejection(&self,error:Failure)->Option<u8>{
        if self.stream.is_none()||self.directory.is_some(){return None}
        match error{Failure::Status(code @ 2..=4)=>Some(code as u8),_=>None}
    }
    async fn next_batch_limited(&mut self,maximum_name_bytes:Option<usize>) -> Result<Option<Vec<Entry>>> {
        let handle=self.directory.clone().ok_or(Failure::Closed)?;
        let body=self.request(12,&handle).await?;
        if wire::incoming(&body)?.kind==ReplyKind::Status(1) { return Ok(None); }
        self.expected(&body,|k|matches!(k,ReplyKind::Names(_)))?;
        let entries=match maximum_name_bytes{
            Some(maximum)=>wire::decode_names_limited(&body,false,maximum),
            None=>wire::decode_names(&body,false),
        };
        match entries{
            Ok(value)=>Ok(Some(value)),
            // The full packet was structurally admitted by incoming(), so the
            // selected-folder size policy can still CLOSE this owned handle.
            Err(wire::Failure::NameLimit)=>Err(Failure::NameLimit),
            Err(error)=>{self.stop();Err(Failure::Protocol(error))},
        }
    }
    pub async fn next_batch(&mut self)->Result<Option<Vec<Entry>>>{self.next_batch_limited(None).await}
    pub async fn next_folder_size_batch(&mut self)->Result<Option<Vec<Entry>>>{self.next_batch_limited(Some(255)).await}
    pub async fn metadata(&mut self, path: &str) -> Result<Metadata> {
        // LSTAT observes a link itself, never follows it to read a body.
        let body=self.request(7,Self::path(path)?).await?;
        self.expected(&body,|k|k==ReplyKind::Attrs)?;
        Ok(wire::decode_attrs(&body)?)
    }
    #[cfg(feature="remote-action-qualification")]
    pub async fn metadata_optional(&mut self,path:&str)->Result<Option<Metadata>>{
        match self.metadata(path).await{Ok(value)=>Ok(Some(value)),Err(Failure::Status(2))=>Ok(None),Err(error)=>Err(error)}
    }
    /// SFTP v3's standard requests. No posix-rename extension, shell or body.
    #[cfg(feature="remote-action-qualification")]
    pub async fn create_directory(&mut self,path:&str)->Result<()>{
        let mut field=Vec::new();Self::append_path(&mut field,path)?;field.extend(0u32.to_be_bytes());
        let body=self.action_request(14,&field).await?;self.expected(&body,|k|k==ReplyKind::Status(0))
    }
    #[cfg(feature="remote-action-qualification")]
    pub async fn rename_standard(&mut self,old:&str,new:&str)->Result<()>{
        let mut field=Vec::new();Self::append_path(&mut field,old)?;Self::append_path(&mut field,new)?;
        let body=self.action_request(18,&field).await?;self.expected(&body,|k|k==ReplyKind::Status(0))
    }
    #[cfg(feature="remote-action-qualification")]
    pub async fn remove_file(&mut self,path:&str)->Result<()>{
        let mut field=Vec::new();Self::append_path(&mut field,path)?;
        let body=self.action_request(13,&field).await?;self.expected(&body,|k|k==ReplyKind::Status(0))
    }
    #[cfg(feature="remote-action-qualification")]
    pub async fn remove_empty_directory(&mut self,path:&str)->Result<()>{
        let mut field=Vec::new();Self::append_path(&mut field,path)?;
        let body=self.action_request(15,&field).await?;self.expected(&body,|k|k==ReplyKind::Status(0))
    }
    /// One bounded metadata probe; no child body is opened or retained.
    #[cfg(feature="remote-action-qualification")]
    pub async fn directory_is_empty(&mut self,path:&str)->Result<Option<bool>>{
        self.open_directory(path).await?;
        let observed=async {
            for _ in 0..16 {
                match self.next_batch().await? {
                    None=>return Ok(Some(true)),
                    Some(entries) if !entries.is_empty()=>return Ok(Some(false)),
                    Some(_)=>{},
                }
            }
            Ok(None)
        }.await;
        let closed=self.close_directory().await;
        // A failed CLOSE leaves handle ownership uncertain, even when READDIR
        // itself returned a safe status. Stop this channel before the action
        // worker can treat that status as a reusable preflight refusal.
        if closed.is_err(){self.stop();return Err(Failure::Closed)}
        observed
    }
    #[cfg(feature="remote-action-qualification")]
    fn append_path(field:&mut Vec<u8>,path:&str)->Result<()> {
        let bytes=Self::path(path)?;field.extend((bytes.len() as u32).to_be_bytes());field.extend(bytes);Ok(())
    }
    pub async fn close_directory(&mut self) -> Result<()> {
        let Some(handle)=self.directory.clone() else { return Ok(()); };
        let body=self.request(4,&handle).await?;
        self.expected(&body,|k|k==ReplyKind::Status(0))?;
        self.directory=None;self.last_close_acknowledged=true;Ok(())
    }
    pub fn stop(&mut self) {
        self.stream.take();
        if self.directory.is_some() { self.last_close_acknowledged=false; }
        self.directory=None;
    }
    pub async fn close(&mut self) -> Drain {
        let acknowledged=self.close_directory().await.is_ok() && self.last_close_acknowledged;
        let shutdown=if let Some(mut stream)=self.stream.take() {
            matches!(tokio::time::timeout(self.deadline,stream.shutdown()).await,Ok(Ok(())))
        } else { false };
        self.directory=None;
        Drain { directory_close_acknowledged:acknowledged, stream_released:self.stream.is_none(), shutdown_completed:shutdown }
    }
}

#[cfg(test)]
mod tests;
