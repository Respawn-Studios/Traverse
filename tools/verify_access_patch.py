#!/usr/bin/env python3
"""Generated-only Traverse patch UI/settings loop, with owned process drain."""
import json
import os
from pathlib import Path
import signal
import subprocess
import time
import uuid

REPO = Path(__file__).resolve().parents[1]
BASE = REPO / '.build/traverse-patch-0.1.1'
APP = REPO / '.build/xcode/Build/Products/Debug/Mac Explorer.app/Contents/MacOS/Mac Explorer'


def main():
    BASE.mkdir(mode=0o700, parents=True, exist_ok=True)
    if BASE.resolve() != BASE or APP.resolve() != APP or not APP.is_file():
        raise RuntimeError('Expected isolated build/fixture paths')
    files = [p for p in BASE.rglob('*') if p.is_file() and not p.is_symlink()]
    if sum(p.stat().st_size for p in files) > 96 * 1024 * 1024 or len(files) > 400:
        raise RuntimeError('Patch evidence headroom exhausted; preserve existing evidence')
    root = BASE / str(uuid.uuid4()).upper()
    root.mkdir(mode=0o700)
    (root / 'Files/Folder').mkdir(parents=True)
    (root / 'Unselected').mkdir()
    (root / 'Blocker').write_text('generated setup failure control\n')
    (root / 'evidence').mkdir()
    (root / 'owned.txt').write_text('Traverse generated access patch v1\n')
    for index in range(12):
        (root / 'Files' / f'Generated {index:02d}.txt').write_text('generated metadata fixture\n')
    (root / 'input.json').write_text(json.dumps(dict(generatedOnly=True, maximumSeconds=45,
        cumulativeEnvelopeMiB=128, nativeRecorder=True, networkConnections=0, credentials=0)))
    env = os.environ.copy()
    env['MAC_EXPLORER_TEST_ROOT'] = str(root)
    env['TMPDIR'] = str(REPO / '.build/tmp') + '/'
    began = time.monotonic()
    with (root / 'run.log').open('xb') as output:
        process = subprocess.Popen([str(APP), '--verify-ui', '--check-access-patch'], env=env,
            cwd=REPO, stdin=subprocess.DEVNULL, stdout=output, stderr=subprocess.STDOUT, start_new_session=True)
        (root / 'process.json').write_text(json.dumps(dict(pid=process.pid, executable=str(APP))))
        timed_out = False
        try:
            process.wait(timeout=45)
        except subprocess.TimeoutExpired:
            timed_out = True
        finally:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait(timeout=3)
    result = json.loads((root / 'result.json').read_text()) if (root / 'result.json').is_file() else dict(passed=False)
    receipt = dict(case=str(root.relative_to(REPO)), actualExit=process.returncode,
        timedOut=timed_out, seconds=time.monotonic()-began, result=result)
    (root / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
    print(json.dumps(receipt, indent=2))
    if process.returncode != 0 or timed_out or result.get('passed') is not True:
        raise SystemExit(1)


if __name__ == '__main__':
    main()
