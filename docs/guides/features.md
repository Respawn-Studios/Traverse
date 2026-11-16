# Using Traverse

Traverse is a Mac file explorer for Apple Silicon and Intel with macOS 15 or
later. This guide describes current source; a downloaded release
has its own feature set in its release notes. Start with the
[main README](../../README.md) for downloads, setup and community links.

## Workspace and navigation

Use up to four panes in one workspace, each with its own tabs, history, view,
sort, filter and selection. Keep a destination visible while you browse a
source, move a tab to another pane, or use Copy/Move to Other Pane for an eligible
local selection. Local-to-server uploads and server/archive-to-local copies
use the supported transfer route for that selection.

Details, List and Icons offer different ways to scan a folder. Breadcrumbs,
editable paths, Back/Forward and Up keep navigation close to the files. Saved
folder views and workspace profiles let you return to a familiar arrangement.
A restored location can still need access or a fresh server connection.

Pin folders in the sidebar and reorder categories, Places and saved locations
by dragging their names or using Move Up/Move Down. Resize the sidebar with its
divider, collapse it through View or the divider, and restore it with the footer's
Show Sidebar button. Its previous width, expanded sections and order are kept.

Quick Look, Properties, Open With, sharing and Reveal in Finder remain available
for eligible selections. Copy Names, Copy Path and Copy Relative Paths help you
reuse a selection in another application.

### Keyboard and appearance

Choose **Explorer**, **Mac** or **Custom** in Settings. Explorer behavior includes
F2 Rename, F4 Address, F5 Refresh, F6 Focus and Delete to Trash. Mac behavior keeps
familiar native choices; Custom lets you adjust the supported actions.
Control aliases cover browser tabs, navigation, file commands and file-list
selection. Command equivalents stay available, and text fields/editors keep
their own editing behavior. Space opens Quick Look in each preset.

Find a Command searches the current browser or editor's actual commands. You
can use the menu, context action or shortcut that suits the task.

Appearance, native Glass controls and interface sizing are shared across the
browser and tools. Full, Reduced and Off motion let you choose how transitions
feel; system Reduce Motion takes priority. Enlarged controls and text adapt to
narrow panes and tool windows.

## File operations and recovery

Cut, Copy, Paste, Duplicate, Rename and New Folder work through the same operation
system. New Folder with Selection groups eligible items, while New File creates
an empty text file with the name and extension you enter.

For batch Rename, choose Add Text, Replace Text or Name and Number, then review
the Before/After list. Numbering follows the captured selection order; file
extensions can be kept. Regex and metadata-driven rename rules are future work.

Conflicts offer **Skip** and **Keep Both**, with explicit **Replace** and folder
**Merge** where supported. Keep Both chooses a new numbered name. Merge retains
unrelated destination items; skipped or changed source items can remain after
a merged move. Replace and Merge always require an explicit choice. Default
Skip/Keep Both preferences apply only to the supported ordinary conflict types.

The queue shows waiting work, the active operation and results needing attention.
Pause Queue holds waiting jobs; it does not pause an arbitrary active byte stream.
Stop requests cancellation and retains the operation until work and cleanup settle.
A partial or uncertain result stays visible rather than becoming a success.

Operation history offers Undo for eligible recorded changes. It rechecks the
current files and can refuse if they have changed or a destination is occupied.
Moving across volumes keeps the source until destination validation and commit;
a same-volume rename has different semantics. The
[file-operation guide](../FILE_OPERATIONS.md) explains these integrity rules.

### Traverse-recorded Trash

Move to Trash uses macOS Trash. Traverse's Trash window shows groups it recorded,
with eligible Restore through the same recovery system. It does not list every
item Finder or another app deleted. Permanent deletion, where available, is a
separate confirmed action; it never substitutes for Move to Trash. Saved editor
versions and recovery copies have their own review and removal rules.

## Archives

Open a ZIP in an archive tab, browse its folders, edit the virtual path and
preview selected members. Text/Hex previews read a bounded part of the chosen
member. Supported PNG, JPEG, GIF and TIFF previews use the native preview window.
Browsing names does not extract the archive.

Eligible ZIP edits include file/folder Rename, batch Rename, Add, Remove, Create
File, New Folder, New Folder with Selection, and internal Copy/Cut/Paste.
Original Update and Save ZIP Copy Instead share a review. The copy leaves the
original unchanged; Original Update uses recorded staging and recovery. An
unsupported archive, unsafe name or changed original can refuse the edit.
Existing folders are not silently merged during ZIP member changes.

