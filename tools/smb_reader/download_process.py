"""Exact copied worker process + independent bounded D1 decoder for tests."""
import fcntl,hashlib,json,os,signal,socket,struct,time,uuid
from download_live_packet import d,child,audit
from download_compatible_candidate import current
def ordinary_image(binary):
    """Exact normal helper fingerprint, separate from copied-case provenance."""
    from vendor_verified_source import verify
    verify()
    expected=d.REPO/'.build/b10-network-tooling/ordinary-helpers/smb-browser-worker'
    record=json.loads((expected.parent/'build.json').read_bytes())
    if binary!=expected or binary.resolve()!=binary or binary.is_symlink()or binary.stat().st_nlink!=1 or record.get('binaries',{}).get('browser')!=d.digest(binary):raise RuntimeError('Exact ordinary helper required')
    for name,value in record.get('inputs',{}).get('sourceSHA256',{}).items():
        source=d.REPO/name
        if source.resolve()!=source or not source.is_file()or d.digest(source)!=value:raise RuntimeError('Ordinary helper source fingerprint changed')
    if not record.get('inputs',{}).get('sourceSHA256'):raise RuntimeError('Ordinary helper has no source fingerprint')
    return binary
class Process:
    def __init__(self,binary,root,label,mapping,mode='--selected-download-browser-worker',ordinary=False):
        if type(ordinary)is not bool:raise RuntimeError('Typed ordinary helper admission required')
        if ordinary:verified=ordinary_image(binary)
        else:_,verified=current(binary.parent.parent)
        if binary!=verified or mode not in ['--browser-worker','--selected-download-browser-worker']or set(mapping)!=set([3,4,5,6])or any(v<32 for v in mapping.values()):raise RuntimeError('Exact copied worker and descriptors required')
        self.root=root;self.label=label;self.code=None;self.stats=None;self.contained=False;self.began=time.monotonic()
        self.log=root/'evidence'/(label+'.stderr')
        with self.log.open('xb')as log,open('/dev/null','rb')as null:
            actions=[(os.POSIX_SPAWN_DUP2,null.fileno(),0),(os.POSIX_SPAWN_DUP2,log.fileno(),1),(os.POSIX_SPAWN_DUP2,log.fileno(),2)]
            actions +=[(os.POSIX_SPAWN_DUP2,source,target)for target,source in mapping.items()]
            self.pid=os.posix_spawn(str(binary),[str(binary),mode],{'LANG':'C','LC_ALL':'C'},file_actions=actions,setpgroup=0)
        d.put(root/'evidence'/(label+'.started.json'),dict(pid=self.pid,ownedGroup=self.pid,binarySHA256=d.digest(binary)))
    def poll(self):
        if self.code is None:
            found,status,stats=os.wait4(self.pid,os.WNOHANG)
            if found:self.code=os.waitstatus_to_exitcode(status);self.stats=stats
        return self.code
    def wait(self,seconds=10):
        until=time.monotonic()+seconds
        while self.poll()is None:
            if time.monotonic()>until or self.log.stat().st_size>65536:raise RuntimeError('Exact Download worker exit/output deadline')
            audit();time.sleep(.02)
        value=dict(actualExit=self.code,peakRSSBytes=self.stats.ru_maxrss,contained=self.contained,seconds=time.monotonic()-self.began,stderrSHA256=d.digest(self.log))
        path=self.root/'evidence'/(self.label+'.exit.json')
        if not path.exists():d.put(path,value)
        if value['peakRSSBytes']>256<<20:raise RuntimeError('Worker runtime RSS ceiling')
        return value
    def close(self):
        if self.poll()is None:
            self.contained=True
            for sig in [signal.SIGTERM,signal.SIGKILL]:
                try:os.killpg(self.pid,sig)
                except ProcessLookupError:pass
                except PermissionError:
                    until=time.monotonic()+.5
                    while self.poll()is None and time.monotonic()<until:time.sleep(.01)
                    if self.code is None:raise RuntimeError('Exact Download child remains inaccessible')
                try:self.wait(3);return
                except RuntimeError:pass
            raise RuntimeError('Exact Download child still running')
        self.wait()
