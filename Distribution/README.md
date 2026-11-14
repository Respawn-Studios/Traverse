# Distribution configuration

This directory holds versioned edition configuration, entitlements, Info
templates, dependency notices, source selection and release history. Generated
apps, archives, installers, signing material and credentials do not belong in Git.

`ReleaseHistory.json` is the source of the app's generated release notes.
`SourceSelection.json` selects the complete contributor source, including tests,
resources, locks and pinned dependency source. Local working notes and generated
output are not public source dependencies.

## Editions and update feeds

| Composition | Feed configuration | Access/data boundary |
| --- | --- | --- |
| Private beta | `PrivateUpdates.json` | Invitation-protected private distribution |
| Scoped public | `PublicUpdates.json` | Selected-folder policy and its public feed |
| Direct public | `DirectPublicUpdates.json` | Local-user policy, separate direct namespace and `/direct-updates/` feed |

The public and direct feeds are invitation-free and use separate default-off
automatic-check preferences. They reuse the common update lifecycle, exact
artifact admission and signature validation. A private/scoped catalog cannot
supply a direct update. Broader file access does not imply permission to import
old authority-bearing histories or credentials into the direct namespace.

The current release-admission policy restricts public/direct updater candidates
to local review. A retained local-review artifact cannot be promoted into shipping
authority. Keep the enforced admission separate from whether a feature is
compiled into an app.

## Release pipeline

Use `tools/distribution/traverse.py` to prepare, archive and export an exact
version. The website download and in-app update should reference the same
admitted installer bytes, with matching release notes, source kit, hashes and
code identity. Feed preparation does not deploy a backend or publish a release.

Retain matching app/framework/helper dSYMs by Mach-O UUID. Complete the applicable
installed upgrade, profile, operation, Undo and updater checks on the exact
artifact. Notarization, stapling, Gatekeeper assessment, upload and publication
are separate steps. Keep a tested rollback until the new release is accepted.

App Store submission metadata and Developer ID notarization have different
requirements. Technical preflight does not decide legal export obligations or
infer portal answers. See the [release guide](../docs/engineering/OPEN_SOURCE_RELEASE.md)
and [distribution tools](../tools/distribution/README.md).
