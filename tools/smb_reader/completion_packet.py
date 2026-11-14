"""Fresh generated B10 completion packet under the owner's overnight authority.

512 MiB total / 128 MiB per case / 81,920 aggregate entries. Failed evidence stays intact.
Generated unsafe-link controls must point only inside their own admitted case.
"""
import fcntl
import json
import os
from pathlib import Path
import stat
import uuid
import sys
sys.dont_write_bytecode = True
from packet import REPO, MIB, directory, put

ROOT = REPO / '.build/b10-completion-qualification'


def measured(case):
    pending = [case]
    total = count = source = receipts = 0
    inode_paths = {}
    while pending:
        path = pending.pop(); info = path.lstat(); count += 1
        amount = max(info.st_size, info.st_blocks * 512); total += amount
        if info.st_uid != os.getuid() or info.st_dev != case.lstat().st_dev:
            raise RuntimeError('Changed completion fixture ownership/device')
        if stat.S_ISDIR(info.st_mode):
            pending.extend(path.iterdir())
        elif stat.S_ISLNK(info.st_mode):
            # These are explicit generated refusal fixtures, never traversal.
            target = Path(os.readlink(path))
            if not target.is_absolute(): target = path.parent / target
            if '..' in target.parts or not target.is_relative_to(case / 'source'):
                raise RuntimeError('Generated refusal link escapes its case')
        elif stat.S_ISREG(info.st_mode):
            if info.st_nlink > 1:
                inode_paths.setdefault((info.st_dev, info.st_ino, info.st_nlink), []).append(path)
        else:
            raise RuntimeError('Unexpected completion fixture entry')
        if path != case:
            first = path.relative_to(case).parts[0]
            if first == 'source': source += amount
            elif first != 'stores': receipts += amount
    if any(links != len(paths) or links > 4 for (_, _, links), paths in inode_paths.items()):
        raise RuntimeError('Unaccounted hard-link alias in completion fixture')
    return dict(bytes=total, entries=count, sourceBytes=source, receiptBytes=receipts)


def audit():
    directory(ROOT)
    result = dict(bytes=0, entries=0, sourceBytes=0, receiptBytes=0, reservedBytes=0, reservedEntries=0)
    for case in ROOT.iterdir():
        if case.name == '.budget.lock':
            if not stat.S_ISREG(case.lstat().st_mode): raise RuntimeError('Unsafe completion budget lock')
            continue
        if not stat.S_ISDIR(case.lstat().st_mode) or str(uuid.UUID(case.name)).upper() != case.name:
            raise RuntimeError('Unexpected completion case')
        value = json.loads((case / 'reservation.json').read_bytes())
        amount, entries = value.get('bytes'), value.get('entries')
        if type(amount) is not int or type(entries) is not int or not 0 < amount <= 128 * MIB or not 0 < entries <= 32768:
            raise RuntimeError('Invalid completion reservation')
        current = measured(case)
        if current['bytes'] > amount or current['entries'] > entries:
            raise RuntimeError('Completion case allowance exceeded')
        for key, count in current.items(): result[key] += count
        result['reservedBytes'] += amount; result['reservedEntries'] += entries
    if result['reservedBytes'] > 512 * MIB or result['reservedEntries'] > 81920 or result['sourceBytes'] > 32 * MIB or result['receiptBytes'] > 24 * MIB:
        raise RuntimeError('Completion aggregate allowance exceeded')
    return result


def reserve(action, amount=4 * MIB, entries=512):
    directory(ROOT)
    with (ROOT / '.budget.lock').open('a+b') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        before = audit()
        if not 0 < amount <= 128 * MIB or not 0 < entries <= 32768 or before['reservedBytes'] + amount > 512 * MIB or before['reservedEntries'] + entries > 81920:
            raise RuntimeError('No completion packet headroom')
        case = directory(ROOT / str(uuid.uuid4()).upper())
        put(case / 'reservation.json', dict(version=1, action=action, bytes=amount, entries=entries))
        return case
