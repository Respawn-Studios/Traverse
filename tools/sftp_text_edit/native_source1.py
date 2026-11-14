#!/usr/bin/env python3
"""Fresh, finite native Original module and offline-pipe qualification.

No old Original admission or LocalStorage object is reused. The shared process
runner supplies identity-checked observation/reap only; its source-specific
validator is replaced by the exact frozen request below before dispatch.
"""
import argparse
import importlib.util
import json
import os
import shutil
import sys
from pathlib import Path
sys.dont_write_bytecode = True
REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / 'tools'))
import development as d

MASTER = 'B9A65D62-0CFC-4400-A1DF-811F5A977962'
PACKET = d.ROOT / MASTER / 'source/SFTPOriginalNative'
PROCESS = REPO / 'tools/sftp_text_edit/original_lifecycle_candidate5/original_process.py'
ACTION = 'sftp-original-native-source-overlay-v1'
BUILD_ACTION = ACTION + '-build'
MODES = ['protocol', 'parent', 'save', 'working-copy', 'fence', 'budget']
FREEZE = '2c3e21cc6851b1440e4ce76464bd61036c9adcb8d87359c6120412388b07cc9a'
PROPOSAL = 'b11b8977cb21e0c81d1f85d6d4f0ad21528b7cf88a3e89ef7377dd69de8ceb28'

def load(p): return json.loads(p.read_bytes())
def sha(p): return d.digest(p)
def cases(action): return [p.parent for p in d.ROOT.glob('*/reservation.json') if load(p).get('action') == action]

def check_packet(source):
    if sha(source / 'freeze.json') != FREEZE or sha(source / 'compile-proposal.json') != PROPOSAL:
        raise RuntimeError('Exact final native source1 freeze required')
    frozen = load(source / 'freeze.json')
    for name, proof in frozen['files'].items():
        p = source / name
        if p.is_symlink() or p.stat().st_size != proof['bytes'] or sha(p) != proof['sha256']:
            raise RuntimeError('Native source1 frozen file changed: ' + name)
    proposal = load(source / 'compile-proposal.json')
    for name, proof in proposal['systemDependencySHA256'].items():
        p = Path(name)
        if p.stat().st_size != proof['bytes'] or sha(p) != proof['sha256']:
            raise RuntimeError('Native compiler/SDK/tool changed')
    return proposal

def materialize(value, root):
    if isinstance(value, list): return [materialize(v, root) for v in value]
    if isinstance(value, dict): return {materialize(k, root): materialize(v, root) for k, v in value.items()}
    if isinstance(value, str):
        return value.replace('@SOURCE@', str(root / 'source/SFTPOriginalNative')).replace('@BUILD@', str(root))
    return value

def tools():
    return {str(p.relative_to(REPO)): sha(p) for p in [Path(__file__), PROCESS, REPO / 'tools/development.py',
            REPO / 'tools/native_build_processes.py', REPO / 'tools/ssh_profiles/owned_observer.py']}

def prepare():
    if cases(BUILD_ACTION): raise RuntimeError('One source1 build admission; no failed-output reuse')
    proposal = check_packet(PACKET)
    root = d.reserve(BUILD_ACTION)
    shutil.copytree(PACKET, root / 'source/SFTPOriginalNative', copy_function=shutil.copy2)
    for name in ['cache/modules', 'cache/tmp', 'cache/user', 'source/modules', 'source/maps']:
        (root / name).mkdir(mode=0o700, parents=True, exist_ok=False)
    for module in proposal['modules']:
        (root / 'source/Objects' / module).mkdir(mode=0o700, parents=True, exist_ok=True)
    for path, value in materialize(proposal['outputFileMaps'], root).items(): d.put(Path(path), value)
    d.put(root / 'native-source-admission.json', dict(master=MASTER, action=BUILD_ACTION, sourceFreezeSHA256=FREEZE,
          proposalSHA256=PROPOSAL, buildEnvelope=proposal['buildEnvelope'], runtimeEnvelope=proposal['runtimeEnvelope'],
          tools=tools(), commands=materialize(proposal['commands'], root),
          compiledCurrentDependencySources={name: proof['sha256'] for name, proof in load(PACKET / 'input-inventory.json')['inputs'].items()
              if name.startswith('Packages/ExplorerKit/Sources/ExplorerCore/') or name.startswith('Packages/ExplorerKit/Sources/FileOperations/') or name.startswith('Packages/ExplorerKit/Sources/SSHConfiguration/')},
          ordinaryActivation=False, sharedLedgerComplete=False, networkRequests=0, privateCredentials=0,
          compilerLaneExclusive=True, usageBefore=d.audit()))
    print(json.dumps(dict(case=root.name, prepared=True, compilerDrivers=5, ordinaryActivation=False)), flush=True)

