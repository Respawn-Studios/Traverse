# Storage analysis

This UI-free module owns scanner consumers, bounded recorded results and pure
accounting. App presentation lives in `App/MacExplorer/Features/StorageAnalysis`;
Rust traversal lives in `Workers/StorageScanner`. Those owners have different
lifetimes and must not be replaced with a second scanner or index in a view.

| Source | Responsibility |
| --- | --- |
| `ScannerWorkerProcess.swift`, `ScannerProtocol.swift`, `ScannerSession.swift` | Worker lifetime, bounded wire decoding and automatic summaries |
| `PagedScannerSession.swift`, `StorageAnalysisResult.swift`, `AnalysisResultStore.swift` | Explicit scan, sealed catalog readers and temporary-storage ownership |
| `RecordedAnalysisOwner.swift`, `RetainedAnalysisController.swift` | App-facing recorded-result lifecycle, publication and revocation coordination |
| `RetainedAnalysisRecord.swift`, `RetainedAnalysisIndex.swift` | Versioned metadata observations, epochs and durable Forget state |
| `RetainedNativeBackend.swift`, `RetainedNativeIndexStore.swift` | Concrete catalog preservation, cold access, recovery and exact cleanup |
| `Stored*.swift` | Bounded read-only classification, accounting, location and page projections |
| `StorageAnalysisPolicy.swift`, `Startup*.swift` | Privacy policy, startup-root facts and explicit access boundaries |
| `AnalysisModels.swift`, `StorageAnalysisAccumulator.swift` | Pure accounting/reference values described below |

Prepare fallible scan inputs before launching the worker. The shared
`ScannerWorkerProcess` loop drains both pipes and reaps the owned child even
after decoding fails. The caller still owns admission, access and what counts
as valid output. Raw topology inquiries and framed scanner results have
separate byte limits and validation rules.

The ordinary app can retain at most two explicit analyses in the existing bounded
pool and reopen their dated metadata across sessions. It does not silently scan
on cold display, claim that a saved result is current, or use recorded paths as
access grants. Scan Again performs a full metadata traversal. The explicit
Update changed folders uses a bounded per-device event checkpoint and
the same scanner/publication owner to replace an immutable generation, with full
scan fallback and dated reuse provenance. Dirty direct listings and recursive
subtrees
remain distinct: reconciling a parent can retain unchanged child listings after
identity checks, while recursive root or uncertain history still scans fully.
Retained diagnostics separately count replayed rows and borrowed directories;
borrowing an empty directory avoids enumeration without replaying a child row.
Continuous background reconciliation is not
introduced. Hovers have a separate short-lived
in-memory cache and never preserve a catalog here.

## Pure accounting core

`AnalysisModels.swift` and `StorageAnalysisAccumulator.swift` are pure value-model
code. They perform no filesystem access, body processing, scheduling, persistence,
logging or cleanup. Scanner protocol/session adapters have separate ownership and
qualification; the accumulator does not grant a root or prove a backend's scope.

## Input and accounting

Create `StorageAnalysisAccumulator(rootIdentity:limits:)`, feed already-scoped
`AnalysisEntryObservation` values in parent-first order, inspect cheap `progress`,
and request `snapshot()` or `finish(_:)`. Root is implicit. A directory appears
before its children; an orphan, non-directory parent, duplicate path or changed
identity is rejected without a second charge and makes coverage partial. Repeated
directory identities retain the observed edge but cannot accept alias descendants.
Symlinks are namespace edges only and cannot become directory parents.

Raw relative bytes are checked in the accumulator, before retention: no absolute,
empty, dot/dotdot, NUL, over-depth or over-length path. Admitted paths are copied
into bounded owned storage so a small input `Data` slice cannot retain a much
larger caller buffer. No lossy Unicode conversion is used for identity or lookup.

Only regular-file byte observations contribute to recursive accounting. Four
families remain distinct: data-fork logical, all-fork logical, data-fork allocated,
and all-fork allocated. Nonreturned file attributes on ordinary directories,
symlinks or other entries are not regular-file missing values. A directory's
directly reported own bytes are retained separately and never counted as its
recursive contents.

