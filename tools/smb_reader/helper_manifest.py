"""Small explicit local identity manifest; written before the enclosing seal."""
import plistlib
import os
import stat
from packet import digest

IDENTIFIERS = {'browser': 'local.macexplorer.smb.browser', 'resolver': 'local.macexplorer.smb.resolver'}


def write(app, roles, *, parent, team, case=None, replace=False):
    target = app / 'Contents/Resources/SMBHelperManifest.plist'
    for path in [app, app / 'Contents', target.parent]:
        if path.is_symlink(): raise RuntimeError('Redirected helper resource directory')
        if path.exists() and (not path.is_dir() or path.stat().st_uid != os.getuid()):
            raise RuntimeError('Unowned helper resource directory')
    target.parent.mkdir(mode=0o755, parents=True, exist_ok=True)
    if target.is_symlink(): raise RuntimeError('Redirected helper identity manifest')
    if target.exists():
        info = target.lstat()
        if not replace or not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_uid != os.getuid():
            raise RuntimeError('Existing helper identity manifest must not be replaced implicitly')
    value = dict(version=1, channel='qualification' if case else 'development', parentIdentifier=parent, teamIdentifier=team,
        roles={role: dict(identifier=IDENTIFIERS[role], sha256=digest(path)) for role, path in roles.items()})
    if case: value['case'] = case
    target.write_bytes(plistlib.dumps(value, sort_keys=False))
    return target
