"""Separate first-release accounting; existing qualification packets stay intact."""
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import uuid

REPO = Path(__file__).resolve().parents[2]
ROOT = REPO / '.build/traverse-release'
TOOLING = ROOT / 'tooling'
CLANG_CACHE = REPO / '.build/compiler-cache/xcode'
SWIFT_CACHE = REPO / '.build/compiler-cache/xcode-swift'
CRASH_TOOLING = REPO / '.build/crash-reporter-tooling'
COMPILER_ROOTS = frozenset({TOOLING, CLANG_CACHE, SWIFT_CACHE, CRASH_TOOLING})
MIB = 1 << 20
# Owner-approved 23 October complete tester-review build: one additional GiB
# for archive/installer/rollback and visual evidence. Preserve prior failures.
# Entry/tooling/scan/network limits stay unchanged.
ARTIFACT_BYTE_LIMIT = 7 << 30

def directory(path):
    if not path.is_absolute() or not path.is_relative_to(REPO / '.build'):
        raise RuntimeError('Release output must stay in the repository build root')
    current = REPO
    for part in path.relative_to(REPO).parts:
        current /= part
        if current.is_symlink(): raise RuntimeError('Redirected release directory')
        current.mkdir(mode=0o700, exist_ok=True)
        facts = current.lstat()
        if not stat.S_ISDIR(facts.st_mode) or facts.st_uid != os.getuid():
            raise RuntimeError('Unowned release directory')
    return path

def put(path, value):
    data = (json.dumps(value, indent=2, sort_keys=True) + '\n').encode()
    if len(data) > MIB: raise RuntimeError('Release receipt bound')
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
    with os.fdopen(fd, 'wb') as output:
        output.write(data); output.flush(); os.fsync(output.fileno())

def measure(path):
    value = dict(bytes=0, allocatedBytes=0, entries=0)
    if not path.exists(): return value
    def enumeration_failed(error):
        # A partial tree cannot establish a storage ceiling. The shared Xcode
        # cache alone may lose a compiler temporary during its live sweep.
        if path in COMPILER_ROOTS and isinstance(error, FileNotFoundError): return
        raise error
    for parent, dirs, files in os.walk(path, followlinks=False, onerror=enumeration_failed):
        for name in dirs + files:
            try:
                facts = (Path(parent) / name).lstat()
            except FileNotFoundError:
                # Xcode atomically renames/deletes private compiler temporaries
                # during this live sweep. They occupy no space after removal;
                # missing retained artifacts must still be a hard failure.
                if path in COMPILER_ROOTS:
                    continue
                raise
            value['entries'] += 1
            value['allocatedBytes'] += facts.st_blocks * 512
            if not stat.S_ISDIR(facts.st_mode): value['bytes'] += facts.st_size
    return value

def charged_tooling():
    """Count release/dependency tooling and shared Xcode compiler caches."""
    for path in COMPILER_ROOTS:
        current = REPO
        for part in path.relative_to(REPO).parts:
            current /= part
            if current.is_symlink():
                raise RuntimeError('Redirected compiler or tooling directory')
            if current.exists():
                facts = current.lstat()
                if not stat.S_ISDIR(facts.st_mode) or facts.st_uid != os.getuid():
                    raise RuntimeError('Unowned compiler or tooling directory')
    tooling = measure(TOOLING)
    crash = measure(CRASH_TOOLING)
    shared = dict(clang=measure(CLANG_CACHE), swift=measure(SWIFT_CACHE))
    charged = tooling['allocatedBytes'] + crash['allocatedBytes'] + sum(value['allocatedBytes'] for value in shared.values())
    return dict(tooling=tooling, crashReporterTooling=crash, sharedCompilerCaches=shared,
        chargedToolingAllocatedBytes=charged)

def audit():
    directory(ROOT); artifacts = dict(bytes=0, allocatedBytes=0, entries=0)
    for child in ROOT.iterdir():
        if child == TOOLING: continue
        if child.is_dir() and not child.is_symlink():
            part = measure(child)
            for key in artifacts: artifacts[key] += part[key]
    charged = charged_tooling()
    if artifacts['bytes'] > ARTIFACT_BYTE_LIMIT or artifacts['entries'] > 32768:
        raise RuntimeError('Retained release artifact budget reached')
    if charged['chargedToolingAllocatedBytes'] > 4 << 30:
        raise RuntimeError('Release tooling allocation budget reached')
    return dict(artifacts=artifacts, **charged)