class Channel:
    def __init__(self,sock,session):self.sock=sock;self.session=session;self.sequence=0;self.ordinal=0;self.number=0;self.last_event=None
    def send(self,text):
        if len(text)>16512 or not text.isascii():raise RuntimeError('Bounded generated command required')
        self.sock.sendall(text.encode('ascii'))
    def read(self,count):
        value=bytearray()
        while len(value)<count:
            part=self.sock.recv(count-len(value))
            if not part:raise RuntimeError('D1 unexpected EOF')
            value.extend(part)
        return bytes(value)
    def next(self):
        count=struct.unpack('>I',self.read(4))[0]
        if not 1<=count<=32768+97:raise RuntimeError('D1 frame bound')
        payload=self.read(count)
        if payload[0]==0:
            if len(payload)<98 or payload[:9]!=b'\0MEXSMBD1'or payload[9:45]!=self.session.encode()or struct.unpack('>Q',payload[45:53])[0]!=self.sequence:raise RuntimeError('D1 binary identity/sequence')
            token=str(uuid.UUID(bytes=payload[53:69])).upper();ordinal,sequence,offset,size=struct.unpack('>QQQI',payload[69:97])
            if not 0<size<=32768 or len(payload)!=97+size:raise RuntimeError('D1 binary extent')
            event=('data',token,ordinal,sequence,offset,payload[97:])
        else:
            if len(payload)>16512 or any(v<32 or v>126 for v in payload):raise RuntimeError('D1 noncanonical text')
            fields=payload.decode('ascii').split(' ')
            if len(fields)<4 or ''in fields or fields[:2]!=['MEXSMBD1',self.session]or str(self.sequence)!=fields[2]:raise RuntimeError('D1 text identity/sequence')
            event=tuple(fields[3:])
        self.sequence+=1;self.last_event=event;return event
    def listing(self,components=()):
        self.number+=1;generation=str(uuid.uuid4()).upper();path=','.join(n.encode('utf-16-be').hex()for n in components)or'-'
        self.send(f'READ {self.number} {generation} {path}\n');snapshot=None;began=False
        while True:
            event=self.next()
            if event[0]=='began':assert event==('began',str(self.number),generation);began=True
            elif event[0]=='snapshot':
                assert began and event[1:3]==(str(self.number),generation);snapshot=event
            elif event[0]=='idle':assert event==('idle',str(self.number),'complete')and snapshot[-1]=='1';break
            else:raise RuntimeError('Unexpected D1 listing phase '+event[0])
        token=str(uuid.uuid4()).upper();revision=snapshot[3];count=int(snapshot[4]);rows=[]
        self.send(f'PAGE {token} {self.number} {generation} {revision} 0 name 0\n')
        while True:
            event=self.next()
            if event[0]=='row':
                assert len(event)==8 and event[1:3]==(token,str(self.number));observation,attributes,size,modified=map(int,event[3:7])
                name=bytes.fromhex(event[7]).decode('utf-16-be');rows.append(dict(observation=observation,attributes=attributes,size=size,modified=modified,name=name,wire=event[7]))
            elif event[0]=='page':assert event==('page',token,str(self.number),generation,revision,'0',str(count))and len(rows)==count;return dict(number=self.number,generation=generation,revision=revision,rows=rows)
            else:raise RuntimeError('Unexpected D1 page phase '+event[0])
    def prepare(self,listing,name):
        row=next(r for r in listing['rows']if r['name']==name);self.ordinal+=1;token=str(uuid.uuid4()).upper()
        self.send(f"PREPARE_DOWNLOAD {token} {self.ordinal} {listing['number']} {listing['generation']} {listing['revision']} {row['observation']}\n")
        return row,token,self.ordinal
    def receive(self,listing,name):
        row,token,ordinal=self.prepare(listing,name);event=self.next()
        assert event==('downloadPrepared',token,str(ordinal),str(row['attributes']),str(row['size']),str(row['modified']),row['wire'])
        self.send(f'BEGIN_DOWNLOAD {token} {ordinal}\n');offset=sequence=0;digest=hashlib.sha256()
        while True:
            event=self.next()
            if event[0]=='data':
                _,request,n,seq,at,body=event
                assert (request,n,seq,at)==(token,ordinal,sequence,offset)and body==bytes((offset+i)%251 for i in range(len(body)))
                digest.update(body);offset+=len(body);sequence+=1
                self.send(f'ACK_DOWNLOAD {token} {ordinal} {sequence-1} {offset}\n')
            else:assert event==('downloadComplete',token,str(ordinal),str(offset))and offset==row['size'];return dict(bytes=offset,sha256=digest.hexdigest(),chunks=sequence)
    def end(self,reason=None,first=None):
        profile=drain=closed=None
        while closed is None:
            event=first if first is not None else self.next();first=None
            if event[0]=='profile':assert profile is None;profile=list(map(int,event[1].split(',')));assert len(profile)==19 and all(profile[i]==0 for i in [7,9,10,11,15,17,18])
            elif event[0]=='networkDrained':assert profile is not None and event[1:]in[('4','0','1'),('4','0','0')];drain=event[1:]
            elif event[0]=='closed':assert drain is not None and event[2:]==('1','0');closed=event[1]
            else:raise RuntimeError('Unexpected D1 terminal '+event[0])
        if reason:assert closed==reason
        assert self.sock.recv(1)==b'';return dict(profile=profile,joinedSocketTasks=int(drain[0]),pending=int(drain[1]),remaining=int(drain[2]),reason=closed)
