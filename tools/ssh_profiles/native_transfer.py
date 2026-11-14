#!/usr/bin/env python3
"""Exact signed native Connect/Download/Undo/Upload, generated sources only."""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import plistlib
import select
import stat
import subprocess
import sys
import time
import uuid
sys.dont_write_bytecode = True
from packet import prepare, d, audit, run, TOOLING, directory
from process import Child, line
from worker_qualification import duplicate, public
from worker_build import sources
from transfer_qualification import generated
from network_ledger import record


def unlocked():
    value = plistlib.loads(subprocess.check_output(['/usr/sbin/ioreg','-n','Root','-d1','-a'], timeout=5))
    users = (value if isinstance(value,dict) else value[0]).get('IOConsoleUsers',[])
    if not users or any(user.get('CGSSessionScreenIsLocked',False) for user in users):
        raise RuntimeError('Native field check deferred; console is locked or unavailable')


def native_proof(token):
    import development
    if str(uuid.UUID(token)).upper() != token: raise RuntimeError('Canonical build case required')
    proof = json.loads((d.ROOT/token/'evidence/source.json').read_bytes())
    build = json.loads((d.ROOT/token/'evidence/build.json').read_bytes())
    loaded = development.loaded_object(development.APP,proof['configuration'],proof.get('optimizedQualification',False))
    if proof['configuration'] != 'Debug' or proof['sourceSHA256'] != development.native_sources() \
       or not build.get('passed')or proof['loadedSHA256'] != d.digest(loaded):
        raise RuntimeError('Exact current signed native build required')
    if proof.get('executableSHA256')is not None and proof['executableSHA256']!=d.digest(development.APP/'Contents/MacOS/Mac Explorer'):
        raise RuntimeError('Native launcher/executable no longer matches its build')
    subprocess.run(['codesign','--verify','--strict','--deep',str(development.APP)],capture_output=True,check=True,timeout=30)
    return proof


def generate_source(root):
    keys_case = d.ROOT/'C4D28241-2E4A-4F4D-AF4B-688E164885EE'
    if not json.loads((keys_case/'evidence/result.json').read_bytes())['passed']: raise RuntimeError('Passed generated keys required')
    directory(root/'state/Native'); directory(root/'source/Local'); directory(root/'source/Destination')
    values = {'source/Local/Upload.bin': generated(0,65553), 'source/Destination/Existing.txt': b'Existing generated file',
              'source/client-key': (keys_case/'state/encrypted-0').read_bytes()}
    stamps = {}
    for name, body in values.items():
        path = root/name
        fd = os.open(path,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW|os.O_CLOEXEC,0o600)
        with os.fdopen(fd,'wb') as out: out.write(body)
        facts = path.lstat(); stamps[name] = [d.digest(path),facts.st_dev,facts.st_ino,facts.st_size,facts.st_mtime_ns,facts.st_mode]
    return keys_case/'state', stamps


def verify_sources(root, expected):
    for name, stamp in expected.items():
        path = root/name; facts = path.lstat()
        if not stat.S_ISREG(facts.st_mode) or facts.st_nlink != 1 or [d.digest(path),facts.st_dev,facts.st_ino,facts.st_size,facts.st_mtime_ns,facts.st_mode] != stamp:
            raise RuntimeError('Generated source/occupied destination changed')


def recovery_area_marker(area, expected_operations, *, payload_present):
    """Validate one exact generated recovery area without hiding other files."""
    suffix=area.name.removeprefix('.mac-explorer-recovery-')
    if area.name==suffix or str(uuid.UUID(suffix)).upper()!=suffix:
        raise RuntimeError('Generated recovery area name')
    facts=area.lstat()
    if area.resolve()!=area or not stat.S_ISDIR(facts.st_mode) \
            or facts.st_uid!=os.getuid() or stat.S_IMODE(facts.st_mode)!=0o700:
        raise RuntimeError('Generated recovery area identity')
    marker=area/'.mac-explorer-recovery-v1'
    fd=os.open(marker,os.O_RDONLY|os.O_NOFOLLOW|os.O_CLOEXEC)
    try:
        before=os.fstat(fd)
        if not stat.S_ISREG(before.st_mode) or before.st_uid!=os.getuid() \
                or before.st_nlink!=1 or stat.S_IMODE(before.st_mode)!=0o600 or not 0<before.st_size<=256:
            raise RuntimeError('Generated recovery marker identity')
        raw=os.read(fd,257);after=os.fstat(fd)
        if len(raw)!=before.st_size or (before.st_dev,before.st_ino,before.st_size,before.st_mtime_ns,before.st_ctime_ns) \
                !=(after.st_dev,after.st_ino,after.st_size,after.st_mtime_ns,after.st_ctime_ns):
            raise RuntimeError('Generated recovery marker changed')
    finally:os.close(fd)
    matches=[operation for operation in expected_operations if raw==(
        'MacExplorer recovery v1\n'+operation+'\nRetained until explicit cleanup.\n').encode()]
    expected={marker.name,'payload'} if payload_present else {marker.name}
    if len(matches)!=1 or {path.name for path in area.iterdir()}!=expected:
        raise RuntimeError('Generated recovery ownership or contents differ')
    return matches[0]


