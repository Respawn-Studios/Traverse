import CryptoKit
import Darwin
import Foundation
@testable import FileOperations
import Testing

private struct ProfileUsage: Codable {
    let userSeconds: Double
    let systemSeconds: Double
    let processLifetimePeakRSSBytes: Int64
    let residentBytes: UInt64
    init() throws {
        var value = rusage()
        guard getrusage(RUSAGE_SELF, &value) == 0 else { throw posixFailure() }
        userSeconds = Double(value.ru_utime.tv_sec) + Double(value.ru_utime.tv_usec) / 1_000_000
        systemSeconds = Double(value.ru_stime.tv_sec) + Double(value.ru_stime.tv_usec) / 1_000_000
        processLifetimePeakRSSBytes = Int64(value.ru_maxrss)
        residentBytes = try profileResidentBytes()
    }
}

private func profileResidentBytes() throws -> UInt64 {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    guard result == KERN_SUCCESS else { throw FileOperationFailure.ioFailure }
    return UInt64(info.resident_size)
}

private func profileOpenDescriptorCount() -> Int {
    // Public F_GETFD probes, bounded independently of the process descriptor limit.
    (0..<min(getdtablesize(), 4096)).reduce(0) { $0 + (fcntl($1, F_GETFD) == -1 ? 0 : 1) }
}

private final class ProfileProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var phase: OperationProgressPhase?
    private var stamp: TimeInterval?
    private var durations: [String: Double] = [:]
    private var callbacks = 0
    private var peakDescriptors = 0
    private var peakResidentBytes: UInt64 = 0
    private var lastProbe = -Double.infinity
    private var maxCopyBytes: Int64 = 0
    private var terminal = false
    private var heldProbes = 0
    private var heldPeakDescriptors = 0
    private var heldPeakResidentBytes: UInt64 = 0
    func observeHeldDescriptors() throws {
        let descriptors = profileOpenDescriptorCount(), resident = try profileResidentBytes()
        lock.withLock {
            heldProbes += 1; heldPeakDescriptors = max(heldPeakDescriptors, descriptors)
            heldPeakResidentBytes = max(heldPeakResidentBytes, resident)
        }
    }
    func observe(_ value: OperationProgress) {
        let now = ProcessInfo.processInfo.systemUptime
        lock.withLock {
            if let phase, let stamp { durations[phase.rawValue, default: 0] += now - stamp }
            phase = value.phase; stamp = now; callbacks += 1
            if value.phase == .copying { maxCopyBytes = max(maxCopyBytes, value.bytesCompleted ?? 0) }
            if now - lastProbe >= 0.1 {
                peakDescriptors = max(peakDescriptors, profileOpenDescriptorCount())
                peakResidentBytes = max(peakResidentBytes, (try? profileResidentBytes()) ?? 0)
                lastProbe = now
            }
            terminal = value.isTerminal
        }
    }
    var summary: Summary { lock.withLock { Summary(observedPhaseSeconds: durations, callbacks: callbacks,
        sampledPeakOpenDescriptors: peakDescriptors, sampledPeakResidentBytes: peakResidentBytes,
        maximumObservedCopyPhaseBytes: maxCopyBytes, terminalObserved: terminal,
        heldNodeProbeCount: heldProbes, heldNodePeakOpenDescriptors: heldPeakDescriptors,
        heldNodePeakResidentBytes: heldPeakResidentBytes) } }
    struct Summary: Codable {
        let observedPhaseSeconds: [String: Double]
        let callbacks: Int
        let sampledPeakOpenDescriptors: Int
        let sampledPeakResidentBytes: UInt64
        let maximumObservedCopyPhaseBytes: Int64
        let terminalObserved: Bool
        let heldNodeProbeCount: Int
        let heldNodePeakOpenDescriptors: Int
        let heldNodePeakResidentBytes: UInt64
    }
}

private struct ProfileReceipt: Encodable {
    let schema = 1
    let workload: String
    let profiling: Bool
    let regularFileCount: Int
    let topLevelInputCount: Int
    let logicalSourceBytes: Int64
    let maximumFixtureDepth: Int
    let operationSeconds: Double
    let before: ProfileUsage
    let after: ProfileUsage
    let openDescriptorsBefore: Int
    let openDescriptorsAfter: Int
    let descriptorProbeLimit = 4096
    let descriptorLimit: Int32
    let completedCopyUndoCycles: Int
    let openDescriptorsAfterEachCycle: [Int]
    let residentBytesAfterEachCycle: [UInt64]
    let progress: ProfileProgress.Summary?
    let journalMetrics: JournalMetrics.Snapshot?
    let disposition: String
    let limitations = "Fresh worker; uncontrolled filesystem cache. getrusage RSS is process-lifetime peak; Mach resident bytes are current/sampled working memory. FD and working-memory maxima are sampled, not exact. FD probes cap at4096. Coalesced callback phase durations and bytes are observations, not syscall timers, complete byte accounting, or physical I/O. No paths or content are exported."
}

