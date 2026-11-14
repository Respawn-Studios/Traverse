#!/usr/bin/env python3
"""Build/embed the canonical one-shot SMART helper; never launch or sample it."""
from __future__ import annotations

import fcntl
from contextlib import contextmanager
import hashlib
import json
import os
from pathlib import Path
import platform
import plistlib
import re
import shutil
import stat
import subprocess
from tempfile import TemporaryDirectory
import uuid
from bundle_helper import directory, publish, regular
from distribution import helper_symbols, remote_editor_qa, store_helpers

ROOT = Path(__file__).resolve().parents[1]
NATIVE = ROOT / 'Packages/ExplorerKit/Sources/DriveHealthNative'
WORKER = ROOT / 'Packages/ExplorerKit/Sources/DriveHealthWorker/main.c'
SERVICE = ROOT / 'Packages/ExplorerKit/Sources/DriveHealthXPCService/main.c'
OUTPUT = ROOT / '.build/drive-health'
C_SOURCES = [NATIVE / name for name in ('THSMART.c', 'THAssociation.c', 'THAcquisition.c', 'THWire.c')]
SOURCES = C_SOURCES + sorted((NATIVE / 'include').glob('*.h')) + [WORKER]
SERVICE_SOURCES = C_SOURCES + sorted((NATIVE / 'include').glob('*.h')) + [SERVICE]
SERVICE_COMPOSITION_KEY = 'MAC_EXPLORER_DRIVE_HEALTH_XPC_COMPOSITION'
SERVICE_COMPOSITION = 'held-qa-v1'
SERVICE_VERSION_KEY = 'TraverseDriveHealthServiceVersion'
SERVICE_LEAF = 'drive-health-service.xpc'
SERVICE_EXECUTABLE = 'drive-health-service'
SERVICE_MANIFEST = 'DriveHealthServiceManifest.plist'


def service_identifier(parent: str) -> str:
    return parent + '.drive.health.xpc'


def service_info(service_id: str) -> dict:
    return dict(CFBundleIdentifier=service_id, CFBundleExecutable=SERVICE_EXECUTABLE,
        CFBundlePackageType='XPC!', CFBundleShortVersionString='1.0', CFBundleVersion='1',
        LSMinimumSystemVersion='15.0', XPCService=dict(ServiceType='Application', RunLoopType='dispatch_main'))


def role_requirement(identifier: str) -> str:
    if not re.fullmatch(r'[A-Za-z0-9.-]+', identifier):
        raise ValueError('Unsafe drive-health signing identifier')
    return ('anchor apple generic and identifier "' + identifier + '"'
        + ' and certificate 1[field.1.2.840.113635.100.6.2.6] exists'
        + ' and certificate leaf[field.1.2.840.113635.100.6.1.13] exists'
        + ' and certificate leaf[subject.OU] = "' + store_helpers.TEAM + '"')


def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


