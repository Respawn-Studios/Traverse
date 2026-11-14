"""Exact Traverse App Store helper packaging; no development-signing fallback."""
import os
from pathlib import Path
import plistlib
import stat
import subprocess
import uuid
from distribution import release_candidate

REPO = Path(__file__).resolve().parents[2]
PARENT = 'com.respawnstudios.traverse'
TEAM = 'CDLNJRG82U'
IDENTIFIERS = {'browser': PARENT+'.smb.browser', 'resolver': PARENT+'.smb.resolver', 'sftp': PARENT+'.sftp.metadata'}
CHANNELS = {'app-store-v1':'app-store','developer-id-v1':'developer-id',
    'developer-id-local-user-qualification-v1':'developer-id',
    'developer-id-local-user-public-qualification-v1':'developer-id',
    'developer-id-local-user-public-shipping-v1':'developer-id'}
SCOPED = 'sandbox-selected-v1'
LOCAL = 'local-user-v1'

def access_policy(env):
    tag = env.get('MAC_EXPLORER_TRAVERSE_BUILD')
    policy = env.get('MAC_EXPLORER_ACCESS_POLICY')
    expected = LOCAL if tag in ('developer-id-local-user-qualification-v1',
        'developer-id-local-user-public-qualification-v1',
        'developer-id-local-user-public-shipping-v1') else SCOPED
    if tag not in CHANNELS or policy != expected or env.get('ENABLE_APP_SANDBOX') != ('YES' if policy == SCOPED else 'NO'):
        raise RuntimeError('Explicit matching Traverse access policy required')
    return policy

def helper_rights(policy):
    if policy == SCOPED: return {'com.apple.security.app-sandbox':True,'com.apple.security.inherit':True}
    if policy == LOCAL: return {}
    raise RuntimeError('Unknown helper access policy')

def configuration(app, env):
    if env.get('PRODUCT_BUNDLE_IDENTIFIER') != PARENT: raise RuntimeError('Unknown App Store parent')
    tag=env.get('MAC_EXPLORER_TRAVERSE_BUILD')
    channel=CHANNELS.get(tag)
    policy=access_policy(env)
    if env.get('DEVELOPMENT_TEAM') != TEAM or channel is None or env.get('MAC_EXPLORER_DISTRIBUTION_CHANNEL') != channel \
            or env.get('ENABLE_HARDENED_RUNTIME') != 'YES':
        raise RuntimeError('Incomplete Traverse sandbox/signing configuration')
    identity = env.get('EXPANDED_CODE_SIGN_IDENTITY', '')
    if len(identity) != 40 or any(c not in '0123456789ABCDEFabcdef' for c in identity):
        raise RuntimeError('Existing configured Apple signing identity required; no ad hoc fallback')
    root = REPO/'.build/traverse-release'
    if app.resolve() != app or app.name != 'Traverse.app' or not app.is_relative_to(root):
        raise RuntimeError('Traverse product must stay inside its isolated release root')
    if app != Path(env.get('TARGET_BUILD_DIR','/'))/Path(env.get('CONTENTS_FOLDER_PATH','/')).parent:
        raise RuntimeError('Traverse helper output differs from the selected Xcode product')
    for path in [app, app/'Contents', app/'Contents/Helpers', app/'Contents/Resources']:
        if path.is_symlink() or path.exists() and (not path.is_dir() or path.stat().st_uid != os.getuid()):
            raise RuntimeError('Redirected/unowned App Store product')
    info=app/'Contents/Info.plist'
    if info.is_file():
        fields=plistlib.loads(info.read_bytes())
        if fields.get('CFBundleIdentifier')!=PARENT or fields.get('MacExplorerDistributionChannel')!=channel \
                or fields.get('MacExplorerAccessPolicy') != policy:
            raise RuntimeError('Installed Traverse metadata does not match the signing configuration')
        purpose=fields.get(release_candidate.RELEASE_PURPOSE_KEY)
        if tag=='developer-id-local-user-public-shipping-v1':
            if purpose!=release_candidate.DIRECT_SHIPPING_PURPOSE:
                raise RuntimeError('Direct shipping signed purpose differs')
        elif release_candidate.RELEASE_PURPOSE_KEY in fields:
            raise RuntimeError('Non-shipping Traverse product carries a shipping purpose')
    return identity

def verify(helper, role, policy=SCOPED):
    subprocess.run(['/usr/bin/codesign','--verify','--strict',str(helper)],check=True,capture_output=True,timeout=30)
    result=subprocess.run(['/usr/bin/codesign','-d','-vv',str(helper)],check=True,capture_output=True,timeout=30)
    facts=dict(line.split('=',1)for line in result.stderr.decode().splitlines()if'='in line)
    if facts.get('Identifier')!=IDENTIFIERS[role] or facts.get('TeamIdentifier')!=TEAM:
        raise RuntimeError('Bundled helper signer/role differs from Traverse')
    if 'runtime' not in facts.get('CodeDirectory', '') and '(runtime)' not in result.stderr.decode():
        raise RuntimeError('Bundled helper requires hardened runtime')
    result=subprocess.run(['/usr/bin/codesign','-d','--entitlements','-','--xml',str(helper)],check=True,capture_output=True,timeout=30)
    if (plistlib.loads(result.stdout) if result.stdout.strip() else {}) != helper_rights(policy):
        raise RuntimeError('Unexpected helper access policy rights')

def write_manifest(app, roles):
    expected={'sftp'} if set(roles)=={'sftp'} else {'browser','resolver'}
    if set(roles)!=expected: raise RuntimeError('Incomplete App Store helper family')
    policy=access_policy(os.environ)
    for role, helper in roles.items(): verify(helper,role,policy)
    name='SFTPHelperManifest.plist' if expected=={'sftp'} else 'SMBHelperManifest.plist'
    destination=app/'Contents/Resources'/name
    if destination.is_symlink() or destination.exists() and (not destination.is_file() or destination.stat().st_nlink!=1 or destination.stat().st_uid!=os.getuid()):
        raise RuntimeError('Unsafe App Store manifest destination')
    channel=CHANNELS.get(os.environ.get('MAC_EXPLORER_TRAVERSE_BUILD'))
    if channel is None:raise RuntimeError('Explicit Traverse distribution channel required')
    fields=dict(version=3,channel=channel,accessPolicy=policy,parentIdentifier=PARENT,teamIdentifier=TEAM,
        roles={role:dict(identifier=IDENTIFIERS[role])for role in sorted(roles)})
    stage=destination.with_name('.'+name+'-'+str(uuid.uuid4()).upper())
    fd=os.open(stage,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW|os.O_CLOEXEC,0o644)
    with os.fdopen(fd,'wb')as output: output.write(plistlib.dumps(fields));output.flush();os.fsync(output.fileno())
    os.replace(stage,destination)
