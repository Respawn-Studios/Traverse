# Pinned dependencies

`smb2/` contains the source of the already qualified Rust SMB reader at upstream
commit `b7e88bdf948e8e99923a40c9c2dcf3cba0f2d4aa`, with the tested response,
security and lifetime repairs. The original MIT and Apache-2.0 licenses remain.
`PROVENANCE.json` records every included file; `DOWNSTREAM.patch` records changes
against that upstream commit, including making its manifest independent of the
ignored qualification workspace. This is a maintained downstream snapshot,
not a claim that upstream includes or supports our changes.

Run `python3 -B tools/smb_reader/vendor_verified_source.py` to verify the tracked
snapshot without a network request. The browser wrapper owns the dependency
lockfile. Builds must use that lock and never download or alter sources during
Xcode compilation; initial dependency acquisition is a separate explicit step.

The app uses this source through its SMB wrapper and separately qualified
browse, transfer and file-action paths. Library capabilities alone do not enable
an application feature, credential cache, mount or security fallback. Keep the
Swift protocol, Rust wrapper and app capability policy consistent.

## Local crash capture

`PLCrashReporter/` is version **1.12.2**, upstream commit
`0254f941c646b1ed17b243654723d0f071e990d0`. The adjacent provenance manifest
binds all 350 regular files, sizes, hashes and executable modes. Its 22 upstream
`include/` symlinks are materialized with their exact target bytes. The manifest
also records the reviewed downstream patch, including private exclusive report
creation, its complete diff and the original upstream hashes. Darwin's full-path
and leaf-only no-follow flags are alternatives; combining them prevents file
creation. The source exporter retains the no-links rule.

Run `python3 -B tools/build_crash_reporter.py verify-sources` for offline source
verification. `prepare` builds the upstream macOS framework scheme only when
the source, compiler/SDK identity or cached framework/dSYM changes. The ordinary
`tools/dev.py build` performs that preparation before app linking. Direct release
builders must also prepare before their app build. Xcode's embed phase verifies
and signs the prepared framework; it never compiles or downloads dependencies.
All outputs share `.build/crash-reporter-tooling/`, with the matching dSYM beside
the framework under `derived/Build/Products/Release-macosx/`.

Preserve the upstream MIT-style license, historical Apache-2.0 notice and current
protobuf-c BSD-2-Clause notice. `tools/distribution/notices.py` includes these and
the full Apache-2.0 text in the app's generated notices. This dependency supplies
local native crash capture only; network submission, memory introspection,
analytics and file-content collection are not authorized by its inclusion.
