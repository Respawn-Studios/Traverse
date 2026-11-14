#!/usr/bin/env python3
"""Build/inspect an isolated local-only sandbox app. Launch needs owner exception."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tarfile
import time
import uuid

sys.dont_write_bytecode=True
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
import dev
import development as d
from distribution.packet import ROOT,TOOLING,REPO,MIB,directory,put,measure,audit,reserve
from distribution.preflight import entitlements,signing,read,health_role_requirement
from qualify_foundation import wait_generated
from build_storage_worker import EDITOR_RELEASE_PREFIX,sandbox_foundation_case

IDENTIFIER='local.macexplorer.sandbox.qualification'
QUARANTINE_CASE='82F3B737-D52C-411E-8823-FE6BB7DCA884'
EDITOR_RELEASE_NAME='Traverse Local Editor Sandbox Review (Generated)'
REMOTE_EDITOR_RELEASE_NAME='Traverse SFTP Editor Sandbox Review (Generated)'
EDITOR_RELEASE_PARENT_RIGHTS={
    'com.apple.security.app-sandbox':True,
    'com.apple.security.files.user-selected.read-write':True,
    'com.apple.security.files.bookmarks.app-scope':True,
    'com.apple.security.network.client':True}
# Includes the current app and its matching Release symbols. Source/evidence
# and the existing development aggregate remain independently bounded.
EDITOR_RELEASE_CASE_BYTES=256*MIB
EDITOR_RELEASE_CASE_ENTRIES=2048
EDITOR_RELEASE_TOOLING_BYTES=4*1024*MIB
REMOTE_EDITOR_HELPER_NAMES=frozenset({'storage-scanner-worker','smb-browser-worker',
    'smb-resolver-worker','sftp-metadata-worker'})


class EditorReleaseResourceLimit(RuntimeError):
    def __init__(self,usage):
        super().__init__('Editor Release generated case allowance exceeded')
        self.usage=usage


def editor_release_audit(case):
    current=d.audit()
    # Match the shared release cache policy: Xcode's sparse address-space maps
    # have large logical lengths without occupying those bytes on disk. Retain
    # both measurements, charge allocation here, and keep the generated case,
    # source and evidence logical limits below unchanged.
    from distribution import remote_editor_qa
    shared=remote_editor_qa.STAGING_PRODUCT
    if shared.is_symlink():raise RuntimeError('Redirected shared Release products')
    products=measure(shared) if shared.exists() else dict(bytes=0,allocatedBytes=0,entries=0)
    charged=current['chargedToolingAllocatedBytes']+products['allocatedBytes']
    current.update(sharedReleaseProducts=products,chargedToolingAndProductsAllocatedBytes=charged)
    if charged>EDITOR_RELEASE_TOOLING_BYTES:
        raise EditorReleaseResourceLimit(dict(tooling=current['tooling'],
            sharedCompilerCaches=current['sharedCompilerCaches'],sharedReleaseProducts=products,
            chargedToolingAndProductsAllocatedBytes=charged))
    found=measure(case)
    source=measure(case/'source')
    evidence=measure(case/'evidence')
    if found['bytes']>EDITOR_RELEASE_CASE_BYTES or found['entries']>EDITOR_RELEASE_CASE_ENTRIES \
            or source['bytes']>4*MIB or evidence['bytes']>16*MIB:
        raise EditorReleaseResourceLimit(dict(case=found,source=source,evidence=evidence))
    current['editorReleaseCase']=found
    return current


def scope_audit(case,editor_release):
    return editor_release_audit(case) if editor_release else audit()


def live_build_audit(case,editor_release):
    # Signing and compiler publication atomically replace owned outputs. Retry
    # the entire snapshot, never omit an entry or retry a real quota refusal.
    for attempt in range(3):
        try:return scope_audit(case,editor_release)
        except FileNotFoundError as error:
            missing=Path(error.filename or '')
            from distribution import remote_editor_qa
            if attempt==2 or not any(missing.is_relative_to(root) for root in
                    [case/'Products',d.TOOLING,remote_editor_qa.STAGING_PRODUCT]):
                raise
            time.sleep(.02)


def complete_build_receipt(receipt, *, case, editor_release, actual_exit, elapsed, failure_detail=None):
    """Persist the build's original outcome even when its final audit refuses."""
    result = dict(receipt, actualBuildExit=actual_exit, elapsedSeconds=elapsed)
    if failure_detail is not None:
        result['resourceAuditFailure'] = failure_detail
    try:
        result['packet'] = scope_audit(case, editor_release)
    except Exception as error:
        result['passed'] = False
        result.setdefault('failure', 'Generated build resource audit failed')
        result['packet'] = dict(complete=False)
        details = dict(type=type(error).__name__)
        if isinstance(error, EditorReleaseResourceLimit):
            details['usage'] = error.usage
        result['finalResourceAuditFailure'] = details
    return result


def editor_release_artifacts(product):
    """Only this app and its declared helper symbols; leave other symbols alone."""
    from distribution import helper_symbols
    app=product/'Mac Explorer.app'
    info=plistlib.loads(read(app/'Contents/Info.plist',128*1024))
    helpers=set(REMOTE_EDITOR_HELPER_NAMES)
    if helper_symbols.health_declared(info):helpers.add(helper_symbols.HEALTH_HELPER)
    if helper_symbols.health_service_declared(info):helpers.add(helper_symbols.HEALTH_SERVICE_EXECUTABLE)
    names={'Mac Explorer.app.dSYM'}|{name+'.dSYM' for name in helpers}
    return [app]+[product/name for name in sorted(names)]


def remote_editor_case(case):
    from distribution import remote_editor_qa
    return json.loads((case/'reservation.json').read_bytes()).get('action') in (
        remote_editor_qa.ACTION, remote_editor_qa.DEVELOPER_ID_ACTION)


def remote_editor_developer_id_case(case):
    from distribution import remote_editor_qa
    return json.loads((case/'reservation.json').read_bytes()).get('action') == remote_editor_qa.DEVELOPER_ID_ACTION


def editor_release_identifier(case):
    if remote_editor_case(case):
        from distribution import remote_editor_qa
        return remote_editor_qa.identifier(case.name)
    return EDITOR_RELEASE_PREFIX+case.name.lower().replace('-','')


