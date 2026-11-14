#!/usr/bin/env python3
"""Finite, source-bound input controls on the actual development app."""
import argparse
import hashlib
import importlib.util
import json
import os
import sys
from pathlib import Path

sys.dont_write_bytecode = True
REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / 'tools'))
import development as d

ACTION = 'native-explorer-pointer'
PROCESS = REPO / 'tools/sftp_text_edit/original_lifecycle_candidate5/original_process.py'
LIMITS = dict(cases=4, maximumBytes=64 << 20, maximumEntries=512, runtimeCalls=1,
              maximumSeconds=120, maximumRSSBytes=256 << 20, maximumNativeWindows=1,
              fileMutations=0, OSPostedEvents=0, networkCalls=0, personalFiles=0)

def load(p): return json.loads(p.read_bytes())
def sha(p): return hashlib.sha256(p.read_bytes()).hexdigest()
def cases(): return [p.parent for p in d.ROOT.glob('*/reservation.json') if load(p).get('action') == ACTION]

def proof(build):
    v = load(build / 'evidence/source.json')
    if not load(build / 'evidence/build.json')['passed'] or v['sourceSHA256'] != d.native_sources():
        raise RuntimeError('Exact actual current whole-App build required')
    for rel, digest in [(v['loadedRelative'], v['loadedSHA256']), ('Contents/MacOS/Mac Explorer', v['executableSHA256'])]:
        if sha(d.APP / rel) != digest: raise RuntimeError('Whole-App product changed')
    for name, digest in v['helpersSHA256'].items():
        if sha(d.APP / 'Contents/Helpers' / name) != digest: raise RuntimeError('Helper changed')
    return v

def audit(root):
    m = d.measure(root)
    if m['bytes'] > LIMITS['maximumBytes'] or m['entries'] > LIMITS['maximumEntries']:
        raise RuntimeError('Pointer case limit')
    return d.audit()

def prepare(build, variant):
    if len(cases()) >= LIMITS['cases']: raise RuntimeError('Four finite pointer cases consumed')
    v = proof(build)
    root = d.reserve(ACTION)
    for leaf in ['tmp', 'user']: (root / 'cache' / leaf).mkdir(mode=0o700)
    d.put(root / 'native-admission.json', dict(case=root.name, master='B9A65D62-0CFC-4400-A1DF-811F5A977962',
          variant=variant, maximumNativeWindows=1, generatedInProcessEventsOnly=True))
    files = [Path(__file__), PROCESS, REPO / 'tools/development.py', REPO / 'tools/native_build_processes.py',
             REPO / 'tools/ssh_profiles/owned_observer.py', build / 'evidence/source.json', build / 'evidence/build.json']
    d.put(root / 'inputs.json', dict(limits=LIMITS, variant=variant, build=build.name,
          files={str(p.relative_to(REPO)): sha(p) for p in files}, nativeGraph=v['sourceSHA256'],
          command=[str(d.APP / 'Contents/MacOS/Mac Explorer'), '--verify-ui', '--check-explorer-pointer'],
          usageBefore=d.audit()))
    print(json.dumps(dict(case=root.name, prepared=True, variant=variant)), flush=True)

def checked(root):
    if root.resolve() != root or root not in cases(): raise RuntimeError('Exact pointer case required')
    v = load(root / 'inputs.json')
    if v['limits'] != LIMITS: raise RuntimeError('Frozen pointer limits changed')
    for name, digest in v['files'].items():
        if sha(REPO / name) != digest: raise RuntimeError('Frozen pointer input changed: ' + name)
    if proof(d.ROOT / v['build'])['sourceSHA256'] != v['nativeGraph']: raise RuntimeError('Native graph changed')
    return v

def run(root):
    v = checked(root)
    attempt = root / 'evidence/native-attempt.json'
    if attempt.exists(): raise RuntimeError('One use only; preserve all failures')
    # No app is launched if the desktop cannot show the actual native controls.
    import plistlib
    import subprocess
    console = plistlib.loads(subprocess.check_output(['/usr/sbin/ioreg', '-n', 'Root', '-d1', '-a'], timeout=5))
    users = (console if isinstance(console, dict) else console[0]).get('IOConsoleUsers', [])
    if not users or any(u.get('CGSSessionScreenIsLocked', False) for u in users):
        raise RuntimeError('Native input postponed: desktop locked')
    env = {k: x for k, x in d.dev.environment(tooling=False).items() if not k.startswith('DYLD_')}
    env.update(CFFIXED_USER_HOME=str(root / 'cache/user'), TMPDIR=str(root / 'cache/tmp') + '/',
               MAC_EXPLORER_TEST_ROOT=str(root), MAC_EXPLORER_STATE_ROOT=str(root / 'state'),
               MAC_EXPLORER_CACHE_ROOT=str(root / 'cache'))
    spec = importlib.util.spec_from_file_location('pointer_owned_process', PROCESS)
    owner = importlib.util.module_from_spec(spec); spec.loader.exec_module(owner)
    command = v['command']; label = 'pointer-' + v['variant']
    def closed(actual, area, name, kind, rss, seconds, actual_env):
        checked(root)
        if (actual, area, name, kind, rss, seconds, actual_env) != (command, root, label, 'native', LIMITS['maximumRSSBytes'], LIMITS['maximumSeconds'], env):
            raise RuntimeError('Exact generated pointer process required')
        return dict(maximumBytes=LIMITS['maximumBytes'], maximumEntries=LIMITS['maximumEntries'])
    owner.validate = closed
    d.put(attempt, dict(command=command, maximumSeconds=LIMITS['maximumSeconds'], maximumRSSBytes=LIMITS['maximumRSSBytes'],
          variant=v['variant'], sourceGraphSHA256=hashlib.sha256(json.dumps(v['nativeGraph'], sort_keys=True).encode()).hexdigest()))
    result = dict(passed=False, variant=v['variant'])
    try:
        actual, out, err = owner.run(command, root, label, 'native', LIMITS['maximumRSSBytes'], LIMITS['maximumSeconds'], env, lambda: audit(root))
        control = load(root / 'evidence/native.json') if (root / 'evidence/native.json').is_file() else None
        drained = actual.get('actualProcessAndDescendantDrain') is True and actual.get('observer', {}).get('drained') is True
        good = actual['passed'] and drained and not actual['contained'] and not actual['forced']
        good = good and control is not None and control.get('passed') is True and control.get('activityDrained') is True and control.get('nativeWindowsClosed') is True
        result.update(passed=bool(good), process=actual, controls=control, actualDrain=drained, usage=audit(root))
    finally:
        d.put(root / 'evidence/result.json', result)
        print(json.dumps(dict(case=root.name, passed=result['passed'], variant=v['variant'], failure=(result.get('controls') or {}).get('failure'))), flush=True)
    if not result['passed']: raise SystemExit(1)

if __name__ == '__main__':
    p = argparse.ArgumentParser(); p.add_argument('stage', choices=['prepare', 'run']); p.add_argument('--case'); p.add_argument('--build'); p.add_argument('--variant', choices=['original', 'candidate', 'repair1', 'repair2'])
    a = p.parse_args()
    if a.stage == 'prepare' and a.build and a.variant and a.case is None: prepare(d.ROOT / a.build, a.variant)
    elif a.stage == 'run' and a.case and not a.build: run(d.ROOT / a.case)
    else: p.error('One exact stage and scope required')
