import CryptoKit
import Darwin
import Foundation

/// The scanner creates this only after its actual child has exited and both
/// pipes reached EOF, while its held roots and access retention still exist.
struct RetainedScanCapture: Sendable {
    let result: StorageAnalysisResult
    let scope: RetainedAnalysisRecord.Scope
    let policy: AnalysisMetadataPolicy
    let coverage: RetainedAnalysisRecord.Coverage
    let complete: Bool
    let committedEntries: UInt64
    let observedFrom, observedThrough: RetainedAnalysisRecord.Time
    let helperSHA256: String

    private init(result: StorageAnalysisResult, scope: RetainedAnalysisRecord.Scope,
                 policy: AnalysisMetadataPolicy, coverage: RetainedAnalysisRecord.Coverage,
                 complete: Bool, committedEntries: UInt64,
                 observedFrom: RetainedAnalysisRecord.Time, observedThrough: RetainedAnalysisRecord.Time,
                 helperSHA256: String) {
        self.result = result; self.scope = scope; self.policy = policy; self.coverage = coverage
        self.complete = complete; self.committedEntries = committedEntries
        self.observedFrom = observedFrom; self.observedThrough = observedThrough
        self.helperSHA256 = helperSHA256
    }
    static func capture(result: StorageAnalysisResult, source: Int32, peer: Int32?, root: URL,
                        startup: StartupStoragePlan?, policy: AnalysisMetadataPolicy,
                        coverage: AnalysisScanCoverage, complete: Bool, committed: UInt64,
                        began: RetainedAnalysisRecord.Time,
                        helperBefore: RetainedHelperObservation, workerURL: URL) throws -> Self {
        guard result.classificationRevision == .v4, result.id == helperBefore.session,
              let notices = coverage.workerNotices,
              !complete || !coverage.hasExplanation,
              helperBefore == (try RetainedHelperObservation.read(workerURL, session: result.id)) else {
            throw StorageScanFailure.changed
        }
        let reasonCounts = AnalysisScanCoverageReason.allCases.map { coverage[$0] }
        let counts = try RetainedAnalysisRecord.Coverage(reasonCounts: reasonCounts,
            reportedNotices: coverage.reportedNotices, workerNotices: notices,
            uncategorizedNotices: coverage.uncategorizedNotices,
            reasonCountsAreComplete: coverage.reasonCountsAreComplete,
            terminalReason: coverage.terminalReason)
        let scope: RetainedAnalysisRecord.Scope
        if let startup {
            guard let peer, !startup.isChanged else { throw StorageScanFailure.changed }
            try startup.revalidateNative()
            let data = try RetainedAnalysisRecord.Root.capture(root, descriptor: source)
            let system = try RetainedAnalysisRecord.Root.capture(startup.systemRoot, descriptor: peer)
            let facts = startup.facts
            let active: RetainedAnalysisRecord.ActiveSystem = facts.active.snapshot.map { .snapshot($0.value) } ?? .liveSystem
            let pair = try RetainedAnalysisRecord.StartupPair(container: facts.membership.container.value,
                group: facts.membership.group.value,
                data: .init(root: data, physicalRootInode: startup.data.identity.realInode),
                system: .init(root: system, physicalRootInode: startup.system.identity.realInode,
                    backingVolume: facts.system.volume.value, activeDisk: facts.active.disk.value, active: active))
            scope = .startup(pair)
        } else {
            scope = .single(try RetainedAnalysisRecord.Root.capture(root, descriptor: source))
        }
        try scope.validate()
        let now = Date().timeIntervalSince1970
        guard now.isFinite, now >= 0, now < Double(Int64.max) else { throw StorageScanFailure.changed }
        let through = try RetainedAnalysisRecord.Time(seconds: Int64(now), nanoseconds: Int((now - floor(now)) * 1_000_000_000))
        return .init(result: result, scope: scope, policy: policy, coverage: counts,
            complete: complete, committedEntries: committed, observedFrom: began,
            observedThrough: through, helperSHA256: helperBefore.sha256)
    }
    func makeRecord(catalog: RetainedAnalysisRecord.Catalog) throws -> RetainedAnalysisRecord {
        guard catalog.catalogID == result.id else { throw StorageScanFailure.changed }
        return try RetainedAnalysisRecord(catalog: catalog, helperSHA256: helperSHA256,
            policy: policy, scope: scope, chartOverview: result.supportsChartOverviewForRetention,
            observedFrom: observedFrom, observedThrough: observedThrough,
            coverage: coverage, complete: complete, committedEntries: committedEntries,
            refreshCheckpoint: result.refreshCheckpoint, scanElapsed: result.scanElapsed)
    }
}

