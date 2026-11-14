#!/usr/bin/env python3
"""Reproducible isolated SFTP wire/dependency controls; no personal endpoints."""
import argparse
import hashlib
import json
from pathlib import Path
import os
import signal
import subprocess
import sys
import time
sys.dont_write_bytecode = True
from packet import REPO, ROOT, TOOLING, TOOLCHAIN, MIB, directory, environment, reserve, put, audit

PROJECT = REPO/'tools/sftp_reader/qualification'
SSH_SCENARIOS = ['first','matching','changed-refused','changed-replaced','stale-decision',
    'cancel-host','host-deadline','pre-banner','bad-password','read-stop','lost-close',
    'disconnect-read','unsolicited','legacy-refused']


def admit_ssh(case, scenario, *, phase='reader'):
    """Count admissions durably before a generated binary may bind/connect."""
    import fcntl
    with (ROOT/'.budget.lock').open('a+b') as lock:
        fcntl.flock(lock,fcntl.LOCK_EX)
        audit()
        # One durable connection allowance spans the retained reader and native
        # packets. A new evidence envelope never resets network authority.
        native_root=REPO/'.build/b11-native-qualification'
        if native_root.exists():
            from native_packet import audit as native_audit
            native_audit()
        if case.parent not in [ROOT,native_root]:raise RuntimeError('Unknown SSH evidence envelope')
        previous = list(ROOT.glob('*/evidence/ssh-*-admitted.json'))+list(native_root.glob('*/evidence/ssh-*-admitted.json'))
        if phase not in ['reader','worker']:raise RuntimeError('Unknown generated SSH phase')
        phase_used=0
        for path in previous:
            value=json.loads(path.read_bytes())
            if value.get('connectionAttempts')!=1 or value.get('scope')!='generated-loopback-only':
                raise RuntimeError('Unknown SSH admission; inspect before continuation')
            previous_phase=value.get('phase','reader')
            if previous_phase not in ['reader','worker']:raise RuntimeError('Unknown prior SSH phase')
            phase_used+=previous_phase==phase
        if phase_used >= (32 if phase == 'reader' else 48) or len(previous) >= 80: raise RuntimeError('B11 generated phase/aggregate connection allowance exhausted')
        path=case/'evidence'/('ssh-'+scenario+'-admitted.json')
        put(path,dict(scope='generated-loopback-only',connectionAttempts=1,ordinal=len(previous)+1,phase=phase,phaseOrdinal=phase_used+1,
            scenario=scenario,personalEndpoints=0,systemSSHConfiguration=False))
        with path.open('rb') as receipt: os.fsync(receipt.fileno())
        fd=os.open(path.parent,os.O_RDONLY|os.O_DIRECTORY)
        try: os.fsync(fd)
        finally: os.close(fd)


