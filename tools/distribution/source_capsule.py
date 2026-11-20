"""Private, hash-bound copies of recorded release sources; never restores files."""
import gzip
import hashlib
import io
import os
from pathlib import Path, PurePosixPath
import re
import stat
import tarfile
from build_crash_reporter import reviewed_sources as reviewed_crash_sources

MAX_FILES = 2048
MAX_FILE_BYTES = 1 << 20
MAX_LARGE_FILE_BYTES = 2 << 20
MAX_SOURCE_BYTES = 32 << 20
MAX_ARCHIVE_BYTES = 32 << 20
ROOTS = {'App', 'Packages', 'Workers', 'Distribution', 'tools'}
SUFFIXES = {'.swift', '.rs', '.c', '.h', '.m', '.py', '.toml', '.lock', '.plist', '.entitlements', '.xcconfig', '.xcfilelist'}
RELEASE_INPUTS = {'Distribution/'+name for name in ('ReleaseHistory.json','PrivateUpdates.json','PublicUpdates.json','DirectPublicUpdates.json','Sparkle.lock.json')}
RELEASE_INPUTS.add('Distribution/LicenseSupplements/Sparkle-2.10.0.txt')
RELEASE_INPUTS.update({
    'Distribution/LicenseSupplements/delegate-0.13.5/LICENSE-APACHE',
    'Distribution/LicenseSupplements/delegate-0.13.5/LICENSE-MIT',
    'Distribution/LicenseSupplements/index.json',
    'Distribution/LicenseSupplements/russh-0.65.1/LICENSE.txt',
    'Distribution/LicenseSupplements/russh-0.65.1/PUBLISHED-COPYRIGHT-HEADERS.txt',
    'Distribution/LicenseSupplements/russh-0.65.2/LICENSE.txt',
    'Distribution/LicenseSupplements/russh-0.65.2/PUBLISHED-COPYRIGHT-HEADERS.txt',
    'Distribution/LicenseSupplements/russh-cryptovec-0.62.0/LICENSE.txt',
    'Distribution/LicenseSupplements/russh-cryptovec-0.62.0/PUBLISHED-COPYRIGHT-HEADERS.txt',
    'Distribution/LicenseSupplements/russh-util-0.52.0/LICENSE-2.0.txt',
    'tools/distribution/dmg-requirements.txt',
})
EXACT_BUILD_RESOURCES = {
    'LICENSE',
    'App/MacExplorer/Resources/AppIcon.icns',
    'Distribution/PrivacyInfo.xcprivacy',
    'Distribution/ThirdPartyManifest.json',
    'Distribution/ThirdPartyNotices.txt',
    'MacExplorer.xcodeproj/project.pbxproj',
    'MacExplorer.xcodeproj/xcshareddata/xcschemes/MacExplorer.xcscheme',
    'MacExplorer.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved',
    'Vendor/smb2/PROVENANCE.json',
    'Vendor/smb2/DOWNSTREAM.patch',
}
LARGE_INPUTS = {'App/MacExplorer/Resources/AppIcon.icns', 'Distribution/ThirdPartyNotices.txt'}
WORKER_INPUTS = {'Workers/StorageScanner/'+name for name in (
    'README.md', 'classification-v3-vectors.tsv', 'frozen-origin.json',
    'policy-app-data-vectors.tsv', 'policy-vectors.tsv', 'result.sql')}
IDENTITY = ('st_dev', 'st_ino', 'st_mode', 'st_nlink', 'st_size', 'st_mtime_ns', 'st_ctime_ns')


def file_limit(name):
    return MAX_LARGE_FILE_BYTES if name in LARGE_INPUTS else MAX_FILE_BYTES


def manifest(value):
    if not isinstance(value, dict) or not 1 <= len(value) <= MAX_FILES:
        raise ValueError('Recorded source count refused')
    crash_sources = reviewed_crash_sources()
    for name, digest in value.items():
        path = PurePosixPath(name) if isinstance(name, str) else None
        if (path is None or len(name.encode('utf-8')) > 512 or '\\' in name or
            any(ord(c) < 32 or ord(c) == 127 for c in name) or path.is_absolute() or
            str(path) != name or '..' in path.parts or (len(path.parts) < 2 and name not in EXACT_BUILD_RESOURCES) or
            (path.parts[0] not in ROOTS and name not in EXACT_BUILD_RESOURCES and name not in crash_sources) or
            (path.suffix not in SUFFIXES and name not in WORKER_INPUTS and name not in RELEASE_INPUTS and name not in EXACT_BUILD_RESOURCES and name not in crash_sources) or
            (name in crash_sources and digest != crash_sources[name]) or
            not isinstance(digest, str) or not re.fullmatch('[0-9a-f]{64}', digest)):
            raise ValueError('Recorded source path/hash refused')
    return dict(value)


def same(left, right, fields=IDENTITY):
    return all(getattr(left, key) == getattr(right, key) for key in fields)