def verify_undo(root, report):
    name = report['retainedUndoArea']; operation = report['retainedUndoOperation']
    if name in ['', '.', '..'] or '/' in name or str(uuid.UUID(operation)).upper() != operation: raise RuntimeError('Generated Undo reference')
    area = root/'source/Destination'/name
    if area.resolve() != area or area.is_symlink(): raise RuntimeError('Generated Undo area redirected')
    recovery_area_marker(area,{operation},payload_present=True)
    payload = area/'payload'; fd = os.open(payload,os.O_RDONLY|os.O_NONBLOCK|os.O_CLOEXEC|0x20000000)
    try:
        before = os.fstat(fd)
        if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1 or before.st_size != 1048593: raise RuntimeError('Generated received Undo payload')
        offset = 0; digest = hashlib.sha256()
        while offset < before.st_size:
            data = os.read(fd,min(32768,before.st_size-offset))
            if not data or data != generated(offset,len(data)): raise RuntimeError('Received Undo bytes mismatch')
            offset += len(data); digest.update(data)
        if os.read(fd,1): raise RuntimeError('Generated Undo body grew')
        after = os.fstat(fd)
        if (before.st_dev,before.st_ino,before.st_size,before.st_mtime_ns,before.st_ctime_ns) != (after.st_dev,after.st_ino,after.st_size,after.st_mtime_ns,after.st_ctime_ns):
            raise RuntimeError('Generated Undo body changed')
        return dict(bytes=offset,sha256=digest.hexdigest(),exactMarker=True)
    finally: os.close(fd)


def launch(root, native_case, method, scenario, port, fingerprint, independent=False, observer=None, ordinary=False, record_preview=False, large=False, folder_upload=False):
    import development
    before = native_proof(native_case)
    command = [str(development.APP/'Contents/MacOS/Mac Explorer'),'--verify-ui','--check-sftp-auth-transfer',
               '--generated-method',method,'--generated-transfer',scenario,'--generated-port',str(port),
               '--generated-fingerprint',fingerprint]
    if independent: command += ['--independent-openssh']
    if folder_upload: command += ['--fresh-folder-upload']
    if ordinary: command += ['--ordinary-exclusive-upload']
    if record_preview: command += ['--record-exclusive-upload']
    if large: command += ['--large-interface','--light-interface']
    process, _, _ = run(command,root,'signed-native-auth-transfer',timeout=90,native=True,observer=observer)
    output = root/'evidence/native-auth-transfer.json'
    report = json.loads(output.read_bytes()) if output.is_file() else None
    if not process['passed'] or not report or not report['passed'] or report.get('transferDiagnosticsVerified') is not True or report['keychainCalls'] != 0 or process['peakRSSBytes'] > 256 << 20:
        raise RuntimeError('Signed native authentication/transfer check failed; preserve checkpoint')
    if report.get('ordinaryUpload') != ordinary or report.get('qualificationOverride') != (not ordinary):
        raise RuntimeError('Native Upload activation/qualification binding differs')
    if before['sourceSHA256'] != development.native_sources(): raise RuntimeError('Native source fence changed')
    undo = verify_undo(root,report) if report['exactUndo'] else None
    if d.measure(root)['bytes'] > 64 << 20: raise RuntimeError('Native composition case byte cap')
    return dict(process=process,native=report,independentUndo=undo)


