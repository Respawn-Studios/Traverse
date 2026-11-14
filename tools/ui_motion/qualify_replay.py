#!/usr/bin/env python3
"""Range/parser and actual loopback whitelist/concurrency controls; no UI claim."""
from __future__ import annotations
import argparse,http.client,json,socket,subprocess,sys,time
from pathlib import Path
sys.dont_write_bytecode=True
sys.path.insert(0,str(Path(__file__).resolve().parent));import replay as r

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--case',required=True);parser.add_argument('--port',type=int,default=8878);args=parser.parse_args()
    viewer,inputs=r.checked(args.case);root=r.d.reserve('motion-replay-controls');checks=[]
    sources={str(p.relative_to(r.REPO)):r.d.digest(p)for p in [Path(__file__).resolve(),Path(r.__file__).resolve(),r.TEMPLATE]}
    r.d.put(root/'inputs.json',dict(viewerCase=args.case,sources=sources,port=args.port,host='127.0.0.1',generatedOnly=True,
        existingAssetsOnly=True,newRecordings=0,applicationInteractions=0,maximumCaseBytes=8<<20))
    report=dict(passed=False,checks=checks)
    def request(path,headers=None,method='GET'):
        client=http.client.HTTPConnection('127.0.0.1',args.port,timeout=4)
        try:
            client.request(method,path,headers=headers or{});response=client.getresponse();data=response.read(8<<20)
            return response.status,dict(response.getheaders()),data
        finally:client.close()
    try:
        for value,wanted in[(None,(0,9,False)),('bytes=0-0',(0,0,True)),('bytes=3-',(3,9,True)),('bytes=-4',(6,9,True)),
            ('bytes=0-999',(0,9,True)),('bytes=-999',(0,9,True))]:
            assert r.byte_range(value,10)==wanted
        checks.append('Full, first-byte, open-ended, suffix and clamped ranges are exact')
        for value in['bytes=','bytes=-','bytes=-0','bytes=10-','bytes=4-3','bytes=0-1,4-5','bytes=+1-2','items=0-1',
            'bytes=00000000000000000000-','bytes=0-1\r\nX: y','x'*65]:
            try:r.byte_range(value,10);raise AssertionError('Invalid range admitted')
            except ValueError:pass
        checks.append('Eleven malformed, multi-range, outside and oversized ranges are refused')
        status,headers,data=request('/');assert status==200 and r.hashlib.sha256(data).hexdigest()==json.loads((viewer/'evidence/result.json').read_bytes())['htmlSHA256']
        assert headers['Content-Security-Policy'].find("connect-src 'none'")>=0 and headers['X-Content-Type-Options']=='nosniff'
        checks.append('Actual loopback HTML is the exact generated artifact with constrained browser policy')
        route='/asset/000/video';expected=inputs['assets'][route];full=r.bounded(r.REPO/expected['path'],expected['maximumBytes'])
        status,headers,data=request(route,{'Range':'bytes=0-31'});assert status==206 and data==full[:32]and headers['Content-Range']=='bytes 0-31/'+str(len(full))
        status,headers,data=request(route,{'Range':'bytes=-17'});assert status==206 and data==full[-17:]
        status,headers,data=request(route,method='HEAD');assert status==200 and data==b''and int(headers['Content-Length'])==len(full)
        checks.append('Actual first/suffix media reads and HEAD preserve exact original bytes')
        status,headers,data=request(route,{'Range':'bytes=0-1,4-5'});assert status==416 and data==b''
        checks.append('Actual invalid media range is refused without a full-body fallback')
        for path,code in[('/../inputs.json',404),('/%2e%2e/inputs.json',404),('/asset/000/unknown',404),('/asset/000/video?token=generated',400)]:
            status,_,_=request(path);assert status==code
        status,_,_=request('/',{'Host':'unrelated.example'});assert status==400
        status,_,_=request('/',method='POST');assert status==501
        checks.append('Traversal, encoded traversal, unknown assets, queries, foreign Host and mutation methods cannot access the source tree')
        idle=[]
        try:
            for _ in range(4):idle.append(socket.create_connection(('127.0.0.1',args.port),timeout=1))
            extra=socket.create_connection(('127.0.0.1',args.port),timeout=1)
            try:extra.settimeout(1);assert extra.recv(1)==b''
            finally:extra.close()
        finally:
            for client in idle:client.close()
        status,_,data=request('/health');assert status==200 and json.loads(data)==dict(generatedOnly=True,assets=54)
        checks.append('Four actual idle sockets hold the pre-thread slots; a fifth is refused and closure restores service')
        node='/opt/homebrew/opt/node@24/bin/node'
        command=[node,'-e',"const fs=require('node:fs');const html=fs.readFileSync(process.argv[1],'utf8');const code=html.match(/<script>\\n([\\s\\S]*?)<\\/script>/)[1];new Function(code);process.stdout.write('JavaScript parsed; no DOM executed.\\n');",str(viewer/'evidence/index.html')]
        process=subprocess.run(command,capture_output=True,timeout=10);assert process.returncode==0
        (root/'evidence/javascript-parse.stdout').write_bytes(process.stdout);(root/'evidence/javascript-parse.stderr').write_bytes(process.stderr)
        checks.append('Generated browser JavaScript parses in the existing Node runtime; DOM behavior is separately inspected')
        assert sources=={name:r.d.digest(r.REPO/name)for name in sources}and r.d.measure(root)['bytes']<=8<<20
        report.update(passed=True,sourceUnchanged=True,actualLoopbackControls=True,externalConnections=0,visualAcceptance=False)
    except BaseException as error:report.update(errorType=type(error).__name__,failure=str(error)if type(error)is RuntimeError else None)
    finally:report['usage']=r.audit();r.d.put(root/'evidence/result.json',report)
    print(json.dumps(dict(case=root.name,passed=report['passed'],checks=len(checks),failure=report.get('failure'))),flush=True)
    if not report['passed']:raise SystemExit(1)
if __name__=='__main__':main()