def editor_release_env(case):
    values=dict(MAC_EXPLORER_SANDBOX_EDITOR_RELEASE_CASE=case.name,
        PRODUCT_BUNDLE_IDENTIFIER=editor_release_identifier(case),CONFIGURATION='Release',
        TARGET_BUILD_DIR=str(case/'Products/Release'),CONTENTS_FOLDER_PATH='Mac Explorer.app/Contents',
        ENABLE_APP_SANDBOX='YES')
    if remote_editor_case(case):
        from distribution import remote_editor_qa
        identity, team = remote_editor_qa.signer(case)
        values.pop('MAC_EXPLORER_SANDBOX_EDITOR_RELEASE_CASE')
        values.update({remote_editor_qa.CASE_ENV:case.name,
            'SWIFT_ACTIVE_COMPILATION_CONDITIONS':remote_editor_qa.compilation_conditions(case),
            'MAC_EXPLORER_DISTRIBUTION_CHANNEL':remote_editor_qa.CHANNEL,
            'MAC_EXPLORER_ACCESS_POLICY':'sandbox-selected-v1',
            'ENABLE_HARDENED_RUNTIME':'YES',
            'DEVELOPMENT_TEAM':'' if team == 'adhoc' else team,
            'EXPANDED_CODE_SIGN_IDENTITY':identity})
    return values


def admitted(text,editor_release=False):
    if str(uuid.UUID(text)).upper()!=text:raise RuntimeError('Canonical sandbox case required')
    case=(d.ROOT if editor_release else ROOT)/text
    expected='traverse-development-v1' if editor_release else 'sandbox-foundation-v1'
    if case.resolve()!=case or not (case/'reservation.json').is_file() \
            or json.loads((case/'reservation.json').read_bytes()).get('packet')!=expected:
        raise RuntimeError('Reserved sandbox case required')
    if editor_release and json.loads((case/'reservation.json').read_bytes()).get('action') not in [
            'sandbox-editor-release','sandbox-remote-editor-release','sandbox-remote-editor-developer-id']:
        raise RuntimeError('Editor Release case action required')
    if editor_release:
        if remote_editor_case(case):
            from distribution import remote_editor_qa
            accepted=remote_editor_qa.admitted_build(editor_release_env(case))
        else:accepted=sandbox_foundation_case(editor_release_env(case))
        if accepted!=case:raise RuntimeError('Editor Release purpose admission required')
    scope_audit(case,editor_release);return case


def app(case,editor_release=False):return case/('Products/Release' if editor_release else 'Products/Debug')/'Mac Explorer.app'


