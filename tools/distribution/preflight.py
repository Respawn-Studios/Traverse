#!/usr/bin/env python3
"""Read-only artifact inspection. It never signs, uploads or changes an account."""
from __future__ import annotations
import argparse
import base64
from datetime import datetime,timezone
import hashlib
import json
from pathlib import Path
import plistlib
import re
import subprocess
import sys

sys.dont_write_bytecode=True
sys.path.insert(0,str(Path(__file__).resolve().parent))
sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
from distribution.bundle_notices import GPL_V3_SHA256
from distribution.artifact_files import read
from macho_minimum_os import version as os_version, read_target, admitted as target_admitted
from folder_services import valid as folder_services_valid
from distribution import helper_symbols, release_candidate

PARENT_RIGHTS={'com.apple.security.app-sandbox','com.apple.security.files.user-selected.read-write',
    'com.apple.security.files.bookmarks.app-scope','com.apple.security.network.client'}
IDENTITY_RIGHTS={'com.apple.application-identifier','application-identifier','com.apple.developer.team-identifier',
    'keychain-access-groups','beta-reports-active'}
UPDATER_MACH_RIGHT='com.apple.security.temporary-exception.mach-lookup.global-name'
HELPERS={'storage-scanner-worker':'storage-scanner-worker',
    'smb-browser-worker':'local.macexplorer.smb.browser','smb-resolver-worker':'local.macexplorer.smb.resolver'}
STORE_HELPERS={'storage-scanner-worker':'storage-scanner-worker',
    'smb-browser-worker':'com.respawnstudios.traverse.smb.browser',
    'smb-resolver-worker':'com.respawnstudios.traverse.smb.resolver',
    'sftp-metadata-worker':'com.respawnstudios.traverse.sftp.metadata'}
PERMISSION_PURPOSES=('NSDesktopFolderUsageDescription','NSDocumentsFolderUsageDescription',
    'NSDownloadsFolderUsageDescription','NSRemovableVolumesUsageDescription',
    'NSNetworkVolumesUsageDescription','NSLocalNetworkUsageDescription')

def permission_purpose_checks(info):
    return [check('purpose_'+key,isinstance(info.get(key),str) and 0<len(info[key].strip())<=512,
        'Enabled folder/network scopes must have an explicit user-facing macOS purpose.') for key in PERMISSION_PURPOSES]

def check(identifier,passed,detail):return dict(id=identifier,passed=bool(passed),detail=detail)

def developer_id_checks(identity,suffix=''):
    authorities=identity.get('authorities',[])
    return [check('developer_id_authority'+suffix,bool(authorities) and isinstance(authorities,list)
        and isinstance(authorities[0],str) and authorities[0].startswith('Developer ID Application: '),
        'Developer ID requires the actual Developer ID Application signature authority.'),
        check('developer_id_timestamp'+suffix,identity.get('timestamped') is True,
        'Developer ID requires a secure signing timestamp.')]

def strings(value):
    if isinstance(value,str):yield value
    elif isinstance(value,dict):
        for key,item in value.items():yield from strings(key);yield from strings(item)
    elif isinstance(value,(list,tuple)):
        for item in value:yield from strings(item)

def machine_path_in_metadata(value, *, allowed_volume_hint=None):
    """Find embedded machine paths in metadata, allowing one exact DMG hint."""
    data = value.encode('utf-8') if isinstance(value,str) else value
    if b'/Users/' in data or b'.build/' in data:return True
    for found in re.finditer(rb'/Volumes/',data):
        if allowed_volume_hint is None or not data.startswith(allowed_volume_hint,found.start()):return True
        after=found.start()+len(allowed_volume_hint)
        if after<len(data) and data[after]!=0:return True
    return False

def health_info_admitted(info,expected_bundle,expected_channel):
    try:
        if helper_symbols.HEALTH_SERVICE_VERSION_KEY in info:
            return expected_bundle=='com.respawnstudios.traverse' and expected_channel=='developer-id' \
                and info.get('CFBundleIdentifier')==expected_bundle \
                and info.get('MacExplorerDistributionChannel')==expected_channel \
                and helper_symbols.health_service_declared(info)
        declared=helper_symbols.health_declared(info)
        return not declared or(expected_bundle=='com.respawnstudios.traverse'and expected_channel=='developer-id')
    except (ValueError,TypeError):return False

def health_role_requirement(identifier,team):
    if not isinstance(identifier,str) or re.fullmatch('[A-Za-z0-9.-]+',identifier)is None:
        return None
    return ('anchor apple generic and identifier "'+identifier+'"'
        +' and certificate 1[field.1.2.840.113635.100.6.2.6] exists'
        +' and certificate leaf[field.1.2.840.113635.100.6.1.13] exists'
        +' and certificate leaf[subject.OU] = "'+team+'"')

