# File operations and recovery

`RecoverableFileOperations` is the ordinary local-operation boundary. The app
observes selections, prepares immutable plans, obtains required choices and
executes through app-scoped owners. Native views do not mutate files directly.
Provider-specific connections keep their own concrete operation owners rather
than pretending all filesystems have the same capabilities.

## Integrity contract

A prepared plan binds the selected objects, source parents, destination and
conflict observations. Revalidate those observations at mutation boundaries.
Reject stale work after navigation, cancellation, replacement or a changed
connection. Keep source data until destination validation and commit succeed.

| Operation | Required behavior |
| --- | --- |
| Same-volume Move/Rename | Use an anchored exclusive rename where applicable; preserve the actual object and refuse an unexpected destination |
| Copy | Stage privately, validate exact content and supported metadata, synchronize, then publish without an unapproved replacement |
| Cross-volume Move | Validate and publish the destination before retiring the source into its guarded original-volume recovery area |
| Replace | Retain the observed destination before publishing its replacement; bind Undo to the actual retained objects |
| Keep Both | Choose and revalidate an unused sibling name without changing the existing item |
| Merge | Preserve unrelated children; resolve nested conflicts explicitly; retire source containers only after their admitted children settle |
| New File/Folder | Publish exclusively; an occupied or changed name is not permission to replace it |
| Trash | Use the native API and its returned location; never substitute permanent deletion or scan Trash to guess an outcome |
| Undo/Restore | Validate the record, protocol and current objects before applying the inverse; changed or ambiguous state requires review |

Stop and conflict cancellation preserve completed work and originals. A
continuation comes from an engine-owned token, not from a displayed path or a
count of unfinished rows. Successful publication and a successful retained Undo
are different outcomes.

## Metadata and protection

Content, link topology, object/parent identity and supported ordinary metadata
have explicit verification rules. Strict preservation and native owner/group
copying are separate choices; neither silently changes ACL policy or downgrades
a failed validation. Same-volume rename retains the original object.

When App Logs are enabled, copy verification can identify three failure
boundaries without recording paths, attribute names, values or fingerprints:

| Diagnostic symbol | Check that failed |
| --- | --- |
| `copy.metadataComparison` | Ordinary metadata comparison |
| `copy.receiptCoverage` | Complete source, destination and native receipt coverage |
| `copy.nativeReceipt` | Native receipt identity, security and ownership observations |

These labels explain where verification stopped, not which individual attribute
changed or which filesystem caused it. Other refusal points keep their generic
error. Logging does not change the validation result or authorize a retry.

Authored archives and received-file routes use their concrete documented macOS
protection contracts. Do not infer security meaning from undocumented raw
quarantine bytes, promise identical Gatekeeper decisions, or strip protection
attributes to make a test pass. A newly authored file and a received executable
are different cases. Existing records keep their original versioned semantics.

## Journal and lifetime

The system SQLite-backed journal stores jobs, ordered steps, recovery locations,
intent and confirmed outcomes. Intent precedes a mutation; durable confirmation
follows the required file/directory synchronization and readback. A database
transaction cannot atomically commit an arbitrary filesystem operation.

Only the active writer owns mutation bookkeeping. Lost acknowledgement or changed
store identity invalidates warm authority. Cold records, legacy imports and
incomplete stores require their existing validation; never fall back to an old
successful snapshot to overwrite a newer uncertain one.

Recovery inspection is observational. Startup does not automatically resume,
overwrite, retire a source or roll back uncertain work. Known retained locations
and uncertain locations have different meanings. Permanent deletion and removal
of retained recovery data require their own explicit supported flow.

Access preparation is separate from execution. An Undo command may first acquire
folder authority; completion checks must wait for both preparation and the actual
worker. Keep leases alive through the operation, reject stale chooser responses,
and release them on cancellation, closure and completion.

## Remote and archive operations

Remote account permissions remain authoritative. A denied request should settle
with a useful error and preserve a healthy connection where the protocol permits.
Do not silently elevate privileges, promise remote Trash, or offer a replacement
operation as though it were a new-file upload. Staged uploads, same-session Move,
server Copy extensions and in-place text Save have different concrete contracts.

Archive browsing is bounded and rejects unsafe paths and unsupported structures.
Writing, extraction and file promises reuse their qualified producer and local
publication owners. Preserve the original archive, validate the resulting
structure and contents, and keep guarded Undo. A supported reader does not imply
all mutation formats or every external drag route are available.

## Validation

Use the existing package tests for changed behavior and relevant failure or
interruption cases, then exercise a representative complete app flow. Native
receiver callbacks, real access grants and signed/installed behavior need their
own actual execution; an injected callback cannot establish those outcomes.
See [Contributing](../CONTRIBUTING.md) and the
[engineering guide](engineering/README.md).