def checked(root):
    if root.resolve() != root or cases(BUILD_ACTION) != [root]: raise RuntimeError('Exact source1 build case required')
    v = load(root / 'native-source-admission.json')
    if v['tools'] != tools(): raise RuntimeError('Frozen source1 tooling changed')
    proposal = check_packet(root / 'source/SFTPOriginalNative')
    if v['commands'] != materialize(proposal['commands'], root): raise RuntimeError('Exact source1 compiler commands required')
    for name, digest in v['compiledCurrentDependencySources'].items():
        if sha(REPO / name) != digest: raise RuntimeError('Actual dependency changed during native qualification: ' + name)
    return v, proposal

def audit(root, maximum_bytes, maximum_entries):
    value = d.measure(root)
    if max(value['bytes'], value['allocatedBytes']) > maximum_bytes or value['entries'] > maximum_entries:
        raise RuntimeError('Native source1 exact case envelope')
    body_and_metadata = 0
    for runtime in cases(ACTION):
        for p in (runtime / 'state').rglob('*'):
            if p.is_symlink(): raise RuntimeError('Unexpected runtime symlink')
            if p.is_file(): body_and_metadata += p.stat().st_size
    # Stricter than the4MiB body-only allowance: include retained local metadata.
    if body_and_metadata > 4 << 20: raise RuntimeError('Aggregate generated runtime body/metadata allowance')
    return d.audit()

def process_owner(command, root, label, kind, limit, seconds, env, max_processes, maximum_bytes, maximum_entries, validate):
    spec = importlib.util.spec_from_file_location('source1_exact_owned_runner', PROCESS)
    owner = importlib.util.module_from_spec(spec); spec.loader.exec_module(owner)
    base = owner.Resources
    class Resources(base):
        def __init__(self, pid, cap): super().__init__(pid, cap); self.peak_processes = 0
        def observe(self, pid):
            super().observe(pid)
            with self.lock:
                self.peak_processes = max(self.peak_processes, len(self.live()))
                if self.peak_processes > max_processes:
                    self.reason = 'closed-live-process-bound'; self.signal_known(owner.signal.SIGTERM)
                    raise RuntimeError(self.reason)
        def report(self):
            value = super().report(); value['maximumSimultaneousOwnedProcesses'] = self.peak_processes
            return value
    owner.Resources = Resources
    def exact(actual, area, name, category, rss, deadline, actual_env):
        validate()
        if (actual, area, name, category, rss, deadline, actual_env) != (command, root, label, kind, limit, seconds, env):
            raise RuntimeError('Exact source1 process request required')
        return dict(maximumBytes=maximum_bytes, maximumEntries=maximum_entries)
    owner.validate = exact
    return owner.run(command, root, label, kind, limit, seconds, env, lambda: audit(root, maximum_bytes, maximum_entries))

def environment(root):
    env = {k: v for k, v in d.dev.environment(tooling=False).items() if not k.startswith('DYLD_')}
    env.update(CFFIXED_USER_HOME=str(root / 'cache/user'), TMPDIR=str(root / 'cache/tmp') + '/',
               MAC_EXPLORER_TEST_ROOT=str(root), MAC_EXPLORER_STATE_ROOT=str(root / 'state'),
               MAC_EXPLORER_CACHE_ROOT=str(root / 'cache'), PYTHONDONTWRITEBYTECODE='1')
    return env

