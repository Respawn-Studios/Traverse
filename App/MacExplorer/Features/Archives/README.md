# Archives

Archive presentation stays in this App feature; format readers, creation,
extraction and journaled publication stay in ExplorerKit. Edition and operation
admission are controlled by `AppFeatureAvailability` and the concrete engine
policy. Source support does not establish signed or installed availability.

| Source | Responsibility |
| --- | --- |
| `ArchiveBrowser.swift`, `ArchiveRowsView.swift` | ZIP metadata browsing and native rows |
| `TARBrowserModel.swift`, `TARBrowserWindow.swift` | TAR presentation and retained catalog lifetime |
| `ArchiveExtractionWindow.swift` | Explicit destination review and extraction |
| `ArchiveCreationWindow.swift`, `ArchiveCreationModel` | Shared creation/edit review, progress, Stop and Results |
| `ArchiveWritePlan`, `ArchiveOriginalReferences` | Opaque update plan and original/recovery reference coordination |

## Browsing and previews

Address navigation resolves within the retained archive catalog. Dot segments
cannot escape its root. Failed lookup keeps the folder and typed input; changed
pane, tab, visit, edit or close cancels stale results. No member becomes a local
filesystem URL and address editing starts no extraction or implicit decoder.
Rows and filename-based symbols are metadata-only. Missing or invalid timestamps
remain undated; ZIP timestamps do not invent a time zone.

Text/Hex previews are bounded to 256 KiB. PNG, JPEG, GIF and TIFF previews read
at most 16 MiB, reject images over 32 megapixels and render at most 2,048 pixels
per side. ZIP verifies CRC; TAR has no per-file checksum. Readers retain the
sealed source selection, revalidate it and use the shared native preview window.
They do not invoke external preview plug-ins or publish extracted files.

Plain TAR opens directly. Compressed TAR requires an explicit preparation
request into the shared private pool, bounded to 128 MiB and four copies. Restoring a tab or searching
names does not decode it. `ApplicationCompressedArchives` retains actual worker,
source access and prepared-copy leases through drain and the volume/Quit barrier.
A prepared spool path is never operation authority. Nesting and outgoing TAR
promises require separate support.

In Development, a deliberate ordinary Open includes preparation for a supported
compressed TAR. The archive owner consumes a nonpersisted presentation token
after pool admission, or immediately for a reused unprepared model. Stop,
admission failure and a later presentation invalidate that token. It never lives
in BrowserTab, ArchiveLocation or session history. Merely finding a filename or
restoring a tab cannot admit preparation. A changed retained source on passive
return clears its stale rows and requires a fresh Open or Prepare; healthy
prepared sessions keep their ordinary source check and reuse. Distributed
composition still uses the separate Prepare action.

## TAR editing in development

Plain and prepared gzip/bzip2 TAR members use the common native editor and archive
workbench in Development builds. Rename, batch Rename, Remove, Duplicate, Move, Create File/New Folder,
Group and Add all use one `TARMemberMutation`, including Cut/Paste and local
file drops. The browser seals catalog selections; the table never writes files.
Batch Rename shares the local/ZIP naming controls and Before/After table. It
applies a captured set simultaneously, allows name swaps, keeps unchanged raw
records intact and refuses collisions or implicit folder-tree merges.
Add defaults to Keep Both. Explicit Replace Files replaces only exact regular-file
roots, with a captured preview and the local file's bytes, dates and permissions.
Folders, implicit trees and case variants refuse replacement; there is no merge.
The original archive remains available for exact guarded Undo.
Read-only and larger extraction selections keep their existing Copy route.
`TARTextEditDocument` binds complete UTF-8 bytes to the retained catalog;
`PreparedTARMemberMutation` streams a replacement without unpacking an editable tree.
Unchanged entries retain their original bytes, headers and local PAX records.
The edited member keeps ownership names, mode and unrelated PAX fields; its
header and any PAX size override are updated together. Links, special members,
unsupported root metadata and archives over 1 GiB refuse the write.

Compressed rewriting reuses the retained, unlinked read-only spool. The original
compressed file remains the source and history authority. One fresh decode
must match that spool's digest, length and catalog; the output gets a second
complete verification. Both raw TAR and compressed output stay within 128 MiB.
The gzip wrapper preserves MTIME, OS, FTEXT and opaque extra/name/comment
fields within a 64 KiB header, recalculates compression flags and header CRC,
and refuses malformed headers or concatenated streams rather than discard
their metadata. Fast/Balanced/Smallest choices apply to the complete output.
Bzip2 accepts `.tar.bz2` and `.tbz2`. It preserves an imported block-size
setting unless the user chooses another compression option. Its system codec
uses a charged heap ceiling of 8 MiB for encoding and 4 MiB for decoding;
gzip uses 1 MiB. These are codec allocations, not whole-process memory caps.
Cancellation is checked around codec calls; one bzip2 block can finish inside
a call before Stop is observed. Work stays on the existing bounded worker.

