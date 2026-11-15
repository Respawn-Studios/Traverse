# Development setup

Traverse runs on Apple Silicon and Intel Macs with macOS 15 or later. The
qualified build host uses **Apple Silicon, Xcode 27.2, Python 3.9 or later**, and
the pinned Rust compiler. Xcode 27 requires Apple Silicon; an Intel app can still
be cross-built with its SDK. Building the app on an Intel host with an older
Xcode/Swift toolchain has not been qualified. See Apple's
[Xcode release notes](https://developer.apple.com/documentation/xcode-release-notes/xcode-27-release-notes)
for host requirements. Those build requirements do not change the app's macOS 15
deployment target.

Run the commands below from the repository root. Build products, dependency
caches and development state stay under `.build/`; no global Rust installation
or release-signing credentials are required.

## Install the pinned Rust components

[tools/rust-toolchain.json](../../tools/rust-toolchain.json) defines the required
version, target, installation prefix, component filenames and SHA-256 hashes.
The current pin is **Rust 1.99.1**. Its `components` table lists separate
`aarch64-apple-darwin` and `x86_64-apple-darwin` archives. Install the compiler,
standard library and Cargo for the build host. On the qualified Apple Silicon
host, use the `aarch64-apple-darwin` set.

Download the listed `rustc`, `rust-std` and `cargo` standalone archives from the
official Rust distribution location:

```text
https://static.rust-lang.org/dist/<date-from-manifest>/<component-filename>
```

Keep downloads and extraction under `.build/setup/`. Verify each archive against
its manifest SHA-256 **before extraction or installation**:

```text
shasum -a 256 .build/setup/<component-archive>
```

Install the verified compiler, standard library and Cargo components in that
order, using each extracted component's `install.sh`:

```text
/bin/bash <extracted-component>/install.sh --prefix=<configured-prefix> --disable-ldconfig
```

Replace the placeholders with actual paths. The configured prefix is the
absolute checkout path joined with the manifest's `prefix` value. Existing build
tools expect that location. Inspect a partial or different installation before
reusing it. Keep the compiler component's copyright/license files; the notice
collector uses them. A full Rust documentation component is unnecessary.

## Prepare dependencies and build

Fetch the locked production dependencies once:

```sh
python3 -B tools/worker_setup.py --fetch
python3 -B tools/dev.py build
python3 -B tools/dev.py run --skip-build
```

The explicit `--fetch` step uses the existing SMB/SFTP dependency caches under
`.build/`, checks the lockfiles and validates notices. It does not regenerate
locks or install a global toolchain. The helper rejects unexpected Cargo
credential/configuration files and unreviewed registry sources. A custom
corporate registry configuration requires a compatible reviewed setup.

For an already prepared checkout, check dependencies and notices offline:

```sh
python3 -B tools/worker_setup.py
```

The ordinary build reuses the pinned compiler, offline caches, vendored native
sources and checked-in `MacExplorer` scheme. A complete source-release bundle
must supply the matching dependencies needed for that setup; a minimal private
build snapshot is not a substitute for corresponding source.

## Build the Intel app from Apple Silicon

Add only the pinned **x86_64 standard-library** component to the same toolchain
prefix. Do not replace the host compiler or install the Intel Cargo archive over
it. Use the same checksum and installation steps above, then:

```sh
python3 -B tools/worker_setup.py --fetch --arch x86_64
python3 -B tools/dev.py build --arch x86_64
```

The app and its workers use the selected architecture. Compiler outputs remain
separate where Cargo/Xcode require it; helpers cannot reuse a different CPU's
binary. The ordinary app product path is reused, so finish and close one app
before rebuilding it for the other architecture. `--arch arm64` switches back.

An existing Rosetta installation can run the Intel app on Apple Silicon. That is
useful for compatibility checks, but it doesn't establish behavior on a physical
Intel Mac, a Hackintosh's drivers or a different macOS release. No Rosetta install
or global system change is part of these build commands.

## Development state and signing

Local/ad-hoc signing is the development default. Optional personal signing
overrides belong in ignored `App/Config/DevelopmentSigning.local.xcconfig`.
Keep certificates, provisioning profiles and private keys out of Git.

Development state uses `.build/runtime/`, with caches in
`.build/runtime-cache/`. The supported tools prepare these directories separately
from installed Traverse profiles. Do not change `HOME`, the system's selected
Xcode or global compiler settings as a setup shortcut.

Use [Contributing](../../CONTRIBUTING.md) for focused validation and pull requests,
[Engineering](README.md) for source organization, and the
[distribution tools](../../tools/distribution/README.md) for separate release
packaging and signing.
