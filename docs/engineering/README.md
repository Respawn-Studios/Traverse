# Engineering guide

Welcome to the engine room. We keep one native app and reuse its file-management
and presentation foundations, so fixing a shared behavior helps every feature
that uses it. Start with [local setup](DEVELOPMENT_SETUP.md), the
[project foundation](../PROJECT_FOUNDATION.md), [browser design](../BROWSER_DESIGN.md)
and [file-operation contract](../FILE_OPERATIONS.md).

## Source organization

| Location | Responsibility |
| --- | --- |
| [App](../../App/README.md) | Application composition, browser and feature controllers |
| [Shared presentation](../../App/MacExplorer/Shared/Presentation/README.md) | Window chrome, appearance, sizing, accessibility and motion |
| [ExplorerKit](../../Packages/ExplorerKit/README.md) | UI-free values, platform adapters, operations, archives, search and analysis |
| [StorageScanner](../../Workers/StorageScanner/README.md) | Rust metadata scanner |
| [Tools](../../tools/README.md) | Supported development, packaging and maintenance commands |

Keep file-operation complexity behind small, testable interfaces. Views invoke
commands; they do not perform filesystem mutations directly. Reuse the existing
application composition, shared presentation and concrete provider adapters.
Introduce a module or dependency when a real behavior warrants it, rather than
creating parallel implementations or a speculative universal provider API.

## Working on a feature

1. Identify the user task, existing implementation and intended behavior.
   Agree substantial architecture or interface changes before editing.
2. Implement the complete flow in ordinary source, including application
   integration, cancellation and useful failure states.
3. Build incrementally, run the relevant existing tests and inspect the affected
   app workflow. Investigate a failure before expanding the test scope.
4. Update the public guide when behavior changes. Distinguish implemented source
   from behavior actually exercised and from a released download.

Use the checked-in Xcode scheme, Swift package suites and existing native checks.
Avoid copied source graphs, extra test applications and new harnesses for routine
changes. Keep build inputs stable during compilation and reuse incremental
caches under `.build/`.

## Concurrency and file integrity

Keep blocking filesystem and network work off the main actor. Bound concurrent
work, retain access and session lifetimes until workers drain, support
cancellation and reject stale results. An asynchronous function can still block
its executor; moving work off the UI actor is a separate responsibility.

Revalidate observations before mutation. Preserve source data until a
cross-volume destination is validated and committed; same-volume atomic rename
has different semantics. Refuse unapproved overwrites, retain truthful partial
or uncertain outcomes, and keep recovery and guarded Undo consistent with the
actual operation. Never substitute permanent deletion for Trash.

Local and remote capabilities can differ. Show denied, disconnected and
unsupported states explicitly. Saved paths, cached metadata and displayed
permissions are observations, not proof of current access or object identity.

## Proportionate validation

| Change | Useful validation |
| --- | --- |
| Documentation | Local links, examples and formatting |
| Domain behavior | Focused existing package suite and one integrated flow |
| Native layout or interaction | Build, visible inspection, keyboard/focus and relevant accessibility settings |
| File mutation | Success, conflict/denial and relevant interruption/recovery cases |
| Distribution | Exact artifact checks and separate installed/update acceptance |

The complete package baseline uses serial execution because some suites share
process-wide diagnostics and fixtures:

```sh
python3 -B tools/dev.py test --serial
```

Use a focused suite while iterating. Repeat or broaden checks after meaningful
changes, failures or unresolved concerns. Report device, server, permissions,
minimum-OS and accessibility coverage only when exercised. Native simulation,
view caching and actual foreground interaction provide different evidence.

## Privacy, dependencies and outputs

Browsing and analysis are metadata-first. Reading file bodies, indexing content
or sending data to a service requires an explicit supported user action. Keep
credentials, personal paths and file contents out of diagnostics and examples.
See [Privacy](../../PRIVACY.md) for the product boundary.

Review a dependency's behavior, source provenance, license and build impact
before adding it. Preserve lockfiles, shared schemes and third-party notices.
Development signing is separate from release signing, notarization and
publication; see the [distribution tools](../../tools/distribution/README.md).

Keep build outputs, generated fixtures and personal configuration ignored.
Remove only generated data belonging to a completed test; preserve unresolved
failure evidence and runtime recovery data. Routine cleanup must not reset
application profiles, shared tooling or unrelated work.