def run(command, case, label, *, timeout=300, stdout=None,native=False,auditor=audit):
    log = case/'evidence'/(label+'.log')
    began = time.monotonic()
    with log.open('xb') as out:
        child = subprocess.Popen(command, cwd=PROJECT, env=environment(native=native), stdin=subprocess.DEVNULL,
            stdout=out if stdout is None else stdout, stderr=subprocess.STDOUT if stdout is None else out,
            start_new_session=True)
        failure = None
        stopping = None
        forced = False
        last_audit = began
        while True:
            found, status, stats = os.wait4(child.pid, os.WNOHANG)
            if found:
                child.returncode = os.waitstatus_to_exitcode(status)
                break
            now = time.monotonic()
            if failure is None and (now-began > timeout or log.stat().st_size > 4*MIB):
                failure = 'Generated tool deadline/log bound'
            if failure is None and now-last_audit > 2:
                try: auditor()
                except Exception: failure = 'Generated tool resource bound'
                last_audit = now
            if failure is not None and stopping is None:
                stopping = now
                try: os.killpg(child.pid,signal.SIGTERM)
                except ProcessLookupError: pass
            if stopping is not None and now-stopping > 3 and not forced:
                forced = True
                try: os.killpg(child.pid,signal.SIGKILL)
                except ProcessLookupError: pass
            if stopping is not None and now-stopping > 8:
                raise RuntimeError('Exact generated build group remains; inspect before retry')
            time.sleep(.02)
    put(case/'evidence'/(label+'.process.json'),dict(actualExit=child.returncode, elapsedSeconds=time.monotonic()-began,
        command=command, logSHA256=hashlib.sha256(log.read_bytes()).hexdigest(), peakRSSBytes=stats.ru_maxrss,
        generatedContainment=stopping is not None, forcedContainment=forced, failure=failure))
    auditor()
    if child.returncode != 0 or failure is not None: raise RuntimeError(label+' failed; retained '+str(log))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['wire','resolve','test','published-probe','compare','ssh'])
    parser.add_argument('--offline', action='store_true', help='Use the existing locked local dependency cache only.')
    parser.add_argument('--release', action='store_true', help='Use the optimized qualification configuration.')
    parser.add_argument('--scenario', choices=SSH_SCENARIOS, action='append', help='Admit only selected generated SSH controls.')
    args = parser.parse_args()
    case = reserve(args.action,size=8*MIB if args.action=='test' else 16*MIB,entries=128 if args.action=='test' else 256)
    compiler = str(TOOLCHAIN/'bin/rustc')
    try:
        found = subprocess.check_output([compiler,'--version'],env=environment(),text=True,timeout=10).strip()
        if not found.startswith('rustc 1.99.1 '): raise RuntimeError('Compiler pin differs')
        source = PROJECT/'src/wire.rs'
        put(case/'inputs.json',dict(action=args.action, compiler=found,
            wireSHA256=hashlib.sha256(source.read_bytes()).hexdigest(), personalEndpoints=0,
            keychainQueries=0, connectionAttempts=0, sourceExecution='qualification only',
            sourceSHA256={str(p.relative_to(PROJECT)):hashlib.sha256(p.read_bytes()).hexdigest()
                for p in sorted((PROJECT/'src').rglob('*.rs'))}))
        directory(case/'source')
        for name in ['Cargo.toml','Cargo.lock']:
            if (PROJECT/name).exists():
                with (case/'source'/name).open('xb') as snapshot: snapshot.write((PROJECT/name).read_bytes())
        if args.action == 'wire':
            for name, level in [('debug','0'),('optimized','3')]:
                binary = TOOLING/('wire-tests-'+case.name+'-'+name)
                run([compiler,'--test','--edition=2024','-D','warnings','-C','debuginfo=0','-C','opt-level='+level,
                    str(source),'-o',str(binary)],case,'compile-'+name)
                run([str(binary),'--test-threads=1'],case,'wire-'+name,timeout=15)
        else:
            cargo = str(TOOLCHAIN/'bin/cargo')
            if args.action == 'resolve':
                run([cargo,'generate-lockfile',*(['--offline'] if args.offline else [])],case,'lock')
                with (case/'evidence/metadata.json').open('xb') as output:
                    run([cargo,'metadata',*(['--offline'] if args.offline else []),'--format-version','1','--locked',
                        '--filter-platform','aarch64-apple-darwin'],case,'metadata',stdout=output)
                metadata = json.loads((case/'evidence/metadata.json').read_bytes())
                active = {node['id']:node for node in metadata['resolve']['nodes']}
                packages = [dict(name=p['name'], version=p['version'], license=p['license'], features=active[p['id']]['features'])
                    for p in metadata['packages'] if p['id'] in active]
                forbidden = {'aws-lc-rs','aws-lc-sys','openssl','openssl-sys','flate2'}
                if any(p['name'] in forbidden for p in packages): raise RuntimeError('Unselected crypto/compression backend was resolved')
                if not any(p['name']=='ring' for p in packages): raise RuntimeError('Explicit ring backend absent')
                put(case/'evidence/active-graph.json',dict(packages=packages,
                    cargoLockSHA256=hashlib.sha256((PROJECT/'Cargo.lock').read_bytes()).hexdigest(),
                    fullAdvisoryScreenComplete=False, dependencyAdopted=False))
            elif args.action == 'published-probe':
                run([cargo,'run','--locked',*(['--offline'] if args.offline else []),'--bin','published_parser_probe'],
                    case,'published-parser-probe',timeout=300)
            elif args.action == 'compare':
                run([cargo,'build','--release','--locked',*(['--offline'] if args.offline else []),'--bin','metadata_compare'],
                    case,'build-comparison',timeout=300)
                outputs=[]
                binary=str(TOOLING/'target/release/metadata_compare')
                for pair,lanes in enumerate([['reference','serial'],['serial','reference'],['reference','serial']]):
                    for lane in lanes:
                        label='compare-'+str(pair)+'-'+lane
                        run([binary,lane],case,label,timeout=30)
                        value=json.loads((case/'evidence'/(label+'.log')).read_bytes())
                        if value.get('records')!=100000 or value.get('tasksAfterDrain')!=0:
                            raise RuntimeError('Comparison count or actual task drain differs')
                        outputs.append(value)
                if len({(v['records'],v['totalBytes'],v['checksum'])for v in outputs})!=1:
                    raise RuntimeError('Comparison metadata is not equivalent')
                put(case/'evidence/comparison.json',dict(samples=outputs, fullNativePipelineMeasured=False))
            elif args.action == 'ssh':
                run([cargo,'build','--locked',*(['--offline'] if args.offline else []),*(['--release']if args.release else []),
                    '--bin','ssh_session_probe'],case,'build-ssh',timeout=300)
                binary=str(TOOLING/('target/release'if args.release else'target/debug')/'ssh_session_probe')
                samples=[]
                for scenario in args.scenario or SSH_SCENARIOS:
                    admit_ssh(case,scenario)
                    label='ssh-'+scenario
                    run([binary,scenario],case,label,timeout=12)
                    value=json.loads((case/'evidence'/(label+'.log')).read_bytes())
                    if value.get('passed')is not True or value.get('clientTasksAfterRuntimeDrop')!=0 \
                            or value.get('serverSocketEnded')is not True or value.get('fixtureTasksAborted')!=0:
                        raise RuntimeError('SSH task/socket drain gate failed')
                    samples.append(value)
                put(case/'evidence/ssh-results.json',dict(samples=samples,ordinaryActivation=False,
                    nativeWorkerQualified=False,personalEndpoints=0))
            else:
                run([cargo,'test','--locked',*(['--offline'] if args.offline else []),*(['--release']if args.release else []),
                    '--all-targets','--','--test-threads=1'],case,'tests',timeout=300)
        put(case/'result.json',dict(passed=True, action=args.action, ordinaryActivation=False, packet=audit()))
        print(json.dumps(dict(case=case.name, passed=True, action=args.action)))
    except Exception as error:
        put(case/'result.json',dict(passed=False, failure=type(error).__name__+': '+str(error),
            ordinaryActivation=False, packet=audit()))
        raise


if __name__ == '__main__': main()