def reserve(action):
    directory(ROOT)
    fd = os.open(ROOT / 'budget.lock', os.O_RDWR | os.O_CREAT | os.O_CLOEXEC | os.O_NOFOLLOW, 0o600)
    try:
        facts = os.fstat(fd)
        if not stat.S_ISREG(facts.st_mode) or facts.st_nlink != 1 or facts.st_uid != os.getuid() or facts.st_mode & 0o077:
            raise RuntimeError('Unsafe release budget lock')
        fcntl.flock(fd, fcntl.LOCK_EX); audit()
        case = directory(ROOT / str(uuid.uuid4()).upper())
        put(case / 'reservation.json', dict(packet='traverse-release-v1', action=action))
        directory(case / 'evidence'); directory(case / 'source')
        return case
    finally: os.close(fd)

def require_case(token):
    if str(uuid.UUID(token)).upper() != token: raise RuntimeError('Canonical release case required')
    case = ROOT / token
    if case.resolve() != case or case.is_symlink(): raise RuntimeError('Redirected release case')
    marker = case / 'reservation.json'
    facts = marker.lstat()
    if not stat.S_ISREG(facts.st_mode) or facts.st_nlink != 1 or facts.st_uid != os.getuid() or facts.st_size > 4096:
        raise RuntimeError('Unsafe release reservation')
    if json.loads(marker.read_bytes()).get('packet') != 'traverse-release-v1': raise RuntimeError('Unknown release authority')
    return case

def admit_network(case, action, count=1):
    require_case(case.name)
    fd=os.open(ROOT/'budget.lock',os.O_RDWR|os.O_CLOEXEC|os.O_NOFOLLOW)
    try:
        fcntl.flock(fd,fcntl.LOCK_EX)
        used=sum(1 for p in ROOT.glob('*/evidence/network-admission-*.json'))
        if not 1<=count<=4 or used+count>28: raise RuntimeError('Traverse generated network allowance exhausted')
        for _ in range(count):
            put(case/'evidence'/('network-admission-'+str(uuid.uuid4()).upper()+'.json'),dict(action=action,kind='generated-only',ordinal=used+1));used+=1
    finally:os.close(fd)

# The first 28 release admissions are spent. This is their sorted, relative
# path + SHA-256 inventory, joined with newlines and no final newline.
PREVIEW_METADATA_PRIOR_NETWORK_SHA256='e9bdf6ce808f104c2a626b4b8da7ad2053d6aa0e608aea24f76a1b7328eed2c1'

def _preview_prior_network(paths):
    entries=[];ordinals=[]
    for path in sorted(paths,key=lambda item:item.relative_to(ROOT).as_posix()):
        facts=path.lstat()
        if not stat.S_ISREG(facts.st_mode) or facts.st_uid!=os.getuid() or facts.st_nlink!=1 or facts.st_size>4096:
            raise RuntimeError('Prior network receipt identity changed')
        body=path.read_bytes();value=json.loads(body)
        if value.get('kind')!='generated-only' or type(value.get('ordinal')) is not int:
            raise RuntimeError('Prior network receipt format changed')
        ordinals.append(value['ordinal'])
        entries.append(path.relative_to(ROOT).as_posix()+' '+hashlib.sha256(body).hexdigest())
    if len(entries)!=28 or sorted(ordinals)!=list(range(1,29)) \
        or hashlib.sha256('\n'.join(entries).encode()).hexdigest()!=PREVIEW_METADATA_PRIOR_NETWORK_SHA256:
        raise RuntimeError('Prior 28 network receipts changed')

