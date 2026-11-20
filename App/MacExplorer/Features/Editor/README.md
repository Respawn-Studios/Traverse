# Editor

Document owners decide whether to close, then drain their work. The shared tool
window can fade that same live editor according to Full, Reduced or Off and the
Closing Windows preference. Its text and access stay owned; input and commands
stay blocked. The owner then calls the explicit synchronous native close and
waits for its actual acknowledgement before retiring a buffer or file pin.
No animation completion is treated as a native close acknowledgement.

Quit joins a Close already in progress, including its chosen Save. Re-show or
cancellation can abandon a local/archive fade without discarding the draft.
An already sealed remote close still finishes its semantic handoff if the
optional fade is interrupted. This presentation layer never changes a backend
close decision, grants file access or owns a file operation.

## Document windows and tabs

New editor documents use AppKit's native window tabs by default. Local documents
share a local group; each live server connection has its own group. Existing
document buffers, Save/recovery owners and close review remain independent.
Read-only retained-version viewers continue to use separate windows. The Window
menu provides native Next/Previous Tab, Move Tab to New Window, Merge Editor
Windows and tab-bar visibility. No blank-document command or tab plus button is
implied; open another supported file in Traverse to add a document.

Settings → Tools → Editor Defaults offers Tabs, Separate Windows or the macOS
preference. Changes apply to newly opened documents and do not rearrange current
tabs. New grouping uses an eligible editor on the active desktop, never one with
an attached sheet; reopening a managed document preserves the user's frame/group.
This adds no document slots, connection sharing, automatic reconnection, body
indexing or replacement policy.

`NativeTextSnapshotController` supplies the shared read-only
view. Its closed SMB/SFTP presentation label reuses the same window; a label
never admits a body read or writing capability. The ordinary remote-properties
flow checks both labels, disabled Save/export and close/drain. SMB's off-default
private text-read source now has its own explicit session admission, bounded
selected-file receipt and UTF-8 lease in the existing temporary pool.
This grants neither public Download
nor an existing-file Save transaction. It reuses this native surface, syntax, Find, source context and tab grouping,
but receives only an immutable `TextDocumentValue`, never a remote session, file
URL, Save or export handler. Its command bar is hidden as a whole, so removing
writing controls does not leave an expanding spacer. Its preparation work drains
before the actual native close releases the App's document reservation.
`ApplicationRemoteTextViews` owns selected reads, cleanup status and connection/
termination fences. Product and operation admission remain separate from
window presentation.

Both concrete text leases use a short, separate close-task lock. Closing cancels
and joins their serial read executor before releasing the pinned file; it never
waits synchronously on the lock held by a file read. Unconfirmed cleanup remains
explicit and retained. It does not promise that an earlier retained copy is
directly reviewable through Connection Activity.

## Remote original-file editing

`RemoteEditableTextBackend` is a closed adapter for the real SFTP and SMB document
owners. Both reuse the same native document, captured Save generation, Find,
preferences, close review, local-copy service and connection reservation. The
adapter cannot create a connection, recover authority from a path or retry a
write. `RemoteRetainedTextChoice` similarly preserves each concrete, opaque
saved-version choice while the common Saved Versions window presents both
protocols. An unsuccessful native close or retained-read drain keeps the viewer
and its reservation owned.

SMB original-file Save follows the concrete product and session capability policy.
Its explicit setup uses a separate persistent Before/Edited journal and a versioned connection
workspace. The original server file must still match the captured baseline;
changed files are refused before submission, while an interrupted or ambiguous
write retains versions for review. This is an in-place update with verified
completion, not an atomic replacement promise. Ordinary browsing does not
upgrade an existing workspace. This does not enable received Download or file export.

A confirmed changed-file SMB refusal offers **Before Save** and **Edited Text**
directly in the native editor. Early resource/admission failures do not imply a
retained pair and keep the ordinary local-copy/versions actions instead.
The shortcut correlates the captured generation with exactly one
opaque retained choice and uses the existing pinned, read-only viewer. Missing
or duplicate matches refuse without substituting an older version; later typing
does not change either capture. All Saved Versions remains available for the
broader history. The ordinary native presentation check covers button dispatch
and enlarged narrow layout; the actual current remote journey has its own
acceptance result rather than inheriting that presentation check.

