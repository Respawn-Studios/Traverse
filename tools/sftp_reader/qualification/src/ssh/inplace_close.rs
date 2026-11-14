//! One actual subsystem-close observer per serial Edit. No SSH transport owner.
use std::sync::{Arc,Mutex};
use tokio::sync::oneshot;
use crate::upload::Failure;
#[derive(Default)]pub(super) struct CloseRegistry { inner:Mutex<State> }
#[derive(Default)]struct State { next:u64, pending:Option<Pending> }
struct Pending { ticket:u64, channel:Option<u32>, early:Vec<u32>, failed:bool,
    done:bool, sender:Option<oneshot::Sender<bool>> }
pub(super) struct CloseWatch { registry:Arc<CloseRegistry>, ticket:u64,
    receiver:Option<oneshot::Receiver<bool>> }
impl CloseRegistry {
    pub(super) fn begin(self:&Arc<Self>)->Result<CloseWatch,Failure> {
        let mut state=self.inner.lock().unwrap();
        if state.pending.is_some(){return Err(Failure::Protocol)}
        state.next=state.next.checked_add(1).ok_or(Failure::Protocol)?;
        let ticket=state.next;let(tx,rx)=oneshot::channel();
        state.pending=Some(Pending{ticket,channel:None,early:Vec::new(),failed:false,done:false,sender:Some(tx)});
        Ok(CloseWatch{registry:self.clone(),ticket,receiver:Some(rx)})
    }
    /// Only russh's ACTUAL authenticated channel-close callback calls this.
    pub(super) fn observed(&self,channel:u32) {
        let mut state=self.inner.lock().unwrap();let Some(p)=state.pending.as_mut()else{return};
        if p.done||p.failed{return}
        if let Some(expected)=p.channel {
            if expected==channel{p.done=true;if let Some(tx)=p.sender.take(){let _=tx.send(true);}}
        }else if !p.early.contains(&channel){
            // Bounded close-before-binding mailbox. Unrelated closes cannot
            // complete this watch. Overflow refuses rather than growing history.
            if p.early.len()==8{p.failed=true;if let Some(tx)=p.sender.take(){let _=tx.send(false);}}
            else{p.early.push(channel);}
        }
    }
}
impl CloseWatch {
    pub(super) fn bind(&self,channel:u32)->Result<(),Failure> {
        let mut state=self.registry.inner.lock().unwrap();let p=state.pending.as_mut().ok_or(Failure::Protocol)?;
        if p.ticket!=self.ticket||p.channel.is_some()||p.failed{return Err(Failure::Protocol)}
        p.channel=Some(channel);
        if p.early.contains(&channel){p.done=true;if let Some(tx)=p.sender.take(){let _=tx.send(true);}}
        p.early.clear();Ok(())
    }
    pub(super) async fn wait(mut self,stop:Option<Arc<std::sync::atomic::AtomicBool>>,
        deadline:std::time::Duration)->Result<(),Failure> {
        let receiver=self.receiver.take().ok_or(Failure::Protocol)?;
        let outcome=tokio::select!{biased;
            _=crate::upload::wait_stop(stop)=>return Err(Failure::Stopped),
            value=tokio::time::timeout(deadline,receiver)=>value.map_err(|_|Failure::Timeout)?,
        };
        match outcome {Ok(true)=>Ok(()),_=>Err(Failure::Protocol)}
    }
}
impl Drop for CloseWatch {
    fn drop(&mut self){let mut state=self.registry.inner.lock().unwrap();
        if state.pending.as_ref().is_some_and(|p|p.ticket==self.ticket){state.pending=None;}}
}

#[cfg(test)]mod tests {
    use super::*;use std::time::Duration;
    #[tokio::test(flavor="current_thread")]async fn missing_close_and_eof_alone_cannot_release_rejection(){
        let owner=Arc::new(CloseRegistry::default());let watch=owner.begin().unwrap();watch.bind(7).unwrap();
        // No callback is delivered for EOF or a shutdown request.
        assert_eq!(watch.wait(None,Duration::from_millis(20)).await,Err(Failure::Timeout));
        assert!(owner.inner.lock().unwrap().pending.is_none());
    }
    #[tokio::test(flavor="current_thread")]async fn matching_close_waits_and_foreign_callback_cannot_complete(){
        let owner=Arc::new(CloseRegistry::default());let watch=owner.begin().unwrap();watch.bind(7).unwrap();
        let task=tokio::spawn(watch.wait(None,Duration::from_secs(1)));
        tokio::task::yield_now().await;assert!(!task.is_finished());
        owner.observed(8);tokio::task::yield_now().await;assert!(!task.is_finished());
        owner.observed(7);assert_eq!(task.await.unwrap(),Ok(()));
    }
    #[tokio::test(flavor="current_thread")]async fn callback_before_binding_is_not_lost(){
        let owner=Arc::new(CloseRegistry::default());let watch=owner.begin().unwrap();
        owner.observed(2);owner.observed(7);watch.bind(7).unwrap();
        assert_eq!(watch.wait(None,Duration::from_millis(20)).await,Ok(()));
        // Prior callback history cannot complete a later owner/channel.
        let next=owner.begin().unwrap();next.bind(9).unwrap();
        assert_eq!(next.wait(None,Duration::from_millis(20)).await,Err(Failure::Timeout));
    }
    #[tokio::test(flavor="current_thread")]async fn stop_wins_over_healthy_rejection_and_history_is_bounded(){
        let owner=Arc::new(CloseRegistry::default());let watch=owner.begin().unwrap();watch.bind(7).unwrap();owner.observed(7);
        let stop=Arc::new(std::sync::atomic::AtomicBool::new(true));
        assert_eq!(watch.wait(Some(stop),Duration::from_millis(20)).await,Err(Failure::Stopped));
        let next=owner.begin().unwrap();for id in 0..9{owner.observed(id);}
        assert_eq!(next.bind(7),Err(Failure::Protocol));drop(next);
        assert!(owner.inner.lock().unwrap().pending.is_none());
    }
}
