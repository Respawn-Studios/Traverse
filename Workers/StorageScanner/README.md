# Storage scanner worker

The bundled Rust/C worker performs read-only metadata traversal for the Swift
StorageAnalysis module. It has no Cargo registry dependencies and does not read
file bodies or index content. `tools/build_storage_worker.py` builds the worker
for the ordinary app; its `RESULT_CONFIG` is the enabled-configuration authority.
Use `python3 -B tools/dev.py build` from the repository root.

| Source | Responsibility |
| --- | --- |
| `main.rs`, `traversal.rs`, `ScannerNative.c` | Process protocol, bounded traversal and native bulk metadata |
| `policy.rs`, `startup.rs`, `StartupPhysical.c` | Metadata exclusions and separately checked System/Data coverage |
| `catalog.rs`, `result.rs`, `result.sql` | SQLite writer, identity accounting and versioned results |
| `result_nodes.rs`, `result_reference.rs`, `result_checkpoint.rs` | Bounded regular-file buffer, first-observation references and adaptive commits |
| `result_*.rs`, `layout_hints.rs` | Sealed paging, accounting and classification queries |
| `profiling.rs` | Bounded diagnostics |
| `metadata_prefetch.rs` | Inactive experiment, outside ordinary traversal |

## Result and lifetime contracts

The explicit result route uses classification V4 and a 128-component depth
bound. Automatic summaries have a separate 64-component contract. The initial
committed prefix follows 4,096 observations; later commits bound the pending
tail at 16,384, with a 250 ms check after at least 4,096. Seventeen file-type
groups partition the same observed metrics. Classification uses finite role
accumulators and flushes touched values before the 256-directory projection
commit. SQLite uses FULL synchronization and DELETE journals.

Do not silently apply current result semantics to older wire schemas. The
versioned source codecs, SQL schema and Swift decoders must change together.
Regular-file payload buffering, wire-frame limits and disk/resource ceilings
are enforced by their concrete protocol/configuration. Cancellation is complete
only after the actual worker and native work drain; dropping a Swift task is
not evidence of drain. Stderr diagnostics use fixed codes without filenames.

Traversal uses raw path identity, descriptor-relative no-follow opens,
source-relative revalidation and root identity checks. Directory namespace edges
and distinct regular objects have different accounting. Sparse allocation,
resource forks, hard links, unavailable fields and partial traversal must remain
explicit. Neither logical totals nor allocated totals predict exclusively
reclaimable space. See the [pure accounting module](../../Packages/ExplorerKit/Sources/StorageAnalysis/README.md).

## Retained refresh

The App and Swift retained-analysis owners manage saved catalogs and event
checkpoints. Cold reopening displays dated observations and starts no scan.
Scan Again traverses fully. Changed-folder refresh writes a new immutable result
using a sealed baseline and bounded event dirtiness; unsupported roots or
uncertain history require full-scan fallback. Continuous background reconciliation
is not implied.

The private `TRVREF2` request on inherited descriptor 8 distinguishes direct-entry
reconciliation from recursive subtree dirtiness. Direct reconciliation can borrow
clean child listings only after freshly observed device/inode identities match
the baseline. Directory namespace events and MustScanSubDirs remain recursive,
including FullHistory overlap. `refresh_reused_entries` counts literal replayed
rows; `refresh_reused_directories` counts borrowed listings, including empty ones.
Neither counter claims fresh enumeration or a whole-drive speedup.

## Access and metadata policy

Metadata policy does not grant filesystem access. Automatic summaries exclude
credential locations, Trash, cloud/provider roots and photo-library shapes under
the concrete `AutomaticMetadataPolicy`. Exclusion matching also accounts for
System/Data path aliases. A denied or excluded root must not be represented as
an empty successful traversal. Startup physical accounting has its own checked
volume/topology boundary and cannot grant device access.

Explicit scans carry an immutable `AnalysisMetadataPolicy`; result headers and
children must match its provenance. A later policy choice does not rewrite a
saved result. Application-data choices, user access grants and product capability
admission are independent. Do not broaden exclusions or required attributes as
an undocumented performance optimization.

## Validation

Reuse `python3 -B tools/dev.py test --filter StorageAnalysis` for domain/protocol
changes and the existing `native-check analysis-persistence` flow for scan,
retain, cold reopen, refresh, Forget and repair integration. Generated checks
establish only their exercised route; they do not establish personal-folder
access, device compatibility or installed sandbox behavior. Build artifacts,
fixtures and failed-run evidence stay under ignored repository-local storage.
