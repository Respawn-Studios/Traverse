#!/usr/bin/env python3
"""Review existing native recordings using one cached offline frame decoder."""
import argparse
import hashlib
import json
from pathlib import Path
import sys
import uuid

sys.dont_write_bytecode = True
REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / 'tools'))
import dev


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('cases', nargs='+')
    parser.add_argument('--review-id', default='current')
    parser.add_argument('--forensic', action='store_true', help='Decode a failed Settings, analysis or Help capture for diagnosis; never marks acceptance.')
    args = parser.parse_args()
    if not 1 <= len(args.cases) <= 8 or len(set(args.cases)) != len(args.cases):
        raise ValueError('Choose one to eight distinct generated recordings')
    if not 1 <= len(args.review_id) <= 24 or any(
            value not in 'abcdefghijklmnopqrstuvwxyz0123456789-' for value in args.review_id):
        raise ValueError('A short lowercase review identifier is required')
    for token in args.cases:
        roots = [dev.BUILD / family / token for family in ('traverse-development', 'traverse-release')]
        existing = [root for root in roots if root.exists() or root.is_symlink()]
        if len(existing) != 1:
            raise ValueError('One exact generated recording root is required')
        root = existing[0]
        if str(uuid.UUID(token)).upper() != token or root.resolve() != root \
                or not (root / 'reservation.json').is_file() or (root / 'reservation.json').is_symlink():
            raise ValueError('An exact existing generated recording is required')
        if root.parent.name == 'traverse-release' and json.loads((root / 'reservation.json').read_bytes()).get('action') not in ('traverse-command-finder', 'traverse-native-help-diagnostics'):
            raise ValueError('Release-root decode is limited to generated command discovery and Help diagnostics')

    source = Path(__file__).with_name('review_development.swift')
    frozen = digest(source)
    cache = dev.local_directory('ui-motion')
    binary, receipt = cache / 'frame-review', cache / 'compiler.json'
    if binary.is_symlink() or receipt.is_symlink():
        raise ValueError('Redirected decoder cache refused')
    previous = json.loads(receipt.read_text()) if receipt.exists() else {}
    reuse = binary.is_file() and previous.get('sourceSHA256') == frozen \
        and previous.get('binarySHA256') == digest(binary)
    report = dict(passed=False, offlineDecodeOnly=True, screenRequests=0,
                  synthesizedFrames=0, sourceSHA256=frozen, decoderReused=reuse, clips=[])
    result = dev.local_directory('ui-motion/reviews') / (dev.stamp() + '.json')
    try:
        if not reuse:
            candidate = cache / ('frame-review-' + dev.stamp())
            log = dev.execute(['xcrun', 'swiftc', '-O', '-parse-as-library', '-swift-version', '6',
                               '-strict-concurrency=complete', '-module-cache-path',
                               str(dev.local_directory('compiler-cache/swift')), str(source), '-o', str(candidate)],
                              'build-frame-review', timeout=180)
            if digest(source) != frozen:
                raise RuntimeError('Frame decoder source changed during compilation')
            candidate.replace(binary)
            receipt.write_text(json.dumps(dict(sourceSHA256=frozen, binarySHA256=digest(binary),
                                               buildLog=str(log.relative_to(REPO))), indent=2) + '\n')
        for token in args.cases:
            roots = [dev.BUILD / family / token for family in ('traverse-development', 'traverse-release')]
            root = next(root for root in roots if root.is_dir())
            marker = json.loads((root / 'reservation.json').read_bytes())
            flags = ['--assert-no-black', '--assert-smooth-pages']
            if args.forensic:
                action = marker.get('action')
                forensic_flags = {'settings-sidebar-v1': '--forensic-settings',
                                  'native-analysis-persistence': '--forensic-analysis',
                                  'help-form-motion-v1': '--forensic-help'}
                if action not in forensic_flags:
                    raise ValueError('Forensic mode is limited to failed Settings, analysis or Help recordings')
                flags = [forensic_flags[action]]
            log = dev.execute([str(binary), token, '--review-id', args.review_id, *flags],
                              'decode-native-frames', timeout=90, tooling=False)
            rows = json.loads(log.read_text())
            if not rows or any(row.get('decodedFrames', 0) < 3
                               or not args.forensic and row.get('captureGeometryVerified') is not True for row in rows):
                raise RuntimeError('Complete-frame decode or capture geometry failed')
            report['clips'].append(dict(case=token, observations=rows, log=str(log.relative_to(REPO))))
        if digest(source) != frozen:
            raise RuntimeError('Frame decoder source changed during review')
        report['passed'] = not args.forensic
        report['forensicOnly'] = args.forensic
    finally:
        result.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(dict(passed=report['passed'], forensicOnly=args.forensic, decodedCases=len(args.cases), decoderReused=reuse,
                          decodedFrames=sum(row['decodedFrames'] for value in report['clips']
                                            for row in value['observations']), report=str(result))))


if __name__ == '__main__':
    main()