def drive_health_checks(app,info,expected_bundle,expected_team,expected_channel):
    helper=app/'Contents/Helpers/drive-health-worker'
    manifest=app/'Contents/Resources/DriveHealthHelperManifest.plist'
    service=app/'Contents/XPCServices'/helper_symbols.HEALTH_SERVICE_LEAF
    service_manifest=app/'Contents/Resources/DriveHealthServiceManifest.plist'
    service_declared=helper_symbols.HEALTH_SERVICE_VERSION_KEY in info
    if service_declared:
        product=expected_bundle=='com.respawnstudios.traverse' and expected_channel=='developer-id'
        service_id=str(info.get('CFBundleIdentifier',''))+'.drive.health.xpc'
        binary=service/'Contents/MacOS'/helper_symbols.HEALTH_SERVICE_EXECUTABLE
        try:
            fields=plistlib.loads(read(service_manifest,4096))
            service_info=plistlib.loads(read(service/'Contents/Info.plist',4096))
            image=read(binary,4<<20)
            signed=signing(service);rights=entitlements(service)
            keys={'format','parentIdentifier','serviceIdentifier','teamIdentifier','channel',
                'accessPolicy','parentRequirement','sha256','serviceCDHash'}
            if not product:keys.add('reviewCase')
            info_keys={'CFBundleIdentifier','CFBundleExecutable','CFBundlePackageType',
                'CFBundleShortVersionString','CFBundleVersion','LSMinimumSystemVersion','XPCService'}
            hash=fields.get('serviceCDHash')
            good=(health_info_admitted(info,expected_bundle,expected_channel) if product
                else helper_symbols.health_service_declared(info)) \
                and not service.is_symlink() and service.resolve()==service \
                and set(p.name for p in service.parent.iterdir())=={helper_symbols.HEALTH_SERVICE_LEAF} \
                and set(fields)==keys and fields.get('format')==('drive-health-xpc-developer-id-v1'
                    if product else 'drive-health-xpc-qa-v1') \
                and fields.get('parentIdentifier')==info.get('CFBundleIdentifier') \
                and fields.get('serviceIdentifier')==service_id \
                and fields.get('teamIdentifier')==expected_team \
                and fields.get('channel')==('developer-id' if product else 'qualification') \
                and fields.get('accessPolicy')==info.get('MacExplorerAccessPolicy') \
                and (product or fields.get('reviewCase')==helper_symbols.HEALTH_QA_CASE) \
                and fields.get('parentRequirement')==health_role_requirement(info.get('CFBundleIdentifier'),expected_team) \
                and re.fullmatch('[0-9a-f]{64}',fields.get('sha256','')) is not None \
                and hashlib.sha256(image).hexdigest()==fields['sha256'] \
                and isinstance(hash,str)and re.fullmatch('[0-9a-f]{40}(?:[0-9a-f]{24})?',hash)is not None \
                and set(service_info)==info_keys \
                and service_info.get('CFBundleIdentifier')==service_id \
                and service_info.get('CFBundleExecutable')==helper_symbols.HEALTH_SERVICE_EXECUTABLE \
                and service_info.get('CFBundlePackageType')=='XPC!' \
                and service_info.get('CFBundleShortVersionString')=='1.0' \
                and service_info.get('CFBundleVersion')=='1' \
                and service_info.get('LSMinimumSystemVersion')=='15.0' \
                and service_info.get('XPCService')=={'ServiceType':'Application','RunLoopType':'dispatch_main'} \
                and signed['Identifier']==service_id and signed['TeamIdentifier']==expected_team \
                and signed.get('cdhash')==hash \
                and signed['runtime'] and (not product or signed.get('timestamped') is True) and not rights \
                and command(['/usr/bin/codesign','--verify','--strict',str(service)]).returncode==0 \
                and not any(path.exists()or path.is_symlink()for path in [helper,manifest])
            if good:
                # The service is independently signed; a bundled code hash is
                # checked by the app at admission and the peer requirement.
                good=bool(signed.get('authorities'))and signed['authorities'][0].startswith('Developer ID Application: ')
        except Exception:good=False
        return [check('drive_health_xpc_identity_shape',good,
            'The service bundle, fixed Info, manifest, hash, Developer ID role and empty rights must agree.'),
            check('drive_health_xpc_distribution_admission' if product else 'drive_health_xpc_qa_hold',
                good and product, 'Only the exact timestamped Developer ID product service is admitted.')]
    absent=check('drive_health_xpc_absent',not any(p.exists()or p.is_symlink()for p in [service,service_manifest]),
        'An ordinary composition must not contain an undeclared independent health service.')
    declared=helper_symbols.HEALTH_VERSION_KEY in info
    if not declared:
        return [absent,check('drive_health_absent_without_declaration',not any(p.exists()or p.is_symlink()for p in [helper,manifest]),
            'Legacy packages omit health; undeclared helper code or manifests are refused.')]
    good=health_info_admitted(info,expected_bundle,expected_channel)and expected_team=='CDLNJRG82U'
    try:
        value=plistlib.loads(read(manifest,4096))
        keys={'format','parentIdentifier','helperIdentifier','teamIdentifier','channel','accessPolicy','sha256'}
        expected=dict(format='drive-health-inherited-v2',parentIdentifier=expected_bundle,
            helperIdentifier=expected_bundle+'.drive.health',teamIdentifier=expected_team,
            channel='developer-id',accessPolicy='sandbox-selected-v1')
        digest=value.get('sha256')
        good=good and set(value)==keys and all(value.get(k)==v for k,v in expected.items()) \
            and isinstance(digest,str)and re.fullmatch('[0-9a-f]{64}',digest)is not None \
            and hashlib.sha256(read(helper,4<<20)).hexdigest()==digest
        identity=signing(helper);rights=entitlements(helper)
        good=good and identity['Identifier']==expected['helperIdentifier'] \
            and identity['TeamIdentifier']==expected_team and identity['runtime'] \
            and set(rights)=={'com.apple.security.app-sandbox','com.apple.security.inherit'} \
            and all(type(v)is bool and v is True for v in rights.values())
    except Exception:good=False
    return [absent,check('drive_health_sealed_inherited_composition',good,
        'Declared health requires its exact Developer ID parent, closed v2 manifest, binary hash, hardened role/team and inheritance pair.')]

