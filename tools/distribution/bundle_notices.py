"""Validate and publish only generated text resources before the app is sealed."""
import os
import hashlib
from pathlib import Path
import stat
import tempfile
from distribution.notices import verify_outputs,read,OUTPUT

GPL_V3_SHA256 = '3972dc9744f6499f0f9b2dbf76696f2ae7ad8af9b23dde66d6af86c9dfb36986'

def embed(app: Path):
    resources=app/'Contents/Resources'
    resources.mkdir(mode=0o755,exist_ok=True)
    for directory in [app,app/'Contents',resources]:
        facts=directory.lstat()
        if not stat.S_ISDIR(facts.st_mode) or facts.st_uid!=os.getuid():raise RuntimeError('Unsafe bundled notice directory')
    values=verify_outputs()
    assets=list(zip(['ThirdPartyNotices.txt','ThirdPartyManifest.json'],values))
    assets.append(('PrivacyInfo.xcprivacy',read(OUTPUT/'PrivacyInfo.xcprivacy',131072)))
    license_text = read(OUTPUT.parent/'LICENSE',65_536)
    if hashlib.sha256(license_text).hexdigest() != GPL_V3_SHA256:
        raise RuntimeError('Project GPLv3 text differs from the unmodified GNU license')
    assets.append(('TraverseLicense.txt',license_text))
    for name,data in assets:
        target=resources/name
        if target.exists() or target.is_symlink():
            facts=target.lstat()
            if not stat.S_ISREG(facts.st_mode) or facts.st_uid!=os.getuid() or facts.st_nlink!=1:
                raise RuntimeError('Unsafe bundled notice resource')
        fd,stage=tempfile.mkstemp(prefix='.mac-explorer-notice-',dir=app.parent)
        try:
            with os.fdopen(fd,'wb') as stream:stream.write(data);stream.flush();os.fsync(stream.fileno())
            os.chmod(stage,0o644);os.replace(stage,target)
        finally:
            if Path(stage).exists():Path(stage).unlink() # Only this unpublished regenerable text stage.
    return len(values[0])
