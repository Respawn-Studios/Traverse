# Releasing Traverse

A release pairs a reviewed source revision with its matching binaries,
dependencies, notices and symbols. The [distribution tools](../../tools/distribution/README.md)
provide the existing preparation and inspection commands. Development builds,
archive/export, notarization, upload and publication are separate results.
Use the [versioning policy](VERSIONING.md) when allocating a release and build.

## Source and license requirements

Original Traverse material uses [GPL-3.0-only](../../LICENSE). Preserve the terms
in [LICENSING.md](../../LICENSING.md), complete third-party notices, vendored
provenance and downstream patches. Keep dependency lockfiles, shared schemes,
resources and the scripts needed to reproduce the build.

Corresponding source must include the exact required non-system dependencies,
including locked Rust sources and the matching updater SDK source where used.
An upstream branch link, binary framework or private build-input snapshot does
not replace complete corresponding source. GitHub's automatic tag archive alone
may not contain separately supplied dependency sources.

Use the existing source exporter from a reviewed commit:

```sh
python3 -B tools/distribution/source_release.py --commit HEAD --selection contributor-v1 --bundle
```

This prepares a project archive, dependency sources, a retained/omitted file
inventory and a transparent source kit. It does not publish them. The exporter
reads committed Git objects; uncommitted changes are not included. The
[versioned selection](../../Distribution/SourceSelection.json) must retain every
required build input, license, notice, lockfile and supported build script.

Use `--selection full` when the complete tracked tree is required. The explicit
`--fetch-sources` option acquires missing pinned dependency sources; it is a
separate network step. Preserve the export's manifests and checksums. Build an
extracted copy using the [documented setup](DEVELOPMENT_SETUP.md) and verify its
source correspondence to the exact binary being distributed.

The private `source_capsule.py` inventory serves build reproducibility and
inspection. It is deliberately narrower than a public source export and must
not be presented as complete corresponding source.

## Artifact pipeline

Inspect the current command interface before selecting a distribution channel:

```sh
python3 -B tools/distribution/traverse.py --help
```

| Stage | Result | Separate remaining work |
| --- | --- | --- |
| Prepare | Fixed channel, access policy, source inputs and release configuration | Build and runtime acceptance |
| Archive | Xcode archive plus recorded input/product inspection | Export and distribution checks |
| Export | Signed app and verified export records | Installed behavior, packaging and applicable Apple processing |
| Notarize | Apple submission and eventual acceptance | Stapling, Gatekeeper assessment and final artifact verification |
| Upload | An artifact submitted to its destination | Processing, approval and actual availability |
| Publish | Selected assets/feed become available to their intended audience | Verify the live download/update route and record the released identity |

Use the recorded release directory for subsequent tool actions. Do not switch a
retained configuration's channel, access policy or version to repurpose an old
artifact. Validate the actual app and every bundled helper: architecture, bundle
identity, entitlements, signatures, notices and required symbols.

Local-review output cannot be promoted by editing its records. A fresh direct
public shipping case selects Developer ID, `local-user-v1`, the public updater,
`--shipping-candidate`, and an explicit version/build. Its separate Xcode tag
and signed `MacExplorerReleasePurpose=direct-shipping-v1` must agree with the
saved case through archive, export, notarization, DMG and direct-feed admission.
Select `--arch arm64` or `--arch x86_64` when preparing the case. That selection
is immutable too: the signed app marker and observed app/helper slices must
match before notarization and again during DMG readback. Intel is qualified for
the direct edition; App Store/TestFlight Intel is not covered by that work.
The existing local-review direct case and scoped public composition retain
their separate admission boundaries. Source support alone does not qualify a
shipping artifact; native acceptance and the applicable Apple processing and
delivery checks remain separate. After a successful local export, the direct
shipping app uses `notarize_direct_app.py`; its separate submission, accepted
status, stapling and Gatekeeper checks precede DMG preparation.

For Developer ID distribution, app/installer signing, notarization acceptance,
stapling and Gatekeeper assessment must bind to the exact final files. For App
Store delivery, upload, processing and review are separate from export. Native
runtime and installed/update acceptance remain necessary for the affected
workflows regardless of channel.