def inspect(case,editor_release=False):
    bundle=app(case,editor_release)
    subprocess.run(['/usr/bin/codesign','--verify','--strict','--deep',str(bundle)],check=True,capture_output=True,timeout=30)
    expected=plistlib.loads((REPO/'Distribution/AppStoreParent.entitlements').read_bytes())
    parent=entitlements(bundle)
    child=bundle/'Contents/Helpers/storage-scanner-worker'
    rights=entitlements(child)
    info=plistlib.loads((bundle/'Contents/Info.plist').read_bytes())
    if editor_release and remote_editor_case(case):
        from distribution import remote_editor_qa
        _, qa_team = remote_editor_qa.signer(case)
    else:
        qa_team = 'adhoc'
    parent_signing=signing(bundle)
    expected_adhoc=qa_team == 'adhoc'
    checks=dict(exactParent=parent==expected,inheritingChild=rights=={'com.apple.security.app-sandbox':True,'com.apple.security.inherit':True},
        hardenedRuntime=parent_signing['runtime'],
        caseSigner=(parent_signing['TeamIdentifier'] in [None,'not set'] if expected_adhoc else
            parent_signing['TeamIdentifier']==qa_team and bool(parent_signing['authorities'])
            and parent_signing['authorities'][0].startswith('Developer ID Application: ')),
        caseIdentity=info.get('CFBundleIdentifier')==(editor_release_identifier(case) if editor_release else IDENTIFIER)
            and info.get('MacExplorerSandboxQualificationCase')==case.name,
        portable=info.get('MacExplorerStorageMode')=='portable',noNetworkWorkers=sorted(p.name for p in child.parent.iterdir())==['storage-scanner-worker'],
        noDebugShim=not (bundle/'Contents/MacOS/Mac Explorer.debug.dylib').exists())
    if editor_release:
        name=REMOTE_EDITOR_RELEASE_NAME if remote_editor_case(case) else EDITOR_RELEASE_NAME
        checks.update(exactFourRightPolicy=expected==EDITOR_RELEASE_PARENT_RIGHTS,
            scannerFile=child.is_file() and not child.is_symlink() and child.stat().st_nlink==1,
            reviewName=info.get('CFBundleDisplayName')==name
            and info.get('CFBundleName')==name,
            noDocumentOrURLRegistration='CFBundleDocumentTypes' not in info and 'CFBundleURLTypes' not in info)
        if remote_editor_case(case):
            from distribution import remote_editor_qa,store_helpers,helper_symbols
            expected_helpers=set(REMOTE_EDITOR_HELPER_NAMES)
            try:
                health=helper_symbols.health_declared(info)
                health_service=helper_symbols.health_service_declared(info)
                checks['healthDeclaration']=True
            except ValueError:
                health=False;health_service=False;checks['healthDeclaration']=False
            if health:expected_helpers.add(helper_symbols.HEALTH_HELPER)
            checks.pop('noNetworkWorkers')
            checks['exactHelperFamily']=set(p.name for p in child.parent.iterdir())==expected_helpers
            checks['qaChannel']=info.get('MacExplorerDistributionChannel')==remote_editor_qa.CHANNEL
            checks['qaPolicy']=info.get('MacExplorerAccessPolicy')=='sandbox-selected-v1'
            for helper_name in expected_helpers:
                helper=child.parent/helper_name
                facts=signing(helper)
                checks[helper_name+'-inherit']=entitlements(helper)=={'com.apple.security.app-sandbox':True,'com.apple.security.inherit':True}
                checks[helper_name+'-runtime']=facts['runtime'] and (
                    facts['TeamIdentifier'] in [None,'not set'] if expected_adhoc else
                    facts['TeamIdentifier']==qa_team and bool(facts['authorities'])
                    and facts['authorities'][0].startswith('Developer ID Application: '))
                checks[helper_name+'-file']=helper.is_file() and not helper.is_symlink() and helper.stat().st_nlink==1
            for role,name in [('browser','smb-browser-worker'),('resolver','smb-resolver-worker'),('sftp','sftp-metadata-worker')]:
                checks[role+'-identifier']=signing(child.parent/name)['Identifier']==store_helpers.IDENTIFIERS[role]
            for manifest_name,roles in [('SMBHelperManifest.plist',{'browser':'smb-browser-worker','resolver':'smb-resolver-worker'}),
                    ('SFTPHelperManifest.plist',{'sftp':'sftp-metadata-worker'})]:
                manifest=bundle/'Contents/Resources'/manifest_name
                fields=plistlib.loads(manifest.read_bytes())
                expected_manifest=dict(version=1,channel=remote_editor_qa.CHANNEL,
                    parentIdentifier=editor_release_identifier(case),teamIdentifier=qa_team,case=case.name,
                    roles={role:dict(identifier=store_helpers.IDENTIFIERS[role],
                        sha256=hashlib.sha256((child.parent/name).read_bytes()).hexdigest()) for role,name in roles.items()})
                checks[manifest_name+'-binding']=not manifest.is_symlink() and fields==expected_manifest
            if health:
                health_file=child.parent/helper_symbols.HEALTH_HELPER
                health_manifest=bundle/'Contents/Resources/DriveHealthHelperManifest.plist'
                fields=plistlib.loads(read(health_manifest,4096))
                expected_health=dict(format='drive-health-inherited-v2',parentIdentifier=editor_release_identifier(case),
                    helperIdentifier=editor_release_identifier(case)+'.drive.health',teamIdentifier=qa_team,
                    channel=remote_editor_qa.CHANNEL,accessPolicy='sandbox-selected-v1',reviewCase=case.name,
                    sha256=hashlib.sha256(read(health_file,4*MIB)).hexdigest())
                checks['healthManifestBinding']=fields==expected_health
                checks['healthIdentifier']=signing(health_file)['Identifier']==expected_health['helperIdentifier']
                symbols=bundle.parent/(helper_symbols.HEALTH_HELPER+'.dSYM')
                checks['healthMatchingSymbols']=helper_symbols.validate(health_file,symbols)['hasCompileUnits']
            service=bundle/'Contents/XPCServices'/helper_symbols.HEALTH_SERVICE_LEAF
            service_manifest=bundle/'Contents/Resources/DriveHealthServiceManifest.plist'
            checks['noUndeclaredHealthService']=health_service or not any(
                path.exists()or path.is_symlink()for path in [service,service_manifest])
            if health_service:
                from distribution import preflight
                old_manifest=bundle/'Contents/Resources/DriveHealthHelperManifest.plist'
                checks['healthServiceNoWorkerManifest']=not old_manifest.exists() and not old_manifest.is_symlink()
                service_id=editor_release_identifier(case)+'.drive.health.xpc'
                executable=service/'Contents/MacOS'/helper_symbols.HEALTH_SERVICE_EXECUTABLE
                service_info=plistlib.loads(read(service/'Contents/Info.plist',4096))
                signed=signing(service)
                fields=plistlib.loads(read(service_manifest,4096))
                expected_info=dict(CFBundleIdentifier=service_id,
                    CFBundleExecutable=helper_symbols.HEALTH_SERVICE_EXECUTABLE,
                    CFBundlePackageType='XPC!',CFBundleShortVersionString='1.0',CFBundleVersion='1',
                    LSMinimumSystemVersion='15.0',
                    XPCService=dict(ServiceType='Application',RunLoopType='dispatch_main'))
                expected_manifest=dict(format='drive-health-xpc-qa-v1',
                    parentIdentifier=editor_release_identifier(case),serviceIdentifier=service_id,
                    teamIdentifier=qa_team,channel=remote_editor_qa.CHANNEL,
                    accessPolicy='sandbox-selected-v1',reviewCase=case.name,
                    parentRequirement=health_role_requirement(editor_release_identifier(case),qa_team),
                    sha256=hashlib.sha256(read(executable,4*MIB)).hexdigest(),
                    serviceCDHash=signed['cdhash'])
                checks['healthServiceFamily']=not service.is_symlink() and service.resolve()==service \
                    and set(p.name for p in service.parent.iterdir())=={helper_symbols.HEALTH_SERVICE_LEAF}
                checks['healthServiceInfo']=service_info==expected_info
                checks['healthServiceManifest']=fields==expected_manifest and not service_manifest.is_symlink()
                checks['healthServiceSignature']=signed['Identifier']==service_id \
                    and signed['TeamIdentifier']==qa_team and signed['runtime'] \
                    and bool(signed['authorities']) and signed['authorities'][0].startswith('Developer ID Application: ') \
                    and entitlements(service)=={} and executable.is_file() and not executable.is_symlink() \
                    and executable.stat().st_nlink==1 \
                    and preflight.command(['/usr/bin/codesign','--verify','--strict',str(service)]).returncode==0
                symbols=bundle.parent/(helper_symbols.HEALTH_SERVICE_EXECUTABLE+'.dSYM')
                checks['healthServiceMatchingSymbols']=helper_symbols.validate(executable,symbols)['hasCompileUnits']
    return dict(passed=all(checks.values()),checks=checks,actualSandboxLaunch=False,testFlightQualified=False)


def guard_controls(case):
    env=dict(MAC_EXPLORER_SANDBOX_FOUNDATION_CASE=case.name,PRODUCT_BUNDLE_IDENTIFIER=IDENTIFIER,
        TARGET_BUILD_DIR=str(case/'Products/Debug'),CONTENTS_FOLDER_PATH='Mac Explorer.app/Contents',ENABLE_APP_SANDBOX='YES')
    assert sandbox_foundation_case(env)==case
    assert sandbox_foundation_case({}) is None
    changed=[{'MAC_EXPLORER_SANDBOX_FOUNDATION_CASE':''},{'MAC_EXPLORER_SANDBOX_FOUNDATION_CASE':case.name.lower()},
        {'TARGET_BUILD_DIR':str(REPO/'.build/xcode/Build/Products/Debug')},{'PRODUCT_BUNDLE_IDENTIFIER':'local.macexplorer.development'},
        {'ENABLE_APP_SANDBOX':'NO'},{'CONTENTS_FOLDER_PATH':'Other.app/Contents'}]
    for update in changed:
        try:sandbox_foundation_case({**env,**update})
        except ValueError:pass
        else:raise RuntimeError('Sandbox build guard accepted a mismatched case/output/policy')
    put(case/'evidence/build-guards.json',dict(passed=True,controls=8,noAppLaunch=True))


