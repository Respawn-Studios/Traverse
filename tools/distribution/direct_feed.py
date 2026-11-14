#!/usr/bin/env python3
"""Fixed direct-public feed entry point with fresh shipping-case admission."""
import argparse
import sys
from pathlib import Path

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from distribution import public_feed
from distribution.traverse_packet import require_case


def prepare(case, source_kit_path):
    return public_feed.prepare(case, source_kit_path, public_feed.FeedEdition.DIRECT)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--case', required=True)
    action = parser.add_mutually_exclusive_group(required=True)
    action.add_argument('--source-kit', type=Path)
    action.add_argument('--cask', action='store_true', help='Render a local Cask from an already prepared shipping feed')
    args = parser.parse_args()
    case = require_case(args.case)
    if args.cask:
        public_feed.prepare_cask(case)
    else:
        prepare(case, args.source_kit)
