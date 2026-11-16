# TAR validation

Routine development uses `tools/dev.py native-check tar-archive`,
`compressed-tar` or `create-tar`, plus the reusable package suites. The ordinary
TAR browser is in `App/MacExplorer/Features/Archives/`; extraction and produced
facts live in `Packages/ExplorerKit/Sources/LocalStorage/`.

Parser and reader checks run against the current production module in the
ordinary package target:

```sh
python3 -B tools/dev.py test --filter 'TARMetadataTests|TARReaderTests' --serial
```

The tests keep compact, independently generated USTAR/PAX/GNU fixtures and
literal metadata oracles. They check malformed and unsafe input, bounded
catalogs, metadata-only reads, selection identities and actual cancellation/drain.
They do not compile a second copy of the TAR models.

The remaining older controls retain separate extraction and native evidence:

- `extraction_controls.py` links production package objects and fingerprints the
  production package source for its fault, interruption and cold-recovery checks.
- `native_controls.py` retains the older source-bound native check. Routine
  changes use `tools/dev.py native-check tar-archive` instead.

These historical drivers need their original retained inputs. They are not
prerequisites for an ordinary build. Keep their distinct checks until they are
migrated into an existing production suite; do not create another source graph.
