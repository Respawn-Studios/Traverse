"""Bounded local artifact reads, independent of builders and runtime controllers."""
import os
from pathlib import Path
import stat


def read(path: Path, maximum=2 << 20):
    if path.resolve() != path.absolute():
        raise RuntimeError('Redirected notice input/output')
    fd = os.open(path, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        before = os.fstat(fd)
        if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1 or before.st_size <= 0 or before.st_size > maximum:
            raise RuntimeError('Unbounded or shared notice file')
        with os.fdopen(os.dup(fd), 'rb') as stream:
            data = stream.read(maximum + 1)
        after = os.fstat(fd)
        if (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns, before.st_ctime_ns) != (
                after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns, after.st_ctime_ns) or len(data) != before.st_size:
            raise RuntimeError('Notice input changed during read')
        return data
    finally:
        os.close(fd)