@contextmanager
def build_lock(*, symbols=False):
    output = OUTPUT / 'release' if symbols else OUTPUT
    helper_symbols.build_path(output)
    for folder in (OUTPUT, output):
        folder.mkdir(mode=0o700, parents=True, exist_ok=True)
        facts = folder.lstat()
        if not stat.S_ISDIR(facts.st_mode) or facts.st_uid != os.getuid() or facts.st_mode & 0o077:
            raise RuntimeError('Unsafe drive-health build root')
    lock = output / 'build.lock'
    fd = os.open(lock, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
    try:
        facts = os.fstat(fd)
        if not stat.S_ISREG(facts.st_mode) or facts.st_uid != os.getuid() or facts.st_nlink != 1 or facts.st_mode & 0o077:
            raise RuntimeError('Unsafe drive-health build lock')
        fcntl.flock(fd, fcntl.LOCK_EX)
        current = lock.lstat()
        if (facts.st_dev, facts.st_ino) != (current.st_dev, current.st_ino):
            raise RuntimeError('Drive-health build lock changed')
        yield output
    finally:
        os.close(fd)


def build(*, symbols=False) -> Path:
    with build_lock(symbols=symbols) as output:
        return _locked_build(output, symbols=symbols)


def _locked_build(output: Path, *, symbols=False) -> Path:
    sdk = subprocess.check_output(['/usr/bin/xcrun', '--show-sdk-path'], text=True, timeout=15).strip()
    arch = platform.machine()
    if arch not in ('arm64', 'x86_64'):
        raise RuntimeError('Unsupported local Preview architecture')
    fingerprint = dict(format='drive-health-preview-build-v1', sdk=sdk, architecture=arch,
                       builderSHA256=sha(Path(__file__).resolve()),
                       sourceSHA256={str(path.relative_to(ROOT)): sha(path) for path in SOURCES})
    if symbols:
        fingerprint.update(format='drive-health-inherited-build-v2', symbols=helper_symbols.POLICY)
    binary = output / 'drive-health-worker'
    receipt = output / 'build.json'
    for path in (binary, receipt):
        if path.is_symlink() or path.exists() and (not path.is_file() or path.stat().st_nlink != 1):
            raise RuntimeError('Redirected drive-health build output')
    if receipt.is_file() and receipt.stat().st_size < 65536 and binary.is_file():
        cached = json.loads(receipt.read_bytes())
        if cached.get('input') == fingerprint and cached.get('binarySHA256') == sha(binary):
            if symbols:
                helper_symbols.validate(binary, binary.with_name(binary.name + '.dSYM'))
            return binary
    if len(list(output.iterdir())) >= 128:
        raise ValueError('Retained drive-health build-stage limit reached')
    staged = output / ('drive-health-worker-' + str(uuid.uuid4()).upper())
    command = ['/usr/bin/clang', '-std=c17', '-Wall', '-Wextra', '-Werror', '-O2',
               '-target', arch + '-apple-macos15.0', '-isysroot', sdk,
               '-I', str(NATIVE / 'include'), *map(str, C_SOURCES), str(WORKER),
               '-framework', 'CoreFoundation', '-framework', 'IOKit', '-o', str(staged)]
    try:
        if symbols:
            # Keep the canonical objects for dsymutil; clang's temporary link
            # objects would disappear before their line tables were packed.
            objects = []
            for source in [*C_SOURCES, WORKER]:
                obj = output / (source.stem + '.o')
                if obj.exists() or obj.is_symlink(): regular(obj)
                subprocess.run(command[:command.index('-I')] + ['-gline-tables-only', '-I',
                    str(NATIVE / 'include'), '-c', str(source), '-o', str(obj)],
                    check=True, timeout=120, stdin=subprocess.DEVNULL)
                objects.append(str(obj))
            command = command[:command.index('-I')] + objects + [
                '-framework', 'CoreFoundation', '-framework', 'IOKit', '-o', str(staged)]
        subprocess.run(command, check=True, timeout=120, stdin=subprocess.DEVNULL)
        if fingerprint['sourceSHA256'] != {str(path.relative_to(ROOT)): sha(path) for path in SOURCES}:
            raise RuntimeError('Drive-health source changed during build')
        if staged.is_symlink() or not staged.is_file() or staged.stat().st_size > 4 << 20:
            raise RuntimeError('Unexpected drive-health helper output')
        if symbols:
            staged_symbols = staged.with_name(staged.name + '.dSYM')
            subprocess.run(['/usr/bin/xcrun', 'dsymutil', str(staged), '-o', str(staged_symbols)],
                check=True, timeout=120, stdin=subprocess.DEVNULL)
            helper_symbols.validate(staged, staged_symbols)
        os.replace(staged, binary)
        if symbols:
            helper_symbols.copy_bundle(binary, staged_symbols, binary, binary.with_name(binary.name + '.dSYM'))
            helper_symbols.symbol_file(staged_symbols)
            shutil.rmtree(staged_symbols)
        receipt.write_text(json.dumps(dict(input=fingerprint, binarySHA256=sha(binary)), sort_keys=True) + '\n')
        return binary
    except BaseException:
        # A failed stage remains within the owned ignored build root for review.
        raise


def _locked_build_service(output: Path, parent_requirement: str) -> Path:
    """Compile the same acquisition/codec with the one-request libxpc entry."""
    sdk = subprocess.check_output(['/usr/bin/xcrun', '--show-sdk-path'], text=True, timeout=15).strip()
    arch = platform.machine()
    if arch not in ('arm64', 'x86_64'):
        raise RuntimeError('Unsupported drive-health service architecture')
    fingerprint = dict(format='drive-health-xpc-build-v1', sdk=sdk, architecture=arch,
        parentRequirement=parent_requirement, symbols=helper_symbols.POLICY,
        builderSHA256=sha(Path(__file__).resolve()),
        sourceSHA256={str(path.relative_to(ROOT)): sha(path) for path in SERVICE_SOURCES})
    binary = output / SERVICE_EXECUTABLE
    receipt = output / 'build-service.json'
    for path in (binary, receipt):
        if path.is_symlink() or path.exists() and (not path.is_file() or path.stat().st_nlink != 1):
            raise RuntimeError('Redirected drive-health service build output')
    symbols = binary.with_name(binary.name + '.dSYM')
    if receipt.is_file() and receipt.stat().st_size < 65536 and binary.is_file():
        cached = json.loads(receipt.read_bytes())
        if cached.get('input') == fingerprint and cached.get('binarySHA256') == sha(binary):
            helper_symbols.validate(binary, symbols)
            return binary
    if len(list(output.iterdir())) >= 128:
        raise ValueError('Retained drive-health build-stage limit reached')
    staged = output / (SERVICE_EXECUTABLE + '-' + str(uuid.uuid4()).upper())
    define = '-DTH_HEALTH_XPC_PARENT_REQUIREMENT=' + json.dumps(parent_requirement)
    flags = ['/usr/bin/clang', '-std=c17', '-Wall', '-Wextra', '-Werror', '-O2',
        '-gline-tables-only', '-fblocks', '-target', arch + '-apple-macos15.0', '-isysroot', sdk,
        define, '-I', str(NATIVE / 'include')]
    objects = []
    for source in [*C_SOURCES, SERVICE]:
        obj = output / ('xpc-' + source.stem + '.o')
        if obj.exists() or obj.is_symlink(): regular(obj)
        subprocess.run([*flags, '-c', str(source), '-o', str(obj)],
            check=True, timeout=120, stdin=subprocess.DEVNULL)
        objects.append(str(obj))
    subprocess.run([*flags, *objects, '-framework', 'CoreFoundation', '-framework', 'IOKit',
        '-L', str(Path(sdk) / 'usr/lib/system'), '-lxpc', '-o', str(staged)],
        check=True, timeout=120, stdin=subprocess.DEVNULL)
    if fingerprint['sourceSHA256'] != {str(path.relative_to(ROOT)): sha(path) for path in SERVICE_SOURCES}:
        raise RuntimeError('Drive-health service source changed during build')
    if staged.is_symlink() or not staged.is_file() or not 0 < staged.stat().st_size <= 4 << 20:
        raise RuntimeError('Unexpected drive-health service output')
    staged_symbols = staged.with_name(staged.name + '.dSYM')
    subprocess.run(['/usr/bin/xcrun', 'dsymutil', str(staged), '-o', str(staged_symbols)],
        check=True, timeout=120, stdin=subprocess.DEVNULL)
    helper_symbols.validate(staged, staged_symbols)
    os.replace(staged, binary)
    helper_symbols.copy_bundle(binary, staged_symbols, binary, symbols)
    shutil.rmtree(staged_symbols)
    receipt.write_text(json.dumps(dict(input=fingerprint, binarySHA256=sha(binary)), sort_keys=True) + '\n')
    return binary


def _embed_service(app: Path, env: dict[str, str], case: Path | None) -> bool:
    """One closed QA or Developer ID product service; failed stages stay inspectable."""
    if case is None:
        identity = store_helpers.configuration(app, env)
        team, parent, channel = store_helpers.TEAM, store_helpers.PARENT, 'developer-id'
        access_policy = store_helpers.access_policy(env)
    else:
        if case.name != helper_symbols.HEALTH_QA_CASE:
            raise ValueError('Drive-health XPC composition requires its exact QA case')
        identity, team = remote_editor_qa.signer(case)
        parent, channel = remote_editor_qa.identifier(case.name), 'qualification'
        access_policy = store_helpers.SCOPED
    if team != store_helpers.TEAM or identity in ('', '-'):
        raise ValueError('Drive-health XPC requires the selected archive signer')
    if app != Path(env['TARGET_BUILD_DIR']) / Path(env['CONTENTS_FOLDER_PATH']).parent:
        raise ValueError('Drive-health XPC product differs')
    info_path = app / 'Contents/Info.plist'
    regular(info_path)
    info = plistlib.loads(info_path.read_bytes())
    if info.get('CFBundleIdentifier') != parent or info.get('MacExplorerDistributionChannel') != channel \
            or SERVICE_VERSION_KEY in info or helper_symbols.HEALTH_VERSION_KEY in info \
            or not helper_symbols.health_service_declared({**info, SERVICE_VERSION_KEY: 1}):
        raise ValueError('Drive-health XPC parent metadata differs')
    old = [app / 'Contents/Helpers/drive-health-worker',
        app / 'Contents/Resources/DriveHealthHelperManifest.plist']
    if any(path.exists() or path.is_symlink() for path in old):
        raise ValueError('Drive-health service cannot mix with the inherited worker')
    resource = app / 'Contents/Resources'
    if resource.is_symlink() or not resource.is_dir() or resource.resolve() != resource \
            or resource.stat().st_uid != os.getuid() or resource.stat().st_mode & 0o022:
        raise ValueError('Redirected drive-health service resource folder')
    manifest_path = resource / SERVICE_MANIFEST
    if manifest_path.exists() or manifest_path.is_symlink():
        raise ValueError('Drive-health service manifest already exists')
    services = app / 'Contents/XPCServices'
    if services.exists() or services.is_symlink():
        if services.is_symlink() or not services.is_dir() or services.resolve() != services \
                or services.stat().st_uid != os.getuid() or services.stat().st_mode & 0o022 \
                or services.stat().st_mode & 0o055 != 0o055 \
                or any(services.iterdir()):
            raise ValueError('Unselected or redirected XPC service in app')
    else:
        services.mkdir(mode=0o755)
        services.chmod(0o755)
    destination = services / SERVICE_LEAF
    parent_requirement = role_requirement(parent)
    service_id = service_identifier(parent)
    with build_lock(symbols=True) as output:
        source = _locked_build_service(output, parent_requirement)
        regular(source)
        stage_root = app.parent / '.mac-explorer-helper-staging'
        directory(stage_root)
        if len(list(stage_root.iterdir())) >= 64 or stage_root.stat().st_dev != services.stat().st_dev:
            raise ValueError('Drive-health service stage is full or on another volume')
        stage = stage_root / ('health-xpc-' + str(uuid.uuid4()).upper())
        stage.mkdir(mode=0o700)
        candidate = stage / SERVICE_LEAF
        binary = candidate / 'Contents/MacOS' / SERVICE_EXECUTABLE
        binary.parent.mkdir(mode=0o755, parents=True)
        for folder in [candidate, candidate / 'Contents', binary.parent]:
            folder.chmod(0o755)
        service_fields = service_info(service_id)
        try:
            shutil.copy2(source, binary, follow_symlinks=False)
            binary.chmod(0o755)
            regular(binary)
            service_info_path = candidate / 'Contents/Info.plist'
            service_info_path.write_bytes(plistlib.dumps(service_fields, sort_keys=False))
            service_info_path.chmod(0o644)
            sign_env = dict(env)
            sign_env.pop('CFFIXED_USER_HOME', None)
            if sign_env.get('HOME') in (str(ROOT / '.build/xcode-user'), str(ROOT / '.build/distribution-tooling/user')):
                sign_env.pop('HOME', None)
            subprocess.run(['/usr/bin/xcrun', 'strip', '-S', str(binary)],
                check=True, capture_output=True, timeout=30, env=sign_env)
            previous_umask = os.umask(0o022)
            try:
                subprocess.run(['/usr/bin/codesign', '--force', '--sign', identity, '--timestamp=none',
                    '--options', 'runtime', '--identifier', service_id, str(candidate)],
                    check=True, capture_output=True, timeout=60, env=sign_env)
            finally:
                os.umask(previous_umask)
            subprocess.run(['/usr/bin/codesign', '--verify', '--strict', str(candidate)],
                check=True, capture_output=True, timeout=30, env=sign_env)
            for folder in [candidate, candidate / 'Contents', binary.parent,
                           candidate / 'Contents/_CodeSignature']:
                if folder.is_symlink() or not folder.is_dir() or folder.stat().st_mode & 0o055 != 0o055:
                    raise ValueError('Drive-health service bundle cannot be traversed after installation')
            for file in [binary, service_info_path, candidate / 'Contents/_CodeSignature/CodeResources']:
                if file.is_symlink() or not file.is_file() or file.stat().st_mode & 0o044 != 0o044:
                    raise ValueError('Drive-health service code cannot be read after installation')
            signed = subprocess.run(['/usr/bin/codesign', '-d', '--verbose=4', str(candidate)],
                check=True, capture_output=True, text=True, timeout=30, env=sign_env)
            fields = dict(line.split('=', 1) for line in signed.stderr.splitlines() if '=' in line)
            flags = re.search(r'flags=0x([0-9a-fA-F]+)\b', signed.stderr)
            authorities = [line.split('=', 1)[1] for line in signed.stderr.splitlines() if line.startswith('Authority=')]
            cdhash = fields.get('CDHash', '').lower()
            rights = subprocess.run(['/usr/bin/codesign', '-d', '--entitlements', '-', '--xml', str(candidate)],
                check=True, capture_output=True, timeout=30, env=sign_env)
            actual_rights = plistlib.loads(rights.stdout) if rights.stdout.strip() else {}
            if fields.get('Identifier') != service_id or fields.get('TeamIdentifier') != team \
                    or flags is None or int(flags[1], 16) & 0x10000 != 0x10000 \
                    or not authorities or not authorities[0].startswith(
                        'Developer ID Application: ' if case is not None else 'Apple Development: ') \
                    or re.fullmatch('[0-9a-f]{40}(?:[0-9a-f]{24})?', cdhash) is None \
                    or case is None and fields.get('Timestamp') \
                    or actual_rights != {} or not isinstance(actual_rights, dict):
                raise ValueError('Signed drive-health XPC role, runtime or rights differ')
            manifest = dict(format='drive-health-xpc-qa-v1' if case is not None
                else 'drive-health-xpc-developer-id-v1', parentIdentifier=parent,
                serviceIdentifier=service_id, teamIdentifier=team, channel=channel,
                accessPolicy=access_policy,
                parentRequirement=parent_requirement, sha256=sha(binary), serviceCDHash=cdhash)
            if case is not None: manifest['reviewCase'] = case.name
            manifest_data = plistlib.dumps(manifest, sort_keys=False)
            if len(manifest_data) > 4096 or destination.exists() or destination.is_symlink():
                raise ValueError('Drive-health service destination or manifest differs')
            candidate.rename(destination)
            with manifest_path.open('xb') as target:
                target.write(manifest_data)
            manifest_path.chmod(0o644)
            info[SERVICE_VERSION_KEY] = 1
            info_path.write_bytes(plistlib.dumps(info, sort_keys=False))
            helper_symbols.publish_for_xcode(source, destination / 'Contents/MacOS' / SERVICE_EXECUTABLE, env)
            stage.rmdir()
            return True
        except BaseException as error:
            (stage / 'failure.json').write_text(json.dumps(dict(passed=False, errorType=type(error).__name__,
                preserveStage=True)) + '\n')
            raise


def _release_product(case: Path, app: Path, *, exported: bool) -> None:
    root = ROOT / '.build/traverse-release'
    if case.parent != root or str(uuid.UUID(case.name)).upper() != case.name or not case.is_dir() \
            or case.resolve() != case or app.resolve() != app:
        raise ValueError('Exact release case required for drive-health service')
    parts = app.relative_to(case).parts
    if exported:
        valid = len(parts) == 2 and re.fullmatch(r'export-[0-9]+', parts[0]) and parts[1] == 'Traverse.app'
    else:
        valid = len(parts) == 4 and re.fullmatch(r'Traverse-[0-9]+\.xcarchive', parts[0]) \
            and parts[1:] == ('Products', 'Applications', 'Traverse.app')
    if not valid or not app.is_dir() or app.is_symlink():
        raise ValueError('Drive-health service product placement differs')


def _product_service(app: Path) -> tuple[dict, dict, Path, Path, Path]:
    from distribution.artifact_files import read
    from distribution import preflight
    info = plistlib.loads(read(app / 'Contents/Info.plist', 1 << 20))
    if not preflight.health_info_admitted(info, store_helpers.PARENT, 'developer-id'):
        raise ValueError('Exported drive-health service edition differs')
    service = app / 'Contents/XPCServices' / SERVICE_LEAF
    binary = service / 'Contents/MacOS' / SERVICE_EXECUTABLE
    manifest_path = app / 'Contents/Resources' / SERVICE_MANIFEST
    if service.resolve() != service or service.is_symlink() or not service.is_dir() \
            or set(p.name for p in service.parent.iterdir()) != {SERVICE_LEAF} \
            or any(p.exists() or p.is_symlink() for p in [
                app / 'Contents/Helpers/drive-health-worker',
                app / 'Contents/Resources/DriveHealthHelperManifest.plist']):
        raise ValueError('Exported drive-health service family differs')
    regular(binary); regular(manifest_path)
    if plistlib.loads(read(service / 'Contents/Info.plist', 4096)) != service_info(service_identifier(store_helpers.PARENT)):
        raise ValueError('Exported drive-health service Info differs')
    manifest = plistlib.loads(read(manifest_path, 4096))
    expected = dict(format='drive-health-xpc-developer-id-v1', parentIdentifier=store_helpers.PARENT,
        serviceIdentifier=service_identifier(store_helpers.PARENT), teamIdentifier=store_helpers.TEAM,
        channel='developer-id', accessPolicy=info['MacExplorerAccessPolicy'],
        parentRequirement=role_requirement(store_helpers.PARENT))
    if not isinstance(manifest, dict) or set(manifest) != set(expected) | {'sha256', 'serviceCDHash'} \
            or any(manifest.get(key) != value for key, value in expected.items()) \
            or not isinstance(manifest.get('sha256'), str) \
            or re.fullmatch(r'[0-9a-f]{64}', manifest['sha256']) is None \
            or not isinstance(manifest.get('serviceCDHash'), str) \
            or re.fullmatch(r'[0-9a-f]{40}(?:[0-9a-f]{24})?', manifest['serviceCDHash']) is None:
        raise ValueError('Exported drive-health service manifest differs')
    return info, manifest, service, binary, manifest_path


def _signing_facts(path: Path, role: str, authority: str, *, timestamped: bool) -> dict:
    from distribution import preflight
    facts = preflight.signing(path)
    if facts.get('Identifier') != role or facts.get('TeamIdentifier') != store_helpers.TEAM \
            or facts.get('runtime') is not True or facts.get('timestamped') is not timestamped \
            or not facts.get('authorities') or not facts['authorities'][0].startswith(authority) \
            or not isinstance(facts.get('cdhash'), str) \
            or re.fullmatch(r'[0-9a-f]{40}(?:[0-9a-f]{24})?', facts['cdhash']) is None:
        raise ValueError('Drive-health signing role, team, runtime or timestamp differs')
    return facts


def _leaf_signer(path: Path, scratch: Path) -> str:
    from distribution.artifact_files import read
    prefix = scratch / ('certificate-' + str(uuid.uuid4()).upper())
    subprocess.run(['/usr/bin/codesign', '-d', '--extract-certificates=' + str(prefix), str(path)],
        check=True, capture_output=True, timeout=30)
    certificate = read(Path(str(prefix) + '0'), 32768)
    return hashlib.sha1(certificate).hexdigest().upper()


def _designated_requirement(app: Path) -> str:
    result = subprocess.run(['/usr/bin/codesign', '-d', '-r-', str(app)],
        check=True, capture_output=True, text=True, timeout=30)
    found = [line.strip() for line in (result.stdout + result.stderr).splitlines()
        if line.strip().startswith('designated => ')]
    if len(found) != 1:
        raise ValueError('Exported parent designated requirement unavailable')
    return found[0]


def _strict_verify(path: Path, *, deep: bool = False, role: str | None = None) -> None:
    arguments = ['/usr/bin/codesign', '--verify', '--strict']
    if deep: arguments.append('--deep')
    if role is not None: arguments.append('-R=' + role_requirement(role))
    subprocess.run([*arguments, str(path)], check=True, capture_output=True, timeout=30)


def _parent_rights(app: Path, info: dict) -> dict:
    from distribution import preflight
    rights = preflight.entitlements(app)
    updater = (info.get('TraversePrivateUpdaterVersion') == '2.10.0' \
        and 'TraversePublicUpdaterVersion' not in info) or \
        (info.get('TraversePublicUpdaterVersion') == '2.10.0' \
        and 'TraversePrivateUpdaterVersion' not in info)
    checks = preflight.entitlement_checks(rights, {},
        updater, store_helpers.PARENT, policy=info['MacExplorerAccessPolicy'],
        expected_team=store_helpers.TEAM)
    if not all(row['passed'] for row in checks):
        raise ValueError('Exported parent rights are not admitted')
    return rights


def verify_provisional_archive(case: Path, app: Path) -> dict:
    """The archived service is bound to the same Apple Development parent, never runnable as beta."""
    from distribution.artifact_files import read
    from distribution import preflight
    _release_product(case, app, exported=False)
    info, manifest, service, binary, _ = _product_service(app)
    parent = _signing_facts(app, store_helpers.PARENT, 'Apple Development: ', timestamped=False)
    child = _signing_facts(service, service_identifier(store_helpers.PARENT),
        'Apple Development: ', timestamped=False)
    if preflight.entitlements(service) != {} or manifest['sha256'] != hashlib.sha256(read(binary, 4 << 20)).hexdigest() \
            or manifest['serviceCDHash'] != child['cdhash']:
        raise ValueError('Provisional drive-health archive proof differs')
    _parent_rights(app, info)
    _strict_verify(service)
    _strict_verify(app, deep=True)
    with TemporaryDirectory(dir=case / 'source') as temporary:
        scratch = Path(temporary)
        if _leaf_signer(app, scratch) != _leaf_signer(service, scratch):
            raise ValueError('Provisional service and parent signers differ')
    return dict(format='drive-health-xpc-archive-v1', serviceSHA256=manifest['sha256'],
        serviceCDHash=child['cdhash'], parentCDHash=parent['cdhash'],
        serviceUUIDs=helper_symbols.uuids(binary))


def finalize_exported_product(case: Path, archive_app: Path, exported_app: Path, archive_proof: dict) -> dict:
    """Bind the exported service's final signature before the outer app is sealed."""
    from distribution.artifact_files import read
    from distribution import preflight
    _release_product(case, exported_app, exported=True)
    if verify_provisional_archive(case, archive_app) != archive_proof:
        raise ValueError('Drive-health archive proof changed before export finalization')
    archive_info, archived_manifest, _, archived_binary, _ = _product_service(archive_app)
    info, manifest, service, binary, manifest_path = _product_service(exported_app)
    keys = ('CFBundleIdentifier', 'CFBundleShortVersionString', 'CFBundleVersion',
        'MacExplorerDistributionChannel', 'MacExplorerStorageMode', 'MacExplorerAccessPolicy',
        'TraversePrivateUpdaterVersion', 'TraversePublicUpdaterVersion',
        'TraverseDirectPublicUpdaterVersion', 'TraverseDirectStorageNamespace',
        'MacExplorerFolderServices', 'NSServices', SERVICE_VERSION_KEY)
    if any(info.get(key) != archive_info.get(key) for key in keys) or manifest != archived_manifest \
            or helper_symbols.uuids(binary) != helper_symbols.uuids(archived_binary):
        raise ValueError('Exported drive-health code or source manifest differs')
    _strict_verify(exported_app, deep=True)
    parent = _signing_facts(exported_app, store_helpers.PARENT,
        'Developer ID Application: ', timestamped=True)
    rights = _parent_rights(exported_app, info)
    requirement = _designated_requirement(exported_app)
    _strict_verify(exported_app, role=store_helpers.PARENT)
    _strict_verify(service)
    service_rights = preflight.entitlements(service)
    child = preflight.signing(service)
    if child.get('Identifier') != service_identifier(store_helpers.PARENT) \
            or child.get('TeamIdentifier') != store_helpers.TEAM or child.get('runtime') is not True \
            or service_rights != {}:
        raise ValueError('Exported drive-health service role or rights differ')
    with TemporaryDirectory(dir=case / 'source') as temporary:
        scratch = Path(temporary)
        signer = _leaf_signer(exported_app, scratch)
        child_signer = _leaf_signer(service, scratch)
        authorities = child.get('authorities') or []
        if not authorities or not (authorities[0].startswith('Apple Development: ')
                or authorities[0].startswith('Developer ID Application: ')):
            raise ValueError('Exported drive-health service signer differs')
        needs_sign = child_signer != signer or not authorities[0].startswith('Developer ID Application: ') \
            or child.get('timestamped') is not True
        if needs_sign:
            subprocess.run(['/usr/bin/codesign', '--force', '--sign', signer, '--timestamp',
                '--options', 'runtime', '--identifier', service_identifier(store_helpers.PARENT), str(service)],
                check=True, capture_output=True, timeout=60)
        _strict_verify(service, role=service_identifier(store_helpers.PARENT))
        child = _signing_facts(service, service_identifier(store_helpers.PARENT),
            'Developer ID Application: ', timestamped=True)
        if _leaf_signer(service, scratch) != signer or preflight.entitlements(service) != {}:
            raise ValueError('Final drive-health service signer or rights differ')
        final_sha = hashlib.sha256(read(binary, 4 << 20)).hexdigest()
        changed = needs_sign or manifest['sha256'] != final_sha or manifest['serviceCDHash'] != child['cdhash']
        if changed:
            manifest['sha256'] = final_sha
            manifest['serviceCDHash'] = child['cdhash']
            data = plistlib.dumps(manifest, sort_keys=False)
            if len(data) > 4096: raise ValueError('Final drive-health manifest exceeds bound')
            staged = manifest_path.with_name('.DriveHealthServiceManifest-' + str(uuid.uuid4()).upper())
            descriptor = os.open(staged, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o644)
            with os.fdopen(descriptor, 'wb') as output:
                output.write(data); output.flush(); os.fsync(output.fileno())
            if plistlib.loads(read(manifest_path, 4096)) != archived_manifest:
                raise ValueError('Exported drive-health manifest changed during finalization')
            os.replace(staged, manifest_path)
            subprocess.run(['/usr/bin/codesign', '--force', '--sign', signer, '--timestamp',
                '--preserve-metadata=identifier,entitlements,requirements,flags,runtime,launch-constraints,library-constraints',
                str(exported_app)], check=True, capture_output=True, timeout=60)
        _strict_verify(exported_app, deep=True)
        _strict_verify(exported_app, role=store_helpers.PARENT)
        after = _signing_facts(exported_app, store_helpers.PARENT,
            'Developer ID Application: ', timestamped=True)
        if _leaf_signer(exported_app, scratch) != signer or preflight.entitlements(exported_app) != rights \
                or _designated_requirement(exported_app) != requirement:
            raise ValueError('Outer app signer, rights or requirement changed during finalization')
    checked = preflight.drive_health_checks(exported_app, info, store_helpers.PARENT,
        store_helpers.TEAM, 'developer-id')
    if not all(row['passed'] for row in checked):
        raise ValueError('Final exported drive-health service admission failed')
    return dict(format='drive-health-xpc-export-final-v1', serviceSHA256=final_sha,
        serviceCDHash=child['cdhash'], parentCDHash=after['cdhash'],
        serviceResigned=needs_sign, outerResealed=changed, strictDeepVerified=True)


def embed(app: Path, *, environment: dict | None = None,
          preview: tuple[str, str, str] | None = None) -> bool:
    """One composition owner; local Preview and QA worker lanes stay unchanged."""
    env = dict(os.environ if environment is None else environment)
    if app.resolve() != app or not app.is_relative_to(ROOT / '.build'):
        raise ValueError('Exact repo-local health-helper app required')
    info_path = app / 'Contents/Info.plist'
    case = remote_editor_qa.admitted_build(env) if preview is None else None
    if SERVICE_COMPOSITION_KEY in env:
        if env[SERVICE_COMPOSITION_KEY] != SERVICE_COMPOSITION or preview is not None or case is None:
            raise ValueError('Drive-health XPC is held outside its selected QA composition')
        return _embed_service(app, env, case)
    shipping = env.get('PRODUCT_BUNDLE_IDENTIFIER') == store_helpers.PARENT and (
        env.get('MAC_EXPLORER_TRAVERSE_BUILD') == 'developer-id-v1'
        and env.get('MAC_EXPLORER_ACCESS_POLICY') == store_helpers.SCOPED
        or env.get('MAC_EXPLORER_TRAVERSE_BUILD') in (
            'developer-id-local-user-public-qualification-v1',
            'developer-id-local-user-public-shipping-v1')
        and env.get('MAC_EXPLORER_ACCESS_POLICY') == store_helpers.LOCAL)
    if shipping:
        if preview is not None:
            raise ValueError('Developer ID product cannot select the local Preview helper')
        return _embed_service(app, env, None)
    excluded = preview is None and not shipping and case is None
    if case is not None and (case.name != helper_symbols.HEALTH_QA_CASE
            or remote_editor_qa.signer(case)[1] != store_helpers.TEAM):
        excluded = True
    if excluded:
        if any(path.exists() or path.is_symlink() for path in [
                app / 'Contents/Helpers/drive-health-worker',
                app / 'Contents/Resources/DriveHealthHelperManifest.plist',
                app / 'Contents/XPCServices' / SERVICE_LEAF,
                app / 'Contents/Resources' / SERVICE_MANIFEST]):
            raise ValueError('Unselected health-helper artifacts must be absent')
        if info_path.exists() or info_path.is_symlink():
            regular(info_path)
            existing = plistlib.loads(info_path.read_bytes())
            if helper_symbols.HEALTH_VERSION_KEY in existing or SERVICE_VERSION_KEY in existing:
                raise ValueError('Health metadata outside its selected composition')
        return False
    regular(info_path)
    info = plistlib.loads(info_path.read_bytes())
    if SERVICE_VERSION_KEY in info or any(path.exists() or path.is_symlink() for path in [
            app / 'Contents/XPCServices' / SERVICE_LEAF,
            app / 'Contents/Resources' / SERVICE_MANIFEST]):
        raise ValueError('Legacy drive-health composition cannot mix with an XPC service')
    parent = info.get('CFBundleIdentifier')
    if preview is not None:
        identity, team, review = preview
        if parent != 'local.macexplorer.preview' \
                or info.get('MacExplorerDistributionChannel') != 'development-preview' \
                or info.get('MacExplorerReviewCase') != review:
            raise ValueError('Preview health composition differs')
        identifier = 'local.macexplorer.drive.health'
        manifest = dict(format='drive-health-preview-v1', parentIdentifier=parent,
            helperIdentifier=identifier, teamIdentifier=team, reviewCase=review)
    else:
        if case is not None:
            identity, team = remote_editor_qa.signer(case)
            channel = 'qualification'
        elif shipping:
            identity = store_helpers.configuration(app, env)
            team, channel = store_helpers.TEAM, 'developer-id'
        identifier = parent + '.drive.health'
        if app != Path(env['TARGET_BUILD_DIR']) / Path(env['CONTENTS_FOLDER_PATH']).parent \
                or parent != env.get('PRODUCT_BUNDLE_IDENTIFIER') \
                or info.get('MacExplorerDistributionChannel') != channel \
                or info.get('MacExplorerAccessPolicy') != store_helpers.SCOPED:
            raise ValueError('Inherited health parent metadata differs')
        manifest = dict(format='drive-health-inherited-v2', parentIdentifier=parent,
            helperIdentifier=identifier, teamIdentifier=team, channel=channel,
            accessPolicy=store_helpers.SCOPED)
        if case is not None: manifest['reviewCase'] = case.name
    for folder in [app / 'Contents/Helpers', app / 'Contents/Resources']:
        if folder.resolve() != folder or not folder.is_dir():
            raise ValueError('Redirected or missing health-helper folder')
    destination = app / 'Contents/Helpers/drive-health-worker'
    manifest_path = app / 'Contents/Resources/DriveHealthHelperManifest.plist'
    if manifest_path.exists() or manifest_path.is_symlink(): regular(manifest_path)
    arguments = ['/usr/bin/codesign', '--force', '--sign', identity,
        '--timestamp=none' if preview is not None or case is not None else '--timestamp',
        '--options', 'runtime', '--identifier', identifier]
    if preview is None:
        rights = plistlib.loads((ROOT / 'Distribution/HelperInherit.entitlements').read_bytes())
        if rights != store_helpers.helper_rights(store_helpers.SCOPED):
            raise ValueError('Health-helper inheritance rights differ')
        arguments += ['--entitlements', str(ROOT / 'Distribution/HelperInherit.entitlements')]
    env.pop('CFFIXED_USER_HOME', None)
    if env.get('HOME') in (str(ROOT / '.build/xcode-user'), str(ROOT / '.build/distribution-tooling/user')):
        env.pop('HOME', None)
    with build_lock(symbols=preview is None) as output:
        source = _locked_build(output, symbols=preview is None)
        publish(source, destination, staging_root=app.parent / '.mac-explorer-helper-staging',
            signing_arguments=arguments, signing_environment=env, strip_debug=preview is None)
        result = subprocess.run(['/usr/bin/codesign', '-d', '--verbose=4', str(destination)],
            check=True, capture_output=True, text=True, timeout=30)
        fields = dict(line.split('=', 1) for line in result.stderr.splitlines() if '=' in line)
        flags = re.search(r'flags=0x([0-9a-fA-F]+)\b', result.stderr)
        entitlements = subprocess.run(['/usr/bin/codesign', '-d', '--entitlements', '-', '--xml', str(destination)],
            check=True, capture_output=True, timeout=30)
        actual_rights = plistlib.loads(entitlements.stdout) if entitlements.stdout.strip() else {}
        expected_rights = {} if preview is not None else store_helpers.helper_rights(store_helpers.SCOPED)
        if fields.get('Identifier') != identifier or flags is None or not int(flags[1], 16) & 0x10000 \
                or team != 'adhoc' and fields.get('TeamIdentifier') != team \
                or actual_rights != expected_rights \
                or not isinstance(actual_rights, dict) or any(type(v) is not bool for v in actual_rights.values()):
            raise ValueError('Signed health-helper identity, runtime or rights differ')
        manifest['sha256'] = sha(destination)
        manifest_path.write_bytes(plistlib.dumps(manifest, sort_keys=False))
        if preview is None:
            info[helper_symbols.HEALTH_VERSION_KEY] = 2
            info_path.write_bytes(plistlib.dumps(info, sort_keys=False))
            helper_symbols.publish_for_xcode(source, destination, env)
    return True


if __name__ == '__main__':
    print(build())
