# TAR validation

Routine development uses `tools/dev.py native-check tar-archive`,
`compressed-tar` or `create-tar`, plus the reusable package suites. The ordinary
TAR browser is in `App/MacExplorer/Features/Archives/`; extraction and produced
facts live in `Packages/ExplorerKit/Sources/LocalStorage/`.

Parser, reader and text/hex preview checks run against the current production module in the
ordinary package target:

```sh
python3 -B tools/dev.py test --filter 'TARMetadataTests|TARReaderTests|TARPreviewTests' --serial
```

The tests keep compact, independently generated USTAR/PAX/GNU fixtures and
literal metadata oracles. They check malformed and unsafe input, bounded
catalogs, metadata-only browsing, exact selected preview ranges, text and hex
limits, changed sources, selection identities and actual cancellation/drain.
Run with `--configuration release` to check the optimized build too. These
suites use the current module; they do not compile a second copy of the TAR models.

The remaining older controls retain separate extraction and native evidence:

- `extraction_controls.py` links production package objects and fingerprints the
  production package source for its fault, interruption and cold-recovery checks.
- `native_controls.py` retains the older source-bound native check. Routine
  changes use `tools/dev.py native-check tar-archive` instead.
- [Native preview controls](../tar_preview/native_controls.py) retain window,
  focus and motion coverage, separate from the package's reader tests.

These historical drivers need their original retained inputs. They are not
prerequisites for an ordinary build. Keep their distinct checks until they are
migrated into an existing production suite; do not create another source graph.
