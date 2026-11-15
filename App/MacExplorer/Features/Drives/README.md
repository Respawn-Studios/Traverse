# Drives

`DriveManagement.swift` owns one Drives window, topology selection and reader
lifetime. `DriveWorkspaceView.swift` and `DriveWorkspacePage.swift` compose
Overview, Volumes & Protection, Drive Health, Benchmark and Storage Analysis.
Device selection is independent of disclosure. Selecting or refreshing topology
starts neither a benchmark nor a storage scan.

`DriveControls.swift` and `DriveProtectionStore.swift` retain application-level
protection. Platform discovery and actions belong to LocalStorage and the
application volume coordinator. Product capability policy controls admission;
a visible page or selected device grants no mutation or hardware access.

## Volume creation

`APFSVolumeCreationView.swift` presents an explicit Add Volume review and a Disk
Utility handoff where in-app creation is unavailable. The handoff does not
select a device or submit a Disk Utility operation.

`LocalStorage.APFSVolumeCreation` seals one ordinary external/image APFS
container, validates the name and observed shared space, revalidates the selected
attachment and existing members, and reconciles the exact result. Sandboxed
parents refuse in-app creation at the backend; the common product policy holds
that operation. There is no erase, partition or privilege-helper fallback.
A checked unchanged layout and an uncertain layout are different outcomes.

The unwired `LocalStorage.APFSVolumeFormat` candidate is restricted to one
ordinary APFS member on a generated disk image. Its optional recording hook
persists an intent after fresh APFS preflight and before native submission,
records a launched child without blocking pipe draining, and keeps failed
postlaunch writes uncertain. A compatible APFS replacement stays a provisional,
unresolved durable job until an independent marker/attachment witness is
qualified. `NativeDriveJobStore` uses the existing private
snapshot writer for one generated-image job; an intent surviving a restart is
shown as potentially submitted when Drives is opened. Cold inspection is
read-only and requires the exact generated backing file plus an independent
attachment verifier; a compatible replacement does not clear an unresolved
job without generated marker evidence.
Ordinary Format UI, personal images and physical drives remain held.

## File benchmark

`DriveBenchmark.swift` uses `LocalStorage.DriveFileBenchmark` for an explicit
folder-based workload. The core seals the chosen directory, uses one private
scratch namespace, verifies generated data and reports cache/flush settings and
guarded cleanup. Compact 16 MiB, Quick 64 MiB, Standard 256 MiB and Extended 1 GiB workloads have
a cooperative 180-second ceiling. Stop, close and Quit retain the actual worker
and access until blocking calls return and cleanup settles.

The application admits one exclusive workload and respects physical-group
protection and uncertain identity. Sequential 256 KiB, 1 MiB (default) and 4 MiB
blocks, plus fixed random 4 KiB QD1, share the same guarded file. Random
preparation writes an extra file size outside measured phases. Normal system
caching or a per-file `F_NOCACHE` attempt is explicit; neither clears global
caches nor promises a cold device. Results retain the requested cache mode,
actual bypass/flush outcome, phase rates, IOPS, block latency and bounded curves.
They are file-workload observations, not a hardware-health score or calibrated
raw-device benchmark.

Measurement details also show a fixed nine-range I/O latency histogram for the
already measured write and read block calls. The ranges double from under
0.125 ms to 16 ms or more; counts sum to completed calls. An incomplete run or
invalid timing shows an unavailable state instead of a distribution. The
histogram does not add I/O and is not included in the copied report's v2 JSON.

Quick Mix is one explicit click after folder selection. It runs a fixed 64 MiB
sequential 1 MiB workload, waits for that run's guarded cleanup, then runs a
16 MiB random 4 KiB QD1 workload with the same requested cache setting. Random
preparation writes another 16 MiB outside its measured phases. One operation
owner and access lease span both stages. Stop or close cancellation prevents
the second stage from starting, while Quit waits for the active owner to drain;
a failed or unclean first stage also stops the suite. Selected-drive identity
and protection are checked again before the random stage. Each attempted stage
remains an individual measured history entry, and
the suite view reports only per-stage rates. No aggregate speed is inferred.

At most eight individual results remain in session memory. Copy Results produces
individual or paired text/versioned JSON without volume names, filesystem
identifiers or recovery paths. A paired result with no second stage states that
the random run was not started.
Partial/failed runs keep byte/time facts without aggregate speed claims.
`DriveBenchmarkComparison.swift` admits only completed, matching filesystem,
workload, block/test/preparation-size, requested cache mode and actual cache/flush
outcomes, including when the runs belong to different Quick Mix suites. Its paired view
starts no read or benchmark and adds no persistent result store.
Two complete Quick Mix suites can also be compared as a pair when both named
stages independently pass those exact-match rules. Sequential rates stay MB/s,
random 4 KiB rates stay IOPS, and the four phase changes are shown separately.
An incomplete suite, stale history partner or mismatched cache/flush outcome
does not become a suite comparison. This is a session-only projection of the
same retained results; it starts no additional workload.

## Read-only health

`DriveDetails.swift` owns explicit checks through `DriveHealthSession` and the
selected helper/service transport. Native acquisition and the bounded wire codec
are shared with the independently configured direct-distribution XPC service.
Reader/signature, edition and device admission remain separate checks.

Live is opt-in and internal-only at both scheduler and request entry. A missing
opt-in stays Off despite an older saved Live value. The shared card and benchmark
use one reader: reads never overlap or queue catch-up. Visible intervals are
1, 2, 5, 10, 30 or 60 seconds; hidden, minimized, sleeping, closing and quiescent
windows admit no new reads. Denied, unsupported or uncertain outcomes pause
retry, and an earlier reading remains visibly dated. The trend retains at most
300 readings in memory. An uncertain-cleanup fence prevents premature reuse.

`NVMeHealthReadings.swift` presents documented temperature, spare, endurance and
ten exact 128-bit lifetime counters from the same 512-byte response. Invalid or
unreported values do not become healthy readings. No serial/Identify request,
reserved-tail parsing, SMART enable, self-test or raw-disk write is added.
Device/enclosure compatibility, sandbox access and installed helper behavior
require their own validation; an unsupported external attachment proves no
positive external SMART support.

Use existing package/native flows and the
[engineering guide](../../../../docs/engineering/README.md). Tests must retain
actual read/drain, stale-result and scratch-cleanup boundaries.