def compile_stage(root, label):
    v, proposal = checked(root)
    labels = [c['label'] for c in v['commands']]
    if label not in labels: raise RuntimeError('Closed native compiler label')
    for prior in labels[:labels.index(label)]:
        if not load(root / 'evidence' / (prior + '.result.json'))['passed']: raise RuntimeError('Earlier module did not pass')
    if (root / 'evidence' / (label + '.request.json')).exists(): raise RuntimeError('One use per compiler stage')
    item = v['commands'][labels.index(label)]
    request = dict(action=ACTION, label=label, sourceRoot=str(root / 'source/SFTPOriginalNative'),
        sourceFreezeSHA256=FREEZE, recorderSHA256=sha(root / 'source/SFTPOriginalNative/compiler_frontend.py'),
        realFrontendSHA256=proposal['requestSchema']['realFrontendSHA256'], frontendSources=item['frontendSources'])
    path = root / 'evidence' / (label + '.request.json'); d.put(path, request)
    env = environment(root)
    env.update({k: x.replace('@REQUEST_SHA256:' + label + '@', sha(path)) for k, x in item['environment'].items()})
    # Enforce the stricter individual cap on the whole compiler group too.
    result = dict(passed=False)
    try:
        actual, out, err = process_owner(item['argv'], root, label, 'compiler', item['maximumIndividualRSSBytes'], item['maximumSeconds'], env,
            item['maximumSimultaneousOwnedProcesses'], proposal['buildEnvelope']['maximumBytes'], proposal['buildEnvelope']['maximumEntries'], lambda: checked(root))
        records = [json.loads(x) for x in (root / 'evidence' / (label + '.frontends.jsonl')).read_text().splitlines()] if (root / 'evidence' / (label + '.frontends.jsonl')).exists() else []
        all_records = sum(len(p.read_text().splitlines()) for p in (root / 'evidence').glob('*.frontends.jsonl'))
        good = actual['passed'] and actual['actualProcessAndDescendantDrain'] and actual['observer']['drained'] and not actual['contained'] and not actual['forced']
        good = good and len(records) > 0 and all_records <= proposal['buildEnvelope']['maximumFrontendInvocations']
        if label != 'controls-link':
            module = item['argv'][item['argv'].index('-module-name') + 1]
            good = good and len(records) >= proposal['modules'][module]['minimumRecordedModuleFrontends']
            output_map = materialize(proposal['outputFileMaps'], root)[str(root / 'source/maps' / (module + '.json'))]
            expected_objects = [Path(row['object']) for row in output_map.values() if 'object' in row]
            good = good and len(expected_objects) == proposal['modules'][module]['sourceCount'] and all(p.is_file() and p.stat().st_size > 0 for p in expected_objects)
        descendants = len(actual['observed']['knownOwnedIdentities'])
        for p in (root / 'evidence').glob('*.result.json'):
            descendants += len(load(p).get('process', {}).get('observed', {}).get('knownOwnedIdentities', {}))
        good = good and descendants <= proposal['buildEnvelope']['maximumDescendantProcessesTotal']
        if label == 'controls-link': good = good and (root / 'source/controls').is_file()
        result.update(passed=bool(good), process=actual, frontends=len(records), totalFrontends=all_records,
            stderrBytes=err.stat().st_size, actualDrain=actual['actualProcessAndDescendantDrain'],
            outputs={str(p.relative_to(root)): sha(p) for p in (root / 'source/Objects').rglob('*.o')},
            executableSHA256=sha(root / 'source/controls') if (root / 'source/controls').is_file() else None)
    finally:
        d.put(root / 'evidence' / (label + '.result.json'), result)
        print(json.dumps(dict(case=root.name, stage=label, passed=result['passed'], frontends=result.get('frontends'), processFailure=result.get('process', {}).get('failure'))), flush=True)
    if not result['passed']: raise SystemExit(1)

