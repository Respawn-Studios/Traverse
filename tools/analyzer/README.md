# Scanner source provenance

The app's production scanner lives in [Workers/StorageScanner](../../Workers/StorageScanner/README.md).
Build it through the ordinary app rather than a second scanner target:

```sh
python3 -B tools/dev.py build
python3 -B tools/dev.py test --filter StorageAnalysis --serial
python3 -B tools/dev.py native-check analysis-persistence --skip-build
```

Three original source files remain here because the worker's
[`frozen-origin.json`](../../Workers/StorageScanner/frozen-origin.json) records
their exact derivation hashes: `rust/main.rs`, `AnalyzerNative.c` and
`AnalyzerNative.h`. They are provenance inputs, not a separate product or setup
step. Keep their bytes unchanged when modifying the current worker.

Package tests and the ordinary native checks cover current analysis behavior.
Historical benchmark corpora and one-off scanner experiments are not part of
contributor setup. A generated fixture test does not establish support for every
filesystem, privacy setting or drive.