def editor_release_guard_controls(case):
    env=editor_release_env(case)
    assert sandbox_foundation_case(env)==case
    changed=[{'MAC_EXPLORER_SANDBOX_EDITOR_RELEASE_CASE':''},
        {'MAC_EXPLORER_SANDBOX_EDITOR_RELEASE_CASE':case.name.lower()},
        {'MAC_EXPLORER_SANDBOX_FOUNDATION_CASE':case.name},
        {'PRODUCT_BUNDLE_IDENTIFIER':IDENTIFIER},
        {'CONFIGURATION':'Debug'},
        {'TARGET_BUILD_DIR':str(case/'Products/Debug')},
        {'CONTENTS_FOLDER_PATH':'Other.app/Contents'},
        {'ENABLE_APP_SANDBOX':'NO'}]
    for update in changed:
        try:sandbox_foundation_case({**env,**update})
        except ValueError:pass
        else:raise RuntimeError('Editor Release build guard accepted a mismatched case/output/policy')
    put(case/'evidence/editor-release-build-guards.json',dict(passed=True,controls=len(changed)+1,noAppLaunch=True))


def quarantine_repair(case):
    if case.name!=QUARANTINE_CASE:
        raise RuntimeError('The quarantine repair is limited to its retained generated case')
    authority=case/'evidence/quarantine-repair-admission.json'
    reconciliation=case/'evidence/inspection-reopen-reconciliation.json'
    if not authority.is_file() or not reconciliation.is_file() \
            or json.loads(authority.read_bytes()).get('aggregateLaunchCeiling')!=8 \
            or json.loads(reconciliation.read_bytes()).get('exactGeneratedProcessNoLongerRunning') is not True:
        raise RuntimeError('Exact repair authority and preceding cleanup are required')
    # Read process facts only. Never stop a shared or unexpectedly reopened app.
    processes=subprocess.check_output(['/bin/ps','-axo','args='],text=True,timeout=10).splitlines()
    owned=str(case)+'/'
    if any(line.startswith(owned) and '/Contents/MacOS/Mac Explorer' in line for line in processes):
        raise RuntimeError('The prior generated artifact still has a live process')


def compiled_tree_receipt(bundle):
    digest=hashlib.sha256();files=0
    for path in sorted(bundle.rglob('*')):
        relative=str(path.relative_to(bundle));digest.update(relative.encode()+b'\0')
        if path.is_symlink():digest.update(b'L'+os.readlink(path).encode())
        elif path.is_file():
            digest.update(b'F')
            with path.open('rb') as source:
                for block in iter(lambda:source.read(1024*1024),b''):digest.update(block)
            files+=1
        elif path.is_dir():digest.update(b'D')
        else:raise RuntimeError('Unexpected object in generated sealed artifact')
    return dict(treeSHA256=digest.hexdigest(),regularFiles=files,preserved=True)


def seal_receipt(bundle):
    subprocess.run(['/usr/bin/codesign','--verify','--strict','--deep',str(bundle)],check=True,capture_output=True,timeout=30)
    return dict(**compiled_tree_receipt(bundle),signature=signing(bundle))


def local_features(case):
    quarantine_repair(case)
    admission=case/'evidence/local-feature-admission.json'
    if not admission.is_file() or admission.is_symlink():raise RuntimeError('Generated local feature admission required')
    found=json.loads(admission.read_bytes())
    if found.get('packet')!='sandbox-local-feature-v1' or found.get('ownerExtendedAuthority') is not True \
            or found.get('aggregateLaunchCeiling')!=10:raise RuntimeError('Local feature scope differs')


def preserve_editor_release_products(case,attempt):
    """Keep the failing artifact without retaining another loose product tree."""
    processes=subprocess.check_output(['/bin/ps','-axo','args='],text=True,timeout=10).splitlines()
    if any(line.startswith(str(case)+'/') and '/Contents/MacOS/Mac Explorer' in line for line in processes):
        raise RuntimeError('Close the generated editor before replacing its artifact')
    products=case/'Products'
    if products.is_symlink() or not products.is_dir() or products.stat().st_uid!=os.getuid():
        raise RuntimeError('Only the owned generated Products tree can be retained')
    previous=case/'evidence'/('build-result-editor-release'+('' if attempt==2 else '-'+str(attempt-1))+'.json')
    outcome=json.loads(previous.read_bytes()) if previous.is_file() else {}
    failed_compile=remote_editor_case(case) and outcome.get('passed') is False \
        and isinstance(outcome.get('actualBuildExit'),int) and outcome['actualBuildExit']!=0
    if failed_compile:
        # A failed build need not have a valid enclosing seal to preserve.
        # Keep and verify its exact compiled tree; never relabel it qualified.
        before=compiled_tree_receipt(products)
    else:
        if not inspect(case,editor_release=True)['passed']:
            raise RuntimeError('The prior editor artifact must still pass inspection')
        before=seal_receipt(app(case,editor_release=True))
    retention=directory(d.ROOT/'retained-compiled-products'/case.name) if remote_editor_case(case) else case
    archive=retention/f'retained-editor-release-{attempt-1}.tar.gz'
    with archive.open('xb') as output,tarfile.open(fileobj=output,mode='w:gz') as retained:
        retained.add(products,arcname='Products')
    # Verify every archived object before disposing only these superseded,
    # owned compiled outputs. Generated documents and recovery are elsewhere.
    with tarfile.open(archive,'r:gz') as retained:
        for member in retained:
            path=case/member.name
            if not path.is_relative_to(products) or '..' in Path(member.name).parts:
                raise RuntimeError('Unexpected retained product path')
            if member.issym():
                if not path.is_symlink() or os.readlink(path)!=member.linkname:
                    raise RuntimeError('Retained product symlink differs')
            elif member.isdir():
                if path.is_symlink() or not path.is_dir():raise RuntimeError('Retained product directory differs')
            elif member.isfile():
                if path.is_symlink() or not path.is_file() or path.stat().st_size!=member.size:
                    raise RuntimeError('Retained product file differs')
                archived=hashlib.sha256();current=hashlib.sha256()
                with retained.extractfile(member) as source:
                    for block in iter(lambda:source.read(1024*1024),b''):archived.update(block)
                with path.open('rb') as source:
                    for block in iter(lambda:source.read(1024*1024),b''):current.update(block)
                if archived.digest()!=current.digest():raise RuntimeError('Retained product bytes differ')
            else:raise RuntimeError('Unsupported retained product object')
    editor_release_audit(case)
    current=compiled_tree_receipt(products) if failed_compile else seal_receipt(app(case,editor_release=True))
    if current!=before:
        raise RuntimeError('Editor artifact changed while retaining it')
    put(case/f'evidence/retained-editor-release-{attempt-1}.json',dict(
        artifact=before,archive=str(archive.relative_to(REPO)) if remote_editor_case(case) else archive.name,
        archiveRelativeToRepository=remote_editor_case(case),archiveSHA256=hashlib.sha256(archive.read_bytes()).hexdigest(),
        archivedObjectsVerified=True,generatedRecoveryUntouched=True,
        failedBuildWithoutQualifiedSeal=failed_compile,
        unlaunchedFailedBuild=failed_compile and not list((case/'evidence').glob('launch-*.json'))))
    shutil.rmtree(products)


