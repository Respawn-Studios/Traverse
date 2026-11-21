# Changelog

Public Traverse releases live here. Each download also has its own notes on
[GitHub Releases](https://github.com/Respawn-Studios/Traverse/releases).
Earlier private-beta version numbers belong to a separate release history.

## [0.4.1] - 2026-11-21

This patch makes split-pane controls easier to see and keeps the sidebar
separator at its current edge. Build 106 has Apple Silicon and Intel installers.

### Bug fixes

- The pane controls sit in the middle of the divider between the two panes.
  They use a solid background and the pane outline color. The exposed divider
  remains available for resizing.
- The sidebar separator draws at the current sidebar edge during resizing and
  layout changes.

## [0.4.0] - 2026-11-21

This release brings local Git review, a more capable editor and more ways to
work between panes. Build 105 has separate Apple Silicon and Intel installers.

### Features

#### Workspace

- Hover over a pane divider to swap, stack or balance the panes, compare the pair,
  link matching folder navigation, or copy the current selection directly to
  its neighbour. The View and File menus give the same actions from the
  keyboard. In Full motion, pane contents cross with a brief translucent
  card effect and the active pane carries its focus with it. The controls
  center beside the two panes under the pointer, leaving the resize line clear.
- Compare two local folders by path, name and metadata. Check Contents catches
  changed bytes even when size and date match. Filter the review, open a
  text diff, open either file directly in the editor, or copy a group of
  missing files across with one Undo.
- Open Review Copy to confirm the source, destination and selected names before
  copying missing files between compared folders.
- Compare two local text files, one from each pane, or two text members of a
  ZIP or supported TAR. One selection can compare with the same filename in
  the neighboring pane. The native viewer has line and inline highlights, a
  change map, linked scrolling, Find and optional whitespace filters.
- Find Across Diffs searches the visible files in a folder or Git review.
  Find in Diff searches one comparison. Choose changed lines or all lines
  and either version, then jump to the exact match. Full diffs and small
  change previews use stronger shading and plus or minus signs.
- Unified Diff shows removed and added lines together and folds long stretches
  of unchanged text. Find opens a folded match and keeps its place when you
  return to Split Diff.
- Compare with Clipboard reviews copied text beside a selection or the current
  editor buffer without changing either.
- Select and reveal the matching file or folder in the neighbouring pane.
  The source keeps its selection and keyboard focus.
- Select by Name replaces, adds to or removes from the selection in a local
  folder or the current ZIP or TAR page using patterns such as `*.pdf`.
- Search Settings (`⌘F`) highlights the exact control, including individual
  browser shortcuts and settings with a prerequisite. Use the clear button
  or Escape to return to the page list.
- Icons view shows thumbnails for supported local images and PDFs, and can
  display embedded thumbnails in Word, Excel, PowerPoint and OpenDocument
  files. Online-only files show a cloud badge and keep their type icon until
  they are available locally.
- Finder's **Open in Traverse** service opens selected folders. Direct builds
  link to macOS Full Disk Access settings for users who need protected folders.

#### Git

- Git Tools appears inside local repositories and identifies the branch or
  detached commit. Browse existing worktrees in tabs or panes, open the same
  file in another checkout, or compare checked-out revisions from the divider.
- Review and stage one saved file, or unstage one path back to HEAD. The
  confirmation checks the file and index again before applying the change.
  Use the same commands from a local editor to keep working on its draft.
- Compare revisions across a folder or the entire project, directly or from
  their common ancestor. See unique commits on each side and inspect changes
  against each parent of a merge. Step through the visible changed files in
  one diff window. Combine path and change-type filters before searching those
  files, and filter loaded commits by message or ID.
- Compare a working folder with a revision or the exact Git index. Filter paths,
  check file contents, hide confirmed matches, and open differences against the
  disk or an existing draft. Open the selected working file in the editor and
  keep any edits already open. Start a folder or staged review from the browser
  or editor. Review Base, Ours and Theirs for a conflict, including missing sides.
- Stage a saved file or confirm the removal of a tracked file from Compare
  Working Folder with Git Index selected. Unstage restores the index entry
  while an absent file stays absent.
- Stage or unstage one block from a tracked file's exact text diff. The Git
  review refreshes after confirmation and keeps any other changes in place.
- Walk a folder’s first-parent history or follow a file across renames. Open
  history from either side of a diff and find the commit behind a matching
  line, including unchanged lines in a live draft.
- Compare a selected file on disk or in an open editor with a branch, tag or
  commit. Compare two revisions, the editor against HEAD or the index, or the
  same file across worktrees. Optional Git badges distinguish staged, untracked
  and unmerged files from unsaved editor text.

#### Editor

- Check JSON or JSONC and jump to a syntax or schema issue without editing the
  draft. Choose a local schema for supported draft 2020-12 rules, including
  alternatives, conditional rules, tuples and numeric bounds checked without
  rounding.
- Indent incomplete JSON while preserving what you typed. The editor marks the
  first live syntax issue, checks JSON Lines record by record, and can repair
  one missing colon or comma when the corrected draft parses. F5 suggests
  properties and scalar values from a chosen local schema, with descriptions,
  declared types and valid scalar defaults.
- Reopen checked JSON findings from the editor footer, or cycle through them
  with F8 and Shift-F8.
- Fold code blocks, recognized Python classes and functions, Markdown
  headings, INI and TOML sections, and recognized YAML blocks. Find opens a
  folded match automatically.
  Fold Top-Level Blocks gives you the outer structure of a long file.
  The editor shows the current scope while scrolling supported Python, Go and
  C-family source and other recognized structures. Choose a parent scope from
  the same header or the Go menu.
- INI and `.editorconfig` get syntax highlighting, section and key outline
  entries, and a line-comment command.
- Navigate TOML tables and keys from the outline and see the current table
  while scrolling, including repeated array-of-table headings.
- Go files have syntax highlighting, type and function outline entries,
  project declaration search, line comments and automatic brace indentation.
- Browse project folders, open buffers and a searchable Document Outline in
  the sidebar. Command-P finds files by name or initials and accepts a line
  and column. Control-Command-O finds symbols in this file, while
  Option-Command-O searches open editors. Both include unsaved declarations,
  headings and keys. JavaScript and TypeScript outlines
  include named arrow and function assignments. C-family outlines find named
  types and functions with supported headers.
- Jump to the previous or next outline item with Option-Command-Up or Down.
  Go to Enclosing Scope moves up through recognized blocks. Swift outlines
  handle function names after blank lines or comments and recognize bodies
  after supported multiline signatures.
- Find text in an open buffer, the project, a selected folder or a selection.
  Project and folder searches start with the current selected text when it
  fits. Narrow a search to a file type or a relative folder and see why any
  results were skipped.
  Continue larger project searches in batches. F12 jumps to a recognized
  declaration in the current file, and F5 completes a local name. Find Project
  Declarations searches supported source on disk for a name or its initials.
- Click an unsaved-change marker or press Option-F7 to peek at saved and
  edited text. F7 steps through changes, and Option-Command-F7 opens a list
  with the saved and edited line ranges. The full comparison opens at the
  selected change. Take one change from a comparison into a live editor
  with one native Undo.
- Compare the current draft with another open editor, the file on disk or a
  retained Save or Undo version. Resolve individual Git conflict markers
  inside the editable text.
- Go to Last Edit returns to the latest text change in the current editor.
  Previous Text Location takes you back to where you were reading.
- Mark lines in the open editor, then revisit them with F2, Shift-F2 or the
  bookmark chooser. Bookmarks follow edits in the open document.
- Start Replace Occurrences with the word at the caret or selected text.
  Find opens with matching case and the replacement field ready to type.
- Search within the recognized function, heading or JSON property at the
  caret. The Find bar shows the scope and offers a return to the whole file.
- Toggle indent guides or show spaces, tabs and line breaks in editors and
  comparisons. Highlight matching brackets at the caret, jump to their
  partners, or retrace a selection or navigation
  jump. Smart Return adds an inner indent for supported Swift,
  Rust, Python, JavaScript, TypeScript, C-family, CSS and JSON blocks.
- Opt in to completing code brackets as you type, with matching-closer skip,
  empty-pair deletion and native Undo.
- Opt in to inline name suggestions from the current file. Tab accepts the
  visible suggestion, and Escape dismisses it.

#### Storage

- Reopen saved folder analyses from Drives without starting another scan.
- P50, P95 and P99 markers make benchmark latency distributions easier to read.
- Repeat Benchmark uses the selected run’s settings and compares the two
  measurements when the workload and measured conditions match.
- Compare matching benchmark runs or Quick Mix pairs from different volumes
  recorded during the same session.
- Copy the matched comparison as a table with workload rates and P95 latency.
- Copy phase rates, latency and completion status for a single run or Quick Mix
  as tab-separated text.
- Benchmark cards, charts and comparisons lead with IOPS for random 4 KiB
  runs and MB/s for sequential runs.
- Copy the displayed SMART reading without starting another device check.

#### Archives

- Browse Python wheels as read-only ZIP packages and copy supported members
  into a local pane.

### Optimizations

- Group editor comparisons and Git commands in the File menu so Save and
  Close stay easy to reach. The command finder includes both groups.
- Skip common dependency and build folders in project lookups. Editor
  Defaults lets you include them.
- Smart Return and bracket completion share the syntax scanner and skip
  word classification while you type.
- Text comparisons retain separate changes and linked scrolling when a few
  small edits are far apart in a large file.
- Sequential benchmarks coalesce intermediate progress updates so the interface
  can stay responsive. Every I/O measurement and phase boundary is retained.
- Splitting a pane that has enough room captures only that pane for the
  transition. Neighbouring panes keep their live views and avoid the extra
  image work.
- Git reviews return sooner after short local Git commands finish.
- The address bar fits more nearby parent folders while keeping a small
  space to click and edit the path.

### Bug Fixes

- Editing the replacement field while a Replace All request is preparing
  keeps the draft unchanged and leaves your new replacement ready to use.
- On macOS 15, operation history, guarded Trash and temporary storage checks
  accept folder URLs when macOS adds a directory marker after creation.
- New and relinked Remembered Items in the direct edition use current
  filesystem permissions. Move and Undo preserve the access method saved with
  the item.
- Operation Results keeps the selected file when you switch between all items
  and items needing attention. Filtering out that file clears its actions.
- New Folder opens its inline name field without a selection flash. A confirmed
  local rename moves the affected visible files smoothly into their sorted
  positions with Full motion enabled.
- F6 and Shift-F6 move through browser controls in the intended direction,
  including the clipboard inspector in either keyboard preset.
- ZIP and TAR windows respect remapped and disabled keyboard shortcuts. Their
  shared Find field accepts typing, Return and Escape at every interface size.
- Quick Look shortcuts in archive tabs open Traverse's bounded member preview.
- XZ and Zstandard TARs use the default macOS application when opened.
- Separate ZIP and TAR windows connect Cut, Copy and Paste to the shared
  clipboard, including copied local files. Clipboard shortcuts follow the
  focused archive instead of the browser window behind it.
- Configured keys also reach archive New Folder, Create File, Duplicate,
  Remove and Properties. Clicking a selected name uses the same Rename rules.
- Restored archive workspaces load Undo history without a visit to Recovery.
  Open panes and windows stay in sync when an operation completes or is Undone.
- Looking up an older operation preserves loaded history and its paging position.
  Closing a pane or Recovery window cannot leave the remaining workspace stuck.
- Closing a pane preserves Copy from an inactive archive tab. Paste uses the
  surviving pane, and pending pane startup cannot replace a newer destination.
- Add Volume starts a fresh review when reopened. Late progress from an earlier
  request cannot replace a finished result.
- Settings and Help keep the current sidebar page when an edit prevents
  leaving it. Drives keeps the device highlight aligned during blocked
  switches or when the selected device disappears.
- Tool windows clear outdated outgoing fades when motion settings or appearance
  change, while preserving unrelated animations.
- Native Glass tool windows keep the current controls readable when appearance
  and interface size change together.
- Text-size changes reveal the current layout instead of blending it with an
  outgoing snapshot. Adaptive panels share that transition and retain native
  controls and keyboard focus.
- The editor sidebar switches to a compact picker at narrow widths and keeps
  incoming rows readable during mode changes. Refreshing a text diff preserves
  the unchanged pane’s Find results, selection and scroll position.
- Editor scroll jumps lay out the destination viewport so long files land on
  the intended line and the scope header follows.
- Command and editor search panels share the window opening and closing
  preferences. Escape returns focus to the exact list or editor caret.
- The File menu groups its comparison commands and shows the Git section
  when a supported repository is open.
- Git File History keeps its action labels and dates readable at larger
  interface sizes.
- The sidebar slides out and back at its saved width. Rows stay readable as
  they move instead of squeezing into the shrinking space.
- Local inline Rename keeps the typed name visible while the operation
  finishes. If the rename fails, the verified name returns.
- Narrow panes preserve room for the address and Filter before showing
  secondary navigation buttons.
- Analyzer and Properties keep the storage chart in place as grouping and
  drill-down controls change beside it. Changing the size metric during a
  lookup keeps the selected slice.

### Security

- Updated the SSH and RSA libraries used for SFTP and the constant-time
  primitives used for SMB signature verification.

### Known Issues

- Verified Copy and cross-volume Move to FAT-formatted destinations remain
  unavailable. Traverse now explains this before creating staging or history.

## [0.3.0] - 2026-11-17

### Added

- Open Terminal at the current local folder, with a default-on navigation
  button and a selected-folder context action. General and setup let you hide it.
- Compare two selected local files in Kaleidoscope, Beyond Compare, Visual
  Studio Code or FileMerge, with automatic discovery and an app preference.
- F6/Shift-F6 focus navigation, Control-Tab/Control-Shift-Tab and Shift-F10
  selection menus in both keyboard presets. Existing explicit bindings keep
  priority, and address/search fields leave marked text composition alone.
- Reviewed crash reports include capture-device details and current CPU/memory
  information by default. Current information is labelled separately from the
  crash-time capture; the editable report remains the source of what is shared.
- Plain and prepared gzip/bzip2 TAR member editing through the shared archive workbench and native
  editor: Rename, batch Rename, Remove, Duplicate, Move, Add, Create File/Folder, Group and
  Cut/Copy/Paste. Original updates retain the earlier archive for guarded Undo,
  including after restart.
- TAR.gz and TAR.bz2 creation through the shared archive publisher, with
  compression choices and guarded Undo. Gzip edits preserve bounded optional
  headers; bzip2 edits keep the current compression setting by default.
  Common `.tgz`, `.tbz2` and `.tbz` names keep their wrapper identity through
  opening, editing and creation.
- A saved Quick Compress format in Operations settings. Choose from ZIP, TAR,
  TAR.gz and TAR.bz2; the one-click command uses the selected
  format and numbers occupied names without splitting compound extensions.
  Compress… keeps the full creation controls.
- Explicit Replace Files for TAR additions, with binary-file support, a
  captured preview, unchanged local inputs and guarded Undo. Keep Both remains
  the default; folder replacement and merging are refused.
- Benchmark block-size and file-cache options, with requested and actual cache
  behavior recorded in results and exports.
- A bounded Quick Mix benchmark, matched suite comparisons and readable
  per-block latency distributions alongside the existing result metrics.
  Copied text and JSON results include the same completed-call distribution.
- Deliberate compressed-TAR Open in the qualified direct workbench includes bounded preparation.
  Passive restore and return to a changed archive still wait for Prepare.
- Archive export completion keeps the same selection ready for another drag,
  while late work cannot replace a newer archive view's message.
  Early destination/admission refusals leave a source-window explanation and
  a sanitized diagnostic event.
- Drag files and folders from plain, gzip or bzip2 TARs into
  Finder, with guarded Undo after restart. The same export owner handles
  ZIP and TAR delivery.
- Editor closing follows animation preferences while retaining text until the
  native window closes. Quit joins a Close or its chosen Save already in progress.

### Fixed

- Returning from an archive restored at startup keeps the current local file
  view selected in the footer.
- Context-menu shortcuts follow the focused separate ZIP or TAR window, using
  the same configured keys and selection as the workspace.
- Changed or cleared shortcuts also update the header menu buttons before
  dispatch, so a cached menu cannot invoke an old binding.
- Local Copy logs identify failures in file-detail comparison, receipt coverage
  and native receipt verification without recording paths or attribute values.
- Sidebar collapse and its restore button now follow the same live layout
  transition, including a reversal before the previous movement finishes.
- Pane transitions reuse foreground snapshots instead of capturing native Glass
  containers. Unchanged split branches stay attached, and divider reconciliation
  cannot save a temporary fraction during layout.
- This Mac, sidebar rows, file icons and drive tiles follow the same native
  active/inactive selection emphasis when keyboard focus changes.
- Read-only bzip2 TAR browsing no longer depends on editing being enabled.
- Moving TAR members within the same archive no longer depends on extraction
  being available. Internal moves keep their own checked drag path.
- Saving a copy of an edited, marked ZIP uses a fresh macOS protection mark
  without copying the source's security attributes. The original stays intact
  and the new copy supports guarded Undo.
- Creating a folder and finishing Rename keep the current listing visible while
  its replacement loads.
- Pane transitions leave unchanged neighbours still, preserve Glass backgrounds
  and finish sooner. Larger interface sizes reserve enough room for the footer.
- Details lists avoid a layout loop when restoring the sidebar in a split workspace.
- Properties keeps its chart and scroll position steady when changing storage
  groups, drilling into a slice or going Back. Repeated groups reuse stored totals.
- Settings, What's New, Properties and Analyzer share native opening and closing
  transitions. Discarding an unsaved Properties draft follows the same close flow.
- Separate ZIP and TAR browser windows follow the same motion preferences,
  including an interrupted Close and reopening the existing window.
- Rebinding an embedded tool's appearance keeps its opening transition running,
  including the shorter Reduced motion in Drives.

## [0.2.0] - 2026-11-15

### Added

- Separate Intel and Apple Silicon packages built from one source revision.
  The app and every bundled worker match the selected CPU. macOS 15 remains
  the minimum; Intel compatibility was exercised under Rosetta, with native
  Intel testing still welcome.
- Architecture-specific signed update feeds and automatic package selection in
  the Homebrew tap. Existing Apple Silicon clients keep their established feed.
- Wiki walkthroughs for the workspace, servers, archives, editing, storage and
  recovery, plus this public changelog.

### Security

- Updated russh to 0.65.1 and Tokio to 1.54.1 across the production and retained
  qualification lockfiles. The Windows-only transitive Pageant dependency is
  also patched to 0.2.5; it is not shipped in the Mac app.
- Refreshed checksum-bound source and license notices for both macOS targets.
- Release admission binds the actual app/helper architecture and signed marker
  to the requested case before notarization and installer readback.

Build 95. Existing file-operation protections and access policies are unchanged.

## [0.1.1] - 2026-11-15

### Fixed

- A successful update check keeps “You're up to date” in Help after its alert
  closes, instead of showing a misleading failure.
- About uses public-release wording alongside the exact version and build.
- The optional support invitation appears after the second launch, remembers
  each released update and respects its local opt-out. Every feature stays free.

Build 94. File operations and access policies are unchanged from 0.1.0.

## [0.1.0] - 2026-11-15

Our first public, open-source release. Build 93 targets Apple Silicon and
macOS 15 or later.

### Added

- Tabs, up to four panes, saved workspaces and an editable address with suggestions.
- Local file operations, collision choices, native macOS Trash and guarded Undo.
- SFTP and SMB transfers, supported server actions and text editing with saved
  versions and protection against overwriting a changed remote file.
- ZIP/TAR browsing, creation and extraction, plus changes inside supported ZIPs.
- A native text editor with syntax colours, Find/Replace, smart indentation and
  familiar Undo/Redo.
- Metadata-based storage analysis, saved results and supported drive tools.
- Local crash reports with a reviewed GitHub issue draft, a signed updater and
  Homebrew installation.

The [feature guide](docs/guides/features.md) covers formats, limits and supported
workflows. Intel builds, broad external-drive SMART support and physical drive
formatting were not qualified for this release.

[0.4.1]: https://github.com/Respawn-Studios/Traverse/releases/tag/v0.4.1
[0.4.0]: https://github.com/Respawn-Studios/Traverse/releases/tag/v0.4.0
[0.3.0]: https://github.com/Respawn-Studios/Traverse/releases/tag/v0.3.0
[0.2.0]: https://github.com/Respawn-Studios/Traverse/releases/tag/v0.2.0
[0.1.1]: https://github.com/Respawn-Studios/Traverse/releases/tag/v0.1.1
[0.1.0]: https://github.com/Respawn-Studios/Traverse/releases/tag/v0.1.0
