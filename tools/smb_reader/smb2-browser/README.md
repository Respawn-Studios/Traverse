# Production SMB crate

`tools/build_network_helpers.py` builds this manifest as the ordinary SMB worker.
Its historical package name includes `qualification`; it remains active source,
with a tracked lockfile and the pinned `../../../Vendor/smb2` path dependency.
Generated Cargo targets stay under the builder's ignored roots.

`src/` implements the worker protocol and concrete operations. `build.rs` and
the parent `catalog/` supply the existing native catalog/authority bridge.
Pair protocol changes with the concrete Swift session/operation owners in
`Packages/ExplorerKit/Sources/LocalStorage/`; preserve refusal, cancellation,
exclusive publication and durable outcomes at both ends.

Use the [worker guide](../README.md) and normal app/package commands.
Direct compilation, a Cargo feature name or a generated test does not activate
a held product capability or grant access to an existing server.
