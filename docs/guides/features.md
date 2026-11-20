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

Hover over a pane divider for **Swap Pane Sides** and **Balance Pane Sizes**.
Drag the line between those buttons to resize. A swap carries the panes' tabs,
selection, and focus with them. At a divider between pane groups, it moves each
group together. Use **Stack Panes** or **Place Panes Side by Side** to change the
split in place when both panes fit. The action keeps the same tabs and focus.
The View menu and Find a Command offer the same actions for the active pane's
divider, including **Change Pane Split Direction**. **Compare Folders** appears
between two different local folders. Select one file in each pane to get
**Compare Selected Text Files** in the same spot. The diff follows the displayed
pane order.
With a local selection, the divider’s Copy action names its receiving pane and
folder. It uses the same conflict review, progress and Undo as Paste.

**Link Pane Navigation** follows the same subfolder in the other pane when
both contain it. It works in either direction and is handy beside a different
Git checkout. If the other side has no matching folder, it stays where it is.
Turn the link off from the divider or View. Leaving either starting folder's
tree or switching to another tab also turns it off.

Use **View → Select Matching Item in Other Pane** to reveal and select a row
with the exact same name and kind. Keep the other pane's selection empty.
The source keeps keyboard focus. The divider offers the same action for
matching folders and other items outside its supported text comparison.

Details, List and Icons offer different ways to scan a folder. Breadcrumbs,
editable paths, Back/Forward and Up keep navigation close to the files. Saved
folder views and workspace profiles let you return to a familiar arrangement.
A restored location can still need access or a fresh server connection.
The address keeps nearby parents visible as space permits. Click the small
blank area at its end or use the pencil to type an address.

Pin folders in the sidebar and reorder categories, Places and saved locations
by dragging their names or using Move Up/Move Down. Resize the sidebar with its
divider, collapse it through View or the divider, and restore it with the footer's
Show Sidebar button. Its previous width, expanded sections and order are kept.

Quick Look, Properties, Open With, sharing and Reveal in Finder remain available
for eligible selections. Copy Names, Copy Path and Copy Relative Paths help you
reuse a selection in another application.

### Keyboard and appearance

Choose **Explorer**, **Mac** or **Custom** in Settings. Explorer behavior includes
F2 Rename, F4 Address, F5 Refresh and Delete to Trash. Mac behavior keeps
familiar native choices; Custom lets you adjust the supported actions.
Control aliases cover browser tabs, navigation, file commands and file-list
selection. Command equivalents stay available, and text fields/editors keep
their own editing behavior. Space opens Quick Look in each preset.

Both presets use **F6 / Shift-F6** to move between the sidebar, address, search
and file list, and **Control-Tab / Control-Shift-Tab** to change tabs. Use
**Shift-F10** for the focused selection's context menu. These actions also live
in Go → Keyboard Navigation and Window. On keyboards that use function keys
for hardware controls, hold Fn too. macOS shortcuts and active text composition
keep priority; Custom can change or disable Traverse's bindings.

Find a Command searches the current browser or editor's actual commands. You
can use the menu, context action or shortcut that suits the task.

Use **Search Settings** (`⌘F` in Settings) to find a specific control by name
or related words. Try `swap pane shortcut` to jump to that command's binding.
Choose a result with the mouse or press Return to jump to the highlighted row.
Click the X or press Escape to clear the search and return to the page list.

Use **Edit → Select by Name…** in a local folder or on the current ZIP or TAR
page. Enter part of a name, or use `*` for any text in a pattern such as `*.pdf`.
The command can replace, add to or remove from your selection. It matches the
names already displayed.

### Terminal and comparisons

**Open Terminal Here** opens the current local folder in Apple's Terminal,
including folders on mounted drives. A selected folder has the same action in
its context menu. The navigation button is on by default and can be hidden in
Settings → General or during setup. This opens a local shell; it does not start
an SSH session or extract an archive.

Select **two local files** and choose **Compare Files** to open an external diff.
Automatic chooses an installed supported app; General lets you prefer
Kaleidoscope, Beyond Compare, Visual Studio Code or FileMerge from the active
Xcode installation. Display order decides the left and right files. Traverse
passes each path separately without a shell command or an automatic merge.
The comparison app controls any editing you do there. Remote and archive members
need an explicit local copy first.

