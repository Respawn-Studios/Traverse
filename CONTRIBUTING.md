# Contributing to Traverse

Thanks for helping make Traverse a nicer place to work with files. A bug fix,
a clearer sentence, an accessibility improvement or a translation all count.
You don't need to arrive with a big feature in hand. Original project material uses
[GPL-3.0-only](LICENSE); third-party material retains its own terms. Payment is
never required to use or contribute to the app.

## Build and run

The app targets Apple Silicon and Intel with macOS 15 or later. Our qualified
build host is Apple Silicon with Xcode 27.2; Intel packages are cross-built. Follow the
[setup guide](docs/engineering/DEVELOPMENT_SETUP.md) for Xcode, Python and the
pinned Rust compiler and dependencies, then run from the repository root:

```sh
python3 -B tools/dev.py build
python3 -B tools/dev.py run --skip-build
```

Use `--skip-build` only after a successful build of the current source.
The setup guide includes `--arch x86_64`, pinned target components and the
distinction between running the app on Intel and building it on an Intel host.
Development uses local/ad-hoc signing and checkout-local state; release
certificates and installed application profiles are not prerequisites.

## Find the relevant code

You shouldn't have to explore the whole repository to fix one thing. These
guides point to the owners of each part of the app:

| Area | Source guide |
| --- | --- |
| Application, browser and features | [App](App/README.md) |
| Shared appearance, window layout and motion | [Presentation](App/MacExplorer/Shared/Presentation/README.md) |
| Filesystem, archives, connections and analysis | [ExplorerKit](Packages/ExplorerKit/README.md) |
| Rust metadata scanner | [StorageScanner](Workers/StorageScanner/README.md) |
| Build, test and maintenance commands | [Tools](tools/README.md) |
| Architecture and development practices | [Engineering](docs/engineering/README.md) |

Reuse the existing controllers, modules and shared presentation. Keep native UI
in `App/` and file mutations behind the operation interfaces in `ExplorerKit`.
Discuss substantial architecture or interface changes before implementation.
The [roadmap](docs/ROADMAP.md) distinguishes current priorities from proposals.

## Validate the change

Check the task you changed from beginning to end, then choose the existing
checks that help you trust it. A typo fix doesn't need a tour of every feature.

Run the relevant existing suite and exercise one complete affected workflow:

```sh
python3 -B tools/dev.py test --filter ExplorerCoreTests
python3 -B tools/dev.py test --filter FileOperationsTests --serial
python3 -B tools/dev.py native-check --help
```

Choose the checks that match the change; these examples are not a required
sequence. Add a regression for a demonstrated bug or integrity contract. Broaden
validation when shared behavior changes or a failure exposes another risk.
For visual changes, build and inspect normal and enlarged layouts, keyboard
focus and the relevant motion settings. State what was checked and what remains
unexercised; a hidden-window check does not establish visible interaction.

Use generated fixtures under ignored build directories. Never use personal
files, an existing server or real Trash as disposable test data. File-operation
changes must preserve sources, refuse unapproved overwrites and cover relevant
failure, interruption and recovery behavior. See the
[file-operation contract](docs/FILE_OPERATIONS.md).

## Submit a focused change

You keep copyright in your work. Contributions to Traverse use the project's
GPL-3.0-only license. We do not require a CLA, copyright assignment or a legal
declaration on each pull request. Please submit work you have the right to share,
get any employer or coauthor permission you need, and identify reused material
and its license.

Use Issues for concrete bugs and changes, and Discussions for questions and
exploratory ideas. A pull request should describe the problem, resulting
behavior, relevant validation and remaining limits. Include reviewed screenshots
for visible changes and keep unrelated refactors separate.

Do not include credentials, personal paths or file contents in issues, logs,
examples or captures. Keep generated outputs and signing overrides out of Git.
The [privacy guide](PRIVACY.md) explains the app's data boundaries. Preserve
copyright, dependency notices and the terms in [LICENSING.md](LICENSING.md).
Public forks should also follow the [trademark policy](TRADEMARKS.md).
