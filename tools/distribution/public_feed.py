#!/usr/bin/env python3
"""Prepare one signed public feed from a qualified public app and source kit.

This producer never publishes. Only a separately admitted fresh shipping case
may reach the signer; local-review artifacts retain their original purpose.
"""
import argparse
import datetime
import hashlib
import json
import os
import plistlib
import re
import subprocess
import sys
from enum import Enum
from email.utils import format_datetime
from pathlib import Path

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from distribution import preflight, private_feed, release_candidate, release_notes, source_capsule, sparkle
from distribution.traverse_packet import REPO, audit, directory, put, require_case

PUBLIC_KEY = 'MG4sBFr76ad6D4nGo+i2VuZ4hxVMEQZToBUjYyui3IA='
ORIGIN = 'https://respawn-studios.com'
BASE = ORIGIN + '/products/traverse/public-updates'
FEED_URL = BASE + '/appcast.xml'
DIRECT_BASE = ORIGIN + '/products/traverse/direct-updates'
DIRECT_FEED_URL = DIRECT_BASE + '/appcast.xml'
DIRECT_STORAGE_NAMESPACE = 'com.respawnstudios.traverse.direct'


class FeedEdition(Enum):
    SCOPED = 'scoped'
    DIRECT = 'direct'


def edition_contract(edition):
    if edition is FeedEdition.SCOPED:
        return dict(base=BASE, feed=FEED_URL, policy='sandbox-selected-v1',
                    marker='TraversePublicUpdaterVersion', mode='public-updater-v1',
                    channel='public-free-v1', output='public-updates', title='Traverse public updates')
    if edition is FeedEdition.DIRECT:
        return dict(base=DIRECT_BASE, feed=DIRECT_FEED_URL, policy='local-user-v1',
                    marker='TraverseDirectPublicUpdaterVersion', mode='direct-public-updater-v1',
                    channel='direct-public-free-v1', output='direct-updates', title='Traverse direct updates')
    raise ValueError('Unknown public feed edition')
SOURCE_LIMIT = 256 << 20
DMG_LIMIT = 128 << 20
SHA = re.compile(r'[a-f0-9]{64}\Z')
SIGNATURE = re.compile(r'[A-Za-z0-9+/]{86}==\Z')
VERSION = re.compile(r'(?:0|[1-9][0-9]{0,2})(?:\.(?:0|[1-9][0-9]{0,2})){2}\Z')
BUILD = re.compile(r'[1-9][0-9]{0,9}\Z')


def build_inputs_sha256(inputs):
    if not isinstance(inputs, dict) or not 0 < len(inputs) <= 4096 \
            or any(not isinstance(name, str) for name in inputs):
        raise ValueError('Invalid build input table')
    digest = hashlib.sha256()
    total = 0
    for name in sorted(inputs, key=lambda value: value.encode('utf-8')):
        value = inputs[name]
        if not isinstance(name, str) or not isinstance(value, str) or not SHA.fullmatch(value) \
                or len(name.encode('utf-8')) > 512 or name.startswith('/') or '\\' in name \
                or any(part in ('', '.', '..') for part in name.split('/')) \
                or any(ord(c) < 32 or ord(c) == 127 for c in name):
            raise ValueError('Invalid build input')
        total += len(name.encode('utf-8')) + 66
        if total > 512 << 10:
            raise ValueError('Build input table exceeds bound')
        digest.update((name + '\0' + value + '\n').encode('utf-8'))
    return digest.hexdigest()


