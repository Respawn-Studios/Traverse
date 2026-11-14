# Development and release tools

Use the ordinary app, existing package suites and a small set of supported
commands. Start with the supported entries below and choose validation that
exercises the behavior being changed.

## Supported entries

| Entry | Purpose |
| --- | --- |
| `dev.py` | Incremental app build, Swift package tests and generated native feature checks |
| `worker_setup.py` | Offline production-worker prerequisite check; explicit `--fetch` seeds only the two locked Cargo caches |
| `generate_project.py` | Deterministic project creation when missing; regeneration is explicit |
| `build_storage_worker.py`, `build_network_helpers.py` | Bundled Rust worker builds |
| [distribution/](distribution/README.md) | Release configuration, source delivery, notices, signing, updates and DMG preparation |
| `distribution/source_release.py --commit HEAD [--selection contributor-v1]` | Prepare project/dependency archives and a retained/omitted Git-object inventory; no publication or privacy approval |
| `preview.py --native-configuration Debug --version … --build-number … --profile-case …` | Package the ordinary app for the existing Preview identity |
| `upgrade_preview.py --native-artifact … --expected-current-build …` | Refresh only a quit Preview, preserving its exact previous app and profile |
| `folder_services.py` | Shared exact folder-only Services declaration; no preference or registration change |
| [ui_motion/](ui_motion/README.md) | Record owned native windows and review existing captures with the shared decoder/cache |
| [archives/](archives/README.md) | Archive code ownership, package regressions and ordinary native checks |
| `maintenance/storage.py` | Generated-storage inventory and reviewed cleanup plans |

For initial compiler/dependency setup, use the [local setup guide](../docs/engineering/DEVELOPMENT_SETUP.md).
For a feature journey, use the [native workflow guide](NATIVE_WORKFLOWS.md).
Choose the relevant check; a menu of available flows is not a test quota.

## Validation without a second toolchain

Most contributions need a focused package suite and one ordinary app workflow.
The root `verify_*.py` commands retain deeper generated-file checks for archive
publication, operation recovery and process interruption. Read a command's help
and fixture requirements before running it. Some package tests need one of these
explicit fixture drivers and intentionally skip in the normal suite.

Production worker crates, their pinned dependencies and useful failure checks
belong in this tree. Old release-number scripts, fixed private-server controllers
and one-off benchmark experiments do not. Extend the existing commands when a
new check fits their purpose instead of adding another release-specific runner.

## Build and runtime ownership

```sh
python3 -B tools/dev.py build
python3 -B tools/dev.py build --configuration release
python3 -B tools/dev.py native-check --help
```

Builds update one current manifest per configuration in `.build/results/`.
`native_build_inputs.py` supplies the finite app, package, worker, resource and
build-helper inventory. A manifest binds exact source and product identities to
existing build/signature logs. It is development evidence, not release approval.

`native_checks.py` owns generated fixtures and the native runtime controller.
The CLI loads it only for that command. Controller edits do not invalidate an
unchanged compiled app; each run separately records/rechecks both CLI and
runtime-module hashes. Live feature checks use the bound ordinary product in
place, rather than copying another app, target or source graph.

After editing canonical `Distribution/ReleaseHistory.json`, run
`python3 -B tools/distribution/release_notes.py --write` before building. The
catalog, generator and generated Swift are frozen build inputs. Keep the
existing 24-item summary limit.

## Release and machine boundaries

Preview packaging uses the signed installed identity and existing profile.
`--expected-current-build` identifies the installed build being replaced, not
the incoming version. See [distribution tools](distribution/README.md)
for symbols, crash review and signed release validation.

A generated native flow does not authorize a server, sign-in, real Trash call,
OS test container, personal document, global preference change or publication.
Build/inspection and execution are separate actions. Preserve current recovery
and failed evidence, and use the [engineering guide](../docs/engineering/README.md)
for proportional checks and retention.

## Source and generated output

Keep `.orig`, `.rej`, `.bak` and editor backups in ignored build storage. Xcode's
synchronized App groups can copy them into a bundle even when Git ignores them;
the ordinary build refuses them there.

Worker Rust source, manifests and lockfiles are production inputs. Generated
`target` trees and downloaded Cargo data are not source replacements and stay
ignored. Keep shared schemes, dependency locks and intentional small fixtures.
Never change another project's caches or global development settings as setup.
The [SFTP](sftp_reader/qualification/README.md) and
[SMB](smb_reader/smb2-browser/README.md) crate guides describe their production
inputs and paired Swift protocol ownership.