def reserve_runtime(build, mode):
    _, proposal = checked(build)
    compiled = load(build / 'evidence/controls-link.result.json')
    if not compiled['passed']: raise RuntimeError('Actual current complete native compile required')
    prior = cases(ACTION)
    if len(prior) >= 6 or mode != MODES[len(prior)]: raise RuntimeError('Exactly six ordered runtime cases')
    if prior and any(not load(p / 'evidence/result.json')['passed'] for p in prior): raise RuntimeError('First RED stops source1 runtime packet')
    root = d.reserve(ACTION)
    # The actual control exclusively creates its state directory itself.
    # Remove only this freshly reserved, empty0700 directory before admission.
    if any((root / 'state').iterdir()): raise RuntimeError('Fresh state unexpectedly nonempty')
    (root / 'state').rmdir()
    for leaf in ['cache/user', 'cache/tmp']: (root / leaf).mkdir(mode=0o700)
    d.put(root / 'original-native-admission.json', dict(format=1, action=ACTION, parentCase=MASTER, caseID=root.name, mode=mode))
    d.put(root / 'inputs.json', dict(build=build.name, executableSHA256=sha(build / 'source/controls'), mode=mode, tools=tools(),
          runtimeEnvelope=proposal['runtimeEnvelope'], sourceFreezeSHA256=FREEZE, networkRequests=0, credentials=0))
    print(json.dumps(dict(case=root.name, prepared=True, mode=mode)), flush=True)

def run_runtime(root):
    v = load(root / 'inputs.json'); build = d.ROOT / v['build']; _, proposal = checked(build)
    def validate():
        checked(build)
        if v['tools'] != tools() or sha(build / 'source/controls') != v['executableSHA256'] or root.resolve() != root or root not in cases(ACTION):
            raise RuntimeError('Exact source1 runtime/source/tool proof required')
    validate()
    mode = v['mode']; label = 'native-' + mode
    if (root / 'evidence/attempt.json').exists(): raise RuntimeError('One use only')
    command = [str(build / 'source/controls'), mode, str(root)]
    d.put(root / 'evidence/attempt.json', dict(command=command, envelope=proposal['runtimeEnvelope']))
    env = environment(root); result = dict(passed=False)
    try:
        actual, out, err = process_owner(command, root, label, 'runtime', 256 << 20, 60, env, 2, 8 << 20, 128, validate)
        control = load(out)
        good = actual['passed'] and actual['actualProcessAndDescendantDrain'] and actual['observer']['drained'] and not actual['contained'] and not actual['forced'] and control.get('passed') is True
        good = good and control.get('actualOwnersDrained') is True and control.get('ordinaryActivation') is False and control.get('serverAcceptance') is False and control.get('sharedBudgetQualified') is False
        result.update(passed=bool(good), process=actual, controls=control, actualDrain=actual['actualProcessAndDescendantDrain'], predictedBudgetRed=mode == 'budget')
    finally:
        d.put(root / 'evidence/result.json', result)
        print(json.dumps(dict(case=root.name, mode=mode, passed=result['passed'], stage=(result.get('controls') or {}).get('stage'), error=(result.get('controls') or {}).get('error'))), flush=True)
    if not result['passed']: raise SystemExit(1)

if __name__ == '__main__':
    p = argparse.ArgumentParser(); p.add_argument('stage', choices=['prepare', 'compile', 'reserve-runtime', 'runtime']); p.add_argument('--case'); p.add_argument('--label'); p.add_argument('--build'); p.add_argument('--mode', choices=MODES); a = p.parse_args()
    if a.stage == 'prepare' and not any([a.case, a.label, a.build, a.mode]): prepare()
    elif a.stage == 'compile' and a.case and a.label: compile_stage(d.ROOT / a.case, a.label)
    elif a.stage == 'reserve-runtime' and a.build and a.mode: reserve_runtime(d.ROOT / a.build, a.mode)
    elif a.stage == 'runtime' and a.case: run_runtime(d.ROOT / a.case)
    else: p.error('One exact native source1 stage required')