Native [AppKit tabs](https://developer.apple.com/documentation/appkit/nswindow/tabbedwindows)
reuse the platform's drag/close/window behavior instead of a second custom tab
strip. Actual ordinary editor opening/preferences/group/close checks and owned
captures are development evidence; installed/public versions remain separate.
Explicit Edit in Traverse accepts up to four selected local files. An existing
document is reused; a selection that exceeds the shared editor capacity is
refused before opening a partial group. Remote selection keeps its own admission.

`NativeTextEditorWindow.swift` and `NativeTextEditorSurface.swift` are presentation.
`LocalTextDocumentController.swift` / `RemoteTextDocumentController.swift` own document
lifetimes. `EditorSyntax.swift`, `EditorFindController.swift` and
`EditorPreferences.swift` supply editing behavior. Save/recovery stays behind
the existing FileOperations and LocalStorage interfaces.

New File is shared by local and server menus. It accepts the complete filename
with an optional extension; the neutral Untitled suggestion adds none. The
existing empty-file producer, no-replace checks and document owner remain
authoritative. JSON, source and configuration files are text formats; choosing
an image/PDF suffix does not generate that binary format. Syntax selection does
not silently rename an existing file or change its extension.

Automatic syntax can recognize clear extensionless JSON, HTML/XML and literal
script headers through `EditorPreparationOwner`'s existing cancellable background
pass. A default-on preference controls this hint; a manual language or explicit
default wins. Local, SFTP and ZIP editable documents share the same result and
stale-generation admission. JSON detection is bounded to32KiB and literal headers
to512 characters; ambiguous input stays Plain Text. This parses only the already
open editor buffer, without execution, indexing, a model, logging or renaming.

Help → Find a Command (the same discovery shortcut as the browser) searches the
active editor's actual File/Edit/Window menu, including editing, formatting,
Find, Save/reload and native tab actions. `EditorCommandFinder` owns that menu
snapshot and exact editor focus/text/selection validation. It clears transient
queries on dismissal and revalidates the ordinary menu after restoring the exact
responder; it never runs a browser command or writes files itself. Read-only and
busy documents retain their existing disabled actions. Browser and editor reuse
`CommandDiscoveryPresentation` for panel allocation, search/result geometry,
Glass, accessibility, placement and Full/Reduced/Off entrance motion; neither
feature borrows the other's command authority.

`EditorLocationContext.swift` is display-only source context for the same native
window: current local URL, current ZIP/member after Copy-follow, or the exact
remote folder captured at Open. It performs no lookup and grants no Save access.
The compact location row has a full tooltip. Remote Save remains the captured
server operation; Save Local Copy clearly names its separate local destination.
Normal remote states keep generic safety instructions in tooltips, while actual
conflict/disconnect/recovery explanations remain visible.

## Surround Selection

Edit → Surround Selection adds double quotes, single quotes, parentheses, square
brackets, braces or backticks around the selected text. The exact inner text
remains selected, including multiline and composed Unicode text. This is an
explicit editing command: it does not escape characters, parse the language or
save the document. One native Undo removes the surrounding pair. Empty selections
and read-only buffers disable the commands; the existing generation, admission,
byte limits and off-main line-command preparation remain authoritative.

The command finder searches nested menu categories too, so searching “surround”
finds these actions without expanding the submenu. This adopts the familiar
[editor surrounding-pair interaction](https://code.visualstudio.com/api/language-extensions/language-configuration-guide#autosurrounding)
as an explicit native action. Editor Defaults has independent preferences for
automatic JSON and code bracket completion. Both use the bounded syntax walk
for context and the editor's native Undo.

## Find in Open Editors

Edit → Find in Open Editors (Shift-Command-F, with the Explorer Control alias)
searches the already-open native buffers, including inactive tabs and read-only
views. Selected single-line text can prefill the query. Match Case, the existing
word-matching choices and Refresh remain in the compact panel. Return opens the
exact document and selects its UTF-16 match; changed or closed documents refresh
the results rather than navigating an obsolete range.

`EditorOpenSearch` reuses `EditorFindPlan` and `CommandDiscoveryPresentation`.
It owns one cancellable worker and one latest request, capped at16 existing
buffers and500 results. A capped result explicitly asks for a narrower query.
Small snippets, transient query and weak window references never become an
index, file read, network request, saved history, diagnostic text, replacement
operation or Save authority. Closing joins pending work before document release.

The search scope is the already-open buffers; it does not scan a folder.

File → Compare with Open Editor uses the same native list to choose a second
buffer by name or source location. The chooser holds weak references and
captured generations. An explicit Return captures both eligible buffers on the
main actor, including unsaved text and each document's encoding format. The
shared diff prepares the comparison off-main. Refresh resolves the same owners
and source labels and retains the earlier review if either becomes unavailable.

## Project navigation

`EditorFileSidebar` shares one native outline for project folders, open editors
and document symbols. `EditorProjectFileSearch` presents file names, text hits and
declarations in the same keyboard-driven picker. File lookup uses metadata.
`EditorProjectTextSearch` reads supported text in bounded batches only after an
explicit query. Result navigation verifies the current file or draft before
moving the caret. Outline, declaration search and local name completion share
the editor's prepared syntax and source positions.

## Compare Changes

File → Compare Changes compares the last successfully loaded or saved text with
a captured editable local, remote or archive buffer. Previous and Next Change
(Command-F7 and F7), original line positions, explicit Refresh Snapshot and panes
that stack at narrow/enlarged sizes keep each version identifiable. A refreshed
comparison uses the current buffer and its saved baseline.

`EditorTextComparison` maps byte-distinct text to line and grapheme identities
off the main actor. ExplorerCore's `TextAlignment` compares those identities
within a 1 MiB direction matrix and tries a bounded Myers frontier for sparse
line edits beyond that grid. The viewer groups changes when neither pass
finishes within its budget. Find Across Diffs, linked scrolling and unsaved
line marks share the same alignment. Check it without a native build using
`python3 -B tools/dev.py check unit --filter TextAlignmentTests`.
`EditorComparisonWindow` reuses native text
surfaces, common chrome, adaptive columns and text preferences. Editors and
comparison windows use `ToolWindowMenuOwnership` to keep commands with the
focused window.
**Apply Selected Change to Editor** sends one exact change back to its live
editor. The editor rechecks the captured generation and the old text and
owns the edit, its Undo and any later Save. Parent close joins pending comparison
work and clears both buffers.

Git's working-folder and staged reviews reuse this window for selected-block
actions. `GitComparisonWindow` binds the displayed file and both text versions
to `GitIndexEditFlow`. The confirmed action refreshes the Git review and leaves
open buffers alone. Use `python3 -B tools/dev.py check section git-index` for
the existing package tests and native check.

The native text surface uses contiguous TextKit layout. The earlier opt-in
noncontiguous mode can stall first-responder layout when a second document joins
an AppKit tab group. The shared surface fixes local, SFTP and archive editors
together; a generated two-tab reproduction and distant navigation in a 10,000-line
document cover the affected presentation path.

Opening defaults recognize exact familiar text names as well as extensions:
Dockerfile/Containerfile, Makefile, common shell profiles, .env variants, Git
configuration names and extensionless README/LICENSE files. The same filename
policy drives local Open, SFTP double-click, icons and Settings. Explicit per-type
choices remain authoritative. Prefix lookalikes do not gain text-editor routing. Dockerfile/Makefile modes add
instructions, comments, quoted values, variables and rule/assignment hints through
the existing bounded lexer. Docker heredoc bodies remain content, rather than
being mistaken for build instructions. These are presentation hints, not a build
validator or embedded shell. References: [Dockerfile](https://docs.docker.com/reference/dockerfile/),
[GNU Make](https://www.gnu.org/s/make/manual/html_node/Makefile-Contents.html).

## Text inside archives

An admitted ZIP, plain-TAR or prepared gzip/bzip2 TAR edit opens one eligible regular member in this same editor.
`ArchiveTextDocumentController` owns the exact member snapshot and retains its
archive access; the concrete format reader and shared archive mutation journal own every
read, replacement, copy and Undo. Save updates the original archive; Save Archive Copy
creates a new archive and follows that exact verified copy. A changed archive refuses
Save while keeping the draft visible. Reload is explicit, and Save a Text Copy
exports the visible draft independently. No temporary extracted editing tree or
second file writer is introduced. Initial and saved encoded text are bounded to
256 KiB; larger drafts can be exported as text.

The editor-preferences native flow exercises repeated Save, exact rebind,
original-archive Undo, stale refusal, Reload, copy-follow and copy Undo.
`native-check tar-editor`, `tar-gzip-editor` and `tar-bzip2-editor` cover the same
lifecycle with separate v18, v19 and v20 original-update admission. The compressed
variants reuse the bounded codec, TAR layout and publisher. TAR editing is
qualified in Development and the next direct-build source, including signed
operation and restart/Undo checks. It is not part of public 0.2.0. Packaged-app
acceptance and sandbox source grants require separate validation.

The existing Explorer/Custom Control-alias preference also applies to local and
remote editor menus: Save/Save As/Close, Undo/Redo, Cut/Copy/Paste, Select All,
Find/Replace and line comments. Mac Command equivalents remain available; Mac
mode preserves native Control text commands. This uses window-owned
[AppKit menu equivalents](https://developer.apple.com/documentation/appkit/nsmenuitem/allowskeyequivalentwhenhidden),
not a global event tap. Native text/Find fields retain responder-chain editing,
and sheets/inactive editors cannot dispatch a Save. No new preference is stored.

- The ordinary local editor is enabled in Release source. `LocalEditorFileSession`
  binds explicit Open, Save, Save As and saved-version Undo to the existing engine;
  the window never writes a file directly.
- File → New File creates one empty file in the current local folder through
  that same no-replace text producer and Undo journal, then opens the ordinary
  editor. The name prompt, existing-file refusal and Cancel reuse browser controls.
  Writer, destination access and editor-capacity reservation remain owned through
  actual publication. It adds no untitled-file identity or parallel writer.
- `ApplicationRemoteTextEditors` owns exact connection/document
  lifetimes; a remote row cannot grant itself editing capability. Ordinary Open
  also honors the shared extension preference; explicit Edit uses the same owner.
- Save stages and typed refusals use the existing local App Logs recorder through
  `observedSaveBoundary`; filenames, text and server inputs never enter that
  callback. Full working space and busy/unavailable connections get distinct
  explanations. The shared format3 inventory permits64 small bodies within the same30 MiB
  byte budget; each document still has at most eight distinct retained bodies.
  Record validation includes the active body in that eight-member union. This
  is not permission to delete old versions or retry a remote write silently.
  A full workspace makes the existing Review Versions button open the shared
  Saved Versions manager; its closed-document checks still govern removal.
- Cold Saved Versions isolates only validated inactive interrupted receives,
  preserving them and showing an incomplete notice while valid versions remain
  readable. Unknown/dangling state still refuses. Retirement is not invoked or
  enabled for this partial state; the strict mutation guards are unchanged.
  Discovery logs fixed metadata stages and canonical error codes, never names,
  bodies or server inputs. Rows distinguish saved and unsent changes.
- Find, line commands, syntax and indentation reuse the same text surface for
  local and remote documents. Presentation changes must not replace the document
  owner or reset unsaved text.
- Continue line indentation keeps the current line's spaces/tabs on Return.
  Indent JSON blocks on Return is an independent, default-on preference. In JSON
  and JSONC mode, Return after an opening brace/bracket adds one configured
  indentation level; between matching delimiters it also puts the close on a
  separate line at the outer indentation and leaves the caret on the inner line.
  This uses one normal native text edit/Undo, respects admission and byte limits,
  and never Saves. Strings/comments do not expand delimiters; selections, marked
  text and multiple carets keep native behavior. Lexical lookbehind is bounded
  to the first 65,536 UTF-16 units; later positions keep ordinary indentation
  continuation if enabled. Older profiles keep their existing continuation
  choice, including an inherited or explicit false; the additive JSON block
  preference defaults on when absent and preserves an explicit new opt-out.
  Turning off JSON block indentation retains ordinary continuation when enabled.
  Local, SFTP and ZIP editors
  share this implementation and their existing language controls.
- Complete JSON brackets is a separate, default-on editor preference. In JSON
  and JSONC mode, a lone opening brace/bracket at an empty caret inserts its
  matching close as one native edit. Typing that close moves past it only while
  this view still owns its insertion provenance; existing document closes are
  ordinary input. Nested pairs and Return retain this provenance during normal
  typing. A closing key can cross at most 4,096 whitespace-only UTF-16 units to
  its owned close, including the empty inner line created by Return, without
  changing that whitespace. Undo/Redo, composition, user caret movement, focus
  loss, reload and syntax/indentation/completion changes discard it conservatively. Quotes, selected text,
  other languages and insertions before non-boundary content stay native.
  Bracket keys use the same bounded lexical prefix as Return, with at most
  64 tracked closes per view; ordinary characters add no prefix scan or copy.
  No body reads, Save or format changes are added.
- Edit → JSON → Format JSON (Option-Shift-F) and Compact JSON use the same bounded
  off-main command preparation and native one-edit Undo/Redo path. Foundation
  checks the input, but original token bytes supply the output: duplicate keys,
  key order, string escapes and numeric spellings stay intact. Indented output
  uses the current spaces/tabs preference; selection follows its original text.
  Invalid/unrepresentable input and output over the editor bound leave the buffer
  unchanged with a short notice. JSONC uses the same commands and retains exact
  line/block comment bytes and trailing commas; Compact keeps the newlines
  needed to terminate line comments. The formatter validates a temporary masked
  syntax view but emits original tokens, without constructing a replacement
  object graph. Strict JSON still refuses comments. Both modes use the existing
  one-edit Undo/Redo and never Save or change file associations automatically.
- Edit → Lines → Toggle Line Comment (Command-/) uses the current syntax and the existing
  bounded in-memory command/Undo owner. It preserves indentation and blank selected
  lines, adds/removes one layer, and disables itself for strict JSON and syntaxes
  without qualified line comments. This is an explicit buffer edit, never a Save.
- Edit → Lines → Sort Lines Ascending/Descending naturally sorts the selected complete
  lines, preserving equal-key order, spelling and surrounding text. A lone caret
  does not sort the document. Trim Trailing Whitespace explicitly removes only
  spaces/tabs at line ends throughout the current document; indentation,
  newlines, Unicode spaces and the mapped selection stay intact. Both reuse the
  bounded off-main line-command owner and one native Undo edit. Trimming never
  runs automatically during Save, since trailing spaces can be meaningful text.
- HTML/XML and Markdown use the same bounded, cancellable UTF-16 highlighting
  pass. Markup tags, attributes, quotes, comments, CDATA and entity-shaped text
  have distinct roles; Markdown headings, fences, code and link destinations are
  colored. This is source highlighting, not validation, a rendered preview or
  embedded-language execution. Grammar references: [XML](https://www.w3.org/TR/xml/)
  and [CommonMark](https://spec.commonmark.org/0.31.2/).
- JSON and JSONC have separate language choices. JSONC enables the same native
  line-comment/Undo action; strict JSON keeps it disabled. The shared lexical
  highlighter recognizes quoted keys across comments, including CRLF documents,
  while retaining cancellation and token bounds. It does not validate syntax or
  reformat the document. The distinction follows the familiar
  [JSON with Comments mode](https://code.visualstudio.com/docs/languages/json#_json-with-comments).
- `EditorSettingsTools.swift` supplies the Tools settings page. File-opening
  choices control Traverse's own Open action; they do not change macOS defaults.

Use the existing `tools/dev.py native-check local-editor` complete generated flow
for relevant local changes, and `native-check remote-properties` for remote row
actions. The latter has no body-transfer backend and cannot establish remote
Save correctness. Real server, sandbox and OS Trash checks need their specific
scope; passing a view check is not an activation decision.
`native-check editor-preferences` covers opening defaults, generated language
roles and live editor preferences through the ordinary app.
`native-check editor-lines` exercises the real menu, one-step Undo/Redo and the
shared input/focus/stale/close boundaries using generated in-memory documents.

JSON assistance follows the familiar separation between language-aware bracket
completion and indentation described in the
[VS Code language configuration guide](https://code.visualstudio.com/api/language-extensions/language-configuration-guide).
These are bounded native text edits with independent opt-outs, rather than an
embedded language server or automatic filename renaming.

These are folders within the same App module, not additional packages. Consult App/README.md and docs/engineering/README.md from the repository root.
