# Browser

BrowserViewController.swift is the controller entry. BrowserViews.swift and FileIconBrowserView.swift render the canvas; BrowserTabManagement.swift, BrowserPointerSelection.swift and BrowserDragDrop.swift own the corresponding interactions. Shared material/motion/window code lives in ../Shared/Presentation.

BrowserSidebarNameView.swift owns click/hold/drag on existing labels. The sidebar layout adapter/coordinator retains ordering, expansion and native insertion feedback; it never moves filesystem items. Category disclosures use AppKit’s native controls.

Local **New Folder** uses the ordinary recoverable creation owner immediately,
then selects the new folder and offers its existing inline filename editor.
**New Folder…** retains the explicit name dialog. `BrowserInlineRename` keeps
the creation handoff tied to its original tab, listing and user focus; navigating
or starting another interaction retires the offer without undoing the folder
creation. `LocalStorage.LocalAvailableName` supplies the bounded, metadata-only
available-name hint shared with archive outputs. The final operation still
creates exclusively and decides whether a name is occupied.

**Open Folder…** offers remembered access by default through the ordinary macOS
folder chooser, with a visible opt-out. It reuses `FolderAccessController` and
the existing bookmark store; it does not grant access from a path or start a
scan. Remembered access can support a later Undo without another chooser when
macOS still accepts that saved grant. A failed or stale grant remains explicit.

Ordinary local **Move to Trash** starts directly through the existing observed
operation owner. Operations settings can restore its confirmation; menu
ellipses follow that choice. The gesture captures the preference and any
explicit controlled prompt before preparation. Analyzer item reviews,
recovery-copy cleanup, archive removal and remote permanent Delete retain their
own confirmations. This preference does not change the native Trash contract,
silently retry a failure or substitute permanent deletion.

Saved server rows use the same order owner as Places, known drives and remembered
folders. Only protocol kind and saved UUID are persisted; names, addresses,
credentials and connection authority remain with their existing owners. A unique
saved row keeps its position while connected or disconnected and after property
edits. Duplicate live sessions keep separate temporary identities. Mixed sections
persist the saved subsequence and keep temporary slots in memory.

Layouts without saved server ordering keep canonical version1 bytes. Reordering
saved servers opts that private layout into version2. Older apps preserve/refuse
that newer layout instead of overwriting it; other app data is unchanged. Reset
Sidebar Layout in the newer app clears those positions and returns to version1.

Explorer's existing Control-alias preference includes Control-click selection and
Control-drag Copy. `BrowserPointerSelection` supplies the view-scoped alias check;
the table/collection native drag source avoids AppKit filtering that exact alias
into a Link, and `BrowserDragDrop` negotiates Copy against the captured source
mask through the normal queue. Other modifier behavior is retained. Control-Shift
Link and contradictory combinations stay unsupported; an external Move is never
silently converted into Copy. This does not install global shortcuts or rewrite
physical input. Behavior references: [Windows copy drag](https://support.microsoft.com/en-au/accessibility/windows/keyboard-shortcuts-in-windows)
and [AppKit modifier filtering](https://developer.apple.com/documentation/appkit/nsdragginginfo/draggingsourceoperationmask).

`BrowserPaneTransfers` routes Copy to the existing local engine or the remote
Download callback. Local selections can target eligible SFTP panes through
`BrowserSFTPPaneUpload` and the same group/drop owner. Source access belongs to
the captured source browser; tab, visit, selected rows and freshly observed kinds
are rechecked before admission. Mixed destination choices use one native menu;
Cancel is inert. Cross-server Move remains unavailable. Same-session SFTP and
same-share SMB Move use their existing selected-action owners and one shared
destination chooser; they do not emulate Move through Copy and Delete.

`LocalPaneUploadSelection` is the existing captured local row group shared by
concrete SFTP and SMB destinations. `BrowserSMBUpload` owns its picker, optional
Cautious review, progress/Stop and native input adapters. The LocalStorage
planner/session remain the mutation authority. File-group and folder availability
are separate from the previously accepted single-file lane until their actual
transport acceptance; a successful menu callback is not a macOS source grant.

`VolumeBrowserView` gives This Mac one scrolling document. Drives and
`ConnectedServersView` share `BrowserLocationFlowLayout` and the native
`BrowserLocationTileBackground`; `ServerLocationTile` adds connection status and
bounded activity presentation. `BrowserConnectedLocations` routes server clicks
and context actions to the existing application connection owner. Merely showing
or refreshing saved locations reads no password and starts no connection.

`BrowserRemoteBatchDownload`, `RemoteBatchDownloadSource` and
`RemoteDownloadBatchResults` share destination selection, progress, local
publication and exact per-file Undo while retaining concrete SMB/SFTP session
and receipt types. Per-protocol transfer authority stays in LocalStorage.

`BrowserSFTPFileActions` and the existing remote menu adapter supply concrete
New Folder, file/folder Rename and explicit permanent file/empty-folder Delete. They reuse the
same interaction owner, canonical App Logs and Connection Storage rather than
adding a remote file-operation framework. Local file-URL Paste reuses the mixed
drop-upload owner. `BrowserScopedClipboard` shares the captured source observation,
opaque private clipboard token and native responders for remote Cut/Copy/Paste;
the concrete Move/Copy owners recheck the original after navigation. Copy keeps
the source and clipboard, while confirmed Move consumes only its own generation.
SFTP Copy remains independently gated. `disconnectCurrentConnection` dispatches the
shared Go command using the current tab's concrete protocol.

`FilePresentation.FileColumnSizing` is the one responsive column owner for
local, SFTP, SMB and archive tables. Name keeps its readable scaled floor;
default metadata widths yield first. Explicit native header widths remain
logical points for that table's lifetime, with horizontal scrolling rather than
silently shrinking a user choice. Allocation is layout, never a persisted
preference change. Keep native header tracking and column visibility in this
shared owner instead of adding per-protocol resize rules.

These are folders within the same App module, not additional packages. Consult App/README.md and docs/engineering/README.md from the repository root.