def build(case=None,repair=False,features=False,editor_release=False,remote_editor_release=False,
          developer_id=False,new_case=None):
    if remote_editor_release:editor_release=True
    if remote_editor_release:
        dev.execute([sys.executable, '-B', str(REPO/'tools/smb_reader/vendor_verified_source.py')],
                    'verify-network-provenance', timeout=30, tooling=False)
    if new_case is not None:
        if not remote_editor_release or case is not None or repair or features \
                or str(uuid.UUID(new_case)).upper()!=new_case:
            raise RuntimeError('A fresh canonical case is only available for a new remote-editor build')
        selected_case=d.ROOT/new_case
        if selected_case.exists() or selected_case.is_symlink() or selected_case.resolve()!=selected_case:
            raise RuntimeError('A new case cannot reuse or redirect an existing generated root')
    if developer_id and not remote_editor_release:
        raise RuntimeError('Developer ID QA requires the exact remote editor Release purpose')
    if developer_id:
        from distribution import remote_editor_qa
        selected_identity=remote_editor_qa.available_developer_id_identity()
        if case is not None and remote_editor_qa.signer(case)!=(selected_identity,remote_editor_qa.DEVELOPER_ID_TEAM):
            raise RuntimeError('Configured Developer ID identity differs from the admitted case')
    if editor_release and (repair or features):
        raise RuntimeError('Editor Release preparation cannot use a legacy repair mode')
    if features:
        if case is None:raise RuntimeError('Local feature packet cannot create another case')
        local_features(case);repair=True
    if repair and case is None:raise RuntimeError('Repair cannot create another sandbox case')
    fresh=case is None
    if fresh:
        if editor_release:
            dev.check_source_backups()
            d.audit()
            if new_case is not None:
                # Exclusive creation preserves --case as the sole resume path.
                # All remaining setup is the existing fresh build path below.
                dev.local_directory('traverse-development')
                case=selected_case
                case.mkdir(mode=0o700)
            else:
                case=dev.local_directory('traverse-development/'+str(uuid.uuid4()).upper())
            case.chmod(0o700)
            d.put(case/'reservation.json',dict(packet='traverse-development-v1',
                action=remote_editor_qa.DEVELOPER_ID_ACTION if developer_id else
                    'sandbox-remote-editor-release' if remote_editor_release else 'sandbox-editor-release'))
        else:case=reserve()
        directory(case/'evidence');directory(case/'source')
        source=directory(case/'source/Scan Root');directory(source/'Nested')
        operations=directory(case/'source/Operation Root')
        (source/'Generated.txt').write_text('Only generated sandbox Copy bytes.\n')
        (source/'Generated.swift').write_text('// Generated sandbox metadata fixture\n')
        (source/'Nested/Nested.txt').write_text('Generated nested metadata\n')
        if editor_release:
            (operations/'Editor.txt').write_text('Generated local editor fixture.\n')
            identifier=editor_release_identifier(case)
            container=Path.home()/'Library/Containers'/identifier
            if container.exists() or container.is_symlink():
                raise RuntimeError('A generated editor review identity already has an OS container')
            admission=dict(packet=remote_editor_qa.DEVELOPER_ID_PACKET if developer_id else
                    'sandbox-remote-editor-release-v1' if remote_editor_release else 'sandbox-editor-release-v1',
                case=case.name,bundleIdentifier=identifier,buildAndInspectOnly=True,
                generatedOperationRoot=str(operations),priorOSContainerAbsent=True)
            if developer_id:
                admission.update(signingIdentity=selected_identity,teamIdentifier=remote_editor_qa.DEVELOPER_ID_TEAM)
            d.put(case/'evidence'/('remote-editor-release-admission.json' if remote_editor_release else 'editor-release-admission.json'),admission)
            if not remote_editor_release:editor_release_guard_controls(case)
        else:guard_controls(case)
        info=plistlib.loads((REPO/'Distribution/Info.plist').read_bytes())
        info['MacExplorerSandboxQualificationCase']=case.name
        if editor_release:
            info.pop('CFBundleDocumentTypes',None);info.pop('CFBundleURLTypes',None)
            name=REMOTE_EDITOR_RELEASE_NAME if remote_editor_release else EDITOR_RELEASE_NAME
            info['CFBundleDisplayName']=name;info['CFBundleName']=name
        if remote_editor_release:
            from distribution import remote_editor_qa
            info['MacExplorerDistributionChannel']=remote_editor_qa.CHANNEL
            info['MacExplorerAccessPolicy']='sandbox-selected-v1'
        with (case/'SandboxInfo.plist').open('xb') as stream:plistlib.dump(info,stream)
        if remote_editor_release:
            if remote_editor_qa.admitted_build(editor_release_env(case))!=case:
                raise RuntimeError('Remote editor Release build admission required')
    elif not editor_release and list((case/'evidence').glob('launch-*.json')):
        if not repair:raise RuntimeError('A launched artifact is never rebuilt')
        quarantine_repair(case)
    # Configurations are immutable attempt markers. Log retention must never
    # rewind numbering and collide with an earlier build or retained product.
    attempts = [int(match.group(1) or 1) for entry in case.iterdir()
        if (match := re.fullmatch(r'Sandbox(?:-editor-release)?(?:-(\d+))?\.xcconfig', entry.name))]
    attempt=max(attempts, default=0)+1
    if not fresh and (case/'Products').exists():
        if editor_release:preserve_editor_release_products(case,attempt)
        else:
            if repair:put(case/f'evidence/retained-seal-{attempt-1}.json',seal_receipt(app(case)))
            (case/'Products').rename(case/f'retained-products-{attempt-1}')
            if repair:
                retained=case/f'retained-products-{attempt-1}/Debug/Mac Explorer.app'
                before=json.loads((case/f'evidence/retained-seal-{attempt-1}.json').read_bytes())
                if seal_receipt(retained)!=before:raise RuntimeError('Retained artifact seal changed during preservation')
    suffix=('-editor-release' if editor_release else '')+('' if attempt==1 else '-'+str(attempt))
    config=case/('Sandbox'+suffix+'.xcconfig')
    with config.open('x') as stream:
        stream.write('#include "'+str(REPO/'Distribution/AppStoreCandidate.xcconfig')+'"\n')
        stream.write('INFOPLIST_FILE = '+str(case/'SandboxInfo.plist')+'\n')
        if not editor_release:stream.write('SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG MAC_EXPLORER_DISTRIBUTION\n')
    if editor_release:
        env=dev.environment()
        packages=dev.local_directory('source-packages')
        package_cache=dev.local_directory('package-cache')
        clang=dev.local_directory('compiler-cache/xcode')
        swift=dev.local_directory('compiler-cache/xcode-swift')
        env.update(CLANG_MODULE_CACHE_PATH=str(clang),SWIFTPM_MODULECACHE_OVERRIDE=str(swift))
    else:
        for leaf in ['user','tmp','derived','packages','package-cache','clang','swift','swiftpm']:
            directory(TOOLING/leaf)
        env=dev.environment()
        env.update(TMPDIR=str(TOOLING/'tmp')+'/',CFFIXED_USER_HOME=str(TOOLING/'user'),
            CLANG_MODULE_CACHE_PATH=str(TOOLING/'clang'),SWIFTPM_MODULECACHE_OVERRIDE=str(TOOLING/'swiftpm'))
        packages=TOOLING/'packages';package_cache=TOOLING/'package-cache'
        clang=TOOLING/'clang';swift=TOOLING/'swift'
    configuration='Release' if editor_release else 'Debug'
    retained_product=case/'Products'/configuration
    # Reuse the ordinary Release products, including package linker objects and
    # modules. Only the sealed app/symbols are retained in the review case.
    if remote_editor_release:
        from distribution import remote_editor_qa
    product=directory(remote_editor_qa.STAGING_PRODUCT) if remote_editor_release else retained_product
    if remote_editor_release:
        from native_build_processes import observation
        if any(Path(row['executable']).is_relative_to(product/'Mac Explorer.app')
                for row in observation().values()):
            raise RuntimeError('Quit the ordinary Release development app before preparing its shared review product')
    identifier=editor_release_identifier(case) if editor_release else IDENTIFIER
    derived=REPO/'.build/xcode-release' if editor_release else TOOLING/'derived'
    qualifier='MAC_EXPLORER_SANDBOX_EDITOR_RELEASE_CASE' if editor_release else 'MAC_EXPLORER_SANDBOX_FOUNDATION_CASE'
    conditions=[] if editor_release else ['SWIFT_ACTIVE_COMPILATION_CONDITIONS=DEBUG MAC_EXPLORER_DISTRIBUTION']
    if remote_editor_release:
        from distribution import remote_editor_qa
        qualifier=remote_editor_qa.CASE_ENV
        conditions=['SWIFT_ACTIVE_COMPILATION_CONDITIONS='+remote_editor_qa.compilation_conditions(case),
            'MAC_EXPLORER_DISTRIBUTION_CHANNEL='+remote_editor_qa.CHANNEL,
            'MAC_EXPLORER_ACCESS_POLICY=sandbox-selected-v1']
    qa_identity, qa_team = remote_editor_qa.signer(case) if remote_editor_release else ('-', 'adhoc')
    command=['/usr/bin/xcodebuild','-project',str(REPO/'MacExplorer.xcodeproj'),'-scheme','MacExplorer','-configuration',configuration,
        '-destination','platform=macOS,arch=arm64','-xcconfig',str(config),
        '-derivedDataPath',str(derived),'-clonedSourcePackagesDirPath',str(packages),
        '-skipPackageUpdates','-disableAutomaticPackageResolution','-disablePackageRepositoryCache',
        '-packageCachePath',str(package_cache),'-packageAuthorizationProvider','netrc','-jobs','4',
        'CODE_SIGN_STYLE=Manual','CODE_SIGN_IDENTITY='+qa_identity,
        'DEVELOPMENT_TEAM='+('' if qa_team == 'adhoc' else qa_team),
        'CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO',
        *(['MAC_EXPLORER_HELPER_OUTPUT_PROFILE=local-only'] if not remote_editor_release else []),
        *(['OTHER_CODE_SIGN_FLAGS=--timestamp=none'] if developer_id else []),
        # Hardened ad-hoc QA cannot load Xcode's separately ad-hoc signed Debug
        # shim. Link the DEBUG hooks into the main executable instead; never
        # disable library validation or broaden sandbox rights for this test.
        'ENABLE_DEBUG_DYLIB=NO',
        'PRODUCT_BUNDLE_IDENTIFIER='+identifier,'CONFIGURATION_BUILD_DIR='+str(product),
        'INFOPLIST_FILE='+str(case/'SandboxInfo.plist'),*conditions,
        qualifier+'='+case.name,'MAC_EXPLORER_DISTRIBUTION_COPYRIGHT=Generated qualification only',
        'SWIFT_TREAT_WARNINGS_AS_ERRORS=YES','OTHER_SWIFT_FLAGS=$(inherited) -j4 -driver-batch-count 4',
        'CLANG_MODULE_CACHE_PATH='+str(clang),'SWIFT_MODULE_CACHE_PATH='+str(swift),'build']
    def source_paths_for_build():
        if remote_editor_release:
            from distribution.traverse import sources
            return [REPO/name for name in sources()]
        if editor_release:
            return sorted((REPO/'App/MacExplorer').rglob('*.swift')) \
                +sorted((REPO/'Packages/ExplorerKit/Sources').rglob('*.swift')) \
                +[REPO/name for name in ['MacExplorer.xcodeproj/project.pbxproj',
                    'Packages/ExplorerKit/Package.swift','Distribution/AppStoreCandidate.xcconfig',
                    'Distribution/AppStoreParent.entitlements','Distribution/HelperInherit.entitlements',
                    'Distribution/Info.plist','tools/build_storage_worker.py','tools/distribution/sandbox.py']]
        return list((REPO/'App/MacExplorer').glob('*.swift')) \
            +list((REPO/'Packages/ExplorerKit/Sources/FileOperations').glob('*.swift'))
    inputs=dict(case=case.name,configuration='Release' if editor_release else 'isolated local-only sandbox',
        sourceBytes=measure(case/'source')['bytes'],
        sourceSHA256={str(p.relative_to(REPO)):hashlib.sha256(p.read_bytes()).hexdigest() for p in source_paths_for_build()},
        appStoreRecordCreated=False,uploaded=False,appLaunches=0)
    if editor_release:inputs.update(bundleIdentifier=identifier,buildAndInspectOnly=True,derivedDataPath=str(derived),
        sourcePackagesPath=str(packages),packageCachePath=str(package_cache),
        clangModuleCachePath=str(clang),swiftModuleCachePath=str(swift),
        buildProductsPath=str(product),retainedProductsPath=str(retained_product))
    put(case/('inputs'+suffix+'.json'),inputs)
    if editor_release:editor_release_audit(case)
    began=time.monotonic();failure=None;failure_detail=None
    with (case/('evidence/build'+suffix+'.log')).open('xb') as log:
        child=subprocess.Popen(command,cwd=REPO,env=env,stdin=subprocess.DEVNULL,stdout=log,stderr=subprocess.STDOUT)
        while child.poll() is None:
            try:live_build_audit(case,editor_release)
            except Exception as error:
                failure='Generated build resource audit failed'
                failure_detail=dict(type=type(error).__name__)
                if isinstance(error,EditorReleaseResourceLimit):failure_detail['usage']=error.usage
                missing=Path(getattr(error,'filename',None) or '')
                if missing.is_relative_to(case):failure_detail['relativeCasePath']=str(missing.relative_to(case))
                elif missing.is_relative_to(d.TOOLING):failure_detail['relativeToolingPath']=str(missing.relative_to(d.TOOLING))
            if time.monotonic()-began>900:failure='Generated build deadline'
            if failure:
                child.terminate()
                try:child.wait(timeout=5)
                except subprocess.TimeoutExpired:child.kill();child.wait(timeout=5)
                break
            time.sleep(1)
    if editor_release and child.returncode==0 and failure is None:
        current={str(p.relative_to(REPO)):hashlib.sha256(p.read_bytes()).hexdigest() for p in source_paths_for_build()}
        if current!=inputs['sourceSHA256']:failure='Editor Release source changed during build'
    if child.returncode==0 and failure is None:
        # Xcode's local build can omit hardened runtime. Seal this exact QA
        # product with its admitted signer and unchanged four parent rights.
        # A signing refusal or system prompt is never bypassed.
        try:
            subprocess.run(['/usr/bin/codesign','--force','--sign',qa_identity,'--timestamp=none','--options','runtime',
                '--entitlements',str(REPO/'Distribution/AppStoreParent.entitlements'),
                str(product/'Mac Explorer.app')],
                check=True,capture_output=True,timeout=30,stdin=subprocess.DEVNULL)
        except (subprocess.CalledProcessError,subprocess.TimeoutExpired) as error:
            failure='Generated QA sealing failed or timed out'
            failure_detail=dict(type=type(error).__name__,signer='developer-id' if developer_id else 'adhoc')
    if child.returncode==0 and failure is None:
        if remote_editor_release:
            directory(retained_product)
            artifacts=editor_release_artifacts(product)
            if not all(p.is_dir() and not p.is_symlink() and p.resolve()==p for p in artifacts):
                raise RuntimeError('Expected sealed review app and matching symbols')
            for artifact in artifacts:
                before=compiled_tree_receipt(artifact)
                destination=retained_product/artifact.name
                shutil.copytree(artifact,destination,symlinks=True)
                if compiled_tree_receipt(destination)!=before:
                    raise RuntimeError('Retained review artifact differs from compiled product')
            # Only the exact just-copied compiler artifacts are disposable.
            # Keep linker/module products for the next incremental build.
            for artifact in artifacts:
                if compiled_tree_receipt(artifact)!=compiled_tree_receipt(retained_product/artifact.name):
                    raise RuntimeError('Compiled artifact changed before cache disposal')
                shutil.rmtree(artifact)
    receipt=inspect(case,editor_release) if child.returncode==0 and failure is None else dict(passed=False,failure=failure or 'Build failed')
    receipt=complete_build_receipt(receipt,case=case,editor_release=editor_release,
        actual_exit=child.returncode,elapsed=time.monotonic()-began,failure_detail=failure_detail)
    put(case/('evidence/build-result'+suffix+'.json'),receipt)
    print(json.dumps(dict(case=case.name,**receipt)),flush=True)
    if not receipt['passed']:raise SystemExit(1)


