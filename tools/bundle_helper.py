"""Publish a signed helper without overwriting an executable's live inode.

Staging is beside the app, never inside its sealed/shipped contents. Failed
stages are retained. This concerns regenerable build products, not operation
journals or atomic replacement of user files.
"""
from __future__ import annotations
import json
import os
from pathlib import Path
import stat
import subprocess
import uuid

MAXIMUM_HELPER_BYTES = 32 * 1024 * 1024


def regular(path: Path):
    facts = path.lstat()
    if not stat.S_ISREG(facts.st_mode) or facts.st_nlink != 1 or facts.st_uid != os.getuid():
        raise ValueError('Refusing redirected/shared helper artifact')
    if not 0 < facts.st_size <= MAXIMUM_HELPER_BYTES:
        raise ValueError('Helper artifact exceeds build staging bound')
    return facts


def directory(path: Path):
    path.mkdir(mode=0o700, exist_ok=True)
    facts = path.lstat()
    if not stat.S_ISDIR(facts.st_mode) or facts.st_uid != os.getuid() or facts.st_mode & 0o077:
        raise ValueError('Unsafe private helper staging directory')


def publish(source: Path, destination: Path, *, staging_root: Path,
            signing_arguments: list[str], signing_environment: dict[str, str],
            strip_debug: bool = False) -> None:
    """Validate/sign before one rename. Caller's build lock covers the sources.

    `staging_root` must be outside the app on the product filesystem. Existing
    destination checks are repeated before replacement; no symlink is followed
    at publication. No signing fallback or original-file removal is attempted.
    """
    before = regular(source)
    if destination.exists() or destination.is_symlink(): regular(destination)
    directory(staging_root)
    if len(list(staging_root.iterdir())) >= 64:
        raise ValueError('Retained helper staging limit reached; inspect failures')
    if staging_root.stat().st_dev != destination.parent.stat().st_dev:
        raise ValueError('Helper stage and destination must share a filesystem')
    case = staging_root / str(uuid.uuid4()).upper()
    case.mkdir(mode=0o700)
    staged = case / destination.name
    published = False
    try:
        descriptor = os.open(source, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW)
        with os.fdopen(descriptor, 'rb') as current, staged.open('xb') as output:
            opened = os.fstat(current.fileno())
            if (opened.st_dev, opened.st_ino, opened.st_size, opened.st_mtime_ns) != \
                    (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns):
                raise ValueError('Helper source changed before staging')
            remaining = before.st_size
            while remaining:
                block = current.read(min(65536, remaining))
                if not block: raise ValueError('Helper source ended during staging')
                output.write(block); remaining -= len(block)
            if current.read(1): raise ValueError('Helper source grew during staging')
            output.flush(); os.fsync(output.fileno())
            after = os.fstat(current.fileno())
            if (opened.st_dev, opened.st_ino, opened.st_size, opened.st_mtime_ns) != \
                    (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns):
                raise ValueError('Helper source changed during staging')
        staged.chmod(0o755)
        if strip_debug:
            # Symbols remain in the private matching dSYM, outside the app.
            # Strip before signing; the source cache is never modified here.
            subprocess.run(['/usr/bin/xcrun', 'strip', '-S', str(staged)],
                env=signing_environment, check=True, capture_output=True, timeout=30)
        subprocess.run([*signing_arguments, str(staged)], env=signing_environment,
            check=True, capture_output=True, timeout=30)
        subprocess.run(['/usr/bin/codesign', '--verify', '--strict', str(staged)],
            env=signing_environment, check=True, capture_output=True, timeout=30)
        regular(staged)
        if destination.exists() or destination.is_symlink(): regular(destination)
        os.replace(staged, destination)
        published = True
        case.rmdir()  # Only this now-empty successful stage is removed.
    except Exception as error:
        receipt = case / 'failure.json'
        if not receipt.exists():
            with receipt.open('x') as output:
                json.dump(dict(passed=False, errorType=type(error).__name__,
                    originalNotOverwritten=not published, preserveStage=True), output)
        raise