def read_at(root, relative, limit):
    """No-follow component walk, bounded bytes and descriptor/linked rechecks."""
    root = Path(root)
    parts = PurePosixPath(relative).parts
    if root.resolve() != root or not parts or any(p in ('', '.', '..') for p in parts) or parts[0] == '/':
        raise ValueError('Source root/path refused')
    opened = [os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)]
    names = []
    fd = None
    try:
        root_facts = os.fstat(opened[0])
        for part in parts[:-1]:
            child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=opened[-1])
            names.append(part)
            opened.append(child)
        fd = os.open(parts[-1], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC, dir_fd=opened[-1])
        before = os.fstat(fd)
        if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1 or not 0 <= before.st_size <= limit:
            raise ValueError('Source type/size refused')
        data = bytearray()
        while len(data) <= before.st_size:
            chunk = os.read(fd, min(65536, before.st_size + 1 - len(data)))
            if not chunk:
                break
            data.extend(chunk)
        after = os.fstat(fd)
        linked = os.stat(parts[-1], dir_fd=opened[-1], follow_symlinks=False)
        if len(data) != before.st_size or not same(before, after) or not same(after, linked):
            raise ValueError('Source changed while copying')
        for index, name in enumerate(names):
            if not same(os.fstat(opened[index+1]), os.stat(name, dir_fd=opened[index], follow_symlinks=False), ('st_dev', 'st_ino', 'st_mode')):
                raise ValueError('Source parent changed while copying')
        if not same(root_facts, root.lstat(), ('st_dev', 'st_ino', 'st_mode')):
            raise ValueError('Source root changed while copying')
        return bytes(data)
    finally:
        if fd is not None:
            os.close(fd)
        for directory in reversed(opened):
            os.close(directory)


def create(repo, wanted, output, recovered=None):
    repo = Path(repo).absolute()
    output = Path(output).absolute()
    wanted = manifest(wanted)
    if recovered is None:
        recovered = {}
    if not isinstance(recovered, dict) or not set(recovered) <= set(wanted):
        raise ValueError('Unrecorded recovery override refused')
    total = 0
    # Exclusive output: failed partial capsules remain evidence and are not reused.
    fd = os.open(output, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
    with os.fdopen(fd, 'wb') as raw:
        with gzip.GzipFile(filename='', fileobj=raw, mode='wb', mtime=0) as zipped:
            with tarfile.open(fileobj=zipped, mode='w|', format=tarfile.PAX_FORMAT) as archive:
                for name, digest in sorted(wanted.items()):
                    root, relative = recovered.get(name, (repo, name))
                    data = read_at(root, relative, file_limit(name))
                    total += len(data)
                    if total > MAX_SOURCE_BYTES or hashlib.sha256(data).hexdigest() != digest:
                        raise ValueError('Recorded source hash/total refused')
                    entry = tarfile.TarInfo(name)
                    entry.size = len(data)
                    entry.mode = 0o644
                    entry.mtime = 0
                    archive.addfile(entry, io.BytesIO(data))
                    if raw.tell() > MAX_ARCHIVE_BYTES:
                        raise ValueError('Capsule byte bound reached')
        raw.flush()
        os.fsync(raw.fileno())
        if raw.tell() > MAX_ARCHIVE_BYTES:
            raise ValueError('Capsule byte bound reached')
    payload = read_at(output.parent, output.name, MAX_ARCHIVE_BYTES)
    return dict(files=len(wanted), sourceBytes=total, archiveBytes=len(payload), sha256=hashlib.sha256(payload).hexdigest())


def inspect(path, wanted, expected_sha256):
    """Read only an already bound private capsule; no arbitrary archive import."""
    path = Path(path).absolute()
    payload = read_at(path.parent, path.name, MAX_ARCHIVE_BYTES)
    return inspect_payload(payload, wanted, expected_sha256)


def inspect_payload(payload, wanted, expected_sha256):
    """Validate one bounded payload so a caller can parse those same bytes."""
    wanted = manifest(wanted)
    if not isinstance(payload, bytes) or len(payload) > MAX_ARCHIVE_BYTES:
        raise ValueError('Private capsule byte bound reached')
    if not isinstance(expected_sha256, str) or hashlib.sha256(payload).hexdigest() != expected_sha256:
        raise ValueError('Private capsule identity refused before archive parsing')
    seen = set()
    total = 0
    with tarfile.open(fileobj=io.BytesIO(payload), mode='r:gz') as archive:
        for entry in archive:
            if entry.name not in wanted or entry.name in seen or not entry.isfile() or not 0 <= entry.size <= file_limit(entry.name):
                raise ValueError('Private capsule member refused')
            total += entry.size
            if total > MAX_SOURCE_BYTES:
                raise ValueError('Private capsule source bound reached')
            with archive.extractfile(entry) as member:
                data = member.read(file_limit(entry.name)+1)
            if len(data) != entry.size or hashlib.sha256(data).hexdigest() != wanted[entry.name]:
                raise ValueError('Private capsule source differs from recorded input')
            seen.add(entry.name)
    if seen != set(wanted):
        raise ValueError('Private capsule is missing recorded sources')
    return dict(passed=True, files=len(seen), sourceBytes=total, archiveBytes=len(payload), sha256=expected_sha256, extractedFiles=0)
