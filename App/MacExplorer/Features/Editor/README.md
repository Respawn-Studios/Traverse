# Editor

Traverse shares one native editor across local files, archive members and
remote documents. The [feature guide](../../../../docs/guides/features.md)
covers the menu commands and settings. This page shows where to make a change.

## Where the code lives

| If you’re changing… | Start here |
| --- | --- |
| Text, native selection, gutter or folding | `NativeTextEditorSurface.swift` and `EditorCodeFolding.swift` |
| Menus, shortcuts or window behavior | `NativeTextEditorWindow.swift` and `EditorTabPresentation.swift` |
| Syntax, outline or scope navigation | `EditorSyntax.swift`, `EditorDocumentOutline.swift` and `EditorOutlineScopes.swift` |
| Find, line commands or indentation | `EditorFindController.swift`, `EditorLineCommandController.swift` and `EditorIndentation.swift` |
| Project files, symbols or search | `EditorFileSidebar.swift`, `EditorProjectFileSearch.swift` and `EditorProjectTextSearch.swift` |
| Diffs and reviewing unsaved text | `EditorComparisonWindow.swift` and `EditorTextComparison.swift` |
| Opening, saving or closing a document | `LocalTextDocumentController.swift`, `ArchiveTextDocumentController.swift` or `RemoteTextDocumentController.swift` |
| Viewing a retained version | `NativeTextSnapshotController.swift` and the matching versions window |

## Boundaries worth keeping

- AppKit owns selection, marked text, native tabs and Undo. A fold changes
  layout over the same text storage. Find, Copy and Save use the full source.
- Prepare syntax, outlines, searches and proposed edits off the main actor.
  Use the captured text generation and selection before applying an edit.
  Ranges passed to AppKit are UTF-16 offsets in the exact captured document.
- File and project search have separate scopes. Project path lookup uses
  metadata. A text query reads supported files only after the user requests
  it, and a result must verify the file or draft before navigation.
- Keep file operations in the document owner and the shared FileOperations
  or LocalStorage layer. Each source owns its access, Save and recovery rules.
  A read-only text snapshot receives an immutable `TextDocumentValue`. It
  carries no live file, archive or server access.
- On close, let the document owner finish any admitted work and confirm the
  native close before releasing its resources. Window motion follows the shared
  presentation settings. An animation finishing by itself cannot release a
  file pin or connection reservation.
- Local JSON schemas are explicitly selected. Validation and completion reuse
  the same schema reader and work on the captured buffer. Keep selected schema
  text, buffer contents and search excerpts out of logs and persistent indexes.

## Check a change

Run the matching native check from the repo root. The
[native workflow guide](../../../../tools/NATIVE_WORKFLOWS.md) lists options
for the shared development app and its generated fixtures.

| Change | Native check |
| --- | --- |
| AppKit editing, command routing and Undo | `python3 -B tools/dev.py native-check editor-lines` |
| Preferences, project navigation and native layout | `python3 -B tools/dev.py native-check editor-preferences` |
| Local Open, Save and closing | `python3 -B tools/dev.py native-check local-editor` |
| Split and unified comparisons | `python3 -B tools/dev.py check section editor-comparison` |
| Editing ZIP or TAR members | `python3 -B tools/dev.py native-check zip-editor-native` or `tar-editor` |

For changes to saving or recovery, also run the affected FileOperations or
LocalStorage tests. A native UI check with generated content exercises the
editor. Use the matching runtime check for a real file backend.
