# Archive validation

Archive behavior belongs to the application and ExplorerKit, rather than to
these tools. Start with the [native workflow guide](../NATIVE_WORKFLOWS.md) and
choose a check for the behavior you changed.

| Location | Responsibility |
| --- | --- |
| [ExplorerKit LocalStorage](../../Packages/ExplorerKit/Sources/LocalStorage) | ZIP/TAR readers, writers, extraction and publication rules |
| [LocalStorage tests](../../Packages/ExplorerKit/Tests/LocalStorageTests) | Archive format, conflict, interruption and recovery regressions |
| [Archive feature](../../App/MacExplorer/Features/Archives/README.md) | Archive panes, reviews and export lifetimes |
| [Application](../../App/MacExplorer/Application) | Compressed-archive and editor coordination |
| [Browser](../../App/MacExplorer/Browser) | Workspace selection, commands and archive integration |
| [Native checks](../../App/MacExplorer/Development/Checks) | Integrated checks using the ordinary app |

Run package checks through the normal build owner. For example:

```sh
python3 -B tools/dev.py test --filter 'ZIPRootExportTests|ZIPExportBatchStateTests' --serial
```

Use an existing native flow to check application integration:

```sh
python3 -B tools/dev.py native-check archive-pane --skip-build
python3 -B tools/dev.py native-check tar-archive --skip-build
```

Build first when compiled inputs changed. Check `native-check --help` for
available flows and their options; an offscreen check does not establish
foreground input, Finder drag delivery or signed distribution behavior.

`native_promise_export.py` is a retained, bounded diagnostic for the native ZIP
promise owner. Its `--ordinary-build` option reuses the current Debug build and
checks its receipt. It has separate fixture and execution prerequisites, starts
no server, and does not perform a physical Finder drag or grant filesystem
access. It is not the default contributor test command.

Extend the existing package suites and native flows when adding archive
behavior. Keep generated archives under ignored build storage, and preserve
failed output and recovery records until their cause is understood.