Use **File → Compare → Compare Text Files…** on two local text files to review
them in Traverse.
With one file selected in each pane, choose **Compare Text with Other Pane…**.
The focused pane's file appears first.
You can also select just one supported text file when the other pane lists a
file with the same name and has no selection. The divider offers **Compare
Text with Matching Filename** using the visual pane order. The File menu's
comparison command uses your focused pane first. Your selections stay put.
The diff opens both files read-only and counts added and removed lines. Use
**F7 / Command-F7** to step through the change groups. Refresh reads the pair again.
**F6** switches text panes. Find and Go to Line follow the focused pane.
Enter a line number or a position such as `240:6` in Go to Line.
**Find in Diff** (`⇧⌘F`) searches changed lines or all lines on both sides of
the displayed snapshot. A short selection fills the search field. Choose a
result to select its exact text. Refresh retires old results and keeps the query.
Use `⌥⌘G` and `⇧⌥⌘G` to visit the next or previous result while reading
either pane. The same shortcuts work in Find Across Diffs.
Added lines have a green fill and a plus sign. Removed lines have a red fill
and a minus sign. The signs also distinguish the two sides in grayscale.
Paired changes can also highlight the exact text that changed within a line.
Use **View → Highlight Changes Within Lines** to toggle those marks.
Very long lines and grouped overviews keep their line shading.
Use **View → Whitespace** to hide trailing spaces and tabs, or changes in
indentation and repeated spacing. The viewer keeps the original text, current
selection, Find and scroll position.
**Link Scrolling** follows matching lines across insertions and deletions. Turn
it off in the viewer or change the default in Editor Defaults. Large comparisons
that show a grouped overview use independent scrolling. The viewer accepts
UTF-8 text up to 1 MiB per file.
When there are several change groups, click either track in the change map
to jump to the nearest group in that document. The numbered list button or
**View → Go to Change…** (`⌥F7`) shows a short preview and the line ranges
for each change. Use the arrows to review the list and Return to jump.

**Compare Folders…** reviews two selected local folders in
display order. With two different local folders open side by side, clear the
selection and choose **Compare with Other Pane…** from the current pane's
context menu. The current folder goes on the left. If you select one folder,
the comparison uses that folder on the left instead.

Compare Folders matches exact names and looks at file sizes and modification
times. It shows a folder present on just one side as one row for that branch.
Use **Show** to look at one side's missing items, differences, or skipped
locations. Press `⌘F` to filter by a name or relative path within that view.
You can include hidden items and refresh the same pair. To inspect
the contents of a file difference, select it and choose **Open Text Diff**.
It reads the selected regular files and shows an empty side for a missing file.
Use **Open in Editor** to work on the left or right file directly. The editor
keeps any draft you already have open for that file. If the file has changed
since the comparison, refresh the report before opening it.
**Find Across Diffs** searches the visible list of comparable changes.
**Check Contents** also looks for byte differences in up to 64
same-sized file pairs, reading up to 1 MiB per file and 4 MiB in total. It
counts pairs it could not read or fit in that limit. Your current report stays
visible while it checks. **Stop** returns to that report. Select missing regular
files with the same parent folder and choose
**Copy to Left** or **Copy to Right** to queue them together under their
original names. **Review Copy…** shows the exact source, destination and file
list before you decide. Both sides must contain the parent folder. The report refreshes
when files are copied. **File → Undo File Operation** reverses a completed
group. When a name becomes occupied during a copy, the transfer results show
which files arrived and which need review. Refresh if a file or its folder
changed after the report.

### Git inside a folder

Open **Git Tools** in a supported local repository to see its checked-out
branch or detached revision and review its history. The same commands appear
in **File → Git**. The editor's Files sidebar also shows the current branch
in its project heading.

Turn on **Show Git badges in file lists and icons** in Settings to see **S**
for staged changes, **?** for untracked files and **!** for conflicts. The file’s
tooltip and accessibility label explain the mark. Traverse checks visible
files using local Git metadata.

Select one regular file and use **Stage Saved File…** in the Git menu to review
the index change. Traverse stages the bytes on disk, and unsaved edits stay in
the editor. **Unstage File…** restores that path's entry at HEAD. For a staged
addition it removes the entry, and for a staged removal it restores the index
entry without recreating the working file. Use the staged review to select a
file that is absent on disk.
In **Compare Working Folder…**, choose **Compare with Git Index** from View.
Select a regular file to stage its saved bytes in the same review. Select a
missing tracked file and choose **Stage File Removal…** to stage its absence.
Traverse checks the working folder, file and index again before it applies
either action.
The local editor offers the same actions in **File → Git**. It checks the
editor's saved file before staging. A replacement or an external edit asks
you to reload or review the file from the browser. The draft and its Undo
history stay in the editor.

These actions cover one whole file in an ordinary local checkout with a commit.
For a tracked file, Stage preserves the index's execute bit. Use your Git client
to stage a mode-only change.
The Stage check uses repository ignore and attribute rules. For clean filters,
line-ending conversion, global conversion rules, linked rename pairs, or
special index layouts such as sparse and split indexes, use your Git client.
Another Git writer or a change after the confirmation sends you back to review.

