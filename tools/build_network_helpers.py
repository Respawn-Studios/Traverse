#!/usr/bin/env python3
"""Reproducible ordinary SMB/resolver helpers, without qualification admission.

No downloads, credentials, network sessions or global toolchain configuration.
Xcode calls embed before its enclosing signature is produced.
"""
from __future__ import annotations
import argparse
import fcntl
import json
import os
import resource
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import time
import uuid

sys.dont_write_bytecode = True
REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / 'tools/smb_reader'))
from packet import TOOLING, TOOLING_LIMIT, TOOLCHAIN, MIB, environment, usage, directory, digest
from helper_manifest import write, IDENTIFIERS
from vendor_verified_source import verify
from bundle_helper import publish
from distribution import helper_symbols
from distribution import remote_editor_qa
from build_architecture import selected

RELEASE = helper_symbols.requested(os.environ)
ARCHITECTURE = selected()
RELEASE_TOOLING = REPO / '.build/traverse-release/tooling'
OUTPUT = ARCHITECTURE.cache_directory((RELEASE_TOOLING / 'smb-ordinary-helpers') if RELEASE else TOOLING / 'ordinary-helpers')
BROWSER = REPO / 'tools/smb_reader/smb2-browser'


def command(arguments, env, log):
    with log.open('xb') as output:
        child = subprocess.Popen(arguments, cwd=REPO, env=env, stdin=subprocess.DEVNULL,
            stdout=output, stderr=subprocess.STDOUT, start_new_session=True)
        began = time.monotonic(); problem = None; stats = None
        while True:
            found, status, observed = os.wait4(child.pid, os.WNOHANG)
            if found:
                child.returncode = os.waitstatus_to_exitcode(status); stats = observed; break
            if time.monotonic() - began > 240: problem = 'bounded compile deadline'
            elif log.stat().st_size > MIB: problem = 'bounded compiler log'
            else:
                try:
                    if RELEASE:
                        from distribution.traverse_packet import audit as release_audit
                        release_audit()
                    elif usage(TOOLING, TOOLING_LIMIT, building=True, compiler_locks=True)['bytes'] + 4 * MIB > TOOLING_LIMIT:
                        problem = 'isolated tooling ceiling'
                except Exception: problem = 'tooling ownership audit'
            if problem:
                os.killpg(child.pid, 15)
                try: child.wait(timeout=5)
                except subprocess.TimeoutExpired: os.killpg(child.pid, 9); child.wait(timeout=5)
                raise RuntimeError('Network helper build stopped: ' + problem)
            time.sleep(.1)
    # Darwin wait4 carries the maximum of this child and its reaped children.
    # Record stages separately; the outer Python invocation cannot identify
    # which compiler owns its whole-tree high-water mark.
    stage = dict(actualExit=child.returncode, seconds=time.monotonic()-began,
        invocationTreePeakRSSBytes=stats.ru_maxrss if stats else None,
        launcherSelfPeakRSSBytes=resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,
        executable=Path(arguments[0]).name, metric='Darwin wait4 child-tree maximum, not a sum or compiler attribution')
    with log.with_suffix('.process.json').open('x') as receipt:
        json.dump(stage, receipt, sort_keys=True, indent=2); receipt.write('\n'); receipt.flush(); os.fsync(receipt.fileno())
    if child.returncode: raise RuntimeError('Network helper compilation failed; inspect its owned build log')


def fingerprint(sdk):
    sources = list(BROWSER.glob('*.toml')) + [BROWSER / 'Cargo.lock'] + list(BROWSER.rglob('*.rs'))
    sources += [REPO / 'tools/smb_reader' / value for value in [
        'common.rs', 'auth_security.rs', 'catalog/catalog.rs', 'catalog/selected_catalog.rs', 'catalog/StoreAuthority.c', 'catalog/build.rs']
        if (REPO / 'tools/smb_reader' / value).is_file()]
    sources += [REPO / 'tools/smb_resolver/main.swift', REPO / 'Vendor/smb2/PROVENANCE.json']
    return dict(version=4, sdk=sdk, target=ARCHITECTURE.clang_target, resolverControls=False,
        symbols=helper_symbols.POLICY if RELEASE else None,
        compilerSHA256=digest(TOOLCHAIN / 'bin/rustc'),
        sourceSHA256={str(path.relative_to(REPO)): digest(path) for path in sources},
        **helper_symbols.rust_source_path_fingerprint(RELEASE))