def launch(case,phase,exception,manual_grant=False,repair=False,features=False):
    if not exception:raise RuntimeError('Owner-approved container exception is required before an OS sandbox launch')
    if phase in ['features','reference-reopen'] and not features:
        raise RuntimeError('Local feature phases require their separately recorded packet')
    if not inspect(case)['passed']:raise RuntimeError('Artifact changed or sandbox inspection failed')
    runs=list((case/'evidence').glob('launch-*.json'))
    total=sum(len(list((candidate/'evidence').glob('launch-*.json'))) for candidate in ROOT.iterdir() if candidate.is_dir())
    binary=app(case)/'Contents/MacOS/Mac Explorer'
    binary_hash=hashlib.sha256(binary.read_bytes()).hexdigest()
    if features:
        local_features(case)
        if manual_grant or repair or not 6<=total<10 or phase not in ['features','reference-reopen']:
            raise RuntimeError('Local feature packet aggregate allowance exhausted or phase differs')
        if phase=='reference-reopen':
            preceding=case/f'evidence/result-{len(runs)}.json'
            result=json.loads(preceding.read_bytes())
            if result.get('passed') is not True or result.get('report',{}).get('phase')!='features':
                raise RuntimeError('Saved-reference reopen requires a passed feature launch')
            prior=json.loads((case/f'evidence/launch-{len(runs)}.json').read_bytes())
            if prior.get('binarySHA256')!=binary_hash:raise RuntimeError('Cold reference check must use the same sealed artifact')
    elif repair:
        quarantine_repair(case)
        if phase!='grant' or not 5<=total<8 or manual_grant:
            raise RuntimeError('Quarantine repair admits only its three additional manual grant launches')
    elif manual_grant:
        if phase!='grant' or total!=4 or not (case/'evidence/inspection-reopen-reconciliation.json').is_file():
            raise RuntimeError('Additional manual grant is limited to the exact reconciled four-launch checkpoint')
        reconciliation=json.loads((case/'evidence/inspection-reopen-reconciliation.json').read_bytes())
        if reconciliation.get('exactGeneratedProcessNoLongerRunning') is not True:
            raise RuntimeError('Previous generated inspection reopen is not reconciled')
    elif total>=3:raise RuntimeError('Owner-approved aggregate sandbox launch allowance exhausted')
    container=Path.home()/'Library/Containers'/IDENTIFIER
    marker=container/'Data/Library/Application Support'/IDENTIFIER/'sandbox-qualification-owner-v1.json'
    if phase=='bootstrap':
        if container.exists() or container.is_symlink():raise RuntimeError('Pre-existing qualification container is not adopted')
    else:
        if container.is_symlink() or not marker.is_file() or marker.is_symlink() \
                or json.loads(marker.read_bytes()).get('case')!=case.name:raise RuntimeError('Exact qualification container owner missing')
    run=len(runs)+1
    put(case/f'evidence/launch-{run}.json',dict(phase=phase,aggregateAdmission=total+1,ownerApprovedContainerException=True,
        binarySHA256=binary_hash,
        separatelyApprovedManualGrant=manual_grant,quarantineRepair=repair,localFeaturePacket=features,
        nativeInspectorAttachment=False if manual_grant or repair or features else None,containerByteCeiling=64*MIB,
        containerEntryCeiling=1024,networkRequests=0,keychainQueries=0))
    env=dev.environment(tooling=False)
    env['MAC_EXPLORER_TEST_ROOT']=str(case)
    args=[str(binary),'-ApplePersistenceIgnoreState','YES','--verify-ui','--check-sandbox-foundation','--sandbox-phase',phase,
        '--analysis-source',str(case)]
    if phase=='bootstrap':args.append('--offscreen')
    log=case/f'evidence/native-{run}.log';began=time.monotonic()
    with log.open('xb') as stream:
        child=subprocess.Popen(args,cwd=REPO,env=env,stdin=subprocess.DEVNULL,stdout=stream,stderr=subprocess.STDOUT,start_new_session=True)
        stats,failure,contained,forced=wait_generated(child,log,case/'evidence',deadline=60 if phase in ['bootstrap','reference-reopen'] else 600)
    reports=[line[len('MAC_EXPLORER_SANDBOX_REPORT '):] for line in log.read_text(errors='replace').splitlines() if line.startswith('MAC_EXPLORER_SANDBOX_REPORT ')]
    report=json.loads(reports[0]) if len(reports)==1 else None
    size=measure(container) if container.is_dir() and not container.is_symlink() else dict(bytes=0,entries=0)
    passed=child.returncode==0 and failure is None and report is not None and report.get('passed') is True \
        and stats.ru_maxrss<=256*MIB and 0<size['bytes']<=64*MIB and size['entries']<=1024
    put(case/f'evidence/result-{run}.json',dict(passed=passed,report=report,actualExit=child.returncode,failure=failure,
        generatedContainment=contained,forcedContainment=forced,container=size,peakRSSBytes=stats.ru_maxrss,
        elapsedSeconds=time.monotonic()-began,packet=audit(),testFlightQualified=False))
    print(json.dumps(dict(case=case.name,run=run,phase=phase,passed=passed,report=report,container=size)),flush=True)
    if not passed:raise SystemExit(1)