def one(native_case, worker_case, method, scenario, allowance='transfer-loopback', ordinary=False, record_preview=False, large=False):
    if record_preview: raise RuntimeError('Use the separate zero-network native Upload preview recorder; keep transfer timing uninstrumented')
    unlocked(); proof = native_proof(native_case)
    built = json.loads((d.ROOT/worker_case/'evidence/result.json').read_bytes())
    mode = 'release' if built['release'] else 'debug'; fixture = TOOLING/'target'/mode/'key_fixture'
    if not built['passed'] or built['sources'] != sources() or d.digest(fixture) != built['binaries']['key_fixture']:
        raise RuntimeError('Current source-bound body fixture required')
    root = d.reserve('sftp-native-auth-transfer'); peer = None; fds = []; pending = []; stop_notices = []
    d.put(root/'inputs.json',dict(nativeCase=native_case,workerCase=worker_case,method=method,scenario=scenario,
        nativeSources=proof['sourceSHA256'],generatedOnly=True,personalKeychain=False,sourceBodyBytes=65553,
        visualAcceptance=False,toolSHA256=d.digest(Path(__file__))))
    try:
        keys, stamps = generate_source(root)
        if allowance not in ['transfer-loopback','exclusive-upload-loopback']:raise RuntimeError('Finite native packet required')
        record(allowance,root,'signed-native-'+method+'-'+scenario)
        read, write = map(duplicate,os.pipe()); ir, iw = map(duplicate,os.pipe()); fds += [read,write,ir,iw]
        os.write(iw,public(keys/'key-0.pub')); os.close(iw); fds.remove(iw)
        prefix = {'key':'key-auth-','prompts':'interactive-auth-','mfa':'mfa-key-auth-'}[method]
        role = {'success':'composed-success','download-stop':'transfer-stop','upload-lost-close':'composed-lost-close','upload-stop':'composed-stop-write'}[scenario]
        peer = Child([fixture,prefix+role],root,'native-body-fixture',stdin=ir,stdout=write)
        os.close(ir); fds.remove(ir); os.close(write); fds.remove(write)
        ready = line(read,root,'native-body-ready')
        fingerprint = 'SHA256:'+base64.b64encode(hashlib.sha256(bytes.fromhex(ready['generatedPublicKey'])).digest()).decode().rstrip('=')
        def observe(pid):
            if scenario in ['download-stop','upload-stop'] and not pending and select.select([read],[],[],0)[0]:
                value = line(read,root,'generated-native-io-pending')
                if value != {'generatedBodyPending':'read' if scenario=='download-stop' else 'write'}: raise RuntimeError('Exact generated I/O boundary required')
                pending.append(value); stop_notices.append(time.monotonic()); d.put(root/'state/Stop.control',dict(nativePID=pid,generatedReadPending=True))
        result = launch(root,native_case,method,scenario,ready['port'],fingerprint,observer=observe,ordinary=ordinary,record_preview=record_preview,large=large)
        stop_upper_bound = None if not stop_notices else time.monotonic() - stop_notices[0]
        if stop_upper_bound is not None and stop_upper_bound >= 3: raise RuntimeError('Generated pending I/O to actual app exit exceeded3 seconds')
        observed = line(read,root,'native-body-ended')
        if allowance == 'exclusive-upload-loopback':
            exclusive = line(read,root,'native-exclusive-observation')
            if not exclusive.get('exclusiveObservation') or exclusive['renameRequests'] != 0 or exclusive['deleteRequests'] != 0 or exclusive['temporaryPresent']:
                raise RuntimeError('G sent a prohibited mutation or retained staging alias')
        assert observed['ended'] and observed['runtimeTasksAfter'] == 0 and observed['fixtureTasksAborted'] == 0
        assert observed['authCalls'] == (0 if method == 'prompts' else 1) and observed['interactiveCalls'] == (0 if method == 'key' else 3)
        assert observed['uploadPublishedLengthPlusOne'] == (0 if scenario in ['download-stop','upload-stop'] else 65554)
        if scenario not in ['download-stop','upload-stop']: assert observed['uploadFinalSHA256'] == stamps['source/Local/Upload.bin'][0]
        if scenario in ['download-stop','upload-stop']: assert len(pending) == 1
        assert peer.wait() == 0 and peer.log.stat().st_size == 0
        verify_sources(root,stamps)
        d.put(root/'evidence/result.json',dict(passed=True,method=method,scenario=scenario,result=result,fixture=observed,
            sourceUnchanged=True,pendingIOToActualAppExitUpperSeconds=stop_upper_bound,visualAcceptance=False,usage=audit()))
        print(json.dumps(dict(case=root.name,passed=True,method=method,scenario=scenario)),flush=True); return root.name
    except BaseException as error:
        d.put(root/'evidence/result.json',dict(passed=False,error=type(error).__name__,usage=audit())); raise
    finally:
        if peer:
            peer.contain()
            if peer.status == 0 and read in fds and select.select([read],[],[],0)[0] and not (root/'evidence/native-body-ended.json').exists():
                try: line(read,root,'native-body-failure-end',timeout=1)
                except (RuntimeError,ValueError): pass
        for fd in fds: os.close(fd)


def main():
    parser = argparse.ArgumentParser(); parser.add_argument('--native-case',required=True); parser.add_argument('--worker-case',required=True)
    parser.add_argument('--method',choices=['key','prompts','mfa'],default='mfa')
    parser.add_argument('--scenario',choices=['success','download-stop','upload-lost-close','upload-stop'],default='success')
    args = parser.parse_args(); prepare(); one(args.native_case,args.worker_case,args.method,args.scenario)


if __name__ == '__main__': main()