def info_checks(info,expected_bundle,expected_channel='app-store'):
    if expected_channel not in ('app-store','developer-id'):raise ValueError('Explicit known distribution channel required')
    namespace=info.get('CFBundleIdentifier')
    fields=list(strings(info))
    versions=all(isinstance(info.get(key),str) and re.fullmatch(r'[0-9]+(?:\.[0-9]+){0,2}',info[key])
        for key in ['CFBundleShortVersionString','CFBundleVersion'])
    try:reviewed_floor=os_version(info.get('LSMinimumSystemVersion'))==(15,0,0)
    except ValueError:reviewed_floor=False
    private_marker=info.get('TraversePrivateUpdaterVersion')
    public_marker=info.get('TraversePublicUpdaterVersion')
    direct_marker=info.get('TraverseDirectPublicUpdaterVersion')
    updater_keys={key for key in info if key.startswith('SU')}
    private_updater=private_marker=='2.10.0' and not any(key in info for key in
        ('TraversePublicUpdaterVersion','TraverseDirectPublicUpdaterVersion'))
    public_updater=public_marker=='2.10.0' and not any(key in info for key in
        ('TraversePrivateUpdaterVersion','TraverseDirectPublicUpdaterVersion'))
    direct_public_updater=direct_marker=='2.10.0' and not any(key in info for key in
        ('TraversePrivateUpdaterVersion','TraversePublicUpdaterVersion'))
    release_purpose=info.get(release_candidate.RELEASE_PURPOSE_KEY)
    purpose_valid=release_candidate.RELEASE_PURPOSE_KEY not in info or (
        release_purpose==release_candidate.DIRECT_SHIPPING_PURPOSE
        and expected_channel=='developer-id'
        and info.get('MacExplorerAccessPolicy')=='local-user-v1'
        and direct_public_updater
        and 'MacExplorerReviewCase' not in info
        and 'MacExplorerSandboxQualificationCase' not in info)
    direct_updater=expected_channel=='developer-id' and (
        info.get('MacExplorerAccessPolicy')=='sandbox-selected-v1' and (private_updater or public_updater)
        or info.get('MacExplorerAccessPolicy')=='local-user-v1' and direct_public_updater
        and info.get('TraverseDirectStorageNamespace')=='com.respawnstudios.traverse.direct'
        and 'TraverseDriveHealthHelperVersion' not in info
        and ('TraverseDriveHealthServiceVersion' not in info or
             health_info_admitted(info,expected_bundle,expected_channel)))
    # This key supplies an App Store Connect submission answer. Developer ID
    # inspection checks a supplied value's type without inventing that answer;
    # the report's manual export review still applies to either channel.
    export_check=check('export_answer_present',type(info.get('ITSAppUsesNonExemptEncryption')) is bool,
        'App Store/TestFlight needs a reviewed answer here or in App Store Connect; no exemption is inferred.') \
        if expected_channel=='app-store' else check('export_answer_type',
            'ITSAppUsesNonExemptEncryption' not in info or type(info['ITSAppUsesNonExemptEncryption']) is bool,
            'Developer ID does not require this App Store Connect key; a supplied answer must be Boolean. Export review remains manual.')
    return [
        check('release_purpose_boundary',purpose_valid,
            'A signed shipping purpose belongs only to the exact direct public Developer ID composition.'),
        check('drive_health_edition_boundary',health_info_admitted(info,expected_bundle,expected_channel),
            'Only the closed Developer ID or QA health service and scoped inherited v2 composition are admitted.'),
        check('folder_service_boundary',folder_services_valid(info) and (
            'NSServices' not in info or direct_updater and expected_bundle=='com.respawnstudios.traverse')
            and (not (public_updater or direct_public_updater) or 'NSServices' in info),
            'The selected direct updater declares the exact restricted public.folder Service; public mode must retain it.'),
        check('updater_edition_boundary',direct_updater or(
            'TraversePrivateUpdaterVersion' not in info \
            and 'TraversePublicUpdaterVersion' not in info \
            and 'TraverseDirectPublicUpdaterVersion' not in info and not updater_keys),
            'Updater markers must select exactly one reviewed Developer ID access policy; Apple editions contain no updater settings.'),
        check('direct_storage_namespace',
            (direct_public_updater and info.get('TraverseDirectStorageNamespace')=='com.respawnstudios.traverse.direct')
            or (not direct_public_updater and 'TraverseDirectStorageNamespace' not in info),
            'The local-user updater must use its separate user-domain state namespace.'),
        check('final_bundle_identity',bool(expected_bundle) and namespace==expected_bundle and not namespace.startswith('local.'),
            'A deliberately selected permanent bundle identity must match; development/qualification identities are not upload identities.'),
        check('portable_storage',info.get('MacExplorerStorageMode')=='portable','Portable Application Support/Caches composition is required.'),
        check('no_development_qualifications',not any(k in ('MacExplorerDevelopmentStateRoot','MacExplorerDevelopmentCacheRoot')
            or k.startswith('MacExplorerCopyPreview') for k in info),
            'Machine state/cache paths and development Copy-preview qualifications must be absent.'),
        check('no_unexpanded_or_machine_paths',all('$(' not in s and not machine_path_in_metadata(s) for s in fields),
            'Info metadata must not retain build placeholders or local machine paths.'),
        check('version_and_build',versions,'Version/build must be explicit numeric strings.'),
        check('reviewed_minimum_macos',reviewed_floor,'The declared first-release support floor must remain the reviewed macOS15.0.'),
        check('category',info.get('LSApplicationCategoryType')=='public.app-category.utilities','Candidate category is Utilities.'),
        check('copyright',isinstance(info.get('NSHumanReadableCopyright'),str) and bool(info['NSHumanReadableCopyright'].strip()) and '$(' not in info['NSHumanReadableCopyright'],
            'Final copyright wording must be supplied and reviewed.'),
        check('distribution_runtime_channel',info.get('MacExplorerDistributionChannel')==expected_channel,
            'The artifact must match the explicitly selected distribution channel; runtime qualification remains separate.'),
        export_check]+permission_purpose_checks(info)

