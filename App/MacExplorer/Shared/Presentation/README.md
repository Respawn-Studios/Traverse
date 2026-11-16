# Shared presentation

ToolWindowPresentation.swift owns window allocation/chrome/placement and tool motion. Appearance.swift owns semantic materials; InterfaceSizing.swift owns the app-wide sizing/settings binding. BrowserMotionPreferences.swift owns motion policy. Reuse these from feature controllers; no file-operation authority belongs here.

These are folders within the same App module, not additional packages. Consult App/README.md and docs/engineering/README.md from the repository root.

`RemoteFileTableView` is the existing SMB/SFTP native input table, moved here
from the SMB row controller. It shares responsive columns, pointer selection,
marquee, delayed name-click Rename and native Cut/Copy/Paste routing. Concrete
rows and sessions retain their callbacks and operation admission; the table
does not read remote data or grant file authority.

NativeWindowMenu.swift shares standard Minimize/Zoom, tab controls and the
AppKit-managed window list. EditorMenuOwnership hands off the main, Window and
Help menus together and restores the browser's exact menu owners on return.
AppKit populates and maintains the registered Window menu automatically;
features do not enumerate extra windows, maintain a second list or replace
native activation actions.

FileUploadReview.swift shares the file/name review, materials, sizing and motion
between SFTP and SMB. Protocol-specific name validation and all upload authority
stay in the concrete connection session; the shared view never writes files.

ToolPageNavigation.swift supplies the native source-list rows and shared sidebar
spacing used by Settings, Help and Drives. Keep feature selections in their
existing owners. NativeContextMenu.swift projects existing commands into short,
relevant groups; it does not grant a capability or replace the menubar catalog.
ToolWindowCloseMotion.swift is an opt-in exit after a feature accepts a user
close. Pending work and editor/discard decisions stay with their feature owner;
programmatic closure and actual work draining remain native.
Custom keyboard-window subclasses inherit ToolMotionWindow too. Use
performClose for an ordinary user Close/Done action; keep direct close for
feature-owned teardown after work has drained. New presentations use position;
bringing an existing window forward must preserve its user-selected frame.
Hidden-to-visible presentations share a short native window fade, including the
titlebar and material. It retains no window picture. Showing a visible window or cancelling its close does not replay
the entrance. Opening and closing retain independent motion preferences.
Interface-size changes use the same native content crossfade once per visible
window. Text keeps its actual requested size and native controls keep focus;
there is no bitmap enlargement or replacement control tree. Reduced/Off motion
and system Reduce Motion govern this transition too.
The native editor's finishClose is feature-owned teardown after its Save/discard
decision and worker drain. It uses direct close so document owners receive the
native didClose acknowledgement before releasing or retiring the text buffer;
it must not enter the asynchronous user-close fade a second time.

FilenamePrompt.swift provides native name entry and inline validation for local
and remote creation. Callers retain the observed parent and revalidate before
mutation. Local and SFTP Rename share BrowserInlineRenameController instead of
maintaining separate field-editor implementations.

`CommandDiscoveryPresentation` supplies the common browser/editor search panel
and result rows. Its single-column viewport follows actual native scroller
geometry, including enlarged text. It contains no command catalog, callbacks
that write files, stored queries or history. Each feature still owns context,
focus, menu validation, dispatch and dismissal.

AdaptiveToolColumns.swift keeps the same child views during column/row changes.
Its first measured width is adopted without animation; only later genuine
reflows follow the shared Full/Reduced/Off policy. This avoids new panels
animating from an unmeasured narrow arrangement. Tool-page replacement can use
the existing native compositor crossfade without animating text geometry.
Use one main effect for each change. A comparison that scrolls into place should
use that scroll as its transition; keep page fades for changes in place so
moving labels stay readable.

FileKindText.swift and FileOpeningSymbol.swift share filename-kind labels and
finite native-opening image variants across local/server rows. Cues follow the
existing opening preferences and each connection's edit scope; they never grant
Open or query a file body. Remote preference repaint uses only the bounded loaded
metadata cache. FileSizeText also handles unsigned remote observations without
narrowing overflow and uses the same zero-byte wording as local rows.