def build_locked():
    verify()
    env = environment()
    env.pop('CARGO_BUILD_TARGET', None)
    sdk = subprocess.check_output(['/usr/bin/xcrun', '--show-sdk-path'], env=env, text=True).strip()
    env['SDKROOT'] = sdk
    if RELEASE:
        env.update(CARGO_TARGET_DIR=str(directory(RELEASE_TOOLING / 'rust-smb')),
            CARGO_PROFILE_RELEASE_DEBUG='line-tables-only',
            CARGO_PROFILE_RELEASE_SPLIT_DEBUGINFO='packed')
        helper_symbols.apply_cargo_rust_source_path_policy(env, RELEASE)
    inputs = fingerprint(sdk)
    outputs = {role: OUTPUT / ('smb-' + role + '-worker') for role in IDENTIFIERS}
    cached = OUTPUT / 'build.json'
    if cached.is_file() and not cached.is_symlink() and cached.stat().st_nlink == 1 and cached.stat().st_size < MIB:
        found = json.loads(cached.read_bytes())
        if found.get('inputs') == inputs and all(path.is_file() and not path.is_symlink() and path.stat().st_nlink == 1
            and digest(path) == found.get('binaries', {}).get(role) for role, path in outputs.items()):
            if RELEASE:
                for path in outputs.values():
                    helper_symbols.validate(path, path.with_name(path.name + '.dSYM'))
            return outputs
    if not RELEASE and usage(TOOLING, TOOLING_LIMIT)['bytes'] + 64 * MIB > TOOLING_LIMIT:
        raise RuntimeError('Insufficient isolated network helper build headroom')
    run = str(uuid.uuid4()).upper()
    command([str(TOOLCHAIN / 'bin/cargo'), 'build', '--manifest-path', str(BROWSER / 'Cargo.toml'),
        '--locked', '--offline', '--release', '--jobs', '4', *ARCHITECTURE.cargo_arguments()], env, OUTPUT / ('rust-' + run + '.log'))
    cache = directory((RELEASE_TOOLING / 'swift') if RELEASE else TOOLING / 'swift-module-cache')
    env['CLANG_MODULE_CACHE_PATH'] = str(cache)
    command(['/usr/bin/xcrun', 'swiftc', '-O', *(['-g'] if RELEASE else []), '-swift-version', '6', '-strict-concurrency=complete',
        '-warnings-as-errors', '-sdk', sdk, '-target', ARCHITECTURE.clang_target, '-module-cache-path', str(cache),
        str(REPO / 'tools/smb_resolver/main.swift'), '-o', str(outputs['resolver'])], env, OUTPUT / ('swift-' + run + '.log'))
    source = ARCHITECTURE.cargo_product((RELEASE_TOOLING / 'rust-smb') if RELEASE else TOOLING / 'target', 'macexplorer-smb-browser-qualification')
    if source.is_symlink() or not source.is_file() or source.stat().st_nlink != 1: raise RuntimeError('Unsafe browser compiler output')
    shutil.copyfile(source, outputs['browser'])
    for path in outputs.values(): path.chmod(0o755)
    if RELEASE:
        helper_symbols.copy_bundle(source, helper_symbols.cargo_bundle(source),
            outputs['browser'], outputs['browser'].with_name(outputs['browser'].name + '.dSYM'))
        helper_symbols.validate(outputs['resolver'], outputs['resolver'].with_name(outputs['resolver'].name + '.dSYM'))
    # The provenance file binds vendored bytes, but the fingerprint does not
    # enumerate them. Recheck the verified vendor tree after Cargo has read it.
    verify()
    if fingerprint(sdk) != inputs: raise RuntimeError('Network sources changed during compilation')
    value = dict(inputs=inputs, binaries={role: digest(path) for role, path in outputs.items()})
    staged = cached.with_name('build-' + run + '.json')
    with staged.open('x') as output: output.write(json.dumps(value, sort_keys=True, indent=2) + '\n')
    staged.replace(cached)
    usage(TOOLING, TOOLING_LIMIT); return outputs


