# TAR parser controls and preserved experiments

Routine development uses `tools/dev.py native-check tar-archive`,
`compressed-tar` or `create-tar`, plus the reusable package suites. The ordinary
TAR browser is in `App/MacExplorer/Features/Archives/`; extraction and produced
facts live in `Packages/ExplorerKit/Sources/LocalStorage/`.

These older controls remain for their specific parser investigations:

- `parser_controls.py` explicitly compiles its local TARMetadata/TARCatalog
  snapshots and ParserControls.
- `reader_controls.py` explicitly compiles its five local reader snapshots and
  ReaderControls.
- `extraction_controls.py` links production package objects and fingerprints the
  production package source.
- `native_controls.py` exercises the ordinary app.

They are not extra prerequisites for an ordinary build or a reason to create a
new source graph. Keep source snapshots selected by those retained controls until
their behavior is deliberately migrated into an existing production suite.
