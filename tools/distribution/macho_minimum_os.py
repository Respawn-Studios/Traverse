"""Read only bounded Mach-O deployment metadata; no execution or signing."""
import os
import re
import stat
import struct

HEADER_BYTES = 32
MAX_COMMANDS = 4096
MAX_COMMAND_BYTES = 1 << 20


def version(value):
    if not isinstance(value, str) or not re.fullmatch(r'[0-9]{1,5}(?:\.[0-9]{1,3}){0,2}', value):
        raise ValueError('Invalid minimum macOS version')
    parts = tuple(int(p) for p in value.split('.'))
    parts += (0,) * (3-len(parts))
    if parts[0] < 1 or parts[0] > 65535 or any(p > 255 for p in parts[1:]):
        raise ValueError('Minimum macOS version is outside packed bounds')
    return parts


def packed(value):
    return (value >> 16, (value >> 8) & 255, value & 255)


def command_bounds(header):
    if len(header) != HEADER_BYTES or header[:4] != b'\xcf\xfa\xed\xfe':
        raise ValueError('Expected the qualified thin little-endian64 Mach-O header')
    count, size = struct.unpack_from('<II', header, 16)
    if not 1 <= count <= MAX_COMMANDS or not 8 <= size <= MAX_COMMAND_BYTES or size % 8:
        raise ValueError('Mach-O load-command bounds refused')
    return count, size


def decode(data):
    count, size = command_bounds(data[:HEADER_BYTES])
    if len(data) != HEADER_BYTES + size:
        raise ValueError('Truncated or unexpected Mach-O command region')
    offset = HEADER_BYTES
    found = None
    for _ in range(count):
        if offset + 8 > len(data):
            raise ValueError('Truncated Mach-O load command')
        command, length = struct.unpack_from('<II', data, offset)
        if length < 8 or length % 8 or offset + length > len(data):
            raise ValueError('Invalid Mach-O load-command size')
        if command == 0x32:
            if found is not None or length < 24:
                raise ValueError('Missing or duplicated build-version fields')
            platform, minimum, sdk, tools = struct.unpack_from('<IIII', data, offset+8)
            if length != 24 + tools*8:
                raise ValueError('Inconsistent build-tool records')
            found = dict(platform=platform, minimumOS=packed(minimum), sdk=packed(sdk))
        offset += length
    if offset != len(data) or found is None:
        raise ValueError('No unique complete LC_BUILD_VERSION')
    return found


def admitted(target):
    return target['platform'] == 1 and target['minimumOS'][0] > 0 and target['minimumOS'] <= (15, 0, 0)


def read_target(path):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
    try:
        before = os.fstat(fd)
        if not stat.S_ISREG(before.st_mode):
            raise ValueError('Binary deployment metadata requires a regular file')
        header = os.pread(fd, HEADER_BYTES, 0)
        _, size = command_bounds(header)
        if before.st_size < HEADER_BYTES + size:
            raise ValueError('Binary ends inside its load commands')
        target = decode(header + os.pread(fd, size, HEADER_BYTES))
        after, linked = os.fstat(fd), os.stat(path, follow_symlinks=False)
        fields = ('st_dev', 'st_ino', 'st_mode', 'st_size', 'st_mtime_ns', 'st_ctime_ns')
        if any(getattr(before, f) != getattr(after, f) or getattr(after, f) != getattr(linked, f) for f in fields):
            raise ValueError('Binary changed during deployment inspection')
        return target
    finally:
        os.close(fd)