Use the [Release installer smoke test](https://github.com/Respawn-Studios/Traverse/actions/workflows/release-installers.yml)
to check a GitHub release on both macOS 15 architectures. Maintainers dispatch
it with a draft release ID or leave the ID empty to check the latest release.
GitHub requires push access to read draft assets. Each job verifies the installer
checksum, app version and signing identity, installs the app in its isolated
runner, and checks startup and normal quit. Choose **homebrew** to use the
official tap for both architectures and verify the same published checksum
before installation.

## Update channels

Keep these compositions and delivery records distinct:

- **Private updater:** `private_feed.py` prepares its own signed appcast and
  release assets for the private update route.
- **Public updater:** `public_feed.py` binds its public appcast to the exact app,
  DMG, source kit, input inventory and signatures.
- **Direct public access:** the direct composition uses its separate identity,
  storage and feed configuration. It must not reuse a sandboxed/private feed as
  an access-policy migration shortcut.

The scoped and direct public feeds currently use the same Ed25519 public key
and signing account. Their routes and signed app identities are distinct; this
source change does not rotate the key. Feed generation is not upload or
publication. Keep test/local-review feeds off live routes and verify the
delivered artifact and source URLs after a release is published.

The shipping archive saves a checked snapshot of its inputs. The updater uses
that snapshot to select the release notes for its exact version and build.

The direct ARM endpoint stays at `direct-updates/appcast.xml`. Intel uses
`direct-updates-intel/appcast.xml`, with matching note, archive and source routes.
This keeps existing ARM clients compatible without relying on XML item order
or inventing an Intel hardware token Sparkle doesn't define. Each lane admits
one matching-architecture notarized package; both use the same source kit.

## Homebrew Cask preparation

After a qualified direct shipping case has prepared its signed public feed, run:

```sh
python3 -B tools/distribution/direct_feed.py --case RELEASE_CASE_UUID --cask
```

For a release with both independently prepared architectures, render the one
official recipe from the ARM case and its matching Intel case:

```sh
python3 -B tools/distribution/direct_feed.py --case ARM_CASE_UUID --cask --intel-case INTEL_CASE_UUID
```

This writes `direct-updates/traverse.rb` inside that ignored release case, using
its exact DMG checksum, version/build and official immutable download URL. It
retains the exact fresh direct shipping admission checks; local-review artifacts
are refused. A paired recipe checks that version, build, source kit and build
input inventory agree, then uses Homebrew's `on_arm` and `on_intel` blocks to
select the verified DMG. Both require macOS 15 or later, following the
[Homebrew Cask format](https://docs.brew.sh/Cask-Cookbook).
It contains no data-removal hooks or quarantine bypass. Generation neither
publishes the artifact nor creates a tap. Before separately publishing a recipe,
verify the official download is live and matches the recorded checksum, and
perform the applicable Homebrew review and installed acceptance.

The official [Homebrew tap](https://github.com/Respawn-Studios/homebrew-tap)
checks the latest immutable full GitHub release hourly, with a manual Actions
trigger when needed. Its updater checks both architecture catalogs, source-kit
agreement, GitHub asset digests and the delivered installer bytes before making
a cask commit. A publisher acceptance comment in the official release notes must bind the
recipe and both installer hashes to both-architecture parsing and a real ARM
installation with cold startup. This editable statement records the publisher’s
checks; it is separate from immutable artifact identities and is not independent
test evidence. Drafts and prereleases are excluded; a failed check leaves the
existing cask unchanged. Publish and verify both download routes before promoting
a release to Latest. This tap automation does not replace signed app-feed
generation, installed acceptance or the user's choice to upgrade.

## Symbols and crash reports

Retain the app and required helper dSYMs with matching binary UUIDs and
architectures. Preserve symbol manifests alongside the exact package and rollback
artifacts; an incremental compiler cache is not a symbol archive.
Older `.xcarchive` bundles may be compacted with macOS metadata-preserving
`ditto` ZIP storage after every regular member and symlink has been verified.
Keep a locator, archive checksum and member inventory beside the case; restore
and revalidate the archive before using a tool that expects its original path.
The published DMG, source kit and current notarized app stay independently
identifiable. Compaction doesn't reset a test result or execution allowance.

Use `tools/distribution/symbolicate_report.py` only with an explicitly supplied
generated or consented report and its matching binary/dSYM. Unknown images or
missing source lines remain unresolved. Review reports and symbols for sensitive
paths or context before sharing them; symbols need not be publicly distributed
merely because they are required for support.

## Privacy and publication review

Review the selected source, captures, notices and distribution records for
credentials, personal paths and user-file contents. Ignoring or deleting a file
does not remove earlier Git history. Publishing an existing repository's history
and publishing a reviewed source snapshot require separate privacy review.

Use [Privacy](../../PRIVACY.md), [Security](../../SECURITY.md) and the
[community/distribution guide](COMMUNITY_AND_DISTRIBUTION.md) for reporting and
audience boundaries. A source export or successful package check is not privacy
clearance, installed acceptance or permission to publish.