def admit_preview_metadata_network(case, artifact_receipt_sha256, install_receipt_sha256, owner_scope_sha256):
    """Reserve one exact Preview metadata case and two prospective UI sign-ins.

    The caller must separately verify the installed artifact and owner scope
    before supplying these bindings. This admission does not observe protocol
    authentication counts.
    """
    if case != require_case(case.name):raise RuntimeError('Preview metadata case changed')
    marker=json.loads((case/'reservation.json').read_bytes())
    if marker.get('action')!='preview73-metadata-ui':raise RuntimeError('Preview metadata action required')
    if any(not isinstance(value,str) or not re.fullmatch('[a-f0-9]{64}',value) for value in
        [artifact_receipt_sha256,install_receipt_sha256,owner_scope_sha256]):
        raise RuntimeError('Exact installed Preview binding required')
    fd=os.open(ROOT/'budget.lock',os.O_RDWR|os.O_CLOEXEC|os.O_NOFOLLOW)
    try:
        fcntl.flock(fd,fcntl.LOCK_EX)
        audit()
        prior=sorted(ROOT.glob('*/evidence/network-admission-*.json'),key=lambda path:path.relative_to(ROOT).as_posix())
        if len(prior)!=28 or list(ROOT.glob('*/evidence/preview73-metadata-admission.json')):
            raise RuntimeError('Preview metadata network allowance spent or changed')
        _preview_prior_network(prior)
        binding=dict(action='preview73-metadata-ui',kind='generated-only',case=case.name,
            artifactReceiptSHA256=artifact_receipt_sha256,installReceiptSHA256=install_receipt_sha256,
            ownerScopeSHA256=owner_scope_sha256,
            priorNetworkSHA256=PREVIEW_METADATA_PRIOR_NETWORK_SHA256,maximumUISignIns=2,protocolAuthCountVerified=False)
        put(case/'evidence/preview73-metadata-admission.json',dict(**binding,maximumSMBRuntimes=1))
        for ordinal in [29,30]:
            put(case/'evidence'/('network-admission-'+str(uuid.uuid4()).upper()+'.json'),dict(**binding,ordinal=ordinal))
        evidence_fd=os.open(case/'evidence',os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
        try:os.fsync(evidence_fd)
        finally:os.close(evidence_fd)
        _preview_prior_network(prior)
    finally:os.close(fd)

def require_preview_metadata_network(case):
    """Check the exact spent admission before starting its single SMB runtime."""
    if case!=require_case(case.name):raise RuntimeError('Preview metadata case changed')
    if json.loads((case/'reservation.json').read_bytes()).get('action')!='preview73-metadata-ui':
        raise RuntimeError('Preview metadata action required')
    marker=case/'evidence/preview73-metadata-admission.json';facts=marker.lstat()
    if not stat.S_ISREG(facts.st_mode) or facts.st_uid!=os.getuid() or facts.st_nlink!=1 or facts.st_size>4096:
        raise RuntimeError('Preview metadata admission identity changed')
    value=json.loads(marker.read_bytes())
    if value.get('case')!=case.name or value.get('action')!='preview73-metadata-ui' or value.get('kind')!='generated-only' \
        or value.get('priorNetworkSHA256')!=PREVIEW_METADATA_PRIOR_NETWORK_SHA256 \
        or value.get('maximumSMBRuntimes')!=1 or value.get('maximumUISignIns')!=2 or value.get('protocolAuthCountVerified') is not False:
        raise RuntimeError('Preview metadata admission changed')
    if any(not isinstance(value.get(key),str) or not re.fullmatch('[a-f0-9]{64}',value[key]) for key in
        ['artifactReceiptSHA256','installReceiptSHA256','ownerScopeSHA256']):
        raise RuntimeError('Preview metadata artifact binding changed')
    receipts=list(case.glob('evidence/network-admission-*.json'))
    if len(receipts)!=2 or len(list(ROOT.glob('*/evidence/network-admission-*.json')))!=30:
        raise RuntimeError('Preview metadata network count changed')
    for path,ordinal in zip(sorted(receipts,key=lambda item:json.loads(item.read_bytes()).get('ordinal',0)),[29,30]):
        facts=path.lstat()
        if not stat.S_ISREG(facts.st_mode) or facts.st_uid!=os.getuid() or facts.st_nlink!=1 or facts.st_size>4096:
            raise RuntimeError('Preview metadata network receipt identity changed')
        receipt=json.loads(path.read_bytes())
        if receipt!={**{key:part for key,part in value.items() if key!='maximumSMBRuntimes'},'ordinal':ordinal}:
            raise RuntimeError('Preview metadata network binding changed')
    _preview_prior_network([path for path in ROOT.glob('*/evidence/network-admission-*.json') if path not in receipts])
    return value

# One separately decided repair after Preview73's failed UI size check. The
# first 30 admissions and both halves of that failed case remain immutable.
PREVIEW74_REPAIR_CASE='05512775-1A69-4C9E-9DA9-4AE7BADDAFA2'
PREVIEW74_REPAIR_SCOPE_SHA256='8a4692a597c665c0c936fbd4756169b2c8dca82799fc16e589f38204e4d532e6'
PREVIEW74_REPAIR_ARTIFACT_SHA256='307d136f00f282a7580055b107d69b541c2d30b3f0d6029b7c9068f19d2d2bf8'
PREVIEW74_REPAIR_INSTALL_SHA256='ad28594798e0a593c8d5ce3b7137f2124183c8f35475fc334ae4a882bce7d4e1'
PREVIEW74_REPAIR_CAPSULE_SHA256='be591f014a015337738995b4048e2be7eab1a5f7341ea8deecb32bda98b86480'
PREVIEW74_REPAIR_SOURCE_REVIEW_SHA256='adfefeb8407f1f6ec9d45e49bcac71351574ed4f16693ee480b72d635da1be95'
PREVIEW74_PRIOR_CASE='C6397A5C-9711-408E-A21A-E81781DAC292'
PREVIEW74_PRIOR_FILES={
    'evidence/preview73-metadata-admission.json':'70c500be4b3d7c89e23df696bd7f15313fab4a02763dce15aa4297949acccf6b',
    'evidence/network-admission-2AB4E936-0B67-4A60-81B0-BD7791173158.json':'dfd5e970adf454c74324fffcdd55f291cc087892ce62feea5bce7a3b34186dfe',
    'evidence/network-admission-859C7D43-17D3-4240-9951-FE5CE2357ECA.json':'9f80264624022a144d69b70696a9f0a966fa92d486173206d7c57e2e0efbf15d',
    'evidence/ui-result.json':'c57985b8a769a8a63b9d7d97699fcc68d25a59c32b278a9d12eab7a088898c9c',
    'result.json':'74ba5577f8477752b8b64f1b7ddb31c20c9d7eeec0da238998ff3171278f0a03',
    'metadata-acceptance-result.json':'8b5418340a70f2859f8eda055138ccf50e593494d14395748f3049a9403b8bf8',
}

def _preview74_owned_sha(path, expected):
    if path.resolve()!=path or path.parent.resolve()!=path.parent:
        raise RuntimeError('Redirected Preview repair evidence')
    facts=path.lstat()
    if not stat.S_ISREG(facts.st_mode) or facts.st_uid!=os.getuid() or facts.st_nlink!=1 or facts.st_size>65536 \
            or hashlib.sha256(path.read_bytes()).hexdigest()!=expected:
        raise RuntimeError('Preview repair binding changed')

def _preview74_prior_network(new_receipts=()):
    prior_case=require_case(PREVIEW74_PRIOR_CASE)
    if json.loads((prior_case/'reservation.json').read_bytes()).get('action')!='preview73-metadata-ui':
        raise RuntimeError('Prior Preview case changed')
    for name,expected in PREVIEW74_PRIOR_FILES.items():
        _preview74_owned_sha(prior_case/name,expected)
    ui=json.loads((prior_case/'evidence/ui-result.json').read_bytes())
    lifecycle=json.loads((prior_case/'result.json').read_bytes())
    aggregate=json.loads((prior_case/'metadata-acceptance-result.json').read_bytes())
    if ui.get('passed') is not False or ui.get('checks',{}).get('calculateSubmissions')!=1 \
            or ui.get('failure',{}).get('networkCode')!=1707 \
            or lifecycle.get('passed') is not True or lifecycle.get('cleanup',{}).get('serverStopped') is not True \
            or aggregate.get('passed') is not False or aggregate.get('lifecyclePassed') is not True \
            or aggregate.get('uiPassed') is not False or aggregate.get('repaired') is not False:
        raise RuntimeError('Prior SMB failure or cleanup verdict changed')
    old_receipts={prior_case/name for name in PREVIEW74_PRIOR_FILES if name.startswith('evidence/network-admission-')}
    all_receipts=set(ROOT.glob('*/evidence/network-admission-*.json'))
    if len(old_receipts)!=2 or not old_receipts.issubset(all_receipts) or not set(new_receipts).issubset(all_receipts) \
            or len(all_receipts)!=30+len(new_receipts):
        raise RuntimeError('Prior SMB admission count changed')
    _preview_prior_network(all_receipts-old_receipts-set(new_receipts))

def _preview74_repair_binding(case):
    if case!=require_case(PREVIEW74_REPAIR_CASE) or case!=ROOT/PREVIEW74_REPAIR_CASE \
            or json.loads((case/'reservation.json').read_bytes())!={'packet':'traverse-release-v1','action':'preview74-metadata-repair'}:
        raise RuntimeError('Exact Preview74 repair case required')
    _preview74_owned_sha(REPO/'.build/maintenance/2026-11-09/preview74-metadata-repair/delegated-run-scope.md',PREVIEW74_REPAIR_SCOPE_SHA256)
    artifact=REPO/'.build/previews/0.1.5-74'
    _preview74_owned_sha(artifact/'result.json',PREVIEW74_REPAIR_ARTIFACT_SHA256)
    _preview74_owned_sha(artifact/'install.json',PREVIEW74_REPAIR_INSTALL_SHA256)
    _preview74_owned_sha(artifact/'immutable-source-review.json',PREVIEW74_REPAIR_SOURCE_REVIEW_SHA256)
    review=json.loads((artifact/'immutable-source-review.json').read_bytes())
    if review.get('capsuleSHA256')!=PREVIEW74_REPAIR_CAPSULE_SHA256 or review.get('sourceCount')!=1188 \
            or review.get('artifactResultSHA256')!=PREVIEW74_REPAIR_ARTIFACT_SHA256 \
            or review.get('installSHA256')!=PREVIEW74_REPAIR_INSTALL_SHA256 \
            or review.get('immutableArtifactBoundary') is not True or review.get('public69Unchanged') is not True:
        raise RuntimeError('Preview74 source review boundary changed')
    return dict(action='preview74-metadata-repair',kind='generated-only',case=case.name,
        artifactReceiptSHA256=PREVIEW74_REPAIR_ARTIFACT_SHA256,installReceiptSHA256=PREVIEW74_REPAIR_INSTALL_SHA256,
        capsuleSHA256=PREVIEW74_REPAIR_CAPSULE_SHA256,ownerScopeSHA256=PREVIEW74_REPAIR_SCOPE_SHA256,
        priorUIFailureSHA256=PREVIEW74_PRIOR_FILES['evidence/ui-result.json'],
        priorLifecycleSHA256=PREVIEW74_PRIOR_FILES['result.json'],maximumSMBRuntimes=1,
        maximumUISignIns=1,protocolAuthCountVerified=False,encryptedZeroReadVerified=False)

def admit_preview74_metadata_repair_network(case):
    binding=_preview74_repair_binding(case)
    fd=os.open(ROOT/'budget.lock',os.O_RDWR|os.O_CLOEXEC|os.O_NOFOLLOW)
    try:
        fcntl.flock(fd,fcntl.LOCK_EX);audit();_preview74_prior_network()
        if list(ROOT.glob('*/evidence/preview74-metadata-repair-admission.json')) \
                or list(case.glob('evidence/network-admission-*.json')):
            raise RuntimeError('Preview74 repair allowance already spent')
        put(case/'evidence/preview74-metadata-repair-admission.json',binding)
        put(case/'evidence/network-admission-031.json',dict(**binding,ordinal=31))
        evidence_fd=os.open(case/'evidence',os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
        try:os.fsync(evidence_fd)
        finally:os.close(evidence_fd)
        _preview74_prior_network((case/'evidence/network-admission-031.json',))
    finally:os.close(fd)

def require_preview74_metadata_repair_network(case):
    binding=_preview74_repair_binding(case)
    marker=case/'evidence/preview74-metadata-repair-admission.json'
    _preview74_owned_sha(marker,hashlib.sha256((json.dumps(binding,indent=2,sort_keys=True)+'\n').encode()).hexdigest())
    receipt=case/'evidence/network-admission-031.json'
    expected=dict(**binding,ordinal=31)
    _preview74_owned_sha(receipt,hashlib.sha256((json.dumps(expected,indent=2,sort_keys=True)+'\n').encode()).hexdigest())
    if list(case.glob('evidence/network-admission-*.json'))!=[receipt]:
        raise RuntimeError('Preview74 repair receipt count changed')
    _preview74_prior_network((receipt,))
    return binding

# One prospective generated SMB folder-size envelope. The first 31 charged
# network receipts remain byte-exact; this case adds only ordinal 32.
PREVIEW76_ENVELOPE_CASE='D272A410-9F46-4F3A-A5A2-94D94C23F1F7'
PREVIEW76_ENVELOPE_ACTION='preview76-folder-envelope'
PREVIEW76_ENVELOPE_MODE='folder-envelope-v1'
PREVIEW76_PRIOR_NETWORK_SHA256='d65886066d3fd773007ad724aff1eb3736a972a0bedb54b768df18a7c7b28583'
PREVIEW76_ENVELOPE_ARTIFACT=REPO/'.build/previews/0.1.5-76'
PREVIEW76_ENVELOPE_SCOPE=REPO/'.build/maintenance/2026-11-09/preview76-folder-envelope/delegated-run-scope.md'
PREVIEW76_ENVELOPE_ARTIFACT_SHA256='6fa0ac5c62f5e592bfb9803935db1d45376e903a341b944949280fdc4564ff7e'
PREVIEW76_ENVELOPE_INSTALL_SHA256='cfcca80d6249d9cde12eed02243fdfd839a063af6983b646366d4f5e92880ddd'
PREVIEW76_ENVELOPE_CAPSULE_SHA256='ba5c547485383dbf61f6caf3489b4d7994e0fb28955830e07a2edcd82714f121'
PREVIEW76_ENVELOPE_REVIEW_SHA256='bf11a099ee9f0a387f5ce082a546375b2163266093588701c05d764034d76af6'
PREVIEW76_ENVELOPE_SCOPE_SHA256='2829d10a0899633bce0acaae10ae9dedfcd45c7fbc94f2e1e0a5b56d1696d634'

def _preview76_envelope_case(case):
    if case!=require_case(PREVIEW76_ENVELOPE_CASE) or case!=ROOT/PREVIEW76_ENVELOPE_CASE \
            or json.loads((case/'reservation.json').read_bytes())!={'packet':'traverse-release-v1','action':PREVIEW76_ENVELOPE_ACTION}:
        raise RuntimeError('Exact Preview76 envelope reservation required')

def _preview76_prior_network(extra=()):
    all_receipts=set(ROOT.glob('*/evidence/network-admission-*.json'))
    extra=set(extra)
    if len(all_receipts)!=31+len(extra) or not extra.issubset(all_receipts):
        raise RuntimeError('Earlier 31 generated network admissions changed')
    entries=[];ordinals=[]
    for path in sorted(all_receipts-extra,key=lambda item:item.relative_to(ROOT).as_posix()):
        facts=path.lstat()
        if path.resolve()!=path or not stat.S_ISREG(facts.st_mode) or facts.st_uid!=os.getuid() \
                or facts.st_nlink!=1 or facts.st_size>4096:
            raise RuntimeError('Earlier network receipt identity changed')
        body=path.read_bytes();value=json.loads(body)
        if value.get('kind')!='generated-only' or type(value.get('ordinal')) is not int:
            raise RuntimeError('Earlier network receipt format changed')
        ordinals.append(value['ordinal'])
        entries.append(path.relative_to(ROOT).as_posix()+' '+hashlib.sha256(body).hexdigest())
    if sorted(ordinals)!=list(range(1,32)) or hashlib.sha256('\n'.join(entries).encode()).hexdigest()!=PREVIEW76_PRIOR_NETWORK_SHA256:
        raise RuntimeError('Earlier 31 generated network admissions changed')

def _preview76_envelope_binding(case):
    _preview76_envelope_case(case)
    _preview74_owned_sha(PREVIEW76_ENVELOPE_SCOPE,PREVIEW76_ENVELOPE_SCOPE_SHA256)
    artifact=PREVIEW76_ENVELOPE_ARTIFACT
    _preview74_owned_sha(artifact/'result.json',PREVIEW76_ENVELOPE_ARTIFACT_SHA256)
    _preview74_owned_sha(artifact/'install.json',PREVIEW76_ENVELOPE_INSTALL_SHA256)
    review_path=artifact/'immutable-source-review.json'
    _preview74_owned_sha(review_path,PREVIEW76_ENVELOPE_REVIEW_SHA256)
    result=json.loads((artifact/'result.json').read_bytes())
    install=json.loads((artifact/'install.json').read_bytes())
    review=json.loads(review_path.read_bytes());verified=review.get('verified')
    if result.get('passed') is not True or result.get('build')!='76' \
            or install.get('passed') is not True or install.get('newBuild')!='76' \
            or review.get('capsuleSHA256')!=PREVIEW76_ENVELOPE_CAPSULE_SHA256 \
            or review.get('artifactResultSHA256')!=PREVIEW76_ENVELOPE_ARTIFACT_SHA256 \
            or review.get('installSHA256')!=PREVIEW76_ENVELOPE_INSTALL_SHA256 or review.get('immutableArtifactBoundary') is not True \
            or review.get('public69Unchanged') is not True or not isinstance(verified,dict) \
            or verified.get('passed') is not True or verified.get('sha256')!=PREVIEW76_ENVELOPE_CAPSULE_SHA256 \
            or verified.get('files')!=1188 or review.get('sourceCount')!=1188:
        raise RuntimeError('Preview76 artifact/source capsule boundary changed')
    return dict(action=PREVIEW76_ENVELOPE_ACTION,kind='generated-only',case=case.name,
        fixtureMode=PREVIEW76_ENVELOPE_MODE,artifactReceiptSHA256=PREVIEW76_ENVELOPE_ARTIFACT_SHA256,
        installReceiptSHA256=PREVIEW76_ENVELOPE_INSTALL_SHA256,capsuleSHA256=PREVIEW76_ENVELOPE_CAPSULE_SHA256,
        sourceReviewSHA256=PREVIEW76_ENVELOPE_REVIEW_SHA256,ownerScopeSHA256=PREVIEW76_ENVELOPE_SCOPE_SHA256,
        priorNetworkSHA256=PREVIEW76_PRIOR_NETWORK_SHA256,maximumSMBRuntimes=1,maximumUISignIns=1,
        protocolAuthCountVerified=False,encryptedZeroReadVerified=False)

def admit_preview76_smb_envelope_network(case):
    fd=os.open(ROOT/'budget.lock',os.O_RDWR|os.O_CLOEXEC|os.O_NOFOLLOW)
    try:
        fcntl.flock(fd,fcntl.LOCK_EX);audit()
        require_preview74_metadata_repair_network(require_case(PREVIEW74_REPAIR_CASE))
        _preview76_prior_network()
        binding=_preview76_envelope_binding(case)
        receipt=case/'evidence/network-admission-032.json'
        if list(ROOT.glob('*/evidence/network-admission-032.json')) or receipt.exists() or receipt.is_symlink():
            raise RuntimeError('Preview76 envelope network allowance already spent')
        put(receipt,dict(**binding,ordinal=32))
        evidence_fd=os.open(case/'evidence',os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
        try:os.fsync(evidence_fd)
        finally:os.close(evidence_fd)
        _preview76_prior_network((receipt,))
    finally:os.close(fd)

def require_preview76_smb_envelope_network(case):
    _preview76_envelope_case(case)
    receipt=case/'evidence/network-admission-032.json'
    facts=receipt.lstat()
    if receipt.resolve()!=receipt or not stat.S_ISREG(facts.st_mode) or facts.st_uid!=os.getuid() \
            or facts.st_nlink!=1 or facts.st_size>4096:
        raise RuntimeError('Preview76 envelope receipt identity changed')
    value=json.loads(receipt.read_bytes())
    keys={'action','kind','case','fixtureMode','artifactReceiptSHA256','installReceiptSHA256','capsuleSHA256',
        'sourceReviewSHA256','ownerScopeSHA256','priorNetworkSHA256','maximumSMBRuntimes','maximumUISignIns',
        'protocolAuthCountVerified','encryptedZeroReadVerified','ordinal'}
    if set(value)!=keys or type(value.get('ordinal')) is not int or value['ordinal']!=32 \
            or type(value.get('maximumSMBRuntimes')) is not int or type(value.get('maximumUISignIns')) is not int \
            or value.get('protocolAuthCountVerified') is not False or value.get('encryptedZeroReadVerified') is not False:
        raise RuntimeError('Preview76 envelope receipt changed')
    binding=_preview76_envelope_binding(case)
    if value!=dict(**binding,ordinal=32):raise RuntimeError('Preview76 envelope binding changed')
    _preview76_prior_network((receipt,))
    return binding
