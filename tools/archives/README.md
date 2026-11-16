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
python3 -B tools/dev.py native-check create-tarbz2 --skip-build
python3 -B tools/dev.py native-check tar-bzip2-editor --marked-source-create --large-interface --skip-build
python3 -B tools/dev.py native-check archive-export --archive-format tar.bz2 --offscreen --skip-build
```

Build first when compiled inputs changed. Check `native-check --help` for
available flows and their options; an offscreen check does not establish
foreground input, Finder drag delivery or signed distribution behavior.
The Development TAR editor flows include a second app process for cold Undo.
They reuse ordinary editor, workbench and operation owners. Running a check
does not change edition admission. The next direct-build source admits its
qualified TAR workbench separately; public 0.2.0 remains unchanged, and
packaged-app acceptance is still required.

`archive-export` runs the shared ZIP/TAR callback checks with generated files,
including collisions, cancellation, scope drain and cold Undo. Choose `zip`,
`tar`, `tar.gz` or `tar.bz2` with `--archive-format`. The callback flow opens no
server and makes no Finder gesture. Add `--external-promise-receiver` without
`--offscreen` for two real file/folder drags into a uniquely named generated
Finder destination. That flow independently checks delivery and Undo and keeps
the same ordinary app; it does not qualify a sandboxed distribution.

Extend the existing package suites and native flows when adding archive
behavior. Keep generated archives under ignored build storage, and preserve
failed output and recovery records until their cause is understood.