def main():
    parser=argparse.ArgumentParser();parser.add_argument('action',choices=['build','inspect','launch'])
    identity=parser.add_mutually_exclusive_group()
    identity.add_argument('--case')
    identity.add_argument('--new-case',help='Reserve a new canonical remote-editor build identity; existing roots are refused.')
    parser.add_argument('--phase',choices=['bootstrap','grant','features','reference-reopen'],default='bootstrap')
    purpose=parser.add_mutually_exclusive_group()
    purpose.add_argument('--editor-release',action='store_true')
    purpose.add_argument('--remote-editor-release',action='store_true')
    purpose.add_argument('--remote-editor-developer-id',action='store_true')
    parser.add_argument('--owner-container-exception-approved',action='store_true')
    parser.add_argument('--owner-additional-manual-grant-approved',action='store_true')
    parser.add_argument('--owner-quarantine-repair-scope-approved',action='store_true')
    parser.add_argument('--owner-local-feature-packet-approved',action='store_true');args=parser.parse_args()
    remote_editor_release=args.remote_editor_release or args.remote_editor_developer_id
    if args.new_case is not None and (args.action!='build' or not remote_editor_release):
        parser.error('--new-case requires a remote-editor build')
    if args.editor_release or remote_editor_release:
        if args.action=='launch' or args.phase!='bootstrap' \
                or args.owner_container_exception_approved or args.owner_additional_manual_grant_approved \
                or args.owner_quarantine_repair_scope_approved or args.owner_local_feature_packet_approved:
            raise RuntimeError('Editor Release qualification admits build and inspection only')
        if args.action=='build':
            case=admitted(args.case,editor_release=True) if args.case else None
            if case is not None and (remote_editor_case(case)!=remote_editor_release
                    or remote_editor_developer_id_case(case)!=args.remote_editor_developer_id):
                raise RuntimeError('The selected editor purpose differs from the case')
            build(case,editor_release=True,remote_editor_release=remote_editor_release,
                developer_id=args.remote_editor_developer_id,new_case=args.new_case);return
        if not args.case:raise RuntimeError('Editor Release inspection requires the exact case')
        case=admitted(args.case,editor_release=True)
        if remote_editor_case(case)!=remote_editor_release \
                or remote_editor_developer_id_case(case)!=args.remote_editor_developer_id:
            raise RuntimeError('The selected editor purpose differs from the case')
        print(json.dumps(inspect(case,editor_release=True)));return
    if args.action=='build':build(admitted(args.case) if args.case else None,args.owner_quarantine_repair_scope_approved,
        args.owner_local_feature_packet_approved);return
    if not args.case:raise RuntimeError('An exact generated case is required')
    case=admitted(args.case)
    if args.action=='inspect':print(json.dumps(inspect(case)));return
    launch(case,args.phase,args.owner_container_exception_approved,args.owner_additional_manual_grant_approved,
        args.owner_quarantine_repair_scope_approved,args.owner_local_feature_packet_approved)


if __name__=='__main__':main()