To stage one block, open **Compare Working Folder…**, select **Git Index**
and open the tracked file's text diff. Use **Previous**, **Next** or **Go to
Change** to select the block, then choose **File → Stage Selected Change…**.
Confirm the proposed index change. Traverse returns to the same file in the
working-folder review so you can open the remaining changes. To unstage one
block, open **Review Staged Changes…** against HEAD, select it in the file's text diff,
and choose **File → Unstage Selected Change…**. That block returns to its
HEAD version in the index. The working file keeps its changes.

Both actions use exact, detailed UTF-8 diffs with LF line endings, no BOM and
matching file mode. Choose **Show All Whitespace** to enable the selected-block actions.

From **Git Tools**, open **Compare Git Revisions…** and choose a branch, tag or
commit for each side. The comparison starts in your current folder.
Turn on **Compare entire repository**
to bring in the rest of the project. Swap the revisions to reverse the comparison.
Choose **Since Common Ancestor** to see what the right-hand revision introduced
since its shared base with the left. The left panel labels the actual base commit.
You can choose a commit directly when the local histories lack a unique base.
The summary shows changed files, affected subfolders and added and removed lines.
Select a text change and choose **Open Text Diff** to read both committed versions.
Press `⌘F` in Changes to filter by name or path on either side, including
both names of a renamed file. **Change Type** narrows the same list to
additions, modifications, removals or another change type. Find Across Diffs
uses the visible list, and the footer keeps the totals for the whole review.
**Return** opens the selected text diff.
When the list has several comparable files, use the header arrows or
`⌥⌘[` and `⌥⌘]` to review the previous and next file in the same window.
The sequence follows the visible Changes list from the time you opened it.
Use **Find Across Diffs** (`⇧⌘F`) to search that sequence by text. Start with
**Changed Lines**, or choose **All Lines** to include the surrounding text.
Search both versions or choose **Before** or **After**. Results show which
side and line matched, with counts for searched, skipped and remaining files.
Open the information button beside those counts to see which inspected files
were skipped. Try **All Lines** for files with grouped changes.
**Stop** keeps completed results. **Search More** picks up with the next
unfinished file. Narrow the search when it reaches the match limit.
Pick a result to open its file and select the match. Search reuses the exact
text shown for the file already open. Use **Refresh** to check that source again.
Traverse asks you to search again if another file changes before you open a match.
Switch to **Folders** to browse both committed trees. Open a folder in either
pane to follow the same path on both sides. Rows show differences in the current
folder, while the summary covers the full comparison scope. Select a file to
compare its committed text, including a file present on just one side.

Use **Compare Working Folder…** to compare the current folder on disk with a
local branch, tag or commit. Open a folder row to visit the same path on both
sides. The table checks names and types first and calls out entries that only
exist on one side. **Check Contents** compares the exact on-disk bytes of up to
64 file pairs in the current folder with Git's stored content, up to 1 MiB per
file and 4 MiB total. This check uses the bytes as saved, including line
endings. Pairs beyond the limits remain unchecked. Choose **Open Text Diff**
to read a selected text pair side by side. Reload the folder review when a
file changes on disk.

Choose **Git Index** in Compare Working Folder to see the file version Git
holds beside what's saved on disk. **Check Contents** compares their exact
bytes, including line endings, so checkout conversions can show as changes.
Reload keeps the selected path when it still exists. If the index changes
while a text diff is open, reload the folder before opening that diff again.
Use **Review Staged Changes** to inspect the Base, Ours and Theirs of an
unmerged index entry.

Press **Command-F** to filter the current folder by name or path. Use the
arrow keys to choose a result and Return to open it. After **Check Contents**,
**Hide Matching Files** leaves folder links, differences and unchecked files
in view. Escape clears the path filter and keeps the matching-file preference
for the current review. **Find Across Diffs** searches the visible files
against the chosen revision or index. It leaves your folder and selected row
in place when you return to the review.

Use **Review Staged Changes…** to compare the Git index with HEAD or a
different local branch, tag or commit. It starts in the current folder and can
expand to the entire repository. The same text viewer opens the captured
staged version. **Conflicts** lists the recorded Base, Ours and Theirs versions
for unmerged files. Pick two stages to compare, including sides where Git
records an absent file.

Select a file and choose **Git File History…** to review changes from a branch,
tag or commit. Use **Older Changes** and **Newer Changes** to move through
history. Press Command-F to filter this page by commit ID, message or either
recorded name. The timeline follows renames across pages and includes changes
introduced by first-parent merges. **Compare Change** shows the file before and
after one commit. Command-click two rows on a page and choose **Compare Versions**
(`⌘↩`) to compare their recorded paths and text across a rename. **Open Version** opens
one row’s text in a read-only editor with Find and line navigation. To compare
the same path across branches, use **Open or Compare Revision** from a chosen
starting revision.
That picker can open the exact version or compare it with the disk, index or
unsaved buffer while keeping your place in the timeline. Use **File path** to
revisit an earlier name recorded in the timeline.