def source_record(path, inspected, build_inputs):
    """Bind an inspected source kit to every recorded native archive input."""
    if not path.is_absolute() or path.is_symlink() or path.resolve() != path \
            or not path.is_relative_to(REPO / '.build/source-release') or not path.is_file():
        raise ValueError('Unowned source kit path')
    if not isinstance(inspected, dict) or inspected.get('format') != 'traverse-source-kit-v1' \
            or type(inspected.get('bytes')) is not int or not 0 < inspected['bytes'] <= SOURCE_LIMIT \
            or path.stat().st_size != inspected['bytes'] or not SHA.fullmatch(inspected.get('sha256', '')) \
            or not re.fullmatch(r'[a-f0-9]{40}', inspected.get('sourceCommit', '')) \
            or inspected.get('sourceSelection') not in ('full', 'contributor-v1') \
            or not SHA.fullmatch(inspected.get('sourceManifestSHA256', '')):
        raise ValueError('Invalid inspected source kit')
    project = inspected.get('projectSourceSHA256')
    if not isinstance(project, dict) or not project:
        raise ValueError('Missing project source inventory')
    build_inputs_sha256(build_inputs)
    if any(project.get(name) != digest for name, digest in build_inputs.items()):
        raise ValueError('The source kit does not match every native build input')
    return dict(filename=inspected['sha256'] + '.tar.gz', bytes=inspected['bytes'],
                sha256=inspected['sha256'], format=inspected['format'],
                sourceCommit=inspected['sourceCommit'], sourceSelection=inspected['sourceSelection'],
                sourceManifestSHA256=inspected['sourceManifestSHA256'])


def public_app_record(info, item, actual_cdhash, edition=FeedEdition.SCOPED):
    contract = edition_contract(edition)
    other_marker = ('TraverseDirectPublicUpdaterVersion' if edition is FeedEdition.SCOPED
                    else 'TraversePublicUpdaterVersion')
    if not isinstance(info, dict) or info.get(contract['marker']) != '2.10.0' \
            or any(key in info for key in ('TraversePrivateUpdaterVersion', other_marker)) \
            or info.get('CFBundleIdentifier') != 'com.respawnstudios.traverse' \
            or info.get('CFBundleShortVersionString') != item['version'] \
            or info.get('CFBundleVersion') != item['build'] \
            or info.get('MacExplorerDistributionChannel') != 'developer-id' \
            or info.get('MacExplorerAccessPolicy') != contract['policy'] \
            or info.get('SUFeedURL') != contract['feed'] or info.get('SUPublicEDKey') != PUBLIC_KEY \
            or not isinstance(actual_cdhash, str) or not re.fullmatch(r'[a-f0-9]{40}', actual_cdhash) \
            or actual_cdhash != item['admission']['appCDHash']:
        raise ValueError('The signed app is not the '
                         + ('scoped' if edition is FeedEdition.SCOPED else 'direct') + ' public updater')
    if edition is FeedEdition.DIRECT:
        if info.get('MacExplorerStorageMode') != 'portable' \
                or info.get(release_candidate.RELEASE_PURPOSE_KEY) != release_candidate.DIRECT_SHIPPING_PURPOSE \
                or info.get('TraverseDirectStorageNamespace') != DIRECT_STORAGE_NAMESPACE \
                or info.get('MacExplorerFolderServices') != 'public-folders-service-v1' \
                or type(info.get('TraverseDriveHealthServiceVersion')) is not int \
                or info['TraverseDriveHealthServiceVersion'] != 1 \
                or any(key in info for key in ('TraverseDriveHealthHelperVersion',
                    'MacExplorerReviewCase', 'MacExplorerSandboxQualificationCase',
                    'SUEnableInstallerLauncherService', 'SUEnableDownloaderService')) \
                or any(type(info.get(key)) is not type(value) or info[key] != value for key, value in (
                    ('SUVerifyUpdateBeforeExtraction', True), ('SURequireSignedFeed', True),
                    ('SUSignedFeedFailureExpirationInterval', 0), ('SUScheduledCheckInterval', 21600),
                    ('SUEnableAutomaticChecks', False), ('SUAutomaticallyUpdate', False),
                    ('SUAllowsAutomaticUpdates', False), ('SUEnableSystemProfiling', False),
                    ('SUEnableJavaScript', False))):
            raise ValueError('The signed app is not the exact direct updater')
    elif 'TraverseDirectStorageNamespace' in info or release_candidate.RELEASE_PURPOSE_KEY in info:
        raise ValueError('The scoped updater inherited direct storage')
    record = dict(mode=contract['mode'], bundleID='com.respawnstudios.traverse',
                  version=item['version'], build=item['build'], updaterVersion='2.10.0',
                  feedURL=contract['feed'], publicEDKey=PUBLIC_KEY,
                  appCDHash=item['admission']['appCDHash'])
    if edition is FeedEdition.DIRECT:
        record.update(accessPolicy=contract['policy'], storageNamespace=DIRECT_STORAGE_NAMESPACE,
                      driveHealthServiceVersion=1,
                      releasePurpose=release_candidate.DIRECT_SHIPPING_PURPOSE)
    return record