Quick Compress performs the common task with current preferences; ZIP is the
default. The next direct build also lets you save TAR, TAR.gz or TAR.bz2 in Operations.
The command shows the chosen format and numbers occupied names. Compress… opens
the full options. Extract to the named folder uses a fresh sibling
destination; Extract opens the destination review. Copy/Paste from an archive
to a local pane uses that same checked extraction path. One selected folder
arrives by its own name; groups retain their archive paths inside a new folder.

| Format | Browse and preview | Create or change |
| --- | --- | --- |
| ZIP | Folders, supported text/hex/images, extraction and internal pane copies | ZIP creation and supported member edits; eligible text members open in the editor |
| Plain TAR | Folders, supported previews, extraction and internal pane copies | Creation; member editing in the next direct build |
| Gzip TAR (`.tar.gz`, `.tgz`) | Bounded preparation, folders and supported previews; deliberate Open prepares in the next direct build | Creation and member editing in the next direct build |
| Bzip2 TAR (`.tar.bz2`, `.tbz2`, `.tbz`) | Bounded preparation, folders and supported previews in the next direct build | Creation and member editing in the next direct build |

The upcoming direct build adds TAR Rename, batch Rename, Remove, Duplicate, Move,
Add, Group, Create File/Folder and internal Cut/Copy/Paste, plus text editing in
plain or prepared compressed TARs. These reuse the ZIP workbench and editor.
Keep Both is the default when adding files; Replace Files is explicit and never
merges folders. Compressed TARs offer compression choices, while bzip2 edits can
keep the current setting. These flows have passed signed operation and restart/Undo
checks. They are not part of the published 0.2.0 package; final packaged-app checks
remain separate.

Archive size, metadata and member-type limits apply. Compressed preparation uses a
bounded temporary copy and is not started by passive tab restore or merely
searching filenames. In the upcoming direct build, deliberately opening a supported compressed
TAR, including a search result, also requests preparation. Stop cancels that
request; returning to a changed archive passively asks for Prepare again.
Encrypted archives, ZIP64 and unsupported member metadata may be refused by a
particular write route. A ZIP external drag and a remote external drag are
different capabilities; this guide does not promise remote-to-Finder delivery.
New TAR-to-Finder support remains held while its native delivery is checked;
explicit extraction and supported copies into a Traverse pane remain available.

## Text editor

Use Edit in Traverse for an eligible local, SFTP, SMB or ZIP text document.
The upcoming direct build also supports eligible plain and prepared compressed TAR text members.
Documents can share native tabs or open in separate windows. Opening preferences
choose Traverse's behavior without changing macOS file associations.

The editor offers syntax highlighting for common code, configuration and markup
formats, including Swift, Python, JavaScript/TypeScript, Rust, JSON/JSONC, shell,
SQL, HTML/XML, Markdown, Dockerfile and Makefile. Highlighting is a reading aid;
it does not execute code or validate a build.

Find/Replace works in the current document. Find in Open Editors searches the
buffers already open in Traverse, including inactive tabs and read-only views.
Results return to the matching document and text. It does not scan a project
folder or build a file-content index.

Indentation, line comments, Surround Selection, selected-line sorting and explicit
trailing-whitespace removal use normal text Undo. JSON/JSONC formatting keeps
key order and original token spellings; JSONC retains supported comments.
JSON bracket completion and block indentation have separate opt-outs.

Compare Changes shows the last loaded/saved text beside a captured current
buffer. Refreshing that comparison does not reread the file or server. It is a
review, with no merge or Save action of its own.

### Saving and saved versions

Local Save, Save As and eligible saved-version Undo use the operation history.
Remote Save stays bound to the connection and original selected file. If the
server file has changed, Save can refuse while retaining your edited text for
review or a local copy. An interrupted write can need review of saved and unsent
versions; it is not automatically retried.

ZIP text Save goes through the archive's Original Update review. Save ZIP Copy
creates a separate archive; Save a Text Copy exports the draft independently.
Changed-source refusal keeps the draft available. ZIP editing has a smaller
text-size bound than ordinary local documents.

Saved Versions provides read-only review of retained text. Version retention is
bounded, and full or uncertain storage can pause further work. The editor is
intended for bounded text documents; it is not an IDE, debugger or language server.