@Suite(.serialized) struct IntegrityProfileTests {
    /// The ordinary regression crosses read-buffer boundaries and alternates long,
    /// short and empty files. The opt-in profile expands only the tiny-file fanout.
    @Test func verifiedTreeMixedFileReads() throws {
        let profiling = ProcessInfo.processInfo.environment["MAC_EXPLORER_RUN_VERIFIED_TREE_PROFILE"] == "1"
        let root = try FileOperationTestFixtures.base().appendingPathComponent("verified-tree-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let sizes = [0, 1, 262_143, 262_144, 262_145, 524_305, 3]
            + (profiling ? Array(repeating: 113, count: 2_048) + [4_194_321] : [])
        var expected: [String: Data] = [:]
        for (index, size) in sizes.enumerated() {
            let name = String(format: "generated-%04d.bin", index)
            let bytes = Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ index) })
            try bytes.write(to: root.appendingPathComponent(name), options: .withoutOverwriting)
            expected[name] = Data(SHA256.hash(data: bytes))
        }
        var seconds: [Double] = []
        var first: VerifiedTree?
        for _ in 0..<(profiling ? 5 : 1) {
            let meter = NativeTrashWalkMeter()
            let start = ProcessInfo.processInfo.systemUptime
            let value = try verifiedTree(root, cancellation: OperationCancellation(),
                                         expectedFileContents: expected, nativeTrashWalkMeter: meter)
            seconds.append(ProcessInfo.processInfo.systemUptime - start)
            if let first { #expect(value == first) } else { first = value }
            let counts = meter.snapshot
            #expect(counts.valid && counts.entries == sizes.count + 1)
            #expect(counts.bodyBytes == Int64(sizes.reduce(0, +)))
        }
        if profiling {
            let report: [String: Any] = ["schema": 1, "regularFiles": sizes.count,
                "logicalBytesPerWalk": sizes.reduce(0, +), "seconds": seconds,
                "medianSeconds": seconds.sorted()[seconds.count / 2],
                "limitations": "Warm repeated generated walk; uncontrolled OS cache. Not physical reads or end-to-end Trash latency."]
            let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
            print("VERIFIED_TREE_PROFILE_JSON " + String(decoding: data, as: UTF8.self))
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MAC_EXPLORER_RUN_INTEGRITY_PROFILE"] == "1"))
    func generatedFixtureWorker() async throws {
        let environment = ProcessInfo.processInfo.environment
        let workload = environment["MAC_EXPLORER_INTEGRITY_PROFILE_CASE"] ?? "large"
        let enabled = environment["MAC_EXPLORER_INTEGRITY_PROFILE_OBSERVER"] != "0"
        guard let batchInputs = Int(environment["MAC_EXPLORER_INTEGRITY_PROFILE_BATCH_INPUTS"] ?? "1024"),
              [64, 128, 256, 512, 1024].contains(batchInputs) else { throw FileOperationFailure.invalidRequest }
        guard ["large", "fanout", "deep", "batch", "cycles"].contains(workload) else { throw FileOperationFailure.invalidRequest }
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let base = package.appendingPathComponent(".build/test-fixtures")
        guard base.resolvingSymlinksInPath().path == base.path else { throw FileOperationFailure.invalidRequest }
        try FileManager().createDirectory(at: base, withIntermediateDirectories: true)
        let root = base.appendingPathComponent("integrity-profile-" + UUID().uuidString)
        try FileManager().createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager().removeItem(at: root) }
        let source = root.appendingPathComponent("source"), destination = root.appendingPathComponent("destination")
        try FileManager().createDirectory(at: source, withIntermediateDirectories: false)
        try FileManager().createDirectory(at: destination, withIntermediateDirectories: false)
        var sources = [source]
        var bytes: Int64 = 0
        var count = 0
        var depth = 1
        switch workload {
        case "large":
            let url = source.appendingPathComponent("generated.bin")
            let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw posixFailure() }
            do {
                defer { close(fd) }
                let block = Data(repeating: 0x69, count: 1_048_576)
                for _ in 0..<64 { guard block.withUnsafeBytes({ write(fd, $0.baseAddress, $0.count) }) == block.count else { throw posixFailure() } }
                guard fsync(fd) == 0 else { throw posixFailure() }
            }
            bytes = 64 * 1_048_576; count = 1
        case "fanout", "batch", "cycles":
            let data = Data(repeating: 0x4d, count: 256)
            count = workload == "fanout" ? 10_001 : workload == "cycles" ? 32 : batchInputs
            for index in 0..<count { try data.write(to: source.appendingPathComponent("item-\(index)"), options: .withoutOverwriting) }
            bytes = Int64(count * 256)
            if workload == "batch" { sources = (0..<batchInputs).map { source.appendingPathComponent("item-\($0)") } }
        default:
            var leaf = source
            for _ in 0..<32 { leaf.appendPathComponent("child"); try FileManager().createDirectory(at: leaf, withIntermediateDirectories: false) }
            try Data(repeating: 0x17, count: 1024).write(to: leaf.appendingPathComponent("item"), options: .withoutOverwriting)
            bytes = 1024; count = 1; depth = 33
        }
        let receipt = ProfileProgress()
        let heldProbes = workload == "deep" && enabled && environment["MAC_EXPLORER_INTEGRITY_PROFILE_HELD_PROBES"] == "1"
        let journalMetrics = environment["MAC_EXPLORER_INTEGRITY_PROFILE_JOURNAL"] == "1" ? JournalMetrics() : nil
        let service = RecoverableFileOperations(journalDirectory: root.appendingPathComponent("journal"),
            hooks: RecoveryHooks(journalHooks: JournalStorageHooks(metrics: journalMetrics), copyFaults: heldProbes ? CopyFaultHooks(beforeNativeCopy: { _, _ in try receipt.observeHeldDescriptors() }) : CopyFaultHooks()))
        let callback: (@Sendable (OperationProgress) -> Void)? = enabled ? receipt.observe : nil
        let before = try ProfileUsage(), descriptorsBefore = profileOpenDescriptorCount()
        let start = ProcessInfo.processInfo.systemUptime
        let plan = try await service.prepareTransfer(sources: sources, destinationDirectory: destination, move: false, progress: callback)
        let result = await service.perform(plan, progress: callback)
        var cycleFDs: [Int] = [], cycleRSS: [UInt64] = []
        if workload == "cycles" {
            var current = result
            for cycle in 0..<8 {
                try #require(current.result.disposition == .succeeded)
                let id = try #require(current.recordID)
                let undone = await service.undo(recordID: id, progress: callback)
                try #require(undone.result.disposition == .succeeded)
                cycleFDs.append(profileOpenDescriptorCount()); cycleRSS.append(try profileResidentBytes())
                if cycle < 7 {
                    let next = try await service.prepareTransfer(sources: sources, destinationDirectory: destination, move: false, progress: callback)
                    current = await service.perform(next, progress: callback)
                }
            }
            // The worker/progress queues may initialize on the first cycle; subsequent
            // cycles must return descriptors instead of accumulating one per operation.
            #expect((cycleFDs.dropFirst().max() ?? 0) - (cycleFDs.dropFirst().min() ?? 0) <= 1)
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        let after = try ProfileUsage(), descriptorsAfter = profileOpenDescriptorCount()
        #expect(result.result.disposition == .succeeded)
        #expect(result.recordID != nil)
        if enabled { #expect(receipt.summary.terminalObserved) }
        let report = ProfileReceipt(workload: workload, profiling: enabled, regularFileCount: count, topLevelInputCount: sources.count,
            logicalSourceBytes: bytes, maximumFixtureDepth: depth, operationSeconds: elapsed, before: before, after: after,
            openDescriptorsBefore: descriptorsBefore, openDescriptorsAfter: descriptorsAfter, descriptorLimit: getdtablesize(),
            completedCopyUndoCycles: cycleFDs.count, openDescriptorsAfterEachCycle: cycleFDs, residentBytesAfterEachCycle: cycleRSS,
            progress: enabled ? receipt.summary : nil, journalMetrics: journalMetrics?.snapshot, disposition: result.result.disposition.rawValue)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        print("INTEGRITY_PROFILE_JSON " + String(decoding: try encoder.encode(report), as: UTF8.self))
    }
}