def admit_artifact(checked, item, entry, edition=FeedEdition.SCOPED):
    """Validate the immutable case and Developer ID receipt before signer access."""
    if edition is FeedEdition.DIRECT:
        checked = release_candidate.configuration(checked)
    contract = edition_contract(edition)
    if checked.get('shippingCandidate') is not True or checked.get('publicUpdater') is not True \
            or checked.get('privateUpdater') is True or checked.get('channel') != 'developer-id' \
            or checked.get('accessPolicy') != contract['policy'] \
            or checked.get('localReviewOnly') is True or checked.get('qualificationOnly') is True:
        raise ValueError('Only a fresh public-updater shipping case can supply a feed')
    request = checked.get('versionOverride')
    if not isinstance(request, dict) or item.get('version') != request.get('version') \
            or item.get('build') != request.get('build') or entry.get('version') != item.get('version') \
            or str(entry.get('build')) != item.get('build') or entry.get('state') == 'unreleased':
        raise ValueError('Frozen notes, case and DMG version must agree')
    version = item['version']; build = item['build']
    if not VERSION.fullmatch(version) or not BUILD.fullmatch(build) or int(build) > 2_147_483_647 \
            or item.get('id') != 'traverse-' + version.replace('.', '-') + '-' + build + '-arm64' \
            or item.get('filename') != f'Traverse-{version}-{build}-arm64.dmg' \
            or item.get('architecture') != 'arm64' or item.get('minimumOS') != '15.0' \
            or not SHA.fullmatch(item.get('sha256', '')) or type(item.get('bytes')) is not int \
            or not 0 < item['bytes'] <= DMG_LIMIT:
        raise ValueError('Only the bounded public arm64 DMG is admitted')
    proof = item.get('admission')
    exact = dict(schema=1, bundleID='com.respawnstudios.traverse', version=version, build=build,
                 channel='Developer ID', team='CDLNJRG82U', timestamped=True, stapled=True,
                 gatekeeper='accepted', container='dmg', containerStapled=True,
                 containerGatekeeper='accepted')
    if not isinstance(proof, dict) or not all(type(proof.get(key)) is type(value) and proof[key] == value
                                              for key, value in exact.items()) \
            or not re.fullmatch(r'[a-f0-9]{40,64}', proof.get('appCDHash', '')):
        raise ValueError('App and DMG signing/notarization admission are required')
    return checked