Folder summaries count descendant namespace edges, excluding that folder's own
edge. Direct parent counters update once per observation; one reverse postorder
pass produces rollups. Global regular-object subtotals deduplicate `(device,inode)`
separately. Cross-folder hardlinks therefore make folder allocations overlap;
clones remain distinct objects with unknown shared extents. No subtotal is
exclusive physical usage or predicted reclaimable space.

Same-object metadata changes make the model partial and retain the first object
observation. Namespace entry subtotals still describe the individual observations.
`potentialOutsideLinkObjects` compares the first observed link count to observed
edges; unknown link counts and missing object identities have separate counts.
Neither observation locates unseen links or proves what deleting a name releases.

## Partial results and bounds

Every field has `returned`, `notReturned` or `failed(code:)` state. A metric output
is a *known subtotal* with missing/failed counts. Overflow sets `knownBytes` to nil
and `overflowed` to true; it never wraps, saturates or erases the other metrics.
An empty known subtotal of zero does not mean missing objects/fields contain zero
bytes. Inspect snapshot completeness and identity/field omission counts together.

Fixed-code `recordCoverageGap(_:in:)` supports enumeration/disconnection,
boundary, changing and truncated observations without path-bearing diagnostics.
The first 100 issue details are retained by default, with an exact bounded total.
Since there are no independent directory-completion events, all folder rows remain
conservatively partial if overall input coverage is partial.

Defaults admit at most 220000 input events, 64 MiB of retained raw path payload,
8192 bytes per path, depth64 and100 detailed issues. Coverage-gap events share the
input-event allowance. Directory count is bounded by entry admission, with one
extra implicit root; there is no new4096-total-directory ceiling. A resource limit
closes admission explicitly. All indexes, objects and folder arrays are bounded
by admitted records, but these are **not RSS guarantees**: dictionary overhead,
retained aggregates and a full hierarchy snapshot require actual memory
qualification before an app integration or maximum-scale claim. A caller must
also bound how many snapshots it retains.

`finish(.completed/.cancelled/.failed/.resourceLimited)` seals only this input
model. Late records and later completion attempts cannot replace terminal state.
It does not mean a scanner/native call/worker has drained, release an access lease,
route session generations, or authorize a drive action. Those guarantees belong
to the qualified session/engine adapter.

## Filename types and coverage explanations

`AnalysisFileTypes.swift` classifies accepted regular-file namespace edges using
the last raw filename extension. Its thirteen fixed slices retain all four metric
families and missing/error/overflow support; no file bodies or extra filesystem
reads are involved. File Types, layout-based Storage Roles and marker-based
Projects are distinct views. Labels are hints, not deletion authority, and the
same hardlink/clone caveats apply to every partition.

`ScannerCoverage.swift` retains fixed reason counters, the sampled-detail count
and the worker's exact notice total. Boundaries, policy, access denial, changes,
deferred materialization and each traversal limit stay distinguishable. A queue
limit with inherited errno is not labelled as another permission failure. Counts
describe notices, not unique missing items or estimated unobserved bytes.

Experimental DFS and temporary SQLite tools do not replace the bundled worker
or the accumulator through this change.

## Focused verification

Explicit paged analysis also carries an immutable `AnalysisMetadataPolicy`.
Standard is the ordinary default and automatic summaries keep their original
policy. Application-data controls remain subject to the concrete source policy.
Scan headers and every read
child must match recorded provenance. Next-request choices never rewrite an
existing result; native pages retain its scope label. Personal access
remains separately opted-in; no grant, indexing or cleanup is
implied by a policy selection.

Use the existing package suite:

```sh
python3 tools/dev.py test --filter StorageAnalysis
```

Pure tests use generated in-memory observations, independently summed prefix
oracles, all four byte families, cross-folder links, sparse/forked/clone examples,
missing/error/zero fields, overflow, path escape, orphan/truncated trees,
duplicates/identity changes, resource bounds, more than4096 folders and late
delivery after cancellation. They are not filesystem, protocol, worker-drain,
actual-memory or UI acceptance tests.