Use **Compare File Across Revisions…** from the file’s context menu or
**File → Git** to pick two versions of this path in one sheet. The comparison
opens directly with both pinned commits.

For one selected file, choose **File → Git → Compare Working File with
Revision…**, then pick a branch, tag or commit. Compare the current file on
disk, or choose **Compare Open Editor** to include its unsaved text. Refresh
keeps the chosen commit and rereads the selected local side.

To compare across history pages, select a version and choose **File → Set
Comparison Base**. Navigate to another version and choose **Compare with Base**
(`⌥⌘↩`). The base holds its original commit and path until you clear it or
close the history window.

In a Git checkout or a read-only Git version, place the caret on a line and choose
**File → Git → Show Commit for Line…**. See the local commit, author and original
path, including tracked renames. **Open Original Line** opens that version at
the recorded line. In an open draft, inserted lines can move a match down the
file. Traverse follows that match when it can identify the exact committed
line. Draft-only lines and ambiguous matches show a message in the editor.
If the line reaches the oldest available history, the result says so.

Under **File → Git**, choose **Compare Editor with HEAD** or **Compare Editor with Git Index**
to open a diff against the committed or staged version in one step. The HEAD
comparison keeps its original commit when you refresh. The index comparison
rereads the current staged version.

In the editor, **File → Git → Open or Compare Git Revision…** goes straight to
the branch, tag and commit picker. Open a read-only version or compare it
with the text in the open editor, including unsaved changes.

**Review Staged Changes…** and **Compare Working Folder…** also open from the
editor’s Git menu. They start in the current document’s folder. Turn on
**Compare entire repository** in the review window for a broader view.

From **Compare Working Folder**, use **Compare Revision with Open Editor**
for a file already open in Traverse. It compares that buffer with the exact
selected commit. **Refresh Editor** captures the same editor again while
keeping the original revision pinned.

Use **Open Working File** to edit the selected file on disk. An existing
editor keeps its unsaved text. If the reviewed file was replaced before a new
editor could open it, reload the folder and choose the file again.

Traverse uses Apple's Command Line Tools to read local Git objects. It keeps
your checked-out files and branch in place and works offline. Standard local
repositories and linked worktrees on the same volume support loose or packed
objects. Each linked worktree shows its own working files and index while
sharing the repository history. From **Git Tools → Browse Git Worktrees…**,
open another accessible checkout in a tab or beside your current pane.
**Open matching folder** takes you to the same path inside that checkout when
it exists. Turn it off in the chooser to open the checkout root directly.
Git Tools visibility is adjustable in Settings → General.

Open corresponding folders in two worktrees of the same repository to get
**Compare Git Checkouts** at the divider and in **View**. It starts with each
pane's checked-out commit. You can switch to another revision inside the
comparison.

Open **Commits** in **Compare Git Revisions** to see commits unique to each
side. Select a commit to read the files it changed and open their text diffs.
For a merge, choose which parent to compare with. Commit lists use the local
history. Press `⌘F` to filter loaded commits by message or ID, then Return to
review the selected commit. The filter stays in place when you go back. The
file report respects the current folder scope.
From Changes, Folders or a commit's file report, open **Left File History** or
**Right File History** for the selected file. Its timeline starts at that side's
commit and follows the path recorded there. Reload keeps the starting commit
you chose, even when your checkout moves on.

**Git Tools → Git Folder History** starts with the current folder and checkout.
Pick another local branch, tag or commit to follow its first-parent history.
Older and Newer keep that choice while you page through commits. Open a commit
to see its changed files and their text diffs. **Show whole repository history**
widens the scope. A commit filter checks the displayed page and stays active
as you move between pages.

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
a same-volume rename has different semantics. FAT-formatted destinations,
including some USB drives, currently cannot receive verified Copy or
cross-volume Move operations. Traverse refuses these before creating temporary
transfer files and keeps the source. The
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
Use **Browse Archive** on a JAR, EPUB, CBZ or Python wheel to inspect its ZIP
members and copy them out. Editing the container is available for supported
ZIPs and TARs, while these packaged formats open for reading and extraction.

Eligible ZIP edits include file/folder Rename, batch Rename, Add, Remove, Create
File, New Folder, New Folder with Selection, and internal Copy/Cut/Paste.
Original Update and Save ZIP Copy Instead share a review. The copy leaves the
original unchanged; Original Update uses recorded staging and recovery. An
unsupported archive, unsafe name or changed original can refuse the edit.
Existing folders are not silently merged during ZIP member changes.