Save and Save TAR Copy use the existing guarded archive engine. TAR original
replacement has its own default-held policy and v18 history; gzip has v19 and bzip2 v20,
independent of ZIP v13. The earlier archive stays available for cold Undo; an interrupted
retained-original step has an explicit, revalidated Restore action. The writer
keeps the native stage's macOS protection and never copies a source mark over
it. This source support does not activate TAR editing in a distributed build.
Initializing protection on a new Update payload has a separate default-held
policy from Create. Only an empty owned private stage is eligible; existing
stage protection and source metadata are never replaced. A consumed plan drops
its entire spool ownership graph after the worker drains. Editor rebind finishes
before browser refresh, and an already prepared browser can refresh a successful
edit without another Prepare click.

## Creation and ZIP edits

Development also offers TAR + gzip and TAR + bzip2 with Fast, Balanced and
Smallest choices. Both stream the same TAR records through bounded system
codecs, then check a fresh decode, the emitted metadata and the completed file digest.
There is no second full TAR spool. Raw TAR and compressed output each stay
within 128 MiB. A separate default-held engine policy keeps this new authoring
route out of distributed builds until qualification. Native stage protection and the existing cold Undo are shared
with plain TAR creation.

Compress/Extract shortcuts share the full workbenches and guarded operations.
Automatic extraction uses a new sibling folder, never an implicit merge.
`LocalAvailableName` supplies hints, not a reservation or overwrite grant.

ZIP Rename, Remove, Add, Create File/New Folder and New Folder with Selection
share the same reviewed writer. Original Update journals staging/replacement;
Save ZIP Copy Instead publishes a fresh sibling without changing the original.
Unsupported metadata, unsafe names or formats refuse rather than losing data.
UI callbacks never replace an archive directly. Legacy journal versions retain
their original inverse semantics and cannot borrow authority from newer records.

A folder edit retains its full descendant set. Existing explicit/implied or
case-conflicting names, duplicate targets and dependencies are checked before
publication. Batch Rename captures 2–128 sibling roots and numbering order with
Before/After preview. Add/Copy chooses available numbered names without merging
folders or replacing occupants. Cut/Paste stays within the same live ZIP tab;
a changed catalog, stale clipboard or another archive cannot adopt it.

Added local inputs capture each distinct parent and revalidate identities and
entry snapshots. The bounded writer supports independent parents/devices but
refuses cross-device descent, links, cloud-only/private locations, resource forks
and unsupported security metadata. The combined ZIP limit is 1 GiB, 10,000 files,
20,000 catalog nodes and 511 added roots plus the source archive. Source and
output protection policy is separate from the writer's generic capability.

The producer verifies decoded bodies, headers, namespace, CRC and SHA-256 before
publication. Supported comments and known timestamp fields remain opaque/exact;
unknown extras, encryption, ZIP64 and special members refuse. Removal also
verifies omitted bodies. Metadata browsing never performs those explicit Save
reads. Changed originals refuse Save while preserving the draft/review.

## Transfers and validation

In-workspace Copy/Paste mints a checked archive selection at Paste and acquires
fresh destination access. One folder arrives by its own name; groups retain
archive paths under a new folder. ZIP/TAR catalogs, prepared gzip, direct
extraction and external file promises have distinct admissions. Native promises
use AppKit's coordinated callback lifetime without acquiring a second coordinator
for the same destination. Each job retains cancellation, access and exactly-once
completion through actual drain; a callback grants no folder access itself.

Reuse existing archive package tests and `tools/dev.py native-check` entries:
`create-zip`, `create-tar`, `create-targz`, `zip-add-copy`, `compressed-tar`,
`tar-editor`, `tar-gzip-editor`, and relevant editor or
batch-rename journeys. Independently inspect generated output and original
identity, conflict refusal, cancellation, interruption and guarded Undo.
Offscreen functional checks do not establish motion, physical input, external
receiver behavior or sandbox grants. See [file operations](../../../../docs/FILE_OPERATIONS.md)
and the [engineering guide](../../../../docs/engineering/README.md).

The two TAR editor journeys reuse the same ordinary Development engine. They
include a second app process for the final edit/Create Undos. The existing
`--marked-source-create` option also covers generated marked editor inputs;
it grants no installed-app or OS-container scope.
