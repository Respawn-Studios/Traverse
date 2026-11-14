#!/usr/bin/env python3
"""Pinned catalog/explicit-transfer helper; no network admission in this build."""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import stat
import subprocess
import sys
import time
sys.dont_write_bytecode=True
from packet import REPO,TOOLING,TOOLCHAIN,MIB,directory,environment,audit
sys.path.insert(0,str(REPO/'tools'))
from bundle_helper import publish
from distribution import helper_symbols
from distribution import remote_editor_qa
from ssh_profiles import packet as profile_packet

RELEASE=helper_symbols.requested(os.environ)
BASE_FEATURES=('download-qualification','upload-qualification','folder-download-qualification')
# The prepared editor backend is packaged in both configurations. Ordinary UI
# activation remains gated separately; protocol mode needs an admitted permit.
_agent_qa=os.environ.get('TRAVERSE_AGENT_QA','')
if _agent_qa not in ('','1'):
    raise RuntimeError('Invalid agent QA build request')
if _agent_qa and not remote_editor_qa.admitted_build(os.environ):
    raise RuntimeError('Agent QA requires exact signed sandbox case')
FEATURES=BASE_FEATURES+('inplace-edit-v1','remote-action-qualification')+(
    ('agent-qualification',) if _agent_qa else ())
RELEASE_TOOLING=REPO/'.build/traverse-release/tooling'
OUTPUT=(profile_packet.TOOLING/'ordinary-release-worker')if RELEASE else profile_packet.TOOLING/'ordinary-worker'
PROJECT=REPO/'tools/sftp_reader/qualification'
IDENTIFIER='local.macexplorer.sftp.metadata'
def profile_audit():
    if 'TRAVERSE_COMPLETION_HELPER_CASE_ID' not in os.environ:
        return profile_packet.audit()
    # A claimed completion build must validate its private case and live
    # xcodebuild ancestry. Invalid claims fail rather than use another ledger.
    import completion_helper_gate
    if not completion_helper_gate.admitted():
        raise RuntimeError('Completion helper gate unavailable')
    return profile_packet.completion_helper_audit()
def digest(path):
    result=hashlib.sha256()
    with path.open('rb') as source:
        while block:=source.read(MIB):result.update(block)
    return result.hexdigest()
def inputs():
    # Include nested library modules too. A change to an exclusive transfer or
    # reader submodule must invalidate the bundled helper, independently of
    # whether its parent .rs file happened to change in the same build.
    sources=[PROJECT/name for name in ['Cargo.toml','Cargo.lock','build.rs','src/bin/catalog_worker.rs']]
    sources+=[p for p in (PROJECT/'src').rglob('*.rs') if not p.is_relative_to(PROJECT/'src/bin')]
    sources+=sorted((REPO/'tools/sftp_reader/catalog').glob('*'))
    sources += [REPO/'tools/smb_reader/catalog/StoreAuthority.c']
    return dict(version=9,target='arm64-apple-macos15.0',features=list(FEATURES),inPlaceStartup=[3,7,1],metadataProtocolRemainsBodyFree=True,symbols=helper_symbols.POLICY if RELEASE else None,compilerSHA256=digest(TOOLCHAIN/'bin/rustc'),
        sdk=subprocess.check_output(['/usr/bin/xcrun','--show-sdk-path'],text=True).strip(),sourceSHA256={str(p.relative_to(REPO)):digest(p) for p in sources if p.is_file()},
        **helper_symbols.rust_source_path_fingerprint(RELEASE))
def compilation_audit(child,target,temporary):
    """Retry full snapshots when active compiler-owned output disappears.

    This never ignores an unsafe path/quota failure. The usual final audits run
    again after this exact compiler exits, with no transient-file exception.
    """
    anchor=target.lstat();scratch=temporary.lstat()
    if temporary!=profile_packet.TOOLING/'tmp'or target.resolve()!=target or temporary.resolve()!=temporary \
       or not stat.S_ISDIR(anchor.st_mode)or not stat.S_ISDIR(scratch.st_mode)or anchor.st_uid!=os.getuid()or scratch.st_uid!=os.getuid():raise RuntimeError('Owned compiler roots required')
    for attempt in range(3):
        try:
            audit();profile_audit()
            if RELEASE:
                from distribution.traverse_packet import audit as release_audit
                release_audit()
            return attempt
        except FileNotFoundError as error:
            missing=Path(error.filename or '')
            current=target.lstat();current_scratch=temporary.lstat()
            generated_target=missing!=target and missing.is_relative_to(target)
            assembly=missing.parent==temporary and re.fullmatch(r'[A-Za-z0-9_.-]{1,96}-[0-9a-f]{6}\.s',missing.name)is not None
            if child.poll()is not None or target.resolve()!=target or (anchor.st_dev,anchor.st_ino)!=(current.st_dev,current.st_ino) \
               or temporary.resolve()!=temporary or (scratch.st_dev,scratch.st_ino)!=(current_scratch.st_dev,current_scratch.st_ino) \
               or not(generated_target or assembly)or attempt==2:
                raise
            time.sleep(.01)