def embed(target: Path, relative: Path):
    if target == Path('/') or relative.is_absolute() or '..' in relative.parts or relative.name != 'Contents':
        raise RuntimeError('Invalid Xcode network helper target')
    app = target / relative.parent
    # Existing Xcode product paths are not new test roots; exact known helper
    # and manifest names may be refreshed before the final product signature.
    if app.is_symlink() or not app.is_dir(): raise RuntimeError('Unavailable Xcode product bundle')
    helpers = app / 'Contents/Helpers'; helpers.mkdir(mode=0o755, exist_ok=True)
    if helpers.is_symlink(): raise RuntimeError('Redirected helper destination')
    from distribution import store_helpers
    store = os.environ.get('PRODUCT_BUNDLE_IDENTIFIER') == store_helpers.PARENT
    qa_case = remote_editor_qa.admitted_build(os.environ)
    identity, team = (store_helpers.configuration(app, os.environ), store_helpers.TEAM) if store else (
        remote_editor_qa.signer(qa_case) if qa_case else (
            os.environ.get('EXPANDED_CODE_SIGN_IDENTITY') or '-',
            os.environ.get('DEVELOPMENT_TEAM', '') if os.environ.get('EXPANDED_CODE_SIGN_IDENTITY') not in (None, '', '-') else 'adhoc'))
    if team != 'adhoc' and (len(team) != 10 or not team.isascii() or not team.isalnum() or team != team.upper()):
        raise RuntimeError('Configured development signing team required; no ad hoc fallback')
    parent = os.environ.get('PRODUCT_BUNDLE_IDENTIFIER')
    if not store and not qa_case and parent != 'local.macexplorer.development':
        raise RuntimeError('A separate reviewed distribution identity configuration is required')
    signing_env = os.environ.copy(); signing_env.pop('CFFIXED_USER_HOME', None)
    if signing_env.get('HOME') == str(REPO / '.build/xcode-user'): signing_env.pop('HOME', None)
    outputs = build_locked(); roles = {}
    for role, source in outputs.items():
        helper = helpers / source.name
        if helper.is_symlink() or helper.exists() and (not helper.is_file() or helper.stat().st_nlink != 1):
            raise RuntimeError('Redirected/shared bundled network helper')
        identifier = store_helpers.IDENTIFIERS[role] if store else remote_editor_qa.ROLE_IDENTIFIERS[role] if qa_case else IDENTIFIERS[role]
        arguments = ['/usr/bin/codesign', '--force', '--sign', identity, '--timestamp=none', '--identifier', identifier]
        if store or qa_case: arguments += ['--options', 'runtime']
        if os.environ.get('ENABLE_APP_SANDBOX') == 'YES':
            arguments += ['--entitlements', str(REPO / 'Distribution/HelperInherit.entitlements')]
        publish(source, helper, staging_root=app.parent / '.mac-explorer-helper-staging',
            signing_arguments=arguments, signing_environment=signing_env, strip_debug=RELEASE)
        helper_symbols.publish_for_xcode(source, helper, os.environ)
        roles[role] = helper
    if store: store_helpers.write_manifest(app, roles)
    elif qa_case: remote_editor_qa.write_manifest(app, roles, qa_case)
    else: write(app, roles, parent=parent, team=team, replace=True)
    # Keep each concrete helper's isolated Cargo/cache/signing module separate.
    # This adds no download, connection or identity configuration.
    subprocess.run([sys.executable,str(REPO/'tools/sftp_reader/build_ordinary_worker.py'),'--embed',str(app)],
        env=os.environ.copy(),stdin=subprocess.DEVNULL,check=True)
    from distribution.bundle_notices import embed as embed_notices
    embed_notices(app)
    print('Bundled signed SMB browser with explicit selected-file mode and hostname resolver')


def main():
    parser = argparse.ArgumentParser(); parser.add_argument('--embed', action='store_true'); args = parser.parse_args()
    directory(OUTPUT)
    lock = OUTPUT / 'build.lock'
    descriptor = os.open(lock, os.O_RDWR | os.O_CREAT | os.O_CLOEXEC | os.O_NOFOLLOW, 0o600)
    try:
        facts = os.fstat(descriptor)
        if not stat.S_ISREG(facts.st_mode) or facts.st_uid != os.getuid() or facts.st_nlink != 1 or facts.st_mode & 0o077:
            raise RuntimeError('Unsafe helper build lock')
        fcntl.flock(descriptor, fcntl.LOCK_EX)
        current = lock.lstat()
        if (facts.st_dev, facts.st_ino) != (current.st_dev, current.st_ino): raise RuntimeError('Helper build lock changed while waiting')
        if args.embed: embed(Path(os.environ['TARGET_BUILD_DIR']).absolute(), Path(os.environ['CONTENTS_FOLDER_PATH']))
        else: print(json.dumps({role: str(path.relative_to(REPO)) for role, path in build_locked().items()}))
    finally: os.close(descriptor)


if __name__ == '__main__': main()
