# Versioning Traverse

Traverse uses `MAJOR.MINOR.PATCH` for product releases and a separate, increasing
build number for packaged candidates. The release version tells you what changed;
the build number identifies the particular app and lets the updater order it.

## Public releases

The first public release is **0.1.0**. We are opening an early version of Traverse
to a wider audience, with supported workflows and remaining limits documented.
**1.0.0** will mark our stable-release milestone. Making the repository public
does not by itself change that maturity label.

Our policy follows [Semantic Versioning](https://semver.org/), applied to the
app's documented behavior and compatibility rather than promising that every
internal Swift or Rust type is a public API:

| Change | Version example |
| --- | --- |
| Compatible bug fixes and polish | `0.1.0` → `0.1.1` |
| New features or substantial compatible improvements | `0.1.1` → `0.2.0` |
| Stable public compatibility milestone | `0.x.y` → `1.0.0` |
| Deliberately incompatible changes after 1.0 | `1.x.y` → `2.0.0` |

During `0.x`, a minor release may change behavior or a documented interface;
release notes must explain the change. After 1.0, incompatible public changes
require a major release. Preferences, workspace formats and recovery records
retain explicit schema versions and migration rules in either phase. A version
bump never authorizes deleting retained work or silently overwriting a file.

## Previews and build numbers

Previews target the next product version. For example, a preview for `0.2.0`
appears in the app as `0.2.0 (104)` with its Preview identity. A GitHub prerelease
can use a tag such as `v0.2.0-beta.1`; the macOS bundle keeps the numeric product
version and the separate build number. Preview and public apps keep their own
profiles and update channels.

Each new distributable candidate receives a higher integer build number, even
when its product version stays the same. Build numbers continue across the
prelaunch beta cycle and are never reset for a public launch. Older beta display
versions therefore do not decide which binary is newer. Release history and
packaging select notes by the exact **version and build** pair.

An incremental local compile does not consume another product version. Releasing
changed app bytes does require a new candidate identity and the relevant checks.
Qualified features use the shared source in Preview and public packages; release
review verifies their availability rather than maintaining a reduced public fork.

## Tags and release assets

Public releases use tags such as `v0.1.0`. The tag, signed app, installer,
corresponding-source kit and release notes must agree. Published tags and assets
are immutable; a correction ships as a new release. A draft or a candidate that
passed notarization is still awaiting publication and installed acceptance.

See [Releasing Traverse](OPEN_SOURCE_RELEASE.md) for the artifact and delivery
checks, and [the roadmap](../ROADMAP.md) for what we would like to build next.
