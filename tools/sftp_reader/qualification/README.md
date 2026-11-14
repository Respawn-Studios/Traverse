# Production SFTP crate

`build_ordinary_worker.py` in the parent directory builds this crate's
`src/bin/catalog_worker.rs` with its explicit production feature list. The
`qualification` directory/package naming predates ordinary app integration;
the source and lockfile here are active build inputs. Do not delete them with
generated `target` outputs or rename the crate as a routine cleanup.

`src/` holds the concrete protocol, authentication, transfer and action modules.
The parent `catalog/` provides shared catalog support. Keep wire changes paired
with the concrete Swift owners in `Packages/ExplorerKit/Sources/LocalStorage/`.
The parent builder owns feature selection, compiler identity, symbols and cache
fingerprints; ordinary builds stay locked and offline.

Other binaries/features in `Cargo.toml` retain their own generated investigations.
`cargo test --all-features` is not a substitute for the supported app/package
workflow and does not grant a live listener, credential or fixture scope.
Follow the [worker guide](../README.md) and supported app/package workflow.
