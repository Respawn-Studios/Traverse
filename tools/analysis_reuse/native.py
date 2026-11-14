#!/usr/bin/env python3
"""Finite actual-App sealed-result reuse qualification, never a release runner."""
import argparse
import fcntl
import hashlib
import json
import os
import plistlib
import shutil
import subprocess
import sys
from pathlib import Path
sys.dont_write_bytecode = True
REPO = Path(__file__).resolve().parents[2]
sys.path[:0] = [str(REPO / 'tools'), str(REPO / 'tools/sftp_text_edit')]
import development as d
import native_source1 as common

MASTER = 'B9A65D62-0CFC-4400-A1DF-811F5A977962'
PACKET = d.ROOT / MASTER / 'source/AnalysisReuseRunner'
ACTION = 'analysis-session-reuse'
CODE_ACTION = ACTION + '-code-cohorts'
LIMITS = dict(runtimeCases=2, bytes=64 << 20, entries=512, seconds=180,
              rssBytes=512 << 20, processes=8, sourceBytes=65536, sourceEntries=64,
              codeBytes=512 << 20, codeEntries=4096)
VARIANTS = ['positive', 'negative01', 'negative02', 'negative03', 'negative04']

def load(p): return json.loads(p.read_bytes())
def sha(p): return d.digest(p)
def cases(action): return common.cases(action)
def tools():
    paths = [Path(__file__), REPO / 'tools/development.py', REPO / 'tools/sftp_text_edit/native_source1.py',
             common.PROCESS, REPO / 'tools/native_build_processes.py', REPO / 'tools/ssh_profiles/owned_observer.py']
    return {str(p.relative_to(REPO)): sha(p) for p in paths}
def packet_proof():
    manifest = PACKET / 'packet-sha256.json'
    if sha(manifest) != '9266496f348f614eb482adf506d268259b4412fca85abbc1d12e3e29b5403f36':
        raise RuntimeError('Exact reviewed runner freeze required')
    value = load(manifest)
    for n, h in value.items():
        expected = h['sha256'] if isinstance(h, dict) else h
        if sha(PACKET / n) != expected: raise RuntimeError('Frozen runner changed')
    return {str(manifest.relative_to(REPO)): sha(manifest), **{str((PACKET / n).relative_to(REPO)):
        h['sha256'] if isinstance(h, dict) else h for n, h in value.items()}}
def whole_app(build):
    proof = load(build / 'evidence/source.json')
    if load(build / 'evidence/build.json').get('passed') is not True or proof['sourceSHA256'] != d.native_sources():
        raise RuntimeError('Actually passed current full App graph required')
    for n, h in [(proof['loadedRelative'], proof['loadedSHA256']),
                 ('Contents/MacOS/Mac Explorer', proof['executableSHA256'])]:
        if sha(d.APP / n) != h: raise RuntimeError('Actual current App image changed')
    for n, h in proof['helpersSHA256'].items():
        if sha(d.APP / 'Contents/Helpers' / n) != h: raise RuntimeError('Actual bundled worker changed')
    return proof
def budget(root, code=False):
    value = d.measure(root)
    if value['bytes'] > LIMITS['codeBytes' if code else 'bytes'] or value['entries'] > LIMITS['codeEntries' if code else 'entries']:
        raise RuntimeError('Exact reuse case budget')
    if value['allocatedBytes'] > LIMITS['codeBytes' if code else 'bytes']: raise RuntimeError('Allocated reuse case budget')
    return value
def admitted(root):
    if root.resolve() != root or root not in cases(ACTION): raise RuntimeError('Exact native reuse runtime root')
    v = load(root / 'inputs.json')
    if v['tools'] != tools() or v['limits'] != LIMITS: raise RuntimeError('Frozen reuse tools/limits')
    for n, h in v['packet'].items():
        if sha(REPO / n) != h: raise RuntimeError('Frozen reuse source changed')
    if sha(Path(v['worker'])) != v['workerSHA256']: raise RuntimeError('Actual qualified worker changed')
    return v
def prepare(build):
    if len(cases(ACTION)) >= LIMITS['runtimeCases']: raise RuntimeError('Finite reuse packet exhausted')
    p = whole_app(build); packet = packet_proof()
    root = d.reserve(ACTION); code = d.reserve(CODE_ACTION)
    for name in ['runs', 'cache/user', 'cache/tmp']: (root / name).mkdir(mode=0o700, parents=True)
    # Preserve the unmodified, accepted development App before any profile seal.
    original = code / 'source/Accepted Development.app'
    shutil.copytree(d.APP, original, symlinks=True)
    worker = original / 'Contents/Helpers/storage-scanner-worker'
    v = dict(master=MASTER, tools=tools(), limits=LIMITS, packet=packet, positiveBuild=build.name,
        positiveGraph=p['sourceSHA256'], codeCase=code.name, worker=str(worker), workerSHA256=sha(worker),
        expectedNativeCases=load(PACKET / 'cases.json'), ordinaryActivation=False, publication=False)
    d.put(root / 'inputs.json', v)
    d.put(root / 'analysis-reuse-admission.json', dict(schema=1, action=ACTION, rootID=root.name,
        maximumBytes=LIMITS['bytes'], maximumEntries=LIMITS['entries'], fixtureBytesPerLane=65536,
        fixtureEntriesPerLane=64, sessionByteLimit=4 << 20, workerPath=str(worker), workerSHA256=sha(worker)))
    d.put(code / 'inputs.json', dict(master=MASTER, runtime=root.name, maximumBytes=LIMITS['codeBytes'],
        maximumEntries=LIMITS['codeEntries'], baseAppSHA256=p['executableSHA256'], variants=VARIANTS))
    budget(code, True); budget(root); d.audit()
    print(json.dumps(dict(runtime=root.name, codeCohorts=code.name, prepared=True)), flush=True)