def entitlement_checks(parent,children,updater_selected=False,expected_bundle=None,policy='sandbox-selected-v1',expected_team=None):
    if policy == 'local-user-v1':
        appid=(str(expected_team)+'.'+str(expected_bundle)) if expected_team and expected_bundle else None
        identity_valid=all(parent.get(key)==appid for key in
            ('com.apple.application-identifier','application-identifier') if key in parent) \
            and ('com.apple.developer.team-identifier' not in parent
                or parent['com.apple.developer.team-identifier']==expected_team) \
            and ('keychain-access-groups' not in parent
                or parent['keychain-access-groups']==[appid]) \
            and ('beta-reports-active' not in parent or parent['beta-reports-active'] is True)
        found=[check('parent_local_user_rights',set(parent).issubset(IDENTITY_RIGHTS)
            and identity_valid and not updater_selected,
            'The local-user parent has no sandbox, selected-folder, temporary Mach or debug rights.')]
        for name,rights in children.items():
            found.append(check('direct_helper_'+name,rights=={},
                'Every local-user helper has no sandbox or inherited rights.'))
        return found
    if policy != 'sandbox-selected-v1':
        return [check('known_access_policy',False,'Only exact scoped or local-user policies are admitted.')]
    extra={UPDATER_MACH_RIGHT}if updater_selected else set()
    found=[check('parent_sandbox_and_selection',all(parent.get(key) is True for key in PARENT_RIGHTS),
        'Sandbox, explicit user-selected read/write, app bookmarks and outgoing networking are required.'),
        check('parent_entitlement_boundary',set(parent).issubset(PARENT_RIGHTS|IDENTITY_RIGHTS|extra),
            'No debug, broad-path, private sandbox, server, Apple Events or unreviewed entitlement is admitted.')]
    if updater_selected:
        found.append(check('updater_exact_mach_names',bool(expected_bundle)and parent.get(UPDATER_MACH_RIGHT)==[expected_bundle+'-spks',expected_bundle+'-spki'],
            'Only the selected bundle’s two reviewed Sparkle installer names are admitted.'))
    for name,rights in children.items():
        found.append(check('inherit_'+name,rights=={'com.apple.security.app-sandbox':True,'com.apple.security.inherit':True},
            'Each direct helper must have exactly the reviewed inheriting sandbox rights.'))
    return found

