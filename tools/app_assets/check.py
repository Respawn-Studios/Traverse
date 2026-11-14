#!/usr/bin/env python3
"""Verify original icon resources; explicit publish accepts one retained render."""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import struct
import subprocess
import uuid

REPO=Path(__file__).resolve().parents[2]
SOURCE=REPO/'tools/app_assets/generate.swift'
RESOURCE=REPO/'App/MacExplorer/Resources/AppIcon.icns'
MANIFEST=REPO/'tools/app_assets/manifest.json'


def digest(path):return hashlib.sha256(path.read_bytes()).hexdigest()


def icon(path):
    if path.is_symlink() or not path.is_file() or path.stat().st_size>4<<20:raise RuntimeError('Icon resource type/size differs')
    data=path.read_bytes()
    if len(data)<8 or data[:4]!=b'icns' or struct.unpack('>I',data[4:8])[0]!=len(data):raise RuntimeError('Icon header invalid')
    offset=8;types=[]
    while offset<len(data):
        if len(data)-offset<8:raise RuntimeError('Truncated icon block')
        kind=data[offset:offset+4].decode('ascii');size=struct.unpack('>I',data[offset+4:offset+8])[0]
        if size<8 or size>len(data)-offset or kind in types:raise RuntimeError('Invalid/duplicate icon block')
        types.append(kind);offset+=size
    if not {'ic04','ic05','ic07','ic08','ic09','ic10','ic11','ic12','ic13','ic14'}.issubset(types):
        raise RuntimeError('All selected small/retina icon representations are required')
    return types


def main():
    parser=argparse.ArgumentParser();parser.add_argument('--publish-case');args=parser.parse_args()
    if args.publish_case:
        if str(uuid.UUID(args.publish_case)).upper()!=args.publish_case:raise RuntimeError('Canonical generated icon case required')
        case=REPO/'.build/icon-qualification'/args.publish_case
        if case.resolve()!=case:raise RuntimeError('Redirected icon case')
        proof=json.loads((case/'result.json').read_bytes())
        source=case/'assets/AppIcon.icns'
        if proof.get('passed') is not True or proof.get('sourceSHA256')!=digest(SOURCE) or proof.get('iconSHA256')!=digest(source):
            raise RuntimeError('Rendered icon does not match its original source/evidence')
        types=icon(source)
        roundtrip=case/'assets/roundtrip.iconset'
        subprocess.run(['/usr/bin/iconutil','-c','iconset',str(source),'-o',str(roundtrip)],check=True,capture_output=True,timeout=30)
        expected={f'icon_{size}x{size}'+('@2x' if scale==2 else '')+'.png':size*scale
            for size in [16,32,128,256,512] for scale in [1,2]}
        if set(p.name for p in roundtrip.iterdir())!=set(expected):raise RuntimeError('Icon round trip lost a representation')
        for name,size in expected.items():
            data=(roundtrip/name).read_bytes()
            if data[:8]!=b'\x89PNG\r\n\x1a\n' or struct.unpack('>II',data[16:24])!=(size,size):raise RuntimeError('Decoded icon dimensions differ')
        if RESOURCE.exists() or MANIFEST.exists():raise RuntimeError('Publish never replaces an existing product resource')
        RESOURCE.parent.mkdir(exist_ok=True)
        RESOURCE.write_bytes(source.read_bytes())
        MANIFEST.write_text(json.dumps(dict(version=1,variant='A',provisional=True,finalNameSelected=False,
            sourceSHA256=digest(SOURCE),iconSHA256=digest(RESOURCE),representations=expected,icnsTypes=types,
            generatedCase=case.name),sort_keys=True,indent=2)+'\n')
        (case/'evidence/roundtrip.json').write_text(json.dumps(dict(passed=True,representations=expected,resourceSHA256=digest(RESOURCE)),indent=2)+'\n')
    value=json.loads(MANIFEST.read_bytes())
    if value.get('sourceSHA256')!=digest(SOURCE) or value.get('iconSHA256')!=digest(RESOURCE):raise RuntimeError('Tracked icon source/resource changed')
    icon(RESOURCE)
    for path in [REPO/'App/MacExplorer/Info.plist',REPO/'Distribution/Info.plist']:
        if plistlib.loads(path.read_bytes()).get('CFBundleIconFile')!='AppIcon':raise RuntimeError('Build Info does not select the qualified icon')
    print(json.dumps(dict(passed=True,provisional=True,finalNameSelected=False,representations=10,bytes=RESOURCE.stat().st_size)))


if __name__=='__main__':main()