def create_worker(binary,root,label,mode='--selected-download-browser-worker',ordinary=False):
    folder=child.directory(root/'state'/label);fds=[];left=right=None;worker=None
    try:
        descriptors=[os.open(folder,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW|os.O_CLOEXEC)]
        for name in ['catalog.sqlite','owner.lock']:descriptors.append(os.open(folder/name,os.O_CREAT|os.O_EXCL|os.O_RDWR|os.O_NOFOLLOW|os.O_CLOEXEC,0o600))
        fcntl.flock(descriptors[2],fcntl.LOCK_EX|fcntl.LOCK_NB);fds+=descriptors
        left,right=socket.socketpair();left.settimeout(15);sources=[right.fileno(),*descriptors]
        copies=[fcntl.fcntl(fd,fcntl.F_DUPFD_CLOEXEC,32)for fd in sources];fds+=copies
        worker=Process(binary,root,label,dict(zip([3,4,5,6],copies)),mode=mode,ordinary=ordinary);right.close();right=None
        for fd in copies:os.close(fd);fds.remove(fd)
        return left,worker,fds
    except BaseException:
        if left is not None:left.close()
        if worker is not None:worker.close()
        if right is not None:right.close()
        for fd in fds:os.close(fd)
        raise
def open_worker(binary,root,label,port,password):
    left,worker,fds=create_worker(binary,root,label)
    try:
        folder=root/'state'/label
        channel=Channel(left,str(uuid.uuid4()).upper())
        channel.send(f"MEXSMBD1 START {channel.session} encrypted 127.0.0.1 {port} 0 3132372e302e302e31 {'DownloadEncryptedQA'.encode('utf-16-be').hex()} {str(folder/'catalog.sqlite').encode().hex()} 8388608\n")
        channel.send('CREDENTIALS '+b'nobody'.hex()+' '+password.encode().hex()+' -\n')
        assert channel.next()==('connected','encrypted')
        return channel,worker,fds
    except BaseException:
        left.close();worker.close()
        for fd in fds:os.close(fd)
        raise