def updater_checks(app,info,expected_team,expected_channel):
    framework=app/'Contents/Frameworks/Sparkle.framework'
    private=info.get('TraversePrivateUpdaterVersion')=='2.10.0' \
        and 'TraversePublicUpdaterVersion' not in info and 'TraverseDirectPublicUpdaterVersion' not in info
    public=info.get('TraversePublicUpdaterVersion')=='2.10.0' \
        and 'TraversePrivateUpdaterVersion' not in info and 'TraverseDirectPublicUpdaterVersion' not in info
    direct_public=info.get('TraverseDirectPublicUpdaterVersion')=='2.10.0' \
        and 'TraversePrivateUpdaterVersion' not in info and 'TraversePublicUpdaterVersion' not in info
    policy=info.get('MacExplorerAccessPolicy')
    enabled=expected_channel=='developer-id' and (
        policy=='sandbox-selected-v1' and (private or public)
        or policy=='local-user-v1' and direct_public)
    if not enabled:
        binary=app/'Contents/MacOS'/str(info.get('CFBundleExecutable',''))
        try:
            linked=command(['/usr/bin/otool','-L',str(binary)])
            no_link=linked.returncode==0 and b'/Sparkle.framework/'not in linked.stdout
        except Exception:no_link=False
        return [check('no_unselected_updater',not framework.exists()and not framework.is_symlink()and no_link,
            'Apple and legacy direct compositions must neither embed nor link Sparkle.')]
    if public or direct_public:
        try:
            values=json.loads(read(Path(__file__).resolve().parents[2]/
                ('Distribution/DirectPublicUpdates.json' if direct_public else 'Distribution/PublicUpdates.json'),8192))
            valid_config=isinstance(values,dict) \
                and set(values)=={'schema','origin','feedPath','publicEDKey','intervalSeconds'} \
                and type(values.get('schema')) is int and values['schema']==1 \
                and values.get('origin')=='https://respawn-studios.com' \
                and values.get('feedPath')==('/products/traverse/direct-updates/appcast.xml' if direct_public
                    else '/products/traverse/public-updates/appcast.xml') \
                and len(base64.b64decode(values.get('publicEDKey',''),validate=True))==32 \
                and type(values.get('intervalSeconds')) is int and values['intervalSeconds']==21600
        except (OSError,ValueError,TypeError,KeyError):
            values={};valid_config=False
        if not valid_config:values={}
    else:
        values=json.loads(read(Path(__file__).resolve().parents[2]/'Distribution/PrivateUpdates.json',8192))
        valid_config=True
    exact=dict(SUFeedURL=values.get('origin','')+values.get('feedPath',''),SUPublicEDKey=values.get('publicEDKey',''),
        SUVerifyUpdateBeforeExtraction=True,SURequireSignedFeed=True,SUSignedFeedFailureExpirationInterval=0,
        SUEnableAutomaticChecks=False,SUAutomaticallyUpdate=False,SUAllowsAutomaticUpdates=False,
        SUScheduledCheckInterval=21600,SUEnableSystemProfiling=False,SUEnableJavaScript=False)
    if not direct_public:
        exact.update(SUEnableInstallerLauncherService=True,SUEnableDownloaderService=False)
    found=[check('updater_security_configuration',valid_config and all(
        type(info.get(k))is type(v)and info[k]==v for k,v in exact.items()) \
        and (not (public or direct_public) or {key for key in info if key.startswith('SU')}==set(exact)),
        'The selected exact feed and signatures fail closed; installation, profiling and JavaScript are not automatic.')]
    if framework.is_symlink()or not framework.is_dir()or framework.resolve()!=framework:
        found.append(check('updater_framework',False,'The exact updater framework is missing or redirected.'));return found
    root=framework/'Versions/B'
    found.append(check('updater_no_downloader_service',not(root/'XPCServices/Downloader.xpc').exists()
        and not(root/'XPCServices/Downloader.xpc').is_symlink(),
        'The app’s existing network client right makes an extra downloader service unnecessary.'))
    installer=root/'XPCServices/Installer.xpc'
    if direct_public:
        found.append(check('updater_no_sandbox_installer',not installer.exists() and not installer.is_symlink(),
            'The local-user edition cannot bundle or enable the sandbox installer service.'))
    roles=[(framework,'org.sparkle-project.Sparkle'),(root/'Autoupdate','org.sparkle-project.Sparkle.Autoupdate'),
        (root/'Updater.app','org.sparkle-project.Sparkle.Updater')]
    if not direct_public:roles.append((installer,'org.sparkle-project.InstallerLauncher'))
    for path,identifier in roles:
        name=path.name
        try:
            identity=signing(path);rights=entitlements(path)
            good=identity['Identifier']==identifier and identity['TeamIdentifier']==expected_team and identity['runtime']and not rights
            found.append(check('updater_nested_'+name,good,'Every required nested role is sealed by the selected team with runtime protection and no added rights.'))
            found.extend(developer_id_checks(identity,'_updater_'+name))
        except Exception:found.append(check('updater_nested_'+name,False,'Required updater role could not be inspected.'))
    return found