def build():
    profile_packet.prepare();profile_packet.directory(OUTPUT);wanted=inputs();cache=OUTPUT/'build.json';binary=OUTPUT/'sftp-metadata-worker'
    if cache.is_file() and not cache.is_symlink() and cache.stat().st_size<MIB:
        saved=json.loads(cache.read_bytes())
        if saved.get('inputs')==wanted and binary.is_file() and not binary.is_symlink() and binary.stat().st_nlink==1 and binary.stat().st_size<=8*MIB and saved.get('sha256')==digest(binary):
            if 'TRAVERSE_COMPLETION_HELPER_CASE_ID' in os.environ:
                audit();profile_audit()
            if RELEASE:helper_symbols.validate(binary,binary.with_name(binary.name+'.dSYM'))
            return binary
    label=str(time.time_ns());log=OUTPUT/('build-'+label+'.log')
    with log.open('xb') as output:
        env=profile_packet.rust_environment(OUTPUT);env['SDKROOT']=wanted['sdk']
        if RELEASE:
            # Reuse the release cache recognized by the shared symbol policy.
            # Registry/toolchain and all existing storage bounds stay unchanged.
            env['CARGO_TARGET_DIR']=str(profile_packet.directory(RELEASE_TOOLING/'rust-sftp'))
            env['CARGO_PROFILE_RELEASE_DEBUG']='line-tables-only'
            env['CARGO_PROFILE_RELEASE_SPLIT_DEBUGINFO']='packed'
            helper_symbols.apply_cargo_rust_source_path_policy(env, RELEASE)
        child=subprocess.Popen([str(TOOLCHAIN/'bin/cargo'),'build','--manifest-path',str(PROJECT/'Cargo.toml'),'--release','--locked','--offline','--features',','.join(FEATURES),'--bin','catalog_worker'],
            cwd=REPO,env=env,stdin=subprocess.DEVNULL,stdout=output,stderr=subprocess.STDOUT,start_new_session=True)
        began=time.monotonic()
        try:
            while child.poll() is None:
                if time.monotonic()-began>180 or log.stat().st_size>MIB:raise RuntimeError('Bounded ordinary SFTP build')
                compilation_audit(child,Path(env['CARGO_TARGET_DIR']),Path(env['TMPDIR']))
                time.sleep(.5)
            if child.returncode:raise RuntimeError('Ordinary SFTP build failed; inspect its owned log')
        finally:
            if child.poll() is None:
                os.killpg(child.pid,15)
                try:child.wait(timeout=3)
                except subprocess.TimeoutExpired:os.killpg(child.pid,9);child.wait(timeout=3)
    source=(RELEASE_TOOLING/'rust-sftp/release/catalog_worker')if RELEASE else profile_packet.TOOLING/'target/release/catalog_worker'
    if source.is_symlink() or not source.is_file() or source.stat().st_nlink!=1 or source.stat().st_size>8*MIB:raise RuntimeError('Ordinary SFTP binary bound')
    if binary.is_symlink() or binary.exists() and (not binary.is_file() or binary.stat().st_nlink!=1):raise RuntimeError('Ordinary SFTP cache target')
    shutil.copyfile(source,binary);binary.chmod(0o755)
    if RELEASE:helper_symbols.copy_bundle(source,helper_symbols.cargo_bundle(source),binary,binary.with_name(binary.name+'.dSYM'))
    if inputs()!=wanted:raise RuntimeError('SFTP source changed during compilation')
    value=dict(inputs=wanted,sha256=digest(binary));stage=cache.with_name('build-'+label+'.json')
    with stage.open('x') as stream:json.dump(value,stream,sort_keys=True,indent=2);stream.write('\n');stream.flush();os.fsync(stream.fileno())
    stage.replace(cache);audit();profile_audit();return binary
