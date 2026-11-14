"""Track identities of one native build's actual descendants, never name-matched apps."""
import ctypes,os,signal,subprocess,time
from pathlib import Path

class BSDInfo(ctypes.Structure):
    # Public sys/proc_info.h; the qualification compares the SDK's sizeof and
    # start-time offsets against this exact structure before real use.
    _fields_=[(name,ctypes.c_uint32)for name in ['flags','status','xstatus','pid','parent','uid','gid','ruid','rgid','svuid','svgid','reserved']]+[
        ('comm',ctypes.c_char*16),('name',ctypes.c_char*32)]+[(name,ctypes.c_uint32)for name in ['files','group','job','tty','ttygroup']]+[
        ('nice',ctypes.c_int32),('start_seconds',ctypes.c_uint64),('start_microseconds',ctypes.c_uint64)]
_proc=ctypes.CDLL('/usr/lib/libproc.dylib',use_errno=True)
_proc.proc_pidinfo.argtypes=[ctypes.c_int,ctypes.c_int,ctypes.c_uint64,ctypes.c_void_p,ctypes.c_int]
_proc.proc_pidinfo.restype=ctypes.c_int

def native_birth(pid,uid):
    value=BSDInfo();count=_proc.proc_pidinfo(pid,3,0,ctypes.byref(value),ctypes.sizeof(value))
    if count!=ctypes.sizeof(value)or value.pid!=pid or value.uid!=uid:return None
    return value.start_seconds,value.start_microseconds,value.parent

def observation():
    output=subprocess.run(['/bin/ps','-axo','pid=,ppid=,uid=,rss=,lstart=,comm='],check=True,capture_output=True,text=True,timeout=3)
    rows={}
    for line in output.stdout.splitlines():
        fields=line.strip().split(None,9)
        if len(fields)!=10:continue
        pid,parent,uid,rss=map(int,fields[:4])
        if uid!=os.getuid():continue
        born=native_birth(pid,uid)
        if born is None:continue
        rows[pid]=dict(pid=pid,parent=born[2],uid=uid,rss=rss*1024,birth=born[:2],started=' '.join(fields[4:9]),executable=fields[9])
    return rows

def identity(row):return row['pid'],row['uid'],row.get('birth',row['started'])

def descendants(rows,root,known):
    active={pid for pid,stamp in known.items()if pid in rows and identity(rows[pid])==stamp}
    if root in rows and root not in known:active.add(root)
    while True:
        added={pid for pid,row in rows.items()if row['parent']in active and row['uid']==os.getuid()}
        if added<=active:return active
        active|=added

class NativeBuildOwner:
    def __init__(self,pid,parent=None):
        self.pid=pid;self.known={};self.peak=0;self.total_peak=0;self.samples=0;self.terminated=[]
        rows=observation();root=rows.get(pid)
        if root is None or root['parent']!=(os.getpid()if parent is None else parent)or root['uid']!=os.getuid()or Path(root['executable']).name!='xcodebuild':
            raise RuntimeError('Exact direct native build owner required')
        self.known[pid]=identity(root);self.observe(rows)
    def observe(self,rows=None):
        rows=observation()if rows is None else rows
        active=descendants(rows,self.pid,self.known)
        if len(active)>128:raise RuntimeError('Native build descendant bound')
        total=0
        for pid in active:
            row=rows[pid];stamp=identity(row)
            if pid in self.known and self.known[pid]!=stamp:raise RuntimeError('Native build identity changed')
            self.known[pid]=stamp
            if len(self.known)>1024:raise RuntimeError('Retained native descendant identity bound')
            if Path(row['executable']).name in ['swift-frontend','clang','rustc']:
                self.samples+=1;self.peak=max(self.peak,row['rss']);total+=row['rss']
        self.total_peak=max(self.total_peak,total)
        return rows,active
    def stop(self):
        rows,active=self.observe()
        # Every PID is rechecked immediately. Xcode frontends own separate
        # process groups; signalling just xcodebuild's group is insufficient.
        for sig,seconds in [(signal.SIGTERM,3),(signal.SIGKILL,2)]:
            for pid in sorted(active,reverse=True):
                fresh=observation().get(pid)
                if fresh is not None and identity(fresh)==self.known[pid]:
                    try:os.kill(pid,sig);self.terminated.append(dict(pid=pid,signal=int(sig)))
                    except ProcessLookupError:pass
            deadline=time.monotonic()+seconds
            while time.monotonic()<deadline:
                rows,active=self.observe()
                if not active:return
                time.sleep(.05)
        # The root may be a waitable zombie; its exact Popen owner reaps it.
        survivors=active-{self.pid}
        if survivors:raise RuntimeError('Owned native build descendants remain')
    def report(self):
        rows=observation()
        active=[pid for pid,stamp in self.known.items()if pid in rows and identity(rows[pid])==stamp]
        return dict(observedPeakCompilerRSSBytes=self.peak,observedPeakAggregateCompilerRSSBytes=self.total_peak,samples=self.samples,trackedProcesses=len(self.known),
            liveObservedPIDs=active,terminated=self.terminated,scope='identity-checked-root-and-transitive-descendants')
