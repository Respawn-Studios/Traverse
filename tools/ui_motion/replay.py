#!/usr/bin/env python3
"""Build/serve only a hash-bound whitelist of generated motion evidence."""
from __future__ import annotations
import argparse,hashlib,http.server,json,os,re,stat,sys,threading,time,uuid
from pathlib import Path
from urllib.parse import urlsplit
sys.dont_write_bytecode=True
sys.path[:0]=[str(Path(__file__).resolve().parents[1]),str(Path(__file__).resolve().parents[1]/'ssh_profiles')]
from packet import d,audit,REPO

TEMPLATE=Path(__file__).with_name('replay.html')
TIMING_CASE='2AB23495-16B7-4141-A8BF-6DBC28D9F15E'

def bounded(path,maximum):
    if path.resolve()!=path:raise RuntimeError('Replay evidence redirected')
    fd=os.open(path,os.O_RDONLY|os.O_NOFOLLOW|os.O_CLOEXEC)
    try:
        before=os.fstat(fd)
        if not stat.S_ISREG(before.st_mode)or before.st_uid!=os.getuid()or before.st_nlink!=1 or before.st_size>maximum:
            raise RuntimeError('Replay evidence file bound')
        data=os.read(fd,maximum+1);after=os.fstat(fd)
        def stamp(v):return(v.st_dev,v.st_ino,v.st_mode,v.st_uid,v.st_nlink,v.st_size,v.st_mtime_ns,v.st_ctime_ns)
        if len(data)!=before.st_size or stamp(before)!=stamp(after):raise RuntimeError('Replay evidence changed during read')
        return data
    finally:os.close(fd)

def generate():
    source=d.ROOT/TIMING_CASE;timing=json.loads(bounded(source/'evidence/result.json',1<<20))
    if not timing.get('passed')or timing.get('analysisCompleted')is not True or len(timing['clips'])!=27:
        raise RuntimeError('Complete exact timing audit required')
    for name,digest in timing['evidenceSHA256'].items():
        path=REPO/name
        if not path.is_relative_to(d.ROOT)or d.digest(path)!=digest:raise RuntimeError('Original generated timing evidence changed')
    root=d.reserve('motion-replay-viewer');assets={};clips=[]
    for index,original in enumerate(timing['clips']):
        value=dict(original);value.pop('case');area=d.ROOT/original['case']/'evidence';label=original['clip']
        if not re.fullmatch('[a-z][a-z0-9-]{0,63}',label):raise RuntimeError('Generated replay label required')
        native=json.loads(bounded(area/'qualification.json',1<<20))['native']
        if native['interfaceSize']not in(100,150)or type(native['lightAppearance'])is not bool:
            raise RuntimeError('Frozen generated appearance required')
        value.update(interfaceSize=native['interfaceSize'],appearance='Light'if native['lightAppearance']else'Dark')
        for kind,name,mime,maximum in [('video',label+'.mov','video/quicktime',4<<20),('sheet',label+'-dense-folder.png','image/png',8<<20)]:
            path=area/name;data=bounded(path,maximum);route='/asset/'+str(index).zfill(3)+'/'+kind
            assets[route]=dict(path=str(path.relative_to(REPO)),sha256=hashlib.sha256(data).hexdigest(),bytes=len(data),mime=mime,maximumBytes=maximum)
            value[kind]=route
        clips.append(value)
    original=TEMPLATE.read_text();assert original.count('__CAPTURE_DATA__')==1
    data=json.dumps(dict(clips=clips),ensure_ascii=False,separators=(',',':')).replace('<','\\u003c').replace('&','\\u0026')
    html=original.replace('__CAPTURE_DATA__',data).encode()
    if len(html)>256<<10:raise RuntimeError('Replay HTML bound')
    (root/'evidence/index.html').write_bytes(html)
    (root/'source/replay.py').write_bytes(Path(__file__).read_bytes());(root/'source/replay.html').write_bytes(TEMPLATE.read_bytes())
    d.put(root/'inputs.json',dict(timingCase=TIMING_CASE,timingSHA256=d.digest(source/'evidence/result.json'),assets=assets,
        toolSHA256=d.digest(Path(__file__)),templateSHA256=d.digest(TEMPLATE),maximumCaseBytes=8<<20,generatedOnly=True,
        newRecordings=0,productActions=0,networkConnections=0))
    d.put(root/'evidence/result.json',dict(passed=True,clips=len(clips),assets=len(assets),htmlSHA256=d.digest(root/'evidence/index.html'),
        generatedOnly=True,sourceUnchanged=True,served=False,usage=audit()))
    print(json.dumps(dict(case=root.name,passed=True,clips=len(clips),assets=len(assets))),flush=True)

def byte_range(value,size):
    if value is None:return 0,size-1,False
    if not isinstance(value,str)or len(value)>64:raise ValueError('Range bound')
    match=re.fullmatch(r'bytes=([0-9]{0,19})-([0-9]{0,19})',value)
    if not match or not any(match.groups()):raise ValueError('One byte range required')
    left,right=match.groups()
    if not left:
        count=int(right)
        if count<=0:raise ValueError('Positive suffix required')
        start=max(0,size-count);end=size-1
    else:start=int(left);end=min(size-1,int(right))if right else size-1
    if not 0<=start<=end<size:raise ValueError('Range outside generated media')
    return start,end,True