def freeze(root, build, variant):
    v = admitted(root); p = whole_app(build)
    if variant not in VARIANTS: raise RuntimeError('Finite code variant')
    if variant == 'positive' and p['sourceSHA256'] != v['positiveGraph']: raise RuntimeError('Positive source must stay identical')
    code = d.ROOT / v['codeCase']; app = code / 'source' / (variant + '.app')
    if app.exists(): raise RuntimeError('One code-cohort seal; preserve failures')
    before = budget(code, True)
    required = d.measure(d.APP)
    if before['bytes'] + required['bytes'] + (1 << 20) > LIMITS['codeBytes'] or before['entries'] + required['entries'] + 8 > LIMITS['codeEntries']:
        raise RuntimeError('Prospective code-cohort headroom')
    shutil.copytree(d.APP, app, symlinks=True)
    info = app / 'Contents/Info.plist'
    values = plistlib.loads(info.read_bytes())
    values.update(CFBundleIdentifier='local.macexplorer.preview', CFBundleName='Traverse reuse qualification',
        MacExplorerDistributionChannel='development-preview', MacExplorerReviewCase=root.name,
        MacExplorerReviewStorage='repository-v1', TraverseVerificationOnly=True, TraverseAnalysisReuseVariant=variant)
    # Qualification bundles must never advertise folder/URL-opening handlers.
    values.pop('CFBundleDocumentTypes', None); values.pop('CFBundleURLTypes', None)
    info.write_bytes(plistlib.dumps(values))
    subprocess.run(['codesign', '--force', '--sign', '-', '--timestamp=none',
        '--preserve-metadata=entitlements,flags,runtime', str(app)], check=True, capture_output=True, timeout=60)
    subprocess.run(['codesign', '--verify', '--strict', '--deep', str(app)], check=True, capture_output=True, timeout=30)
    binary = app / 'Contents/MacOS' / values['CFBundleExecutable']
    record = dict(app=str(app), binary=str(binary), binarySHA256=sha(binary), infoSHA256=sha(info), build=build.name,
        sourceManifest=str(build / 'evidence/source.json'), sourceManifestSHA256=sha(build / 'evidence/source.json'),
        sourceGraph=p['sourceSHA256'], helpers=p['helpersSHA256'], originalProductUnchanged=whole_app(build) == p)
    if variant != 'positive':
        name = next(x['negativePatch'] for x in v['expectedNativeCases'].values() if x['variant'] == variant)
        record['patchSHA256'] = sha(PACKET / 'negative-controls' / name)
    d.put(code / 'evidence' / (variant + '.json'), record)
    budget(code, True); d.audit()
    print(json.dumps(dict(case=root.name, variant=variant, sealed=True, actualAcceptance=False)), flush=True)
def fixture(root, lane):
    directory = root / 'source/analysis-reuse' / lane / 'fixtures'
    directory.mkdir(mode=0o700, parents=True)
    result = {}
    for index in range(5):
        folder = directory / ('Root-' + str(index)); folder.mkdir(mode=0o700)
        for name, body in [('a.swift', b'let generated = 1\n'), ('b.json', b'{"generated":true}\n')]:
            p = folder / name
            with p.open('xb') as stream: os.fchmod(stream.fileno(), 0o600); stream.write(body)
            result[str(p.relative_to(directory))] = hashlib.sha256(body).hexdigest()
    return directory, result
def check_fixture(directory, original, replace):
    actual = {}
    expected_directories = {'Root-' + str(i) for i in range(5)}
    if replace: expected_directories.add('Replaced-Root-0')
    if {p.name for p in directory.iterdir()} != expected_directories:
        raise RuntimeError('Exact generated source root set changed')
    for parent in directory.iterdir():
        if not parent.is_dir() or parent.is_symlink(): raise RuntimeError('Generated root kind changed')
        expected = 'Root-' + parent.name.removeprefix('Replaced-Root-') if parent.name.startswith('Replaced-Root-') else parent.name
        if replace and parent.name == 'Root-0':
            if list(parent.iterdir()): raise RuntimeError('Replacement must remain exact empty root')
            continue
        for child in parent.iterdir():
            if child.is_symlink() or not child.is_file() or child.stat().st_size > 64: raise RuntimeError('Generated fixture changed')
            actual[expected + '/' + child.name] = sha(child)
    if actual != original: raise RuntimeError('Generated source bytes not preserved')
