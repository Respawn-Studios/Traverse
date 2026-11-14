#!/usr/bin/env python3
"""Prepare/build Traverse separately; never changes the development project."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import signal
import subprocess
import sys
import time

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from generate_project import generate
from native_build_inputs import digest, source_inputs
from distribution.traverse_packet import REPO, TOOLING, CLANG_CACHE, SWIFT_CACHE, MIB, directory, reserve, require_case, put, audit, measure, ARTIFACT_BYTE_LIMIT
from distribution import notices, release_candidate, release_notes

# Release configuration, packaging and build/inspection tooling beyond the
# ordinary app inventory. Runtime controllers retain their own execution seals.
RELEASE_INPUTS = (
    'Distribution/AppStoreCandidate.xcconfig',
    'Distribution/AppStoreParent.entitlements',
    'Distribution/AppStoreUploadOptions.plist',
    'Distribution/DeveloperIDExportOptions.plist',
    'Distribution/DeveloperIDNotarizeOptions.plist',
    'Distribution/DirectParent.entitlements',
    'Distribution/DirectPublicUpdates.json',
    'Distribution/ExportOptions.plist',
    'Distribution/HelperInherit.entitlements',
    'Distribution/Info.plist',
    'Distribution/LicenseSupplements/Sparkle-2.10.0.txt',
    'Distribution/LicenseSupplements/delegate-0.13.5/LICENSE-APACHE',
    'Distribution/LicenseSupplements/delegate-0.13.5/LICENSE-MIT',
    'Distribution/LicenseSupplements/index.json',
    'Distribution/LicenseSupplements/russh-0.64.1/LICENSE.txt',
    'Distribution/LicenseSupplements/russh-0.64.1/PUBLISHED-COPYRIGHT-HEADERS.txt',
    'Distribution/LicenseSupplements/russh-cryptovec-0.62.0/LICENSE.txt',
    'Distribution/LicenseSupplements/russh-cryptovec-0.62.0/PUBLISHED-COPYRIGHT-HEADERS.txt',
    'Distribution/LicenseSupplements/russh-util-0.52.0/LICENSE-2.0.txt',
    'Distribution/PrivateUpdates.json',
    'Distribution/PublicUpdates.json',
    'Distribution/Sparkle.lock.json',
    'Distribution/Traverse.xcconfig',
    'Distribution/TraverseDirect.xcconfig',
    'Distribution/TraverseDirectQualification.xcconfig',
    'Distribution/TraverseLocalUserPublicUpdater.xcconfig',
    'Distribution/TraverseLocalUserPublicShipping.xcconfig',
    'Distribution/TraverseInfo.plist',
    'Distribution/TraverseUpdater.entitlements',
    'Distribution/TraverseUpdater.xcconfig',
    'Distribution/TraversePublicUpdater.xcconfig',
    'tools/development.py',
    'tools/distribution/DMGArtwork.swift',
    'tools/distribution/direct_dmg.py',
    'tools/distribution/dmg-requirements.txt',
    'tools/distribution/macho_minimum_os.py',
    'tools/distribution/notarize_direct_app.py',
    'tools/distribution/packet.py',
    'tools/distribution/preflight.py',
    'tools/distribution/private_feed.py',
    'tools/distribution/release_candidate.py',
    'tools/distribution/sandbox.py',
    'tools/distribution/source_capsule.py',
    'tools/distribution/symbolicate_report.py',
    'tools/distribution/traverse.py',
    'tools/qualify_foundation.py',
)

def run(case, command, label, timeout=1200):
    evidence = case / 'evidence'; stamp = str(time.time_ns())
    log = evidence / (label + '-' + stamp + '.log')
    env = os.environ.copy()
    # Keep account/profile lookup at its normal OS location, without assigning
    # HOME or changing Xcode preferences. All explicit outputs/caches stay here.
    env.pop('CFFIXED_USER_HOME', None)
    env.update(TMPDIR=str(directory(TOOLING / 'tmp')) + '/',
        CLANG_MODULE_CACHE_PATH=str(directory(CLANG_CACHE)),
        SWIFTPM_MODULECACHE_OVERRIDE=str(directory(SWIFT_CACHE)),
        SWIFTPM_NETRC_DATA='')
    began = time.monotonic()
    child = None
    try:
        with log.open('xb') as output:
            child = subprocess.Popen(command, cwd=REPO, env=env, stdin=subprocess.DEVNULL,
                stdout=output, stderr=subprocess.STDOUT, start_new_session=True)
            try:
                while child.poll() is None:
                    if time.monotonic() - began > timeout or log.stat().st_size > 32 * MIB:
                        raise RuntimeError('Bounded release build exceeded its deadline/log budget')
                    audit()
                    configuration = case / 'configuration.json'
                    if configuration.is_file() and json.loads(configuration.read_bytes()).get('localReviewOnly') is True:
                        used = measure(case)
                        if used['bytes'] > 256 * MIB or used['entries'] > 2048:
                            raise RuntimeError('Local candidate retained-case budget reached')
                    if configuration.is_file() and json.loads(configuration.read_bytes()).get('shippingCandidate') is True:
                        used = measure(case)
                        if used['bytes'] > 768 * MIB or used['entries'] > 4096:
                            raise RuntimeError('Shipping candidate retained-case budget reached')
                    time.sleep(1)
                if child.returncode:
                    raise RuntimeError(f'{label} failed ({child.returncode}); inspect {log.relative_to(REPO)}')
            finally:
                if child.poll() is None:
                    os.killpg(child.pid, signal.SIGTERM)
                    try: child.wait(timeout=5)
                    except subprocess.TimeoutExpired: os.killpg(child.pid, signal.SIGKILL); child.wait(timeout=5)
    except BaseException as error:
        if child is not None:
            # The old case has no such receipt. Record only this attempt's
            # observed post-stop exit; never infer an exit from the log text.
            try:
                put(evidence / (label + '-' + stamp + '.process.json'), dict(
                    passed=False, errorType=type(error).__name__,
                    actualExit=child.returncode, processReaped=child.poll() is not None,
                    log=str(log.relative_to(REPO)), seconds=time.monotonic()-began))
            except Exception:
                pass  # Preserve the original build or budget failure.
        raise
    return dict(log=str(log.relative_to(REPO)), seconds=time.monotonic()-began, actualExit=child.returncode)

def project_arguments(case, channel, policy='sandbox-selected-v1', version_override=None,
                      private_updater=False, public_updater=False, direct_shipping=False):
    project = case / 'Traverse.xcodeproj'
    generate(destination=project, traverse=True, direct=channel=='developer-id',
        direct_access_qualification=policy=='local-user-v1', private_updater=private_updater,
        public_updater=public_updater,direct_shipping=direct_shipping)
    return ['xcodebuild', '-project', str(project), '-scheme', 'Traverse', '-configuration', 'Release',
        '-destination', 'generic/platform=macOS', '-derivedDataPath', str(directory(TOOLING / 'derived')),
        '-clonedSourcePackagesDirPath', str(directory(TOOLING / 'packages')), '-skipPackageUpdates',
        '-disableAutomaticPackageResolution', '-disablePackageRepositoryCache',
        '-packageCachePath', str(directory(TOOLING / 'package-cache')), '-packageAuthorizationProvider', 'netrc',
        '-jobs', '4', 'SWIFT_TREAT_WARNINGS_AS_ERRORS=YES', 'ARCHS=arm64',
        'COMPILER_INDEX_STORE_ENABLE=NO',
        'CLANG_MODULE_CACHE_PATH=' + str(directory(CLANG_CACHE)),
        'SWIFT_MODULE_CACHE_PATH=' + str(directory(SWIFT_CACHE))] + release_candidate.settings(version_override)

def sources():
    wanted = source_inputs()
    for name in RELEASE_INPUTS:
        wanted[name] = digest(REPO / name)
    return dict(sorted(wanted.items()))

def verify_vendor_source():
    # The narrow source capsule retains the provenance manifest. This checks
    # its complete pinned vendor tree and downstream patch at archive edges.
    subprocess.run([sys.executable, '-B', str(REPO/'tools/smb_reader/vendor_verified_source.py')],
        cwd=REPO, stdin=subprocess.DEVNULL, capture_output=True, check=True, timeout=30)

def main():
    parser=argparse.ArgumentParser(); parser.add_argument('action',choices=['prepare','archive','export','notarize','upload'])
    parser.add_argument('--case'); parser.add_argument('--channel',choices=['app-store','developer-id'])
    parser.add_argument('--access-policy',choices=['sandbox-selected-v1','local-user-v1'])
    parser.add_argument('--version');parser.add_argument('--build-number')
    parser.add_argument('--private-updater',action='store_true')
    parser.add_argument('--public-updater',action='store_true', help='Select the separate public updater composition for this case purpose.')
    purpose=parser.add_mutually_exclusive_group()
    purpose.add_argument('--local-candidate',action='store_true')
    purpose.add_argument('--shipping-candidate',action='store_true');args=parser.parse_args()
    # Validate a fresh request before consuming a retained case; existing case
    # admission below still validates its immutable saved configuration.
    release_candidate.version_override(args.version,args.build_number)
    case=require_case(args.case) if args.case else reserve('traverse-'+args.action)
    configuration=case/'configuration.json'
    saved=json.loads(configuration.read_bytes()) if configuration.exists() else None
    selected=release_candidate.configuration(saved,channel=args.channel,policy=args.access_policy,
        version=args.version,build=args.build_number,local=args.local_candidate,shipping=args.shipping_candidate,
        private_updater=args.private_updater, public_updater=args.public_updater)
    release_candidate.admit_action(selected,args.action)
    channel=selected['channel'];policy=selected.get('accessPolicy','sandbox-selected-v1')
    direct_shipping=selected.get('releasePurpose')==release_candidate.DIRECT_SHIPPING_PURPOSE
    public_selected=selected.get('publicUpdater') is True
    override=selected.get('versionOverride')
    if direct_shipping and args.action=='notarize':
        raise RuntimeError('Direct shipping notarization follows local export through notarize_direct_app.py')
    if saved is None:put(configuration,selected)
    if policy=='local-user-v1' and (channel!='developer-id' or args.action not in
            (['prepare','archive','export','notarize'] if direct_shipping else ['prepare','archive','export'])):
        raise RuntimeError('Local-user release action differs from its original case purpose')
    if args.action in ['prepare','archive']:
        release_notes.verify_bundled()
        notices.verify_outputs()
    owner=REPO/'MacExplorer.xcodeproj/project.pbxproj'; owner_hash=hashlib.sha256(owner.read_bytes()).hexdigest()
    command=project_arguments(case,channel,policy,override,selected.get('privateUpdater')is True,
        public_selected,direct_shipping) if args.action in ['prepare','archive'] else None
    if args.action=='prepare':
        report=run(case,command+['-showBuildSettings','-json'],'settings',120)
        values=json.loads((REPO/report['log']).read_bytes())
        app=next(row['buildSettings'] for row in values if row.get('target')=='Traverse')
        keys=['PRODUCT_NAME','PRODUCT_BUNDLE_IDENTIFIER','DEVELOPMENT_TEAM','INFOPLIST_FILE','SRCROOT',
            'ENABLE_APP_SANDBOX','ENABLE_HARDENED_RUNTIME','CODE_SIGN_ENTITLEMENTS','ARCHS','MARKETING_VERSION','CURRENT_PROJECT_VERSION',
            'MAC_EXPLORER_ACCESS_POLICY','MAC_EXPLORER_TRAVERSE_BUILD','MAC_EXPLORER_DISTRIBUTION_CHANNEL']
        selected={key:app.get(key)for key in keys}
        assert selected['PRODUCT_NAME']=='Traverse' and selected['PRODUCT_BUNDLE_IDENTIFIER']=='com.respawnstudios.traverse'
        assert selected['SRCROOT']==str(REPO) and selected['ENABLE_APP_SANDBOX']==('NO' if policy=='local-user-v1' else 'YES') and selected['ARCHS']=='arm64'
        assert selected['MAC_EXPLORER_ACCESS_POLICY']==policy and selected['ENABLE_HARDENED_RUNTIME']=='YES'
        if policy=='local-user-v1' and selected['MAC_EXPLORER_TRAVERSE_BUILD']!=(
                'developer-id-local-user-public-shipping-v1' if direct_shipping else
                'developer-id-local-user-public-qualification-v1' if public_selected else
                'developer-id-local-user-qualification-v1'):
            raise RuntimeError('Local-user build tag differs from its immutable case purpose')
        if direct_shipping and selected['INFOPLIST_FILE']!=str(
                REPO/'.build/traverse-release/tooling/direct-public-shipping/TraverseInfo.plist'):
            raise RuntimeError('Direct shipping Info path differs from its purpose')
        release_candidate.verify_observed(dict(CFBundleShortVersionString=selected['MARKETING_VERSION'],
            CFBundleVersion=selected['CURRENT_PROJECT_VERSION']),override)
        assert hashlib.sha256(owner.read_bytes()).hexdigest()==owner_hash
        put(case/'prepare.json',dict(passed=True,settings=selected,build=report,ownerProjectUnchanged=True,packet=audit()))
    elif args.action=='archive':
        if (case/'archive.json').exists(): raise RuntimeError('Retain the old archive; use a fresh case for another build')
        if override is not None and ARTIFACT_BYTE_LIMIT-audit()['artifacts']['bytes'] < 256*MIB:
            raise RuntimeError('Local archive requires256MiB of retained artifact headroom')
        verify_vendor_source()
        from build_crash_reporter import prepare as prepare_crash_reporter
        prepare_crash_reporter()
        audit()  # Dependency preparation shares the existing tooling ceiling.
        wanted=sources();put(case/'archive-inputs.json',dict(sourceSHA256=wanted))
        archive=case/('Traverse-'+str(time.time_ns())+'.xcarchive')
        report=run(case,command+['-allowProvisioningUpdates','-archivePath',str(archive),'archive'],'archive')
        assert hashlib.sha256(owner.read_bytes()).hexdigest()==owner_hash
        if sources()!=wanted:raise RuntimeError('Source changed during the archive; do not qualify/upload it')
        verify_vendor_source()
        info=plistlib.loads((archive/'Products/Applications/Traverse.app/Contents/Info.plist').read_bytes())
        release_candidate.verify_observed(info,override,selected.get('releasePurpose'))
        from distribution.helper_symbols import health_service_declared, inspect_archive, retain_crash_reporter_symbols
        retain_crash_reporter_symbols(archive)
        symbols=inspect_archive(archive)
        put(case/'helper-symbols.json',symbols)
        if not symbols['passed']:raise RuntimeError('Release archive is missing matching nonempty helper symbols')
        receipt=dict(passed=True,archive=str(archive.relative_to(REPO)),build=report,
            helperSymbols=symbols,ownerProjectUnchanged=True,packet=audit())
        if health_service_declared(info):
            from build_drive_health_worker import verify_provisional_archive
            receipt['healthServiceArchive']=verify_provisional_archive(case,
                archive/'Products/Applications/Traverse.app')
        put(case/'archive.json',receipt)
    else:
        if not args.case: raise RuntimeError('Export requires an exact successful archive case')
        value=json.loads((case/'archive.json').read_bytes());archive=REPO/value['archive']
        if value.get('passed') is not True or archive.parent!=case or archive.resolve()!=archive:
            raise RuntimeError('Unknown release archive')
        archive_app=archive/'Products/Applications/Traverse.app'
        archive_info=plistlib.loads((archive_app/'Contents/Info.plist').read_bytes())
        release_candidate.verify_observed(archive_info,override,selected.get('releasePurpose'))
        from distribution.helper_symbols import health_service_declared
        service=health_service_declared(archive_info)
        if service:
            if channel!='developer-id' or args.action!='export':
                raise RuntimeError('Drive-health service requires a locally finalized Developer ID export')
            from build_drive_health_worker import verify_provisional_archive
            if value.get('healthServiceArchive')!=verify_provisional_archive(case,archive_app):
                raise RuntimeError('Provisional drive-health archive proof changed')
            if json.loads((case/'archive-inputs.json').read_bytes()).get('sourceSHA256')!=sources():
                raise RuntimeError('Drive-health archive source changed before export')
        output=case/('export-'+str(time.time_ns()))
        if args.action=='notarize' and channel!='developer-id':raise RuntimeError('Notarization requires the explicit Developer ID channel')
        if args.action=='upload' and channel!='app-store':raise RuntimeError('TestFlight upload requires the App Store channel')
        if (case/(args.action+'.json')).exists():raise RuntimeError('This export/submission already has a receipt; do not repeat it blindly')
        options=REPO/('Distribution/AppStoreUploadOptions.plist' if args.action=='upload' else 'Distribution/DeveloperIDNotarizeOptions.plist' if args.action=='notarize' else 'Distribution/DeveloperIDExportOptions.plist' if channel=='developer-id' else 'Distribution/ExportOptions.plist')
        attempt=case/'export-finalization-attempt.json'
        if service:
            if any(path.exists() or path.is_symlink() for path in [attempt,case/'export-finalization-failure.json',
                    case/'export-finalization.json']):
                raise RuntimeError('Review the retained drive-health export attempt before another export')
            put(attempt,dict(format='drive-health-xpc-export-attempt-v1',
                archive=str(archive.relative_to(REPO)),output=str(output.relative_to(REPO)),
                preserveOnFailure=True))
        stage='xcode-export'
        try:
            report=run(case,['xcodebuild','-exportArchive','-archivePath',str(archive),'-exportPath',str(output),
                '-exportOptionsPlist',str(options),'-allowProvisioningUpdates'],'export',300)
            finalization=None
            if service:
                stage='service-finalization'
                from build_drive_health_worker import finalize_exported_product
                finalization=finalize_exported_product(case,archive_app,output/'Traverse.app',
                    value['healthServiceArchive'])
                if json.loads((case/'archive-inputs.json').read_bytes()).get('sourceSHA256')!=sources():
                    raise RuntimeError('Drive-health archive source changed during export')
                put(case/'export-finalization.json',dict(passed=True,output=str(output.relative_to(REPO)),
                    result=finalization))
            if direct_shipping:
                stage='export-identity'
                exported_info=plistlib.loads((output/'Traverse.app/Contents/Info.plist').read_bytes())
                release_candidate.shipping_metadata(selected,exported_info)
            stage='export-receipt'
            receipt=dict(passed=True,output=str(output.relative_to(REPO)),build=report,
                stage='uploaded; Apple processing not established' if args.action in ['upload','notarize'] else 'exported locally',packet=audit())
            if finalization is not None: receipt['healthServiceFinalization']=finalization
            put(case/(args.action+'.json'),receipt)
        except BaseException as error:
            if service:
                failure=case/'export-finalization-failure.json'
                if not failure.exists() and not failure.is_symlink():
                    put(failure,dict(passed=False,stage=stage,errorType=type(error).__name__,
                        output=str(output.relative_to(REPO)),preserveExport=True,retryWithoutReview=False))
            raise
    print(json.dumps(dict(case=case.name,passed=True,action=args.action)),flush=True)

if __name__=='__main__': main()