def embed(app):
    if app.resolve()!=app or not app.is_relative_to(REPO/'.build') or app.suffix!='.app':raise RuntimeError('SFTP product must stay in the isolated repo build root')
    for directory_path in [app,app/'Contents',app/'Contents/Helpers',app/'Contents/Resources']:
        if directory_path.is_symlink():raise RuntimeError('Redirected SFTP product directory')
        if directory_path.exists() and (not directory_path.is_dir() or directory_path.stat().st_uid!=os.getuid()):raise RuntimeError('Unowned SFTP product directory')
    parent=os.environ.get('PRODUCT_BUNDLE_IDENTIFIER')
    info_path=app/'Contents/Info.plist'
    if info_path.is_file() and plistlib.loads(info_path.read_bytes()).get('CFBundleIdentifier')!=parent:raise RuntimeError('SFTP product identity differs from Xcode configuration')
    from distribution import store_helpers
    store=parent==store_helpers.PARENT
    qa_case=remote_editor_qa.admitted_build(os.environ)
    if not store and not qa_case and parent!='local.macexplorer.development':raise RuntimeError('Separate reviewed SFTP distribution identity required')
    identity=store_helpers.configuration(app,os.environ) if store else remote_editor_qa.signer(qa_case)[0] if qa_case else os.environ.get('EXPANDED_CODE_SIGN_IDENTITY')
    if not identity:raise RuntimeError('Explicit Xcode signing identity required')
    team=os.environ.get('DEVELOPMENT_TEAM','') if identity!='-' else 'adhoc'
    if team!='adhoc' and (len(team)!=10 or not team.isascii() or not team.isalnum() or team!=team.upper()):raise RuntimeError('Configured signing team required')
    helper=app/'Contents/Helpers/sftp-metadata-worker';helper.parent.mkdir(exist_ok=True)
    arguments=['/usr/bin/codesign','--force','--sign',identity,'--timestamp=none','--identifier',store_helpers.IDENTIFIERS['sftp']if store else remote_editor_qa.ROLE_IDENTIFIERS['sftp']if qa_case else IDENTIFIER]
    if store or qa_case:arguments+=['--options','runtime']
    if os.environ.get('ENABLE_APP_SANDBOX')=='YES':arguments+=['--entitlements',str(REPO/'Distribution/HelperInherit.entitlements')]
    env=os.environ.copy();env.pop('CFFIXED_USER_HOME',None)
    if env.get('HOME')==str(REPO/'.build/xcode-user'):env.pop('HOME')
    source=build()
    publish(source,helper,staging_root=app.parent/'.mac-explorer-helper-staging',signing_arguments=arguments,signing_environment=env,strip_debug=RELEASE)
    helper_symbols.publish_for_xcode(source,helper,os.environ)
    manifest=app/'Contents/Resources/SFTPHelperManifest.plist'
    if manifest.is_symlink() or manifest.exists() and (not manifest.is_file() or manifest.stat().st_nlink!=1 or manifest.stat().st_uid!=os.getuid()):raise RuntimeError('Unsafe SFTP manifest target')
    if store:store_helpers.write_manifest(app,{'sftp':helper})
    elif qa_case:remote_editor_qa.write_manifest(app,{'sftp':helper},qa_case)
    else:manifest.write_bytes(plistlib.dumps(dict(version=1,channel='development',parentIdentifier=parent,teamIdentifier=team,
        roles={'sftp':dict(identifier=IDENTIFIER,sha256=digest(helper))}),sort_keys=False))
    print('Bundled signed SFTP catalog/explicit-transfer worker; native activation separately gated')
def main():
    parser=argparse.ArgumentParser();parser.add_argument('--embed',type=Path);args=parser.parse_args();directory(OUTPUT)
    descriptor=os.open(OUTPUT/'build.lock',os.O_RDWR|os.O_CREAT|os.O_CLOEXEC|os.O_NOFOLLOW,0o600)
    try:
        facts=os.fstat(descriptor)
        if not stat.S_ISREG(facts.st_mode) or facts.st_nlink!=1 or facts.st_uid!=os.getuid() or facts.st_mode&0o077:raise RuntimeError('SFTP helper build lock')
        fcntl.flock(descriptor,fcntl.LOCK_EX)
        current=(OUTPUT/'build.lock').lstat()
        if (facts.st_dev,facts.st_ino)!=(current.st_dev,current.st_ino):raise RuntimeError('SFTP helper lock changed while waiting')
        if args.embed:embed(args.embed.absolute())
        else:print(json.dumps(dict(binary=str(build().relative_to(REPO)))))
    finally:os.close(descriptor)
if __name__=='__main__':main()