def profile_checks(profile,expected_bundle,expected_team,now):
    rights=profile.get('Entitlements',{})
    if not isinstance(rights,dict):rights={}
    appid=rights.get('com.apple.application-identifier',rights.get('application-identifier'))
    expires=profile.get('ExpirationDate')
    if isinstance(expires,datetime) and expires.tzinfo is None:expires=expires.replace(tzinfo=timezone.utc)
    teams=profile.get('TeamIdentifier',[])
    return [check('profile_identity',bool(expected_bundle) and bool(expected_team) and appid==expected_team+'.'+expected_bundle
        and isinstance(teams,list) and expected_team in teams,'Embedded profile must bind the selected team and bundle identity.'),
        check('profile_not_expired',isinstance(expires,datetime) and expires>now,'An unexpired embedded provisioning profile is required for TestFlight.')]

def command(args):
    result=subprocess.run(args,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=30,check=False)
    if len(result.stdout)>4<<20 or len(result.stderr)>4<<20:raise RuntimeError('Artifact inspector output bound')
    return result

def entitlements(file):
    result=command(['/usr/bin/codesign','-d','--entitlements','-','--xml',str(file)])
    if result.returncode:raise RuntimeError('Signed entitlements unavailable')
    if not result.stdout.strip():return {}
    value=plistlib.loads(result.stdout)
    if not isinstance(value,dict):raise RuntimeError('Entitlements are not a dictionary')
    return value

def signing(file):
    result=command(['/usr/bin/codesign','-d','--verbose=4',str(file)])
    if result.returncode:raise RuntimeError('Signature identity unavailable')
    text=result.stderr.decode('utf-8','replace')
    fields={}
    for key in ['Identifier','TeamIdentifier']:
        match=re.search(r'^'+key+r'=(.*)$',text,re.M);fields[key]=match[1] if match else None
    hash=re.search(r'^CDHash=([0-9a-fA-F]+)$',text,re.M)
    fields['cdhash']=hash[1].lower()if hash else None
    fields['runtime']=bool(re.search(r'flags=0x[0-9a-fA-F]+\([^)]*runtime',text))
    fields['authorities']=re.findall(r'^Authority=(.*)$',text,re.M)
    fields['timestamped']=bool(re.search(r'^Timestamp=\S',text,re.M))
    return fields

