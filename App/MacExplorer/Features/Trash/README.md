# Traverse-owned Trash

Traverse uses macOS `FileManager.trashItem`. This feature adds a catalog and
management window for moves recorded by Traverse. It does not enumerate all
Finder deletions or create a second physical bin.

| Source | Responsibility |
| --- | --- |
| `BrowserOwnedTrash.swift` | Browser-owned window, passive inspection, stale-result rejection and coordinator-backed actions |
| `OwnedTrashWindow.swift` | Native chrome, sizing, motion, columns and group selection |
| `OwnedTrashPresentation.swift` | Display values without filesystem authority |
| `OwnedTrashDeletionReview.swift` | Explicit whole-group irreversible-action review |
| `OwnedTrashFeature.swift` | Application edition and operation admission |
| `Packages/ExplorerKit/Sources/FileOperations/OwnedTrashManagement.swift` | UI-free catalog projection, exact-operation Restore and guarded permanent Delete |

Opening the tool reads recorded metadata. Each action revalidates the current
object through the existing operation engine. Closing cancels inspection; an
admitted mutation retains its worker and access until actual completion.
Restore uses the operation's Undo contract and refuses occupied names. Permanent
Delete requires its own revision-bound, one-use plan and explicit confirmation;
it must never replace Move to Trash. Availability is determined by the product
policy, not by the presence of a backend implementation.

Partial or uncertain groups remain reviewable. New native records cannot lend
inverse authority to old uncertain history. Content, object identity, required
metadata and documented macOS protection properties remain checked. Retiring
editor or recovery copies is a separate operation; unrelated Finder Trash items
must remain untouched.

Reuse the engine tests and existing owned-Trash native flow for relevant
changes. See [file-operation contracts](../../../../docs/FILE_OPERATIONS.md) and
the [engineering guide](../../../../docs/engineering/README.md). A generated
fixture check does not establish installed sandbox or OS Trash behavior.