/// No public/memberwise constructor. The slot yields one candidate only after
/// the session has awaited control.finished and queue release.
struct RetainedDrainedCandidate: Sendable {
    let capture: RetainedScanCapture
    private let claimState: RetainedCandidateClaim
    fileprivate init(_ capture: RetainedScanCapture) {
        self.capture = capture; claimState = RetainedCandidateClaim()
    }
    func claimOnce() -> Bool { claimState.claim() }
}
private final class RetainedCandidateClaim: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    func claim() -> Bool {
        lock.withLock {
            guard !claimed else { return false }
            claimed = true; return true
        }
    }
}
final class RetainedCaptureSlot: @unchecked Sendable {
    private let lock = NSLock()
    private var capture: RetainedScanCapture?
    func install(_ value: RetainedScanCapture) throws {
        try lock.withLock {
            guard capture == nil else { throw StorageScanFailure.changed }
            capture = value
        }
    }
    func take() -> RetainedDrainedCandidate? {
        lock.withLock {
            guard let value = capture else { return nil }
            capture = nil; return RetainedDrainedCandidate(value)
        }
    }
}

/// Observed signed-bundle file identity, not proof of exact launched bytes.
/// The current launcher uses posix_spawn(path), so the path is checked before
/// and after the generated scan without changing worker protocol.
struct RetainedHelperObservation: Equatable, Sendable {
    let session: UUID
    let device: Int32, inode: UInt64, generation: UInt32, size: Int64
    let birth: Int, birthNanos: Int, modified: Int, modifiedNanos: Int, changed: Int, changedNanos: Int
    let sha256: String
    static func read(_ url: URL, session: UUID) throws -> Self {
        let fd = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw StorageScanFailure.workerUnavailable }
        defer { close(fd) }
        var first = stat(), after = stat(), named = stat()
        guard fstat(fd, &first) == 0, first.st_mode & S_IFMT == S_IFREG,
              first.st_uid == geteuid(), first.st_size > 0, first.st_size <= 128 << 20,
              lstat(url.path, &named) == 0, named.st_dev == first.st_dev, named.st_ino == first.st_ino else {
            throw StorageScanFailure.workerUnavailable
        }
        var hasher = SHA256(), buffer = [UInt8](repeating: 0, count: 64 << 10), offset: off_t = 0
        while offset < first.st_size {
            let count = buffer.withUnsafeMutableBytes { pread(fd, $0.baseAddress, min($0.count, Int(first.st_size - offset)), offset) }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw StorageScanFailure.changed }
            hasher.update(data: Data(buffer.prefix(count))); offset += off_t(count)
        }
        guard fstat(fd, &after) == 0, after.st_dev == first.st_dev, after.st_ino == first.st_ino,
              after.st_size == first.st_size,
              after.st_mtimespec.tv_sec == first.st_mtimespec.tv_sec,
              after.st_mtimespec.tv_nsec == first.st_mtimespec.tv_nsec,
              after.st_ctimespec.tv_sec == first.st_ctimespec.tv_sec,
              after.st_ctimespec.tv_nsec == first.st_ctimespec.tv_nsec,
              lstat(url.path, &named) == 0, named.st_dev == first.st_dev, named.st_ino == first.st_ino else {
            throw StorageScanFailure.changed
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return .init(session: session, device: first.st_dev, inode: first.st_ino, generation: first.st_gen,
            size: first.st_size, birth: first.st_birthtimespec.tv_sec,
            birthNanos: first.st_birthtimespec.tv_nsec,
            modified: first.st_mtimespec.tv_sec, modifiedNanos: first.st_mtimespec.tv_nsec,
            changed: first.st_ctimespec.tv_sec, changedNanos: first.st_ctimespec.tv_nsec,
            sha256: digest)
    }
}

extension RetainedAnalysisRecord.Root {
    static func capture(_ url: URL, descriptor: Int32) throws -> Self {
        var value = stat(), fs = statfs(), attributes = attrlist()
        guard fstat(descriptor, &value) == 0, value.st_mode & S_IFMT == S_IFDIR,
              fstatfs(descriptor, &fs) == 0, fs.f_flags & UInt32(MNT_LOCAL) != 0,
              withUnsafeBytes(of: &fs.f_fstypename, { raw in
                  raw.prefix(while: { $0 != 0 }).elementsEqual(Array("apfs".utf8))
              }) else { throw StorageScanFailure.changed }
        attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        attributes.commonattr = UInt32(ATTR_CMN_RETURNED_ATTRS)
        attributes.volattr = UInt32(ATTR_VOL_INFO) | UInt32(ATTR_VOL_UUID)
        var bytes = [UInt8](repeating: 0, count: 40)
        guard fgetattrlist(descriptor, &attributes, &bytes, bytes.count, 0) == 0 else { throw StorageScanFailure.changed }
        let volume = try StartupNativeRoot.decodeVolume(Data(bytes)).value
        let birth = try RetainedAnalysisRecord.Time(seconds: Int64(value.st_birthtimespec.tv_sec),
            nanoseconds: Int(value.st_birthtimespec.tv_nsec))
        return try .init(locator: url.standardizedFileURL.path, volume: volume,
            inode: value.st_ino, generation: value.st_gen, birth: birth)
    }
}