def canonical_feed(manifest, edition=FeedEdition.SCOPED):
    contract = edition_contract(edition)
    item = manifest['artifact']; source = manifest['sourceKit']; note = manifest['note']; app = manifest['app']
    if app.get('mode') != contract['mode'] or app.get('feedURL') != contract['feed']:
        raise ValueError('Feed app does not match its edition')
    if edition is FeedEdition.DIRECT:
        if app.get('accessPolicy') != contract['policy'] \
                or app.get('storageNamespace') != DIRECT_STORAGE_NAMESPACE \
                or app.get('driveHealthServiceVersion') != 1 \
                or app.get('releasePurpose') != release_candidate.DIRECT_SHIPPING_PURPOSE:
            raise ValueError('Direct feed identity mismatch')
    elif 'releasePurpose' in app:
        raise ValueError('Scoped feed inherited direct shipping purpose')
    for signature in (item['edSignature'], note['edSignature']):
        if not SIGNATURE.fullmatch(signature):
            raise ValueError('Exact Ed25519 signature required')
    release_date = datetime.date.fromisoformat(manifest['releaseDate'])
    date = datetime.datetime.combine(release_date, datetime.time(12), datetime.timezone.utc)
    if 'feedPreparedAtUTC' in manifest:
        timestamp = manifest['feedPreparedAtUTC']
        if not isinstance(timestamp, str) or not re.fullmatch(r'\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z', timestamp):
            raise ValueError('A canonical UTC feed preparation time is required')
        date = datetime.datetime.strptime(timestamp, '%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=datetime.timezone.utc)
    inputs = build_inputs_sha256(manifest['buildSourceSHA256'])
    direct_identity = (' accessPolicy="local-user-v1" storageNamespace="'
                       + DIRECT_STORAGE_NAMESPACE + '" driveHealthServiceVersion="1"'
                       + ' releasePurpose="' + release_candidate.DIRECT_SHIPPING_PURPOSE + '"'
                       if edition is FeedEdition.DIRECT else '')
    return f'''<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:traverse="https://respawn-studios.com/ns/traverse-updates/1"><channel>
<title>{contract['title']}</title><link>{ORIGIN}/products/traverse/</link><description>Public Traverse updates</description>
<item><title>Traverse {item['version']}</title><link>{ORIGIN}/products/traverse/</link>
<sparkle:version>{item['build']}</sparkle:version><sparkle:shortVersionString>{item['version']}</sparkle:shortVersionString>
<sparkle:minimumSystemVersion>15.0.0</sparkle:minimumSystemVersion><sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>
<pubDate>{format_datetime(date)}</pubDate>
<sparkle:releaseNotesLink sparkle:edSignature="{note['edSignature']}" sparkle:length="{note['bytes']}">{contract['base']}/notes/{item['build']}.html</sparkle:releaseNotesLink>
<enclosure url="{contract['base']}/archives/{item['sha256']}.dmg" length="{item['bytes']}" type="application/octet-stream" sparkle:edSignature="{item['edSignature']}"/>
<traverse:app mode="{contract['mode']}" bundleID="{app['bundleID']}" updaterVersion="{app['updaterVersion']}" appCDHash="{app['appCDHash']}"{direct_identity}/>
<traverse:source url="{contract['base']}/sources/{source['sha256']}.tar.gz" length="{source['bytes']}" sha256="{source['sha256']}" commit="{source['sourceCommit']}" selection="{source['sourceSelection']}" manifestSHA256="{source['sourceManifestSHA256']}" buildInputsSHA256="{inputs}"/>
</item></channel></rss>
'''.encode('utf-8')


def inspect_source(path):
    from distribution.source_kit import inspect_source_kit
    return inspect_source_kit(path)


def render_cask(checked, catalog, entry):
    """Render the direct edition only, from the same admitted feed identity."""
    contract = edition_contract(FeedEdition.DIRECT)
    item = catalog['artifact']; app = catalog['app']
    admit_artifact(checked, item, entry, FeedEdition.DIRECT)
    expected = dict(bundleID='com.respawnstudios.traverse', version=item['version'],
                    build=item['build'], updaterVersion='2.10.0', publicEDKey=PUBLIC_KEY,
                    appCDHash=item['admission']['appCDHash'],
                    releasePurpose=release_candidate.DIRECT_SHIPPING_PURPOSE)
    if catalog.get('schema') != 1 or catalog.get('channel') != contract['channel'] \
            or catalog.get('publicKey') != PUBLIC_KEY \
            or any(app.get(key) != value for key, value in expected.items()):
        raise ValueError('Cask and prepared direct feed identity must agree')
    canonical_feed(catalog, FeedEdition.DIRECT)
    # Only validated numeric version/build and lowercase hex enter Ruby strings.
    # The URL is the producer's immutable official route, never caller supplied.
    return f'''cask "traverse" do
  version "{item['version']},{item['build']}"
  sha256 "{item['sha256']}"

  url "{contract['base']}/archives/{item['sha256']}.dmg"
  name "Traverse"
  desc "Native macOS file explorer"
  homepage "{ORIGIN}/products/traverse/"

  depends_on arch: :arm64
  depends_on macos: :sequoia

  app "Traverse.app"
end
'''.encode('utf-8')


def prepare_cask(case):
    """Local recipe only; existing shipping admission runs before artifact reads."""
    checked = release_candidate.configuration(json.loads(
        source_capsule.read_at(case, 'configuration.json', 8192)))
    if checked.get('publicUpdater') is not True or checked.get('shippingCandidate') is not True \
            or checked.get('localReviewOnly') is True:
        raise ValueError('A fresh public-updater shipping case is required')
    contract = edition_contract(FeedEdition.DIRECT)
    output = case / contract['output']
    catalog = json.loads(source_capsule.read_at(output, 'direct-updates.json', 1 << 20))
    item = catalog['artifact']
    dmg = json.loads(source_capsule.read_at(case, 'dmg/manifest.json', 65536))
    if dmg.get('schema') != 1 or dmg.get('artifacts') != [
            {key: value for key, value in item.items() if key != 'edSignature'}]:
        raise ValueError('Cask must use the exact prepared final DMG')
    history = private_feed.frozen_history(case, item)
    entry = release_notes.release_for_build(history, item['version'], item['build'])
    recipe = render_cask(checked, catalog, entry or {})
    receipt = json.loads(source_capsule.read_at(output, 'prepared.json', 65536))
    if receipt.get('passed') is not True or receipt.get('binarySourceInputsMatched') is not True \
            or any(receipt.get(key) != value for key, value in dict(
                artifactSHA256=item['sha256'], sourceKitSHA256=catalog['sourceKit']['sha256'],
                version=item['version'], build=item['build']).items()):
        raise ValueError('Cask requires the matching prepared feed receipt')
    feed = source_capsule.read_at(output, 'appcast.xml', 2 << 20)
    canonical = canonical_feed(catalog, FeedEdition.DIRECT)
    trailer = re.fullmatch(rb'<!-- sparkle-signatures:\nedSignature: ([A-Za-z0-9+/]{86}==)\nlength: ([0-9]+)\n-->\n', feed[len(canonical):])
    if feed[:len(canonical)] != canonical or trailer is None or int(trailer[2]) != len(canonical) \
            or catalog['feed'] != dict(filename='appcast.xml', bytes=len(feed),
                                       sha256=hashlib.sha256(feed).hexdigest()) \
            or source_capsule.read_at(output, 'feed-signature-input.bin', 2 << 20) != canonical:
        raise ValueError('Cask requires the exact canonical prepared feed')
    private_feed.verify_signature(output / 'feed-signature-input.bin', trailer[1].decode())
    image = source_capsule.read_at(case, 'dmg/' + item['filename'], DMG_LIMIT)
    if len(image) != item['bytes'] or hashlib.sha256(image).hexdigest() != item['sha256']:
        raise ValueError('Cask DMG bytes differ from the prepared feed')
    directory(output)
    path = output / 'traverse.rb'
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
    with os.fdopen(fd, 'wb') as target:
        target.write(recipe); target.flush(); os.fsync(target.fileno())
    print(json.dumps(dict(case=case.name, cask=str(path.relative_to(case)), published=False,
                          artifactSHA256=item['sha256'])), flush=True)
    return path


def prepare(case, source_kit_path, edition=FeedEdition.SCOPED):
    contract = edition_contract(edition)
    config = json.loads(source_capsule.read_at(case, 'configuration.json', 8192))
    # Admit only an immutable shipping case before signing, Keychain or output.
    checked = release_candidate.configuration(config)
    if checked.get('publicUpdater') is not True or checked.get('shippingCandidate') is not True \
            or checked.get('localReviewOnly') is True:
        raise ValueError('A fresh public-updater shipping case is required')
    manifest = json.loads(source_capsule.read_at(case, 'dmg/manifest.json', 65536))
    if manifest.get('schema') != 1 or len(manifest.get('artifacts', [])) != 1:
        raise ValueError('Exactly one final DMG is required')
    item = manifest['artifacts'][0]
    history = private_feed.frozen_history(case, item)
    entry = release_notes.release_for_build(history, item['version'], item['build'])
    if entry is None:
        raise ValueError('Frozen release notes are missing')
    admit_artifact(checked, item, entry, edition)
    output = case / contract['output']
    if output.exists() or output.is_symlink():
        raise ValueError('Preserve the existing public feed preparation')
    app = case / 'notarized/Traverse.app'
    report = preflight.inspect(app, 'com.respawnstudios.traverse', 'CDLNJRG82U', 'developer-id')
    if any(not row['passed'] for row in report['checks']):
        raise ValueError('Distribution preflight did not pass')
    info = plistlib.loads(source_capsule.read_at(app, 'Contents/Info.plist', 1 << 20))
    # The DMG receipt was minted from the mounted app. Tie the separate
    # notarized app inspected above to that exact sealed code identity.
    app_record = public_app_record(info, item, preflight.signing(app)['cdhash'], edition)
    image = case / 'dmg' / item['filename']
    before = source_capsule.read_at(image.parent, image.name, DMG_LIMIT)
    if len(before) != item['bytes'] or hashlib.sha256(before).hexdigest() != item['sha256']:
        raise ValueError('DMG differs from signed admission')
    build_inputs = json.loads(source_capsule.read_at(case, 'archive-inputs.json', 1 << 20))['sourceSHA256']
    inspected = inspect_source(source_kit_path)
    source = source_record(source_kit_path, inspected, build_inputs)
    note_bytes = private_feed.notes(entry)
    if not 0 < len(note_bytes) <= 1 << 20:
        raise ValueError('Public release note exceeds its bound')
    sparkle.verify(); directory(output)
    signer = sparkle.UNPACKED / 'bin/sign_update'

    def sign(path):
        return subprocess.check_output([str(signer), '--account', 'Respawn-Traverse-Update-Signing-v1',
                                        '--disable-signing-warning', '-p', str(path)], timeout=45).decode().strip()

    archive_signature = sign(image)
    private_feed.verify_signature(image, archive_signature)
    note_path = output / (item['build'] + '.html')
    note_path.write_bytes(note_bytes)
    note_signature = sign(note_path)
    private_feed.verify_signature(note_path, note_signature)

    def record(path):
        data = source_capsule.read_at(path.parent, path.name, 2 << 20)
        return dict(filename=path.name, bytes=len(data), sha256=hashlib.sha256(data).hexdigest())

    public_item = dict(item, edSignature=archive_signature)
    catalog = dict(schema=1, channel=contract['channel'], publicKey=PUBLIC_KEY,
                   releaseDate=entry['date'],
                   feedPreparedAtUTC=datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
                   app=app_record, artifact=public_item,
                   sourceKit=source, buildSourceSHA256=build_inputs,
                   note=dict(**record(note_path), edSignature=note_signature),
                   feed=dict(filename='appcast.xml', bytes=1, sha256='0' * 64))
    feed_path = output / 'appcast.xml'
    feed_path.write_bytes(canonical_feed(catalog, edition))
    sign(feed_path)
    feed = source_capsule.read_at(feed_path.parent, feed_path.name, 2 << 20)
    tag = b'<!-- sparkle-signatures:\n'; index = feed.rfind(tag)
    match = re.fullmatch(rb'<!-- sparkle-signatures:\nedSignature: ([A-Za-z0-9+/]{86}==)\nlength: ([0-9]+)\n-->\n', feed[index:])
    if index < 0 or match is None or int(match[2]) != index or feed[:index] != canonical_feed(catalog, edition):
        raise RuntimeError('The upstream signer did not preserve the canonical public feed')
    unsigned = output / 'feed-signature-input.bin'; unsigned.write_bytes(feed[:index])
    private_feed.verify_signature(unsigned, match[1].decode())
    if source_capsule.read_at(image.parent, image.name, DMG_LIMIT) != before:
        raise RuntimeError('The DMG changed while signing')
    if inspect_source(source_kit_path) != inspected:
        raise RuntimeError('The source kit changed while signing')
    catalog['feed'] = record(feed_path)
    put(output / (contract['output'] + '.json'), catalog)
    put(output / 'prepared.json', dict(passed=True, published=False, websiteAdmission='NOT EXERCISED',
                                      sourcePrivacyReview=inspected.get('privacyReview', 'NOT EXERCISED'),
                                      binarySourceInputsMatched=True, artifactSHA256=item['sha256'],
                                      sourceKitSHA256=source['sha256'], version=item['version'], build=item['build'],
                                      invitationRead=False, privateKeyExported=False, packet=audit()))
    print(json.dumps(dict(case=case.name, prepared=True, published=False, build=item['build'])), flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--case', required=True)
    parser.add_argument('--source-kit', required=True, type=Path)
    args = parser.parse_args()
    prepare(require_case(args.case), args.source_kit)
