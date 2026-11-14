# Connections

SMB and SFTP retain concrete sessions and operation policies. Shared presentation
does not create a universal provider or grant capability. Browsing is metadata-only;
file bodies are read only for an explicit admitted operation. Product admission,
server permissions, authentication and fresh item observations are independent.

| Source | Responsibility |
| --- | --- |
| `SMBConnectWindow.swift` | Shared Connect form and saved-server presentation |
| `SFTPConnectSavedChoices.swift`, `SFTPProfileImportModel.swift`, `SFTPSetupTrust.swift` | Explicit key/certificate selection, suggestions and host verification |
| `SMBTabController.swift`, `SFTPTabController.swift` | Connected-tab/session lifetime, rows and selection |
| `../../Shared/Presentation/RemoteFileTableView.swift` | Native table input, columns, selection, menus and clipboard routing |
| `ConnectionProperties.swift`, `RemoteItemProperties.swift` | Saved/live settings and observed metadata |
| `RemoteMoveDestination.swift`, `RemoteMoveDestinationModel.swift` | Destination review and presentation-only validation |
| `SMBFileActionHistoryView.swift` | Recorded action outcomes, including both parents for Move |
| `../../Browser/BrowserSMBFileActions.swift`, `BrowserSFTPFileActions.swift` | Command admission and domain/session orchestration |

## Authentication and session lifetime

Saved endpoints and paths grant no credentials, keys or access. Explicit private
key selection can pair an OpenSSH user certificate. Reconnect rereads the selected
certificate through its retained access reference after host verification; it
does not execute a company sign-in command or inspect an SSH agent implicitly.
Credentials and certificate/file bodies must not enter diagnostics.

Session owners retain cancellation, metadata requests and transfer workers until
actual drain. A disconnected, busy, denied or uncertain result remains distinct.
View/Properties/Find must not manufacture an operation receipt or silently retry
an uncertain publication. Shared status projections are display-only.

## File actions and transfer

Rename/Move/Copy/Duplicate operate on captured observations, revalidate at mutation
time and preserve existing occupants. Same-share SMB Move uses its checked
same-session transaction; it has no Copy/Delete fallback. SFTP pathname/race
limitations remain explicit. A displayed path or clipboard token is not proof
that an earlier Copy succeeded. Remote Undo requires its own supported contract.

Uploads use a shared bounded serial planner with concrete SMB/SFTP execution.
The selection limit is 64 roots within aggregate, member, node and history bounds.
A folder verifies all children before publishing its top-level name. Each root
keeps a durable outcome; a stopped group reports the verified prefix, current
root and unsubmitted remainder. Cut/Move is not an upload shortcut.

Downloads keep single-file, group, folder and external-promise admission separate
in `RemoteDownloadPublicationFeature`. Content, identity, required metadata,
documented macOS protection properties and guarded Undo remain checked. Raw
private xattr equality does not imply identical provenance or Gatekeeper outcomes.
Upload or private-editor receipts cannot authorize public Download. A durable
publication intent becomes **Publication needs review** after the worker drains;
it is not an active transfer and offers no generic Discard shortcut.

Pane and native drop adapters bind the exact source sequence, selection, session
and destination. They never decode a marker or path into authority. Native file
promises retain coordinated callback lifetime and destination access separately.
External promises and installed sandbox behavior require their own validation.

## Navigation, clipboard and metadata

Remote clipboard source observation temporarily borrows the same authenticated
session. The action owner calls `restoreAfterClipboardSourceObservation()` in
its finally path after operation ownership settles; restoration rereads the
user's current location rather than an earlier navigation target. Its budget
is 15 seconds and 64 bounded metadata pages. Text-field focus keeps ordinary
responder-chain editing rather than dispatching remote file commands.

Current-folder Find uses `RemoteDirectoryFind`, original catalog revision and
observation IDs. Queries remain in memory and never become logs, a new wire
command, recursive search or a credential grant. Tab owners coalesce the latest
intent without cancelling an unrelated session; deadline refusal does not itself
disconnect an authenticated connection. Selected-folder Properties returns dated
logical observations with explicit partial/limit states, not reclaimable space.
The concrete traversal deadline and drain policy remain protocol-specific.

Private text View has its own default-off `textReads` capability and 1 MiB bound.
It cannot authorize Save or publish Download. Original-file editing instead uses
the existing retained document/journal path; listing-storage release must not
remove editor bodies or recovery journals.

Use the existing worker/domain suites and native connection flows, choosing the
one matching the changed route. `connection-metadata` covers Find and viewport;
`remote-properties` has no body-transfer backend. Generated listener, real server,
sandbox grants and installed helper identity need separate explicit checks.
See the [worker guides](../../../../tools/README.md),
[file-operation contracts](../../../../docs/FILE_OPERATIONS.md) and
[engineering guide](../../../../docs/engineering/README.md).
