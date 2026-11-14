# SMB worker

The ordinary app builds [smb2-browser/](smb2-browser/README.md) through
`tools/build_network_helpers.py`. Its library is the tracked, pinned
[Vendor/smb2](../../Vendor/smb2/); no acquired source copy is needed.
Use the [local setup](../../docs/engineering/DEVELOPMENT_SETUP.md),
`python3 -B tools/dev.py build` and relevant existing `LocalStorageTests`.

## Ownership

| Location | Responsibility |
| --- | --- |
| `smb2-browser/Cargo.toml`, `Cargo.lock`, `src/` | Ordinary Rust worker graph, framing and concrete SMB operations |
| `catalog/` | Shared catalog/authority support consumed by the worker |
| `Vendor/smb2/` | Upstream library source, downstream patch, licenses and provenance |
| `vendor_verified_source.py` | Verify that tracked vendor input without fetching another tree |
| `tools/build_network_helpers.py` | Source fingerprint, bounded offline compile, helper/resolver embedding |
| `App/MacExplorer/Features/Connections/` | Native connection, browsing and transfer/editor presentation |
| `Packages/ExplorerKit/Sources/LocalStorage/` | Concrete sessions, identity, observations and `SMBInPlace*` editing owners |

Uploads, downloads, actions and original-file editing reuse these owners. Preserve
exclusive publication, existing occupants, changed-file refusal and recorded
partial/uncertain outcomes. Do not make display metadata, a socket or a saved layout
an operation grant. Do not add a second UI-side writer or silently substitute
Copy/Delete for Move. Browsing stays metadata-only; credentials and user file
bodies must not enter logs.

## Generated storage

Ordinary registry, target and helper data use `.build/b10-network-tooling/`.
The symbol-bearing distribution/review lane uses
`.build/traverse-release/tooling/rust-smb/` for codegen and its existing separate
helper/symbol output. Preserve the pinned vendor source and lockfiles; generated
`target` files are not replacements for source. `tools/worker_setup.py` owns the
small locked/offline prerequisite check.

Edition activation remains in application composition. Source builds, signed
artifacts and installed behavior require separate validation. A live check requires its
explicit generated listener and scope; a source build does not grant a sign-in,
Keychain entry, mount or file mutation on an existing server.
