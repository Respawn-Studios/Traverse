#!/usr/bin/env python3
"""Run by stdin over the owner-authorized SSH session, never as a host service.

Only a fresh UUID-marked packet, two labelled containers, one image and one
private Docker network are mutable. Existing services/packages are untouched.
"""
from __future__ import annotations
import argparse
import hashlib
import ipaddress
import io
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import tarfile
import time
import uuid

MIB = 1024**2
PARENT = Path('/var/tmp/macexplorer-b10-qualification')
LABEL = 'org.macexplorer.b10.case'
PORT = 15445

class TestCommandFailure(RuntimeError):
    def __init__(self, args, result):
        super().__init__('Test command failed: '+args[0]+' '+args[1]+' (status '+str(result.returncode)+')')
        self.diagnostic = result.stdout+result.stderr

def command(args, *, timeout=30, expected=0):
    result = subprocess.run(args, capture_output=True, timeout=timeout, check=False)
    if len(result.stdout)+len(result.stderr) > 8*MIB:
        raise RuntimeError('Test command output exceeded its bound')
    if expected is not None and result.returncode != expected:
        raise TestCommandFailure(args, result)
    return result

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('action', choices=['prepare', 'seal-prepared', 'start', 'retry-runtime', 'resume-comparison', 'resume-corrected', 'resume-repair', 'restore-drain', 'resume-reader', 'inspect', 'stop'])
    parser.add_argument('case')
    parser.add_argument('--session')
    args = parser.parse_args()
    case = str(uuid.UUID(args.case)).upper()
    if args.case != case or os.geteuid() == 0:
        raise RuntimeError('Requires an exact case UUID and the ordinary SSH user')
    PARENT.mkdir(mode=0o700, exist_ok=True)
    if PARENT.resolve() != PARENT or PARENT.stat().st_uid != os.getuid() or stat.S_IMODE(PARENT.stat().st_mode) != 0o700:
        raise RuntimeError('Remote packet parent is not private and owned')
    root = PARENT/case
    marker = root/'receipt.json'
    prefix = 'macexplorer-b10-'+case.lower()[:12]

    def save():
        temporary = root/'receipt.next'
        with temporary.open('x', encoding='utf8') as output:
            json.dump(record, output, sort_keys=True, indent=2); output.flush(); os.fsync(output.fileno())
        temporary.replace(marker)

    def container(key):
        identifier = record.get(key)
        if not isinstance(identifier, str) or not re.fullmatch('[a-f0-9]{64}', identifier):
            raise RuntimeError('No exact owned container receipt')
        value = json.loads(command(['docker','container','inspect',identifier]).stdout)[0]
        if value['Id'] != identifier or value['Config']['Labels'].get(LABEL) != case or value['Name'] != '/'+prefix+'-'+key:
            raise RuntimeError('Container identity changed')
        return value

    def image_bytes():
        identifiers = [record[k] for k in ['baseImage','image'] if k in record]
        total = sum(json.loads(command(['docker','image','inspect',key]).stdout)[0]['Size'] for key in identifiers)
        if 'builder' in record:
            total += json.loads(command(['docker','container','inspect','--size',record['builder']]).stdout)[0].get('SizeRw', 0)
        if total > 2*1024*MIB:
            raise RuntimeError('Server image/tooling allowance exhausted')
        return total

    if args.action == 'prepare':
        if root.exists() or any(PARENT.iterdir()):
            raise RuntimeError('Preserved server packet exists; no implicit new attempt')
        root.mkdir(mode=0o700)
        record = dict(version=1, case=case, uid=os.getuid(), created=time.time(), phase='preparing', port=PORT)
        save()
        try:
            version = command(['docker','version','--format','{{.Server.Version}}']).stdout.decode().strip()
            numbers = tuple(int(part) for part in version.split('.')[:3])
            if numbers < (28,3,3):
                raise RuntimeError('Docker loopback-publishing fixes are not established')
            record['dockerVersion'] = version
            if command(['ss','-ltnH','sport','=',':'+str(PORT)]).stdout.strip():
                raise RuntimeError('Test-only server port is already occupied')
            command(['docker','pull','--platform','linux/amd64','ubuntu:24.04'], timeout=180)
            base = json.loads(command(['docker','image','inspect','ubuntu:24.04']).stdout)[0]
            digest = next((d for d in base.get('RepoDigests', []) if re.fullmatch('ubuntu@sha256:[a-f0-9]{64}',d)), None)
            if digest is None or base['Architecture'] != 'amd64':
                raise RuntimeError('Official base identity is unavailable')
            record['baseImage'] = base['Id']; record['baseDigest'] = digest; save(); image_bytes()
            net = command(['docker','network','create','--internal','--label',LABEL+'='+case,
                           '--opt','com.docker.network.bridge.host_binding_ipv4=127.0.0.1',prefix+'-net']).stdout.decode().strip()
            topology = json.loads(command(['docker','network','inspect',net]).stdout)[0]
            gateway = str(ipaddress.IPv4Address(topology['IPAM']['Config'][0]['Gateway']))
            if not topology['Internal'] or topology['Driver'] != 'bridge' or topology['Labels'].get(LABEL) != case:
                raise RuntimeError('Private test network not established')
            record.update(network=net, networkName=prefix+'-net', gateway=gateway); save()
            context = root/'context'; context.mkdir(mode=0o700)
            policy = context/'policy-rc.d'; policy.write_text('#!/bin/sh\nexit 101\n'); policy.chmod(0o755)
            install = 'set -eu\nexport DEBIAN_FRONTEND=noninteractive\napt-get update\napt-get install --no-install-recommends -y samba smbclient\napt-get clean\ntouch /run/macexplorer-b10-ready\nexec sleep 600\n'
            builder = command(['docker','create','--name',prefix+'-builder','--label',LABEL+'='+case,
                '--memory','384m','--cpus','1','--pids-limit','128','--log-opt','max-size=4m','--log-opt','max-file=1',
                digest,'/bin/sh','-c',install]).stdout.decode().strip()
            record['builder'] = builder; save(); container('builder')
            command(['docker','cp',str(policy),builder+':/usr/sbin/policy-rc.d'])
            command(['docker','start',builder])
            print(json.dumps(dict(phase='Installing Samba inside the isolated build container')), flush=True)
            deadline = time.monotonic()+240
            while command(['docker','exec',builder,'test','-f','/run/macexplorer-b10-ready'],expected=None).returncode:
                if not container('builder')['State']['Running'] or time.monotonic() > deadline:
                    raise RuntimeError('Isolated package preparation did not complete')
                time.sleep(2)
            data = context/'explorer-qa'; data.mkdir(mode=0o755)
            (data/'Folder').mkdir(); (data/'Folder/Empty folder').mkdir()
            payloads = {'Read me.txt': b'Mac Explorer generated SMB qualification v1\n',
                'Café 文件.txt': bytes(range(128)), 'Folder/Nested note.txt': b'generated nested file\n'}
            for name, content in payloads.items():
                path=data/name; path.write_bytes(content); path.chmod(0o444)
            (data/'Inside link').symlink_to('Folder')
            (data/'Outside link').symlink_to('/srv/not-shared/Outside.txt')
            (data/'Broken link').symlink_to('No such generated item')
            for path in [data/'Folder/Empty folder', data/'Folder', data]: path.chmod(0o555)
            outside = context/'not-shared'; outside.mkdir(); (outside/'Outside.txt').write_text('generated outside-share sentinel\n')
            config = context/'smb.conf'
            config.write_text('''[global]
server role = standalone server
security = user
map to guest = Bad User
guest account = nobody
server min protocol = SMB3_00
server max protocol = SMB3
smb ports = 445
interfaces = lo eth0
bind interfaces only = yes
hosts allow = 127.0.0.1 '''+gateway+'''
hosts deny = ALL
hostname lookups = no
server multi channel support = no
load printers = no
disable spoolss = yes
allow insecure wide links = no
private dir = /state/private
state directory = /state/state
cache directory = /state/cache
lock directory = /state/lock
pid directory = /state/run
log file = /state/log/samba.log
max log size = 1024
log level = 0
[ExplorerQA]
path = /srv/explorer-qa
read only = yes
guest ok = yes
guest only = yes
force user = nobody
browseable = no
printable = no
follow symlinks = no
wide links = no
''')
            entry = context/'macexplorer-b10-entry'; entry.write_text('''#!/bin/sh
set -eu
mkdir -p /state/private /state/state /state/cache /state/lock /state/run /state/log
exec /usr/bin/timeout --signal=TERM 1800 /usr/sbin/smbd --foreground --no-process-group --debug-stdout --configfile=/etc/samba/smb.conf
'''); entry.chmod(0o755)
            for source, destination in [(data,'/srv/explorer-qa'),(outside,'/srv/not-shared'),(config,'/etc/samba/smb.conf'),(entry,'/usr/local/bin/macexplorer-b10-entry')]:
                command(['docker','cp',str(source),builder+':'+destination])
            checked = command(['docker','exec',builder,'testparm','-s','--suppress-prompt','/etc/samba/smb.conf'])
            (root/'testparm.txt').write_bytes(checked.stdout+checked.stderr)
            record['sambaVersion'] = command(['docker','exec',builder,'smbd','--version']).stdout.decode().strip()
            record['fixtures'] = {name:dict(bytes=len(body),sha256=hashlib.sha256(body).hexdigest()) for name,body in payloads.items()}
            record['configSHA256'] = hashlib.sha256(config.read_bytes()).hexdigest(); save()
            container('builder'); command(['docker','stop','--time','5',builder])
            image = command(['docker','commit','--change','ENTRYPOINT ["/usr/local/bin/macexplorer-b10-entry"]',builder,prefix+':qualified-source'],timeout=60).stdout.decode().strip()
            record.update(image=image,phase='prepared'); save(); record['toolingBytes']=image_bytes(); save()
            print(json.dumps(dict(phase='prepared',case=case,samba=record['sambaVersion'],toolingBytes=record['toolingBytes'])),flush=True)
        except Exception as error:
            record.update(phase='preparation failed', failure=type(error).__name__); save()
            if isinstance(error, TestCommandFailure): (root/'failure-command.log').write_bytes(error.diagnostic)
            if 'builder' in record:
                own = container('builder')
                if own['State']['Running']: command(['docker','stop','--time','5',record['builder']])
                logs = command(['docker','logs',record['builder']],expected=None)
                (root/'build.log').write_bytes(logs.stdout+logs.stderr)
            raise
        return

    if root.resolve() != root or not marker.is_file() or marker.is_symlink():
        raise RuntimeError('No exact remote packet')
    record=json.loads(marker.read_bytes())
    if record.get('case') != case or record.get('uid') != os.getuid() or record.get('version') != 1:
        raise RuntimeError('Remote receipt mismatch')
    if args.action == 'seal-prepared':
        # Preserve the stopped build exactly. Its first testparm ran before
        # runtime-only state directories existed. Validate that configuration
        # inside the readonly runtime, after creating only its tmpfs directories,
        # and before smbd binds any socket. No package install or file retry.
        if record.get('phase') != 'preparation failed' or 'image' in record or 'runtime' in record:
            raise RuntimeError('Only the retained preflight failure can be sealed')
        own=container('builder')
        if own['State']['Running']: raise RuntimeError('Preserved builder is still running')
        context=root/'context'
        config=context/'smb.conf'
        raw=command(['docker','cp',record['builder']+':/etc/samba/smb.conf','-']).stdout
        with tarfile.open(fileobj=io.BytesIO(raw)) as archive:
            members=archive.getmembers()
            if len(members) != 1 or not members[0].isfile() or members[0].size > 65536:
                raise RuntimeError('Unexpected configuration archive')
            if archive.extractfile(members[0]).read() != config.read_bytes():
                raise RuntimeError('Preserved container configuration changed')
        data=context/'explorer-qa'
        names=['Read me.txt','Café 文件.txt','Folder/Nested note.txt']
        record['fixtures']={name:dict(bytes=(data/name).stat().st_size,sha256=hashlib.sha256((data/name).read_bytes()).hexdigest()) for name in names}
        record['configSHA256']=hashlib.sha256(config.read_bytes()).hexdigest()
        record['preservedPreflightFailure']=True
        record['runtimeConfigurationGate']=True
        record['image']=command(['docker','commit','--change','ENTRYPOINT ["/usr/local/bin/macexplorer-b10-entry"]',record['builder'],prefix+':qualified-source'],timeout=60).stdout.decode().strip()
        record.update(phase='prepared',toolingBytes=image_bytes()); save()
        print(json.dumps(dict(phase='prepared',case=case,preservedPreflightFailure=True,toolingBytes=record['toolingBytes'])),flush=True)
    elif args.action in ['start', 'retry-runtime']:
        key='runtime'
        if args.action == 'retry-runtime':
            first=container('runtime')
            logs=command(['docker','logs',record['runtime']],expected=None)
            if first['State']['Running'] or first['State']['ExitCode'] != 255 or 'runtime2' in record or b'/run/samba/ncalrpc' not in logs.stdout+logs.stderr:
                raise RuntimeError('Only the preserved runtime-directory failure can be retried once')
            (root/'runtime-failure-1.log').write_bytes(logs.stdout+logs.stderr)
            record['preservedRuntimeFailure']=record['runtime']; save(); key='runtime2'
        elif record.get('phase') != 'prepared' or 'runtime' in record:
            raise RuntimeError('No implicit runtime retry')
        if command(['ss','-ltnH','sport','=',':'+str(PORT)]).stdout.strip(): raise RuntimeError('Test port occupied')
        network=json.loads(command(['docker','network','inspect',record['network']]).stdout)[0]
        if network['Labels'].get(LABEL) != case or not network['Internal'] or network['Containers']:
            raise RuntimeError('Private test network changed')
        runtime=command(['docker','create','--name',prefix+'-'+key,'--label',LABEL+'='+case,
            '--network',record['networkName'],'--publish','127.0.0.1:'+str(PORT)+':445/tcp',
            '--read-only','--memory','384m','--cpus','1','--pids-limit','128','--security-opt','no-new-privileges:true',
            '--cap-drop','ALL','--cap-add','CHOWN','--cap-add','DAC_OVERRIDE','--cap-add','FOWNER',
            '--cap-add','SETGID','--cap-add','SETUID','--cap-add','NET_BIND_SERVICE','--cap-add','SYS_CHROOT',
            '--tmpfs','/state:rw,noexec,nosuid,nodev,size=96m,mode=755','--tmpfs','/tmp:rw,noexec,nosuid,nodev,size=16m',
            '--tmpfs','/run:rw,noexec,nosuid,nodev,size=16m','--log-opt','max-size=4m','--log-opt','max-file=2',
            '--entrypoint','/bin/sh',record['image'],'-c',
            'set -eu\nmkdir -p /state/private /state/state /state/cache /state/lock /state/run /state/log /run/samba/ncalrpc\ntestparm -s --suppress-prompt /etc/samba/smb.conf\ntouch /run/macexplorer-b10-config-valid\nexec /usr/local/bin/macexplorer-b10-entry\n']).stdout.decode().strip()
        record[key]=runtime; record['activeRuntimeKey']=key; save()
        value=container(key); host=value['HostConfig']
        if not host['ReadonlyRootfs'] or host['Binds'] or host['Privileged'] or host['RestartPolicy']['Name'] not in ['', 'no'] or host['PortBindings'] != {'445/tcp':[{'HostIp':'127.0.0.1','HostPort':str(PORT)}]}:
            raise RuntimeError('Runtime isolation mismatch; do not start')
        command(['docker','start',runtime]); record.update(phase='running',started=time.time(),expires=time.time()+1800); save()
        print(json.dumps(dict(phase='running',case=case,loopbackPort=PORT,selfExpirySeconds=1800)),flush=True)
    elif args.action == 'resume-comparison':
        # Exactly one restart of the same expired generated server for the
        # separately approved Mac mountpoint comparison. Preserve its first run.
        key=record.get('activeRuntimeKey','runtime'); value=container(key)
        host=value['HostConfig']
        if key != 'runtime2' or value['State']['Running'] or value['State']['ExitCode'] != 124 or 'comparisonResumed' in record:
            raise RuntimeError('Only the once-expired corrected runtime can resume for this comparison')
        if value['Image'] != record['image'] or not host['ReadonlyRootfs'] or host['Binds'] or host['Privileged'] or host['RestartPolicy']['Name'] not in ['', 'no']:
            raise RuntimeError('Retained runtime isolation changed')
        if host['PortBindings'] != {'445/tcp':[{'HostIp':'127.0.0.1','HostPort':str(PORT)}]}:
            raise RuntimeError('Retained loopback scope changed')
        network=json.loads(command(['docker','network','inspect',record['network']]).stdout)[0]
        if network['Labels'].get(LABEL) != case or not network['Internal'] or network['Containers']:
            raise RuntimeError('Private test network changed')
        logs=command(['docker','logs',record[key]],expected=None)
        with (root/'runtime-before-comparison.log').open('xb') as output:
            output.write(logs.stdout+logs.stderr)
        record['comparisonResumed']=time.time(); record['comparisonPriorState']=value['State']; save()
        command(['docker','start',record[key]])
        record.update(phase='running comparison',started=time.time(),expires=time.time()+1800); save()
        print(json.dumps(dict(phase=record['phase'],case=case,sameRuntime=True,selfExpirySeconds=1800)),flush=True)
    elif args.action in ['resume-corrected', 'resume-repair', 'restore-drain']:
        if not args.session or str(uuid.UUID(args.session)).upper()!=args.session or args.session==case:
            raise RuntimeError('Requires the newly approved exact local session')
        key=record.get('activeRuntimeKey','runtime'); value=container(key); host=value['HostConfig']
        repairs=record.get('repairSessions',[])
        if record.get('phase')!='stopped' or key!='runtime2' or value['State']['Running']:
            raise RuntimeError('Only the exact stopped corrected runtime may resume')
        if args.action=='resume-corrected' and 'correctedSession' in record:
            raise RuntimeError('The initial corrected session is already consumed')
        if args.action=='resume-repair' and (not record.get('correctedSession') or len(repairs)>=3
                or args.session in repairs or args.session==record['correctedSession']):
            raise RuntimeError('The three distinct approved repair sessions are exhausted or not admitted')
        drains=record.get('drainSessions',[])
        if args.action=='restore-drain' and (record.get('activeSession')!=args.session
                or args.session not in repairs or args.session in drains):
            raise RuntimeError('Drain-only restoration is not admitted for this active session')
        if value['Image']!=record['image'] or not host['ReadonlyRootfs'] or host['Binds'] or host['Privileged'] or host['RestartPolicy']['Name'] not in ['', 'no']:
            raise RuntimeError('Retained runtime isolation changed')
        if host['Memory']!=384*MIB or host['NanoCpus']!=1_000_000_000 or host['PidsLimit']!=128:
            raise RuntimeError('Retained runtime resource bounds changed')
        if host['PortBindings']!={'445/tcp':[{'HostIp':'127.0.0.1','HostPort':str(PORT)}]}:
            raise RuntimeError('Retained loopback scope changed')
        network=json.loads(command(['docker','network','inspect',record['network']]).stdout)[0]
        if network['Labels'].get(LABEL)!=case or not network['Internal'] or network['Containers'] or network['IPAM']['Config'][0]['Gateway']!=record['gateway']:
            raise RuntimeError('Private test network changed')
        logs=command(['docker','logs',record[key]],expected=None)
        suffix='-drain' if args.action=='restore-drain' else ''
        with (root/('runtime-before-'+args.session+suffix+'.log')).open('xb') as output: output.write(logs.stdout+logs.stderr)
        if args.action=='resume-repair':
            record['repairSessions']=repairs+[args.session]
        elif args.action=='resume-corrected':
            record.update(correctedSession=args.session,correctedPriorState=value['State'],correctedStarted=time.time())
        else:record['drainSessions']=drains+[args.session]
        record['activeSession']=args.session;save()
        command(['docker','start',record[key]])
        record.update(phase='running corrected session',started=time.time(),expires=time.time()+1800);save()
        print(json.dumps(dict(phase=record['phase'],session=args.session,sameRuntime=True,selfExpirySeconds=1800)),flush=True)
    elif args.action == 'resume-reader':
        if not args.session or str(uuid.UUID(args.session)).upper()!=args.session or args.session==case:
            raise RuntimeError('Requires the approved exact reader session UUID')
        key=record.get('activeRuntimeKey','runtime'); value=container(key); host=value['HostConfig']
        readers=record.get('readerSessions',[])
        if (record.get('phase')!='stopped' or key!='runtime2' or value['State']['Running']
                or len(readers)>=3 or args.session in readers):
            raise RuntimeError('Reader session exhausted, repeated or retained server not stopped')
        if (value['Image']!=record['image'] or not host['ReadonlyRootfs'] or host['Binds'] or host['Privileged']
                or host['RestartPolicy']['Name'] not in ['', 'no'] or host['Memory']!=384*MIB
                or host['NanoCpus']!=1_000_000_000 or host['PidsLimit']!=128
                or host['PortBindings']!={'445/tcp':[{'HostIp':'127.0.0.1','HostPort':str(PORT)}]}):
            raise RuntimeError('Retained reader server isolation changed')
        network=json.loads(command(['docker','network','inspect',record['network']]).stdout)[0]
        if (network['Labels'].get(LABEL)!=case or not network['Internal'] or network['Containers']
                or network['IPAM']['Config'][0]['Gateway']!=record['gateway']):
            raise RuntimeError('Retained reader server private network changed')
        if command(['ss','-ltnH','sport','=',':'+str(PORT)]).stdout.strip():
            raise RuntimeError('Generated server port is already occupied')
        # Read only the exact generated bytes/config inside the immutable stopped
        # container; no host share or personal server path is inspected.
        def generated_bytes(path, limit):
            raw=command(['docker','cp',record[key]+':'+path,'-']).stdout
            with tarfile.open(fileobj=io.BytesIO(raw)) as archive:
                members=archive.getmembers()
                if len(members)!=1 or not members[0].isfile() or members[0].size>limit:
                    raise RuntimeError('Generated server verification extent refused')
                body=archive.extractfile(members[0]).read(limit+1)
                if len(body)!=members[0].size:raise RuntimeError('Generated server bytes changed')
                return body
        if hashlib.sha256(generated_bytes('/etc/samba/smb.conf',65536)).hexdigest()!=record['configSHA256']:
            raise RuntimeError('Retained generated configuration changed')
        if set(record['fixtures'])!={'Read me.txt','Café 文件.txt','Folder/Nested note.txt'}:
            raise RuntimeError('Generated fixture namespace changed')
        for name,facts in record['fixtures'].items():
            body=generated_bytes('/srv/explorer-qa/'+name,4096)
            if len(body)!=facts['bytes'] or hashlib.sha256(body).hexdigest()!=facts['sha256']:
                raise RuntimeError('Retained generated fixture changed')
        logs=command(['docker','logs',record[key]],expected=None)
        with (root/('runtime-before-reader-'+args.session+'.log')).open('xb') as output:
            output.write(logs.stdout+logs.stderr)
        record.update(readerSessions=readers+[args.session],activeSession=args.session)
        save()
        command(['docker','start',record[key]])
        probe="from pathlib import Path; import sys; rows=Path('/proc/net/tcp').read_text().splitlines()[1:]; sys.exit(0 if any(r.split()[1].endswith(':01BD') and r.split()[3]=='0A' for r in rows) else 1)"
        deadline=time.monotonic()+10
        while command(['docker','exec',record[key],'/usr/bin/python3','-c',probe],expected=None).returncode:
            if time.monotonic()>deadline:raise RuntimeError('Generated SMB listener did not become ready')
            time.sleep(0.2)
        record.update(phase='running reader session',started=time.time(),expires=time.time()+1800)
        save()
        print(json.dumps(dict(phase=record['phase'],session=args.session,sameRuntime=True,
            verifiedGeneratedFixtures=True,selfExpirySeconds=1800)),flush=True)
    elif args.action == 'stop':
        if args.session and record.get('activeSession',record.get('correctedSession'))!=args.session:
            raise RuntimeError('Corrected-session identity changed')
        key=record.get('activeRuntimeKey','runtime'); value=container(key)
        if value['State']['Running']: command(['docker','stop','--time','10',record[key]])
        logs=command(['docker','logs',record[key]],expected=None)
        with (root/('runtime-stop-'+str(uuid.uuid4()).upper()+'.log')).open('xb') as output:
            output.write(logs.stdout+logs.stderr)
        record.update(phase='stopped',stopped=time.time()); save()
        print(json.dumps(dict(phase='stopped',case=case,listenerPresent=bool(command(['ss','-ltnH','sport','=',':'+str(PORT)]).stdout.strip()))),flush=True)
    else:
        value=container(record.get('activeRuntimeKey','runtime')) if 'runtime' in record else None
        print(json.dumps(dict(phase=record['phase'],case=case,samba=record.get('sambaVersion'),
            toolingBytes=image_bytes(),runtimeRunning=value['State']['Running'] if value else False,
            runtimeExitCode=value['State']['ExitCode'] if value else None,
            runtimeAddresses=[entry.get('IPAddress') for entry in value['NetworkSettings']['Networks'].values()] if value else [],
            loopbackPort=PORT,fixtureCount=len(record.get('fixtures',{})))),flush=True)

if __name__ == '__main__':
    main()