def run(root, lane, visible):
    v = admitted(root); registry = v['expectedNativeCases']
    if lane not in registry: raise RuntimeError('One finite actual case')
    item = registry[lane]
    for previous in (root / 'runs').glob('*/result.json'):
        if load(previous).get('passed') is not True: raise RuntimeError('First failed lane holds this packet')
    if visible and not item['visibleAllowed']: raise RuntimeError('Exact visible lanes')
    code = d.ROOT / v['codeCase']; binding = load(code / 'evidence' / (item['variant'] + '.json'))
    app = Path(binding['app']); command = [binding['binary'], '-ApplePersistenceIgnoreState', 'YES', '--verify-ui',
        '--check-analysis-session-reuse', '--analysis-reuse-case', lane, '--analysis-reuse-worker', v['worker']]
    command += ['--analysis-reuse-visible'] if visible else ['--offscreen']
    folder = root / 'runs' / lane
    if folder.exists(): raise RuntimeError('Lane consumed; failed evidence retained')
    before = budget(root)
    if before['bytes'] + (24 << 20) > LIMITS['bytes'] or before['entries'] + 64 > LIMITS['entries']:
        raise RuntimeError('Prospective actual-store lane headroom')
    if visible:
        console = plistlib.loads(subprocess.check_output(['/usr/sbin/ioreg', '-n', 'Root', '-d1', '-a'], timeout=5))
        users = (console if isinstance(console, dict) else console[0]).get('IOConsoleUsers', [])
        if not users or any(x.get('CGSSessionScreenIsLocked', False) for x in users): raise RuntimeError('Visible check waits for unlocked desktop')
    lock = os.open(root / 'runtime.lock', os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        folder.mkdir(mode=0o700); generated, bodies = fixture(root, lane)
        d.put(folder / 'attempt.json', dict(command=command, visible=visible, limits=LIMITS, binding=binding))
        env = common.environment(root); env['MAC_EXPLORER_TEST_ROOT'] = str(root)
        def validate():
            admitted(root)
            if sha(Path(binding['binary'])) != binding['binarySHA256'] or sha(app / 'Contents/Info.plist') != binding['infoSHA256']:
                raise RuntimeError('Sealed native profile/code changed')
            budget(root); budget(code, True)
        actual, out, err = common.process_owner(command, root, 'reuse-' + lane, 'runtime', LIMITS['rssBytes'],
            LIMITS['seconds'], env, LIMITS['processes'], LIMITS['bytes'], LIMITS['entries'], validate)
        lines = out.read_bytes().splitlines()
        reports = [json.loads(line[len(b'MAC_EXPLORER_ANALYSIS_REUSE '):]) for line in lines if line.startswith(b'MAC_EXPLORER_ANALYSIS_REUSE ')]
        if out.stat().st_size + err.stat().st_size > 65536 or len(reports) != 1: raise RuntimeError('One bounded actual native report')
        report = reports[0]
        good = actual['actualExit'] == item['expectedExit'] and actual['actualProcessAndDescendantDrain'] and actual['observer']['drained'] and not actual['contained'] and not actual['forced']
        good = good and report.get('case') == lane and report.get('variant') == item['variant'] and report.get('outcome') == item['expectedOutcome']
        good = good and report.get('ownerIdle') is True and report.get('activityCount') == 0 and report.get('scheduledDiscardJoinReturned') is True
        good = good and (report.get('positivePassed') is True if item['expectedExit'] == 0 else report.get('semanticNegativeObserved') is True and report.get('failureCode') == item['semanticFailure'])
        validate(); check_fixture(generated, bodies, lane == '04')
        d.put(folder / 'result.json', dict(passed=bool(good), process=actual, controls=report, nativeBudget=budget(root)))
        print(json.dumps(dict(case=root.name, lane=lane, passed=bool(good), outcome=report.get('outcome'), failure=report.get('failureCode'))), flush=True)
        if not good: raise SystemExit(1)
    finally:
        if folder.is_dir() and (folder / 'attempt.json').is_file() and not (folder / 'result.json').exists():
            d.put(folder / 'result.json', dict(passed=False, runnerFailure='IncompleteQualification',
                process=locals().get('actual'), controls=locals().get('report')))
        os.close(lock)
if __name__ == '__main__':
    p = argparse.ArgumentParser(); p.add_argument('stage', choices=['prepare', 'freeze', 'run']); p.add_argument('--case'); p.add_argument('--build'); p.add_argument('--variant', choices=VARIANTS); p.add_argument('--lane'); p.add_argument('--visible', action='store_true'); a = p.parse_args()
    if a.stage == 'prepare' and a.build: prepare(d.ROOT / a.build)
    elif a.stage == 'freeze' and a.case and a.build and a.variant: freeze(d.ROOT / a.case, d.ROOT / a.build, a.variant)
    elif a.stage == 'run' and a.case and a.lane: run(d.ROOT / a.case, a.lane, a.visible)
    else: p.error('Exact finite qualification stage required')
