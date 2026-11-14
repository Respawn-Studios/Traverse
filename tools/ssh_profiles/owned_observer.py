"""One bounded observer of an unreaped direct child, independent of disk audits.

Only the owner reaps. The same lock covers each observation and wait4, so an
observer cannot inspect or signal a recycled PID after actual child exit.
Callbacks must be bounded and must not call poll/wait/reap on the Popen object.
Closing joins the real callback; a cancellation flag is never reported as drain.
"""
import os,threading,time

class OwnedObserver:
 def __init__(self,child,callback):
  if child.returncode is not None:raise RuntimeError('Observer requires an unreaped direct child')
  self.child=child;self.callback=callback;self.lock=threading.Lock();self.stop=threading.Event()
  self.result=None;self.error_type=None;self.calls=0;self.maximum_call=0.;self.maximum_interval=0.;self.last=None
  self.began=time.monotonic();self.closed_at=None
  self.thread=threading.Thread(target=self._loop,name='Traverse.OwnedProcessObserver',daemon=False)
  self.thread.start()
 def _loop(self):
  while not self.stop.is_set():
   with self.lock:
    if self.stop.is_set():break
    began=time.monotonic()
    if self.last is not None:self.maximum_interval=max(self.maximum_interval,began-self.last)
    self.last=began
    try:self.callback(self.child.pid)
    except BaseException as error:
     self.error_type=type(error).__name__;self.stop.set()
    finally:self.calls+=1;self.maximum_call=max(self.maximum_call,time.monotonic()-began)
   self.stop.wait(.02)
 def reap(self):
  with self.lock:
   if self.result is not None:return self.result
   if self.child.returncode is not None:raise RuntimeError('Direct child was reaped outside its observer owner')
   found,status,stats=os.wait4(self.child.pid,os.WNOHANG)
   if found:
    self.child.returncode=os.waitstatus_to_exitcode(status);self.result=(found,status,stats);self.stop.set()
   return self.result or(0,0,None)
 @property
 def failure(self):
  with self.lock:return self.error_type
 def close(self):
  self.stop.set()
  # These callers use a finite ps timeout. Keep ownership if a callback ever
  # violates its contract; do not release an exact child/PID before actual drain.
  self.thread.join()
  if self.closed_at is None:self.closed_at=time.monotonic()
 def proof(self):
  if self.thread.is_alive():raise RuntimeError('Observer proof requires actual callback drain')
  return dict(independent=True,callbacks=self.calls,maximumCallbackSeconds=self.maximum_call,
   maximumLoopIntervalSeconds=self.maximum_interval,failureType=self.error_type,drained=True,
   seconds=(self.closed_at or time.monotonic())-self.began,noObservationAfterReap=True)