## SFTP and SMB

Connect to a server and browse it in an ordinary pane. Properties shows observed
connection/item details; current-folder Find filters the retained directory
catalog. Supported actions include file/folder Rename, same-server moves,
Copy/Duplicate and file, group or folder transfers, according to the protocol
and operation. A remote account's permissions still govern each request.

Remember a server, then click its entry in the sidebar or This Mac to open it
with retained settings. Reconnect uses the saved endpoint and available sign-in
choices; missing credentials, expired certificates and changed identity require
attention. Restoring a workspace does not silently connect, retry a dropped
connection or resume an earlier transfer.

Saved connection settings and saved passwords are separate choices. Where
Remember is offered for credentials, the macOS Keychain holds them. For SFTP,
select the key and optional OpenSSH user certificate explicitly. A remembered
certificate reference can reread a renewed certificate on reconnect. Company
sign-in tools, VPN requirements and issuance of that certificate remain outside
Traverse; the server must offer SFTP.

Transfers keep their own destination, conflicts and result. Upload, download,
server-side move and remote text Save are separate actions with distinct limits.
A server or destination becoming unavailable can leave a partial result that
needs review. Remote-to-Finder file promises are not currently an advertised
workflow. Use the supported pane or explicit transfer destination instead.

## Search and private names

Filter Loaded Items narrows a listing as you type. Search Folder and Search This
Mac use their explicit filename/metadata scope; local indexed search depends on
macOS's index and access. A server's current-folder Find is not a recursive remote
search, and finding a filename grants no extra permission to open it.

Private names and labels help you keep your own descriptions of remembered
items. They stay separate from the on-disk filename and can be forgotten through
the app's controls. This is local metadata, without file-content indexing or
cloud inference. See [Privacy](../../PRIVACY.md) for retained-data behavior.

## Storage analysis

Inspect a folder in Properties or open Storage Analysis for charts, largest
items and type/purpose groupings. Scans enumerate metadata. Logical size describes
file length; allocated size describes recorded filesystem allocation. Hard links,
clones, snapshots, missing fields and incomplete access affect interpretation.
Neither figure is a promise of the space deleting an item will free.

Saved analyses survive app launches. Reopening one displays its original scan
date without starting another scan. Refresh can reuse eligible unchanged folder
observations and enumerate changed folders; it writes a new dated result. Lost
event history, changed roots, unavailable access or unsupported scope can require
a full scan. Scan Every Folder explicitly requests complete traversal.

Forget removes the selected saved analysis, not the files it described. A chart
is an observation, not permission to delete its contents.

## Drives and benchmarks

The Drives window groups topology, volumes, health, benchmarks and analysis.
Selecting a device or refreshing its information does not start a write test.
SMART readings require supported hardware and the admitted reader. Live monitoring
is opt-in and internal-only; readings retain their dates and unavailable values.
USB enclosures and other devices vary, so an unsupported result is not a healthy
reading.

To benchmark, choose a writable folder and explicitly start a sequential or
random file workload. Traverse writes and verifies its own scratch file, reports
cache/flush choices and cleans up that workload. Quick, Standard and Extended
sizes trade work for duration. Results compare matching completed workloads;
they do not measure raw-disk speed or guarantee real-world application performance.

Quick Mix runs the small sequential and random tests together while keeping
their results separate. Measurement Details shows where completed block calls
land in the latency distribution, and Copy Results includes that distribution
in text and JSON. Partial or failed runs keep their progress facts without
claiming a completed speed result. Shared reports leave out drive names and
private recovery paths.

Destructive formatting, partitioning and physical APFS volume management are
not ordinary available workflows. Unsupported operations can hand off to Disk
Utility. Broader device support remains in the
[roadmap](../ROADMAP.md).

## Feedback and crash reports

Help → Crash Reports & Feedback keeps the report editable. Add what happened,
steps to reproduce it and, optionally, a current CPU/RAM snapshot. The privacy
helper hides common private details; review the text yourself before sharing.

Open GitHub Draft prefills the reviewed report when it fits the browser URL
limit. Longer reports produce a clearly abbreviated draft; Copy Report and
Save Report keep the full text. Opening a draft sends its contents to GitHub and
browser history, but you still choose whether to publish the issue. Native
captures stay local and are never uploaded automatically. See [Privacy](../../PRIVACY.md).
