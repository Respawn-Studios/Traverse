#!/usr/bin/env python3
"""Generated loopback HTTP only; no real invitation, Keychain or web changes."""
import argparse,base64,hashlib,json,os,signal,subprocess,sys,threading,time
from http.server import BaseHTTPRequestHandler,ThreadingHTTPServer
from pathlib import Path
sys.dont_write_bytecode=True
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
import dev
from distribution.traverse_packet import REPO,reserve,put,audit,measure,MIB

parser=argparse.ArgumentParser();parser.add_argument('--keychain',action='store_true');args=parser.parse_args()
case=reserve('traverse-private-update-transport')
events=[];guard=threading.Lock();stop=threading.Event()
secret='Basic '+base64.b64encode(b'traverse-beta:Generated-only-update-invitation').decode()
class Handler(BaseHTTPRequestHandler):
 def log_message(self,*args):pass
 def do_GET(self):
  mode=self.headers.get('X-Generated-Scenario','')
  with guard:events.append(dict(sink=self.server.is_sink,scenario=mode,
      authorized=self.headers.get('Authorization')==secret,
      markerForwarded=self.headers.get('X-Traverse-Private-Update')is not None))
  if self.server.is_sink:
   self.send_response(200);self.end_headers();return
  if mode in ['redirect','platform-redirect']:
   self.send_response(302);self.send_header('Location','http://127.0.0.1:'+str(sink.server_port)+'/forbidden');self.end_headers();return
  if mode=='unauthorized':
   self.send_response(401);self.end_headers();return
  if mode=='rate-limited':
   self.send_response(429);self.send_header('Retry-After','900');self.end_headers();return
  if mode=='service-busy':
   self.send_response(503);self.send_header('Retry-After','1');self.end_headers();return
  self.send_response(200)
  self.send_header('Content-Type','application/rss+xml; charset=utf-8')
  body=b'Generated signed-feed transport control'
  if mode=='stall':body=b'G'*4096
  if mode=='oversized':self.send_header('Content-Length',str((2<<20)+1))
  elif mode!='stream-overflow':self.send_header('Content-Length',str(len(body)))
  self.end_headers()
  self.wfile.flush()
  try:
   if mode=='stall':
    self.wfile.write(body[:1024]);self.wfile.flush();stop.wait(5);self.wfile.write(body[1024:])
   elif mode=='stream-overflow':
    for _ in range(33):self.wfile.write(b'X'*65536)
   else:
    if mode=='oversized':stop.wait(5)
    self.wfile.write(body)
  except (BrokenPipeError,ConnectionResetError):pass

sink=ThreadingHTTPServer(('127.0.0.1',0),Handler);sink.is_sink=True;sink.daemon_threads=True
origin=ThreadingHTTPServer(('127.0.0.1',0),Handler);origin.is_sink=False;origin.daemon_threads=True
for server in [sink,origin]:threading.Thread(target=server.serve_forever,daemon=True).start()
put(case/'inputs.json',dict(generatedOnly=True,loopbackOnly=True,maximumRequests=24,
    maximumCaseBytes=64*MIB,maximumCaseEntries=2048,realCredentials=0,keychainEntries=2 if args.keychain else 0))
env=dev.environment();env.update(TRAVERSE_UPDATE_TEST_PORT=str(origin.server_port))
if args.keychain:env['TRAVERSE_UPDATE_KEYCHAIN_CASE']=case.name
command=['xcrun','swift','test','--package-path',str(REPO/'Packages/ExplorerKit'),
    '--scratch-path',str(REPO/'.build/swift-tests'),'--cache-path',str(REPO/'.build/swift-cache'),
    '--config-path',str(REPO/'.build/swift-config'),'--security-path',str(REPO/'.build/swift-security'),
    '--swift-sdks-path',str(REPO/'.build/swift-sdks'),'--disable-keychain','--disable-netrc',
    '--disable-dependency-cache','--manifest-cache','local','--disable-automatic-resolution','--jobs','4',
    '-Xswiftc','-warnings-as-errors','-Xswiftc','-module-cache-path','-Xswiftc',str(REPO/'.build/compiler-cache/swift'),
    '--filter','PrivateUpdatePolicyTests|PrivateUpdateTransportTests|UpdateInvitationStoreTests','--no-parallel']
began=time.monotonic()
try:
 with(case/'evidence/core.log').open('xb')as output:
  child=subprocess.Popen(command,cwd=REPO,env=env,stdin=subprocess.DEVNULL,stdout=output,stderr=subprocess.STDOUT,start_new_session=True)
  try:actual=child.wait(timeout=180)
  finally:
   if child.poll()is None:os.killpg(child.pid,signal.SIGTERM);child.wait(timeout=5)
finally:
 stop.set()
 for server in [origin,sink]:server.shutdown();server.server_close()
with guard:observed=list(events)
usage=measure(case)
sink_requests=[e for e in observed if e['sink']]
passed=actual==0 and 8<=len(observed)<=24 and len(sink_requests)==1 \
    and sink_requests[0]['scenario']=='platform-redirect'and not sink_requests[0]['authorized'] \
    and not any(e['markerForwarded']or(not e['authorized']and not e['sink'])for e in observed) \
    and usage['bytes']<=64*MIB and usage['entries']<=2048
put(case/'result.json',dict(passed=passed,actualExit=actual,requests=observed,seconds=time.monotonic()-began,
    caseUsage=usage,packet=audit()))
print(json.dumps(dict(case=case.name,passed=passed,requests=len(observed),actualExit=actual)),flush=True)
if not passed:raise SystemExit(1)