Quick Compress performs the common task with current preferences; ZIP is the
default. Operations also lets you choose TAR, TAR.gz or TAR.bz2.
The command shows the chosen format and numbers occupied names. Compress… opens
the full options. Extract to the named folder uses a fresh sibling
destination; Extract opens the destination review. Copy/Paste from an archive
to a local pane uses that same checked extraction path. One selected folder
arrives by its own name; groups retain their archive paths inside a new folder.
Separate ZIP and TAR windows use the same clipboard as their Explorer workspace.
Copy can deliver a selection into a local pane; Cut stays in its original
archive. Paste also accepts copied local files through the Add review. Closing
the source archive window expires its captured member selection.

Select two text members and choose **Compare Text Files…** to open the native
diff. Use archive-wide search to select members in different folders. The
viewer reads up to 256 KiB per member and supports UTF-8 text in ZIP and plain
or prepared gzip and bzip2 TAR. Select both members again after the archive
changes to review the updated versions.

| Format | Browse and preview | Create or change |
| --- | --- | --- |
| ZIP | Folders, supported text/hex/images, extraction and internal pane copies | ZIP creation and supported member edits; eligible text members open in the editor |
| Plain TAR | Folders, supported previews, extraction and internal pane copies | Creation and supported member editing |
| Gzip TAR (`.tar.gz`, `.tgz`) | Bounded preparation, folders and supported previews; deliberate Open requests preparation | Creation and supported member editing |
| Bzip2 TAR (`.tar.bz2`, `.tbz2`, `.tbz`) | Bounded preparation, folders and supported previews | Creation and supported member editing |

TAR supports Rename, batch Rename, Remove, Duplicate, Move,
Add, Group, Create File/Folder and internal Cut/Copy/Paste, plus text editing in
plain or prepared compressed TARs. These reuse the ZIP workbench and editor.
Keep Both is the default when adding files; Replace Files is explicit and never
merges folders. Compressed TARs offer compression choices, while bzip2 edits can
keep the current setting. Eligible original updates, local copies and Finder
exports support guarded Undo after restart. Older releases have a smaller archive feature set; see their
release notes when using an earlier download.

Archive size, metadata and member-type limits apply. Compressed preparation uses a
bounded temporary copy and is not started by passive tab restore or merely
searching filenames. Deliberately opening a supported compressed TAR, including
a search result, also requests preparation. Stop cancels that
request; returning to a changed archive passively asks for Prepare again.
Encrypted archives, ZIP64 and unsupported member metadata may be refused by a
particular write route. A ZIP external drag and a remote external drag are
different capabilities; this guide does not promise remote-to-Finder delivery.
Public 0.3.0 also lets you drag files and folders from plain, gzip or bzip2 TARs
into Finder, with guarded Undo after restart. This is separate from supported
archive copies into a Traverse pane; older downloads have a smaller feature set.

## Text editor

