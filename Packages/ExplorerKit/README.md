# ExplorerKit

The existing Swift package supplies reusable behavior independently of native UI.
`Package.swift` is the module/dependency authority; macOS 15 is the declared floor.

| Source module | Purpose |
| --- | --- |
| ExplorerCore | Item/location identity, navigation/workspace and shared values |
| LocalStorage | Local platform adapters, access, volumes, editor and transfer support |
| BoundedArchiveCodecs | Bounded system zlib/libbz2 streams, shared descriptor checks and charged codec memory; no path/publication authority |
| FileOperations | Preflight, execution, durable history, recovery and Undo |
| Search | Filename/metadata queries and cancellation |
| StorageAnalysis | Scanner protocol, stored results, classification and queries |
| FileMemory | Private names, native references, continuity and durable Forget |
| DirectUpdates | Direct-distribution update policy |
| SSHConfiguration | Explicit SSH configuration parsing and import contracts |
| DriveHealthNative | Canonical native health acquisition and bounded wire codec shared by the existing worker and service |
| DriveHealthWorker | Inherited read-only health-worker entry point |
| DriveHealthXPCService | Direct-distribution service entry point; its separate role/signature policy lives in app composition and distribution |
| RetainedColdProbe | Existing bounded subprocess helper for retained-state tests; not another app or operation engine |

Matching suites live in `Tests/`; `NameStoreFaultSupport` supports existing storage
fault tests. New regression tests should live with the affected module and reuse
its fixtures. Do not create another copied package to test normal changes.

Local archive production lives in `LocalStorage/ZIPCreation*`, `ZIPMember*` and
`TARCreation.swift`. ZIP and the portable TAR writer share a
checked input inventory and the existing `FileOperations` staged creation/Undo
protocol. TAR has its own explicit format/policy admission; ZIP qualification
does not authorize it. Reading and explicit extraction remain in the ZIP/TAR
reader and extraction files, with separate received-data protection policies.
Current Preview/private-beta authoring uses the separately qualified native
contracts. Plain and prepared gzip/bzip2 TAR member changes have Development-only source
support. `TARMemberMutation` seals the requested change, `TARMutationLayout`
checks its namespace and limits, and `TARMemberMutationWriter` streams it without
unpacking an editable tree. `TARMemberHeader` preserves unrelated metadata,
including local PAX fields. Text edits use this same writer. Compressed creation
and rewriting use the shared bounded system codecs and a fresh complete decode
check. Original updates have separately admitted v18 (TAR), v19 (gzip) and v20
(bzip2) records; ZIP v13 cannot authorize their Undo. Each format remains held in
distributed composition until its own qualification.
The [roadmap](../../docs/ROADMAP.md) distinguishes shipped behavior, qualified
work and future plans. Edition admission remains in application composition.

`FileOperationTestFixtures` supplies the ordinary generated root for recovery,
native-metadata and copy-security checks. Normal suite runs create disposable
fixtures beneath the checkout without extra environment configuration.

From the repository root, use `python3 tools/dev.py test --filter <SuiteName>`.
The wrapper keeps build/cache/test state under the checkout. Broader suite runs
belong at integration/release or when a changed dependency warrants them.
`--configuration release` uses the stable optimized cache. Retained-analysis
fault/pause/snapshot tests require Debug-only helpers and are compiled only in
Debug; ordinary hook-free cases remain available in both configurations. Do not
add those injection controls to production merely to compile a Release test.
Native-helper, device and isolated crash cases keep their explicit runtime
requirements; a filtered test run does not exercise them automatically.
Keep UI imports out of these modules; keep content processing and access policies
explicit. Root README and the engineering guide own the current workflow.

Shared SMB/SFTP working-space lifetime stays in LocalStorage. Explicit Connect
can prepare its versioned shared graph and retire only proven inactive clean
Original metadata. Retained editor bodies and journals have separate ownership;
releasing listing storage must not remove them. Format3 permits64 small bodies
within the existing30 MiB budget, with at most eight distinct references per
editor record and eight active spools. Older formats retain their old bounds and
older writers refuse format3. Passive startup never performs that migration.

`RemoteDirectoryFind` is a bounded current-folder metadata projection over the
existing SFTP/SMB catalogs. Typed results bind an opaque query to the original
read revision; filtered pages retain original observation IDs for actions. Query
text stays in memory, never diagnostics or the catalog. A query deadline is a
request refusal, not a reason to disconnect an authenticated session.