def checked(tag):
    if str(uuid.UUID(tag)).upper()!=tag:raise RuntimeError('Canonical replay case required')
    root=d.ROOT/tag
    if json.loads(bounded(root/'reservation.json',4096))['action']!='motion-replay-viewer':raise RuntimeError('Wrong replay case')
    proof=json.loads(bounded(root/'evidence/result.json',1<<20));inputs=json.loads(bounded(root/'inputs.json',1<<20))
    if not proof['passed']or len(inputs['assets'])!=54 or d.digest(root/'evidence/index.html')!=proof['htmlSHA256']:
        raise RuntimeError('Replay result changed')
    return root,inputs

def serve(tag,port,seconds):
    if not 8700<=port<=8899 or not 10<=seconds<=1200:raise RuntimeError('Local replay lifetime or port bound')
    root,inputs=checked(tag);slots=threading.BoundedSemaphore(4);counts=dict(requests=0,refused=0)
    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self,*_):pass
        def setup(self):super().setup();self.connection.settimeout(3)
        def do_HEAD(self):self.respond(True)
        def do_GET(self):self.respond(False)
        def respond(self,head):
            try:
                counts['requests']+=1;parts=urlsplit(self.path)
                if self.headers.get('Host')!='127.0.0.1:'+str(port)or parts.query or parts.fragment or parts.scheme or len(self.path)>128:
                    counts['refused']+=1;self.send_error(400);return
                path=parts.path
                if path in('/','/index.html'):data=bounded(root/'evidence/index.html',256<<10);mime='text/html; charset=utf-8'
                elif path=='/health':data=json.dumps(dict(generatedOnly=True,assets=len(inputs['assets']))).encode();mime='application/json'
                elif path in inputs['assets']:
                    entry=inputs['assets'][path];file=REPO/entry['path']
                    if not file.is_relative_to(d.ROOT):raise RuntimeError('Replay asset escaped generated root')
                    data=bounded(file,entry['maximumBytes']);mime=entry['mime']
                    if len(data)!=entry['bytes']or hashlib.sha256(data).hexdigest()!=entry['sha256']:raise RuntimeError('Replay asset changed')
                else:counts['refused']+=1;self.send_error(404);return
                try:first,last,partial=byte_range(self.headers.get('Range'),len(data))
                except ValueError:
                    self.send_response(416);self.send_header('Content-Range','bytes */'+str(len(data)));self.send_header('Content-Length','0');self.end_headers();return
                self.send_response(206 if partial else 200);self.send_header('Content-Type',mime);self.send_header('Content-Length',str(last-first+1))
                if partial:self.send_header('Content-Range','bytes '+str(first)+'-'+str(last)+'/'+str(len(data)))
                for key,value in [('Accept-Ranges','bytes'),('Cache-Control','no-store'),('X-Content-Type-Options','nosniff'),
                    ('Referrer-Policy','no-referrer'),('Content-Security-Policy',"default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; connect-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'")]:self.send_header(key,value)
                self.end_headers()
                if not head:self.wfile.write(data[first:last+1])
            except(BrokenPipeError,ConnectionResetError,TimeoutError):pass
            except(Exception):
                counts['refused']+=1
                try:self.send_error(409)
                except(OSError):pass
    class Server(http.server.ThreadingHTTPServer):
        allow_reuse_address=False
        daemon_threads=False
        def process_request(self,request,address):
            # Bound idle/header-reading clients too, before creating a thread.
            if not slots.acquire(blocking=False):
                self.shutdown_request(request);return
            try:super().process_request(request,address)
            except BaseException:slots.release();raise
        def process_request_thread(self,request,address):
            try:super().process_request_thread(request,address)
            finally:slots.release()
    server=Server(('127.0.0.1',port),Handler);server.timeout=.5;began=time.monotonic();pid=os.getpid()
    d.put(root/'evidence'/('server-'+str(pid)+'-start.json'),dict(pid=pid,host='127.0.0.1',port=port,maximumSeconds=seconds,maximumActiveRequests=4))
    print(json.dumps(dict(case=tag,pid=pid,url='http://127.0.0.1:'+str(port),maximumSeconds=seconds)),flush=True)
    try:
        while time.monotonic()-began<seconds:server.handle_request()
    except KeyboardInterrupt:pass
    finally:
        server.server_close()
        d.put(root/'evidence'/('server-'+str(pid)+'-stop.json'),dict(passed=True,closed=True,handlerThreadsDrained=True,seconds=time.monotonic()-began,**counts))
        print(json.dumps(dict(case=tag,closed=True,**counts)),flush=True)

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--serve-case');parser.add_argument('--port',type=int,default=8878);parser.add_argument('--seconds',type=int,default=600);args=parser.parse_args()
    if args.serve_case:serve(args.serve_case,args.port,args.seconds)
    else:generate()
if __name__=='__main__':main()
