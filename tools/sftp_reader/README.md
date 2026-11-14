# SFTP worker

The ordinary app uses the Rust crate in [qualification/](qualification/README.md),
built by `build_ordinary_worker.py` through `tools/build_network_helpers.py`.
The directory and Cargo package names are historical; this is production source,
not a copied experiment. Use the [local setup](../../docs/engineering/DEVELOPMENT_SETUP.md)
and normal commands from the repository root:

```sh
python3 -B tools/dev.py build
python3 -B tools/dev.py test --filter LocalStorageTests --serial
```

## Ownership

| Location | Responsibility |
| --- | --- |
| `qualification/Cargo.toml`, `Cargo.lock` | Exact production graph and feature definitions |
| `qualification/src/bin/catalog_worker.rs` | Ordinary private IPC worker entry |
| `qualification/src/` | SSH/SFTP framing, authentication and concrete operation modules |
| `catalog/` | Parent protocol/catalog support used by the ordinary worker |
| `build_ordinary_worker.py` | Selected features, source fingerprint, bounded offline compile and embedding |
| `App/MacExplorer/Features/Connections/` | Native connection, browser and editor presentation |
| `Packages/ExplorerKit/Sources/LocalStorage/` | App-facing sessions, helper identity, observations and operation ownership |

The native owner and worker enforce the selected operation together. A host/path
string, displayed row or copied connection layout grants no file authority.
Keep input validation, cancellation, source revalidation and truthful outcomes in
the existing owners. New protocol fields must update both ends, rather than adding
a second UI-side writer. Browsing remains metadata-only; bodies are read for an
explicit operation. Credentials and user file bodies do not belong in logs.

## Generated storage

| Root | Use |
| --- | --- |
| `.build/ssh-profile-tooling/` | Ordinary Cargo caches, target and worker outputs |
| `.build/traverse-release/tooling/rust-sftp/` | Symbol-bearing distribution/review Cargo codegen |
| `.build/b11-reader-tooling/` | Earlier isolated reader experiments; not the ordinary worker cache |

Run `tools/worker_setup.py` for the existing locked/offline setup. Preserve pinned
inputs and reuse the normal caches; do not run acquisition or live server scripts
as routine preparation. The [roadmap](../../docs/ROADMAP.md) describes product direction. A package feature
name or passing parser control does not activate a product route.