def inspect(app,expected_bundle=None,expected_team=None,expected_channel='app-store'):
    if not app.is_absolute() or app.resolve()!=app or app.suffix!='.app':raise RuntimeError('Exact nonredirected app bundle required')
    info=plistlib.loads(read(app/'Contents/Info.plist',1<<20))
    if not isinstance(info,dict):raise RuntimeError('Bundle Info is not a dictionary')
    found=info_checks(info,expected_bundle,expected_channel)
    valid=command(['/usr/bin/codesign','--verify','--strict','--deep',str(app)]).returncode==0
    found.append(check('complete_bundle_signature',valid,'The enclosing and nested seals must verify.'))
    parent=signing(app)
    found.append(check('selected_signature_team',bool(expected_team) and parent['TeamIdentifier']==expected_team,
        'A valid local/ad hoc signature does not establish the chosen distribution signer.'))
    found.append(check('hardened_runtime',parent['runtime'],'The candidate enables the reviewed hardened runtime.'))
    if expected_channel=='developer-id':
        found.extend(developer_id_checks(parent))
    children={};parent_arch=None;architecture_match=True
    executable=info.get('CFBundleExecutable')
    if not isinstance(executable,str) or executable in ['', '.', '..'] or '/' in executable or '\x00' in executable:
        raise RuntimeError('Invalid executable leaf')
    helpers=dict(STORE_HELPERS if expected_bundle=='com.respawnstudios.traverse' else HELPERS)
    if helper_symbols.HEALTH_VERSION_KEY in info:
        helpers['drive-health-worker']=str(expected_bundle)+'.drive.health'
    found.extend(drive_health_checks(app,info,expected_bundle,expected_team,expected_channel))
    files=[app/'Contents/MacOS'/executable]+[app/'Contents/Helpers'/name for name in helpers]
    service_binary=app/'Contents/XPCServices'/helper_symbols.HEALTH_SERVICE_LEAF/'Contents/MacOS'/helper_symbols.HEALTH_SERVICE_EXECUTABLE
    if helper_symbols.HEALTH_SERVICE_VERSION_KEY in info:files.append(service_binary)
    parent_identifier=info.get('CFBundleIdentifier')
    service_role=parent_identifier+'.drive.health.xpc' if isinstance(parent_identifier,str) else None
    for index,file in enumerate(files):
        if file.is_symlink() or not file.is_file():architecture_match=False;continue
        try:
            target=read_target(file);deployment=target_admitted(target)
            deployment_detail='Observed platform '+str(target['platform'])+', minimum '+'.'.join(map(str,target['minimumOS']))+'; requires macOS at or below15.0.'
        except (ValueError,OSError):deployment=False;deployment_detail='Binary deployment metadata is missing, malformed, changed or outside the qualified format.'
        found.append(check('binary_minimum_macos_'+file.name,deployment,deployment_detail))
        arch=command(['/usr/bin/lipo','-archs',str(file)])
        observed=set(arch.stdout.decode('ascii','replace').split()) if arch.returncode==0 else set()
        if index==0:parent_arch=observed
        else:
            architecture_match=architecture_match and observed==parent_arch
            identity=signing(file)
            if file != service_binary:children[file.name]=entitlements(file)
            expected_role=service_role if file==service_binary else helpers[file.name]
            found.append(check('helper_role_'+file.name,identity['Identifier']==expected_role,
                'Helper role identifiers must match the selected reviewed role.'))
            found.append(check('helper_team_'+file.name,bool(expected_team) and identity['TeamIdentifier']==expected_team,
                'Each helper must be signed by the selected team.'))
            if expected_channel=='developer-id':
                found.extend(developer_id_checks(identity,'_'+file.name))
        links=command(['/usr/bin/otool','-L',str(file)])
        lines=links.stdout.decode('utf-8','replace').splitlines()[1:]
        paths=[line.strip().split(' (',1)[0] for line in lines if line.strip()]
        found.append(check('runtime_links_'+file.name,links.returncode==0 and bool(paths)
            and all(p.startswith(('/System/Library/','/usr/lib/','@rpath/','@loader_path/','@executable_path/')) for p in paths),
            'No build-machine library path may be required at runtime.'))
    found.append(check('matching_qualified_architectures',architecture_match and parent_arch=={'arm64'} and len(children)==len(helpers),
        'The first candidate is arm64-only; every mandatory helper must match.'))
    updater_selected=expected_channel=='developer-id' \
        and info.get('MacExplorerAccessPolicy')=='sandbox-selected-v1' \
        and ((info.get('TraversePrivateUpdaterVersion')=='2.10.0' \
            and 'TraversePublicUpdaterVersion' not in info) \
            or (info.get('TraversePublicUpdaterVersion')=='2.10.0' \
            and 'TraversePrivateUpdaterVersion' not in info))
    found.extend(entitlement_checks(entitlements(app),children,updater_selected,expected_bundle,
        policy=info.get('MacExplorerAccessPolicy'),expected_team=expected_team))
    found.extend(updater_checks(app,info,expected_team,expected_channel))
    resources=app/'Contents/Resources'
    icon=info.get('CFBundleIconFile')
    icon_present=isinstance(icon,str) and '/' not in icon and bool(icon) and (resources/(icon if icon.endswith('.icns') else icon+'.icns')).is_file()
    if not icon_present and isinstance(info.get('CFBundleIconName'),str):icon_present=(resources/'Assets.car').is_file()
    found.append(check('app_icon_resource',icon_present,'An actual app icon resource and rendered icon acceptance are needed.'))
    try:
        notice=read(resources/'ThirdPartyNotices.txt',4<<20);manifest=json.loads(read(resources/'ThirdPartyManifest.json',131072))
        notice_ok=type(manifest.get('version')) is int and manifest.get('version')==1 and manifest.get('noticeSHA256')==hashlib.sha256(notice).hexdigest() and isinstance(manifest.get('components'),list) and bool(manifest.get('components'))
    except Exception:notice_ok=False
    found.append(check('bundled_notices',notice_ok,'Bundled notices must match their local integrity manifest.'))
    try: project_license_ok=hashlib.sha256(read(resources/'TraverseLicense.txt',65_536)).hexdigest()==GPL_V3_SHA256
    except Exception: project_license_ok=False
    found.append(check('bundled_project_license',project_license_ok,'The complete unmodified GNU GPLv3 license must be bundled.'))
    privacy=resources/'PrivacyInfo.xcprivacy'
    try:
        declaration=plistlib.loads(read(privacy,131072))
        privacy_ok=type(declaration.get('NSPrivacyTracking')) is bool and isinstance(declaration.get('NSPrivacyAccessedAPITypes'),list)
    except Exception:privacy_ok=False
    found.append(check('privacy_manifest_present',privacy_ok,'Required-reason APIs and actual data behavior need a reviewed privacy manifest.'))
    profile=app/'Contents/embedded.provisionprofile'
    if profile.is_file() and not profile.is_symlink() and profile.stat().st_size<=1<<20:
        decoded=command(['/usr/bin/security','cms','-D','-i',str(profile)])
        try:fields=plistlib.loads(decoded.stdout) if decoded.returncode==0 else {}
        except Exception:fields={}
        found.extend(profile_checks(fields,expected_bundle,expected_team,datetime.now(timezone.utc)))
    elif expected_channel=='app-store':found.append(check('embedded_testflight_profile',False,'No usable embedded provisioning profile was found.'))
    else:found.append(check('developer_id_profile_policy',not profile.exists() and not profile.is_symlink(),
        'Developer ID may omit an App Store profile; an unusable/redirected embedded profile is refused.'))
    return dict(version=1,inspectedAtUTC=datetime.now(timezone.utc).isoformat(),artifact=str(app),
        expectedChannel=expected_channel,
        staticPreflightPassed=all(item['passed'] for item in found),checks=found,readyToUpload=False,
        manualGates=['Final name/bundle/SKU approval','Provisioned sandbox file/helper/Keychain acceptance',
            'Distribution-compatible helper trust','Beta OS/hardware scope and access/recovery instructions',
            'Dependency/license and privacy/export answers','Owner upload approval'],
        actionsPerformed={'uploaded':False,'appStoreRecordCreated':False},accountStateInspected=False,credentialQueries=0)

def main():
    parser=argparse.ArgumentParser();parser.add_argument('app',type=Path)
    parser.add_argument('--expected-bundle-id');parser.add_argument('--expected-team-id');parser.add_argument('--output',type=Path)
    parser.add_argument('--expected-channel',choices=['app-store','developer-id'],default='app-store')
    args=parser.parse_args()
    if args.output:args.output=args.output.absolute()
    value=inspect(args.app.absolute(),args.expected_bundle_id,args.expected_team_id,args.expected_channel)
    if args.output:
        repo=Path(__file__).resolve().parents[2]
        if args.output.resolve()!=args.output.absolute() or not args.output.is_relative_to(repo/'.build'):
            raise RuntimeError('Inspection output must be an explicit nonredirected repo build path')
        with args.output.open('x') as output:json.dump(value,output,sort_keys=True,indent=2)
    print(json.dumps(dict(staticPreflightPassed=value['staticPreflightPassed'],readyToUpload=False,
        passed=[c['id'] for c in value['checks'] if c['passed']],blocked=[c['id'] for c in value['checks'] if not c['passed']],
        uploaded=False,recordCreated=False),indent=2))
    if not value['staticPreflightPassed']:raise SystemExit(2)

if __name__=='__main__':main()
