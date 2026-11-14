# Distribution tools

These tools prepare and inspect exact release artifacts. Preparation, signing,
notarization, installation, upload and publication are distinct actions. Read the
[release guide](../../docs/engineering/OPEN_SOURCE_RELEASE.md) before external
release work.

| Entry | Responsibility |
| --- | --- |
| `traverse.py` | Edition/version selection, archive and export |
| `source_release.py`, `source_kit.py` | Git-verified contributor source and transparent dependency/source bundle |
| `source_capsule.py` | Bounded snapshot of exact recorded build inputs |
| `private_feed.py` | Invitation-protected private-update producer |
| `public_feed.py`, `direct_feed.py` | Fixed scoped/direct entries over the shared signed-feed producer |
| `preflight.py`, `store_helpers.py` | Parent/helper identities, entitlements and product inspection |
| `helper_symbols.py` | Exact app/framework/helper UUID and symbol retention |
| `artifact_files.py` | Bounded artifact reads shared by inspection and notice generation |
| `release_notes.py`, `notices.py` | Deterministic bundled release notes and dependency notices |
| `direct_dmg.py`, `DMGArtwork.swift` | Developer ID installer and artwork |
| `sandbox.py`, `remote_editor_qa.py` | Isolated generated-data signed acceptance support |

Source inventories reuse the normal app, worker, resource and build-control
inputs. Vendored bytes and reviewed patches are verified at build/archive
boundaries. Runtime acceptance is evidence for its exact app and scenario; it
does not silently qualify a different rebuild. Public/direct shipping remains
subject to the enforced release-admission policy.

After changing dependency provenance or license inputs, review and regenerate the
bundled manifest and notices before building:

```sh
python3 -B tools/distribution/notices.py --write
python3 -B tools/distribution/notices.py --check
```

Prepare and archive refuse stale generated notices or release notes before
project generation and compilation. Generation is explicit; the release builder
does not silently rewrite reviewed source files.

## Symbols and crash diagnosis

Keep the exact distributed binaries and matching nonempty dSYMs. A rebuild with
the same version is not a symbol substitute. `symbolicate_report.py` reads one
explicitly staged generated or consented report and exact retained symbols; it
never collects reports from other apps. Unknown images and incomplete locations
remain unresolved rather than acquiring invented source lines.

Worker Rust source locations use the `traverse-source` prefix. In a debugger
session, map it to the matching source checkout:

```text
settings set target.source-map traverse-source /path/to/matching/checkout
```

This is session-local debugger setup. Review source paths and report contents
before sharing symbols or diagnostics. See [Privacy](../../PRIVACY.md).