Use **View → Editor Sidebar** or `⌘\` to show Files and Open in a local editor.
Files starts at the containing folder or the detected Git repository. It lists
one folder at a time as you expand the tree. Open brings an existing document
forward, with a dot beside an unsaved edit. Press **F6** to move between the
outline and text, and **Return** in the outline to expand a folder or open a
file. A new document opened from the sidebar keeps the same project context.
**View → Project Files** and **View → Open Editors** show and focus those lists.
**View → Reveal Current File** opens Files, expands the current document’s
parent folders and selects its row.
You can start new local editors with the sidebar visible in Settings → Tools →
Editor Defaults.

Use **File → Open Project File…** (`⌘P`) to find a file by name inside the
same project, including subfolders. Type, select a result with the arrow
keys, and press **Return** to open it in Traverse. **Escape** returns to your
editor. The picker reads filenames and metadata within the shown folder and
checks the selected file before opening it.
You can type word initials, such as `eht` for `EditorHTTPTrace.swift`. Exact
names and literal fragments appear first.
Append `:line` or `:line:column` to jump directly to a text position, as in
`Settings.swift:42:8`. Type `\:` to search for a literal colon. Previous Text
Location takes you back to the editor you opened the picker from.

Use **Edit → Search Scope → Find in Project…** to search supported text files on disk in the
current project folder. Selecting a short, single line of text fills the
search field in project and folder searches. Return starts the search, then
opens the selected match. Match Case and Whole Words narrow the results.
Use the file-type menu to search one language or text family. Choose **Search
More** to check the next batch and keep the matches you have. The panel shows
how many files it searched, how many it skipped, and which limits it reached.
For unsaved text, use **Find in Open Editors**.
Enter a relative path such as `Sources/Models` in **Folder** to search only that
part of the project. Clear the field to search the entire folder again.
Project file, text and declaration searches skip nested `node_modules`,
`.build`, `DerivedData`, `.venv` and `__pycache__` folders by default. Turn
on **Include generated folders in project searches** under Editor Defaults
to include them. The hidden-files setting still applies.
To narrow the search to one subtree, right-click a folder in the Files
sidebar and choose **Find Text in Folder…**. With that folder selected, the
same action is in **Edit → Search Scope → Find in Selected Folder…**.

Use **Go → Find Project Declarations…** to look for a named function or type
in the same project folder. Type part of the name or its initials and press
Return. Traverse reads supported Swift, Rust, Python, JavaScript, TypeScript
and C-family files on disk in batches. Use the file-type menu to narrow to one
language. Open a result with Return. If it points
to a draft you already have open, Traverse checks the declaration in that
draft before moving the caret. **Previous Text Location** returns you to the
editor you were using.

Choose **Outline** in the sidebar or use **View → Document Outline** (`⇧⌘O`).
Type in **Find in Outline** to narrow the list of recognized code declarations,
Markdown headings, JSON/JSONC keys, YAML block keys, or INI and TOML sections
and keys. TOML includes quoted and dotted keys and repeated table headings.
Press **Return** to jump to the selected entry. **Escape** clears the query
or returns to the text. The outline follows your open text, including unsaved
edits, using the same syntax as highlighting. In JavaScript and TypeScript it
also recognizes direct arrow and function assignments with a single-line
header, plus named types in TypeScript.
In Swift it can also find a function whose name starts on the line after
`func`. Find in Current Scope can use that function when its body opens on
the recognized signature line.
In C, C++, Objective-C and Objective-C++, it recognizes named type definitions,
functions with simple headers, and Objective-C class and protocol headers.

Place the caret in a name and press **F12** or choose **Go → Find Declaration
in This File**. The editor uses the current file's outline. When the name
repeats, choose the signature and line you want. **Previous Text Location**
returns to the original caret.

After typing part of a name, press **F5** or choose **Edit → Complete Name in
This File**. If more than one declaration matches, choose a name with the arrow
keys and Return. Escape keeps what you typed, and Undo restores the prefix after
a completion.

**Go to Symbol in This File** (`⌃⌘O`) filters the current outline without
opening the sidebar. **Go to Symbol in Open Editors** (`⌥⌘O`) checks your
open outlines and shows the file and line for each result. Both include
unsaved edits. Type a name or its initials, such as `dos` for
`draftOnlySymbol`. Press Return to jump, then use **Previous Text Location**
to return to your original caret.

**Show indent guides** in Editor Defaults draws a line at each full indent in
code. Guides follow your tab width and stay in the leading whitespace, including
when a long line wraps.

Choose **View → Show Whitespace Marks** to see space dots, tab arrows and hard
line breaks in the current editor or both sides of a text comparison. **Show
whitespace marks** in Editor Defaults sets the starting value. This display
leaves text, wrapping and comparison rules in place.

When scrolling past a Markdown heading, an INI or TOML section, a JSON/JSONC
container key or a recognized Swift or Rust block, the editor can show its scope beside the
file path. Click it or choose **Go → Go to Visible Scope** to jump to
its start. **Show scope while scrolling** controls it in Editor Defaults.

Use **Go → Outline** to jump to the previous or next outline item with
`⌥⌘↑` or `⌥⌘↓`. **Go to Enclosing Scope** jumps from the caret to
the start of its recognized block, and choosing it again moves up a level.
**Previous Text Location** takes you back.

Use **Go → Go to Matching Bracket** (`⇧⌘\`) with the caret beside a
bracket, or **Edit → Select Inside Brackets** to select its contents. Repeat the
selection command to expand to an outer pair. These commands understand code
brackets in Swift, Python, Rust, C, C++, Objective-C, JSON and JSONC.
**Highlight matching brackets** in Editor Defaults outlines both characters
when the caret is beside a recognized pair in supported code. Comments and
strings stay out of the highlight, and the outlines follow your theme.

**Expand Selection** (`⌃⇧⌘→`) grows the current selection to a word, line,
enclosing bracket, recognized scope or the whole document as appropriate.
**Shrink Selection** (`⌃⇧⌘←`) retraces those steps and restores the earlier
view. Typing or making a different selection starts a new sequence.

Use **Previous Text Location** (`⌃-`) and **Next Text Location** (`⌃⇧-`)
in Go to retrace Outline, Go to Line, bracket and Find in Open Editors jumps.
**Go to Last Edit** returns to the latest text change in the current editor.
Reloading the document starts a new editing location.
The trail returns to the original editor, selection and viewport. It skips
locations whose buffer has since changed or closed.

Use **Go → Toggle Line Bookmark** to mark the current line. **F2** and
**Shift-F2** move between marks, and **Choose Line Bookmark…** shows their
line numbers and short excerpts. Marks stay in the open editor and follow
line shifts as you type. Replacing all text, reloading or closing clears them.

The editor gutter marks unsaved additions, edits and deletions against the
last loaded or saved text. Use **F7** and **Command-F7** to move between change
groups. Click a marker or press **Option-F7** on a changed line to peek at the
saved and edited text. From there, Return opens the full comparison at that
change. Press **Option-Command-F7** or choose **Go → Go to Unsaved Change…**
to pick an addition, edit or deletion with a short preview and line ranges.
Set **Mark unsaved lines** in Editor settings to control the markers and
these quick navigation commands.

Use **Edit → Merge Conflict Markers** to move between complete conflict
blocks and keep the current section, incoming section, both, or a recorded
base. This edits one block in the buffer and supports normal text Undo.
Save the result when you're ready, then stage it in Git.

In a Git project, a file’s context menu opens its Git File History. The editor
also offers it under **File → Git** for a document opened from a known project,
even with the sidebar closed. The sidebar uses **S** for a staged change, **?**
for an untracked file and **!** for a Git conflict. The unsaved dot can appear alongside any
of those marks. Git reads the index and project ignore rules for the visible
files as you browse. Hover a row or use VoiceOver to hear what its marks mean.
Turn on **Highlight on-disk changes in Git projects** in Editor Defaults to
see **M** when a visible file’s exact bytes differ from the version in the
index. Eligible files are capped at 1 MiB each within a 4 MiB viewport check.

Use **Compare Local** in Git File History to choose On Disk, Git Index or
Unsaved Buffer as a comparison source. It can also compare a draft with the
on-disk file, or the on-disk file with the index. The viewer captures each
version when you open or refresh it. Use **Edit at Change** above a side from
an open editor, or **File → Edit at Selected Change**, to move to that change
in the live buffer. Refresh the comparison if you've since edited that buffer.
In a detailed comparison with **Show All Whitespace**, **Apply Selected
Change to Editor** brings the other side's selected lines into the open
editor as one Undoable edit. Review the new text before saving it.

From an editor in a Git project, **File → Git → Open or Compare File in Git
Worktree…** finds the same path in another existing checkout. It can open a
second editor or compare against the other checkout's file. The comparison
uses the other editor's live buffer if that file is already open. Each
checkout keeps its own branch and any unsaved edits.

To compare the current path at two Git revisions, choose **File → Git → Compare
Git Revisions** in the editor. Pick the left revision, then the right one.
Both sides show their chosen ref and exact commit. Use Git File History to
find earlier names when the file has moved.

Use Edit in Traverse for an eligible local, SFTP, SMB, ZIP or TAR text document.
TAR text editing includes plain and prepared gzip/bzip2 archives in public 0.3.0.
Documents can share native tabs or open in separate windows. Opening preferences
choose Traverse's behavior without changing macOS file associations.

The editor offers syntax highlighting for common code, configuration and markup
formats, including Swift, Python, JavaScript/TypeScript, Rust, JSON/JSONC, shell,
SQL, HTML/XML, Markdown, Dockerfile, Makefile and INI. INI files and
`.editorconfig` show sections and keys in the Document Outline. Highlighting
helps you read a file without executing it.

Find and Replace work in the current document. Select a block and choose
**Edit → Search Scope → Find in Selection…** (`⌥⌘L`) to search or replace within that block.
The scope follows replacements made from Find. After another edit or Undo,
select the text again or turn off **Find in Selection** in the Find options.
Each side of a text diff keeps its own search and selection scope.

Choose **Edit → Replace Occurrences in File…** to start a replacement with
the word at the caret or a short one-line selection. Find matches case and
uses whole words for a word seed. Enter the replacement and use the usual
Find controls to review and replace the matches. One Undo reverses Replace All.

Use **Edit → Search Scope → Find in Current Scope…** from a recognized function, heading or
JSON object or array property to search just that part of the open file. The
Find bar shows the scope. After editing, choose it again to check the new
boundaries, or use **Search Whole Document** in the Find options.

**Find in Open Editors** searches text already open in Traverse, including
inactive tabs and read-only views. Results jump to the matching document and
text.

Indentation, line comments, Surround Selection, selected-line sorting and explicit
trailing-whitespace removal use normal text Undo. JSON/JSONC formatting keeps
key order and original token spellings; JSONC retains supported comments.
JSON bracket completion and block indentation have separate opt-outs.

Return also indents brace blocks in Swift, Rust, JavaScript, TypeScript, C,
C++, Objective-C, Objective-C++, Go and CSS, plus Python suite headers. It uses
your indent settings and has its own switch under **Settings → Editor**.
Turn on **Complete code brackets** in Editor Defaults to pair `()`, `[]`,
and `{}` in recognized code in those languages. Typing a closer the editor
inserted moves past it. Backspace between an empty pair removes it in one Undo.
Typing inside comments and strings stays literal.

Use **Edit → JSON → Check JSON** to find a syntax problem in the current JSON
or JSONC draft. Choose **Go to Issue** to move to its line and column. The
check leaves the draft and its Undo history intact.
**Check Against JSON Schema…** accepts a local UTF-8 draft 2020-12 schema and
checks types, required and additional properties, array items and tuples,
enum and const values, numeric bounds and basic length/count limits. It also
supports combining rules with `allOf`, `anyOf`, `oneOf` and `not`, or choosing
a rule with `if`, `then` and `else`. Numeric comparisons retain decimal
precision. References can point to rules within that file.
If a schema uses other rules or external references, the check explains why it
cannot complete. Documents up to 1 MiB and schemas up to 256 KiB are supported.

Go files show types, functions and receiver methods in Document Outline and
project declaration search. Go's raw strings and rune literals stay separate
from code when the editor highlights text and matches brackets.

**File → Compare → Compare Changes** shows the last loaded or saved text beside a captured current
buffer. Refreshing that comparison does not reread the file or server. It is a
review, with no merge or Save action of its own.

Use **File → Compare → Compare with File on Disk** in a local editor to check an external
change before deciding what to do with your draft. Refresh reads the file and
captures the editor again. Your draft and the original Save baseline stay in place.

Choose **File → Compare → Compare with Open Editor** to compare the current editor with
another open tab or window. Type its name or location and press Return. The
comparison includes any unsaved text from both editors. **Refresh Current
Buffers** captures their current text again, or keeps the earlier snapshot
available if an editor closes.

Choose **File → Compare → Compare with Clipboard** to review copied plain
text beside the current selection, or the whole editor buffer if no text is
selected. It captures both sides when you choose the command. Choose it again
after copying something new.

For a single reading column, choose **View → Unified Diff**. It keeps the
original line numbers for each version and folds long stretches of shared text.
Select a fold and press Return or Space to open it, or use **Show All Unchanged
Lines** in View. Find can open a folded
match and restore its exact selection when you return to Split Diff. Use
Split Diff for grouped changes, whitespace filters or applying an editor change.
`⌃G` opens **Go to Line**. Choose Before or After with the arrow keys and
enter a line or `line:column` to jump to that version's original location.

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

In the local editor's **Saved Versions**, select a change and its Save or Undo
attempt, then choose **Compare Versions…**. The read-only diff uses the two
retained versions for that attempt. Close it to return to the same saved change.
In a supported Git project, **Compare with Git Revision…** pairs a retained
version with a chosen branch, tag or commit. Use the two choices in the picker
to decide which side of that Save or Undo to review.
Version retention is bounded, and full or uncertain storage can pause further work.

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
The direct edition checks a saved location against the file and current
filesystem permissions each time it opens. Saving a location adds no access
of its own.

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

Use **Copy SMART Reading** to copy the timestamp, warnings and reported
measurements from the displayed reading. If the screen still shows an earlier
reading, the copied text says so. It leaves out drive names, paths and hardware
identifiers.

To benchmark, choose a writable folder and explicitly start a sequential or
random file workload. Traverse writes and verifies its own scratch file, reports
cache/flush choices and cleans up that workload. Quick, Standard and Extended
sizes trade work for duration. Results compare matching completed workloads;
they do not measure raw-disk speed or guarantee real-world application performance.

Use **Repeat Benchmark** to run a completed result’s settings again in the
same selected folder. Traverse shows the earlier result beside the new one
when their measured conditions match. A protected drive or a new folder
selection requires a fresh run.

The comparison picker also lists matching completed runs from other volumes
in this session. Both volume names and times appear above the measurements.
Complete Quick Mix pairs are available when both stages match their settings.

Quick Mix runs the small sequential and random tests together while keeping
their results separate. Measurement Details shows where completed block calls
land in the latency distribution, with P50/P95/P99 labels on the containing
ranges. Copy Results includes those range labels in text and the original
distribution in JSON. Partial or failed runs keep their progress facts without
claiming a completed speed result. Shared reports leave out drive names and
private recovery paths.
When a matched run or Quick Mix pair is open, **Copy Results → Comparison
table** copies the displayed phases and P95 latency as tab-separated text
for a spreadsheet or report.

Destructive formatting, partitioning and physical APFS volume management are
not ordinary available workflows. Unsupported operations can hand off to Disk
Utility. Broader device support remains in the
[roadmap](../ROADMAP.md).

## Feedback and crash reports

Help → Crash Reports & Feedback keeps the report editable. Add what happened,
steps to reproduce it and any context that helps. Device information is included
by default: available capture-time model/core facts and a separately labelled
current CPU/RAM snapshot. You can edit the report before sharing. The privacy
helper hides common private details; review the text yourself too.

Open GitHub Draft prefills the reviewed report when it fits the browser URL
limit. Longer reports produce a clearly abbreviated draft; Copy Report and
Save Report keep the full text. Opening a draft sends its contents to GitHub and
browser history, but you still choose whether to publish the issue. Native
captures stay local and are never uploaded automatically. See [Privacy](../../PRIVACY.md).
