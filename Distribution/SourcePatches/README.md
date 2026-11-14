# Offline dependency source builds

`Sparkle-local-argument-parser.patch` changes only Sparkle2.10.0's Xcode package
reference to the adjacent, exact `swift-argument-parser` source archive. It changes
no runtime source and leaves upstream licenses intact. The immutable archives,
revisions and hashes are in `../SourceDependencies.json`.

Apply with `patch -p1` from a verified disposable Sparkle source directory; keep
the pinned ArgumentParser directory beside it. Source-delivery requirements are in [the source-release guide](../../docs/engineering/OPEN_SOURCE_RELEASE.md#source-and-license-requirements).
Never apply this patch to the pinned prebuilt framework or run upstream release
packaging scripts as a build check.
