import Darwin
import Foundation
@testable import LocalStorage
import Testing

@Suite(.serialized)
struct DriveFileBenchmarkTests {
    @Test func copiedReportHasBoundedFiniteSamplesAndNoRecoveryIdentity() throws {
        let samples = [DriveBenchmarkSample(phase: .writing, elapsedSeconds: .nan, megabytesPerSecond: 1),
            .init(phase: .reading, elapsedSeconds: 1, megabytesPerSecond: .infinity)]
            + (0..<605).map { DriveBenchmarkSample(phase: .writing, elapsedSeconds: Double($0), megabytesPerSecond: 4) }
        let result = DriveBenchmarkResult(outcome: .completed, bytesWritten: 8_000_000, bytesRead: 8_000_000,
            writeSeconds: .infinity, readSeconds: .nan, flushSeconds: 1,
            preparationSeconds: -1, writeLatency: .init([.infinity]), samples: samples,
            scratchURL: URL(fileURLWithPath: "/generated/private-volume/private-scratch"))
        let report = try DriveBenchmarkReport(result: result, recordedAt: Date(timeIntervalSince1970: 1_700_000_000))
        #expect(report.performanceSamples.count == 600)
        #expect(report.preparationSeconds == nil && report.writeAndFlush.elapsedSeconds == nil && report.readAndVerify.elapsedSeconds == nil)
        #expect(report.writeAndFlush.megabytesPerSecond == nil && report.writeAndFlush.ioLatency == nil)
        let json = try report.json()
        let object = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(object["schemaVersion"] as? Int == 2 && object["cleanupNeeded"] as? Bool == true)
        #expect(object["cacheMode"] as? String == "tryNoCache")
        #expect((object["performanceSamples"] as? [[String: Any]])?.count == 600)
        for text in [json, report.summary] {
            #expect(!text.contains("private-volume") && !text.contains("private-scratch"))
            #expect(!text.contains("scratchURL") && !text.contains("fileSystemID") && !text.contains("volumeName"))
            #expect(!text.contains("NaN") && !text.contains("Infinity"))
        }
        #expect(throws: DriveBenchmarkReport.Failure.self) {
            try DriveBenchmarkReport(result: result, recordedAt: Date(timeIntervalSinceReferenceDate: .nan))
        }
    }

    @Test func copiedReportSeparatesCompletedMeasurementsFromPartialAndFailedFacts() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let complete = DriveBenchmarkResult(outcome: .completed, bytesWritten: 8_000_000, bytesRead: 8_000_000,
            writeSeconds: 1, readSeconds: 4, flushSeconds: 1,
            writeLatency: .init([0.001, 0.002]), readLatency: .init([0.003, 0.004]))
        let measured = try DriveBenchmarkReport(result: complete, recordedAt: date)
        #expect(measured.outcome == .completed && measured.writeAndFlush.megabytesPerSecond == 4)
        #expect(measured.writeAndFlush.operationsPerSecond == 1 && measured.readAndVerify.operationsPerSecond == 0.5)
        #expect(measured.writeAndFlush.ioLatency?.p95Milliseconds == 2)
        for outcome in [DriveBenchmarkResult.Outcome.cancelled, .failed] {
            let partial = DriveBenchmarkResult(outcome: outcome, failure: outcome == .failed ? .verification : nil,
                bytesWritten: 8_000_000, bytesRead: 1_000_000, writeSeconds: 1, readSeconds: 1, flushSeconds: 1,
                writeLatency: .init([0.001]), samples: [.init(phase: .writing, elapsedSeconds: 1, megabytesPerSecond: 8)])
            let report = try DriveBenchmarkReport(result: partial, recordedAt: date)
            #expect(report.outcome == (outcome == .cancelled ? .partial : .failed))
            #expect(report.writeAndFlush.completedBytes == 8_000_000 && report.readAndVerify.completedBytes == 1_000_000)
            #expect(report.writeAndFlush.elapsedSeconds == 2 && report.performanceSamples.isEmpty)
            #expect(report.writeAndFlush.megabytesPerSecond == nil && report.writeAndFlush.operationsPerSecond == nil && report.writeAndFlush.ioLatency == nil)
            #expect(report.summary.contains("Partial/failed observations") && !report.summary.contains(" MB/s"))
            #expect(report.summary.contains("not proof of hardware persistence"))
            #expect(report.failureCode == (outcome == .failed ? "verification" : nil))
            _ = try report.json()
        }
    }

    @Test func randomAccessMeasuresEveryInitializedBlockAndCleansUp() async throws {
        let root = try LocalStorageTestFixtures.directory()
        defer { try? FileManager().removeItem(at: root) }
        let result = await DriveFileBenchmark().runForTesting(in: root, bytes: 1 << 20, workload: .random4K)
        #expect(result.outcome == .completed && result.failure == nil)
        #expect(result.blockBytes == 4096 && result.workload == .random4K)
        #expect(result.preparationBytesWritten == 1 << 20 && result.preparationSeconds > 0)
        #expect(result.bytesWritten == 1 << 20 && result.bytesRead == 1 << 20)
        #expect(result.writeLatency.operations == 256 && result.readLatency.operations == 256)
        #expect(result.writeLatency.medianMilliseconds <= result.writeLatency.p95Milliseconds)
        #expect(result.readLatency.p95Milliseconds <= result.readLatency.p99Milliseconds)
        #expect(!result.samples.isEmpty && result.samples.count <= 600)
        #expect(result.samples.allSatisfy { $0.elapsedSeconds >= 0 && $0.megabytesPerSecond.isFinite && $0.megabytesPerSecond >= 0 })
        #expect(result.scratchURL == nil)
        #expect(try FileManager().contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test(arguments: DriveSequentialBlockSize.allCases)
    func sequentialBlockChoicesKeepExactBytesAndOwnedCleanup(block: DriveSequentialBlockSize) async throws {
        let root = try LocalStorageTestFixtures.directory()
        defer { try? FileManager().removeItem(at: root) }
        let result = await DriveFileBenchmark().runForTesting(in: root, bytes: 8 << 20,
            sequentialBlockSize: block, cacheMode: .normal)
        #expect(result.outcome == .completed && result.failure == nil)
        #expect(result.blockBytes == block.bytes && result.cacheMode == .normal)
        #expect(result.cacheBypass == .notAttempted)
        #expect(result.bytesWritten == 8 << 20 && result.bytesRead == 8 << 20)
        #expect(result.writeLatency.operations == (8 << 20) / block.bytes)
        #expect(result.readLatency.operations == (8 << 20) / block.bytes)
        #expect(result.scratchURL == nil)
        #expect(try FileManager().contentsOfDirectory(atPath: root.path).isEmpty)
        let report = try DriveBenchmarkReport(result: result, recordedAt: Date(timeIntervalSince1970: 1_700_000_000))
        #expect(report.cacheMode == "normal" && report.blockBytes == block.bytes)
        #expect(report.summary.contains("normal policy; bypass not requested"))
    }

    @Test func randomFourKiBDoesNotInheritSequentialBlockChoice() async throws {
        let root = try LocalStorageTestFixtures.directory()
        defer { try? FileManager().removeItem(at: root) }
        let result = await DriveFileBenchmark().runForTesting(in: root, bytes: 1 << 20, workload: .random4K,
            sequentialBlockSize: .mib4, cacheMode: .normal)
        #expect(result.outcome == .completed && result.blockBytes == 4096)
        #expect(result.writeLatency.operations == 256 && result.readLatency.operations == 256)
        #expect(result.preparationBytesWritten == 1 << 20)
        #expect(result.cacheBypass == .notAttempted && result.scratchURL == nil)
        #expect(try FileManager().contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test func generatedReadbackAndCleanupLeaveChosenDirectoryUntouched() async throws {
        let root = try LocalStorageTestFixtures.directory()
        defer { try? FileManager().removeItem(at: root) }
        let sentinel = root.appendingPathComponent("existing-sentinel")
        let contents = Data("preserve this generated fixture".utf8)
        try contents.write(to: sentinel)
        var before = stat()
        #expect(lstat(sentinel.path, &before) == 0)
        var parent = stat()
        #expect(lstat(root.path, &parent) == 0)
        let result = await DriveFileBenchmark().runForTesting(in: root, bytes: 8 << 20,
                                                             expectedFileSystemID: Int64(parent.st_dev))
        #expect(result.outcome == .completed)
        #expect(result.failure == nil)
        #expect(result.bytesWritten == 8 << 20 && result.bytesRead == 8 << 20)
        #expect(result.writeSeconds > 0 && result.readSeconds > 0 && result.flushSeconds > 0)
        #expect(result.flush == .fullSync || result.flush == .fileSyncOnly)
        #expect(result.cacheBypass == .enabled || result.cacheBypass == .unavailable)
        #expect(result.scratchURL == nil)
        #expect(try FileManager().contentsOfDirectory(atPath: root.path) == ["existing-sentinel"])
        #expect(try Data(contentsOf: sentinel) == contents)
        var after = stat()
        #expect(lstat(sentinel.path, &after) == 0)
        #expect(before.st_ino == after.st_ino && before.st_size == after.st_size)
        #expect(before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec &&
                before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec)
    }

    @Test func cancellationDrainsBeforeReturningAndRemovesOnlyOwnedStage() async throws {
        let root = try LocalStorageTestFixtures.directory()
        defer { try? FileManager().removeItem(at: root) }
        let sentinel = root.appendingPathComponent("sentinel")
        try Data([7]).write(to: sentinel)
        let holder = BenchmarkTaskCancellation()
        let task = Task.detached {
            await DriveFileBenchmark().runForTesting(in: root, bytes: 8 << 20) { progress in
                if progress.phase == .writing && progress.completedBytes >= 1 << 20 { holder.cancel() }
            }
        }
        holder.install(task)
        let result = await task.value
        #expect(result.outcome == .cancelled)
        #expect(result.failure == nil && result.scratchURL == nil)
        #expect(result.bytesWritten == 1 << 20 && result.bytesRead == 0)
        #expect(try FileManager().contentsOfDirectory(atPath: root.path) == ["sentinel"])
        #expect(try Data(contentsOf: sentinel) == Data([7]))

        // Deliberately stall this owned worker's first completed chunk. The
        // cooperative deadline includes callback time and returns only after
        // cleanup; it does not pretend to interrupt an outstanding syscall.
        let timed = await DriveFileBenchmark().runForTesting(in: root, bytes: 8 << 20, elapsedCeiling: 0.1) { progress in
            if progress.phase == .writing && progress.completedBytes == 1 << 20 {
                Thread.sleep(forTimeInterval: 0.15)
            }
        }
        #expect(timed.outcome == .failed && timed.failure == .timedOut)
        #expect(timed.bytesWritten == 1 << 20 && timed.bytesRead == 0)
        #expect(timed.flush == .notAttempted && timed.scratchURL == nil)
        #expect(try FileManager().contentsOfDirectory(atPath: root.path) == ["sentinel"])
        #expect(try Data(contentsOf: sentinel) == Data([7]))
    }

    @Test(arguments: DriveBenchmarkWorkload.allCases)
    func changedGeneratedFileIsRefusedAndPreserved(workload: DriveBenchmarkWorkload) async throws {
        let root = try LocalStorageTestFixtures.directory()
        defer { try? FileManager().removeItem(at: root) }
        let result = await DriveFileBenchmark().runForTesting(in: root, bytes: 8 << 20, workload: workload) { progress in
            guard progress.phase == .reading, progress.completedBytes == 0,
                  let scratch = try? benchmarkScratch(in: root) else { return }
            // This is our generated test file, never an owner file.
            if let handle = try? FileHandle(forWritingTo: scratch.appendingPathComponent("generated.dat")) {
                try? handle.write(contentsOf: Data(repeating: 255, count: 8))
                try? handle.close()
            }
        }
        #expect(result.outcome == .failed && result.failure == .verification)
        let scratch = try #require(result.scratchURL)
        #expect(scratch.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL)
        #expect(FileManager().fileExists(atPath: scratch.appendingPathComponent("generated.dat").path))
    }

    @Test func unexpectedAdditionPreventsRecursiveCleanup() async throws {
        let root = try LocalStorageTestFixtures.directory()
        defer { try? FileManager().removeItem(at: root) }
        let result = await DriveFileBenchmark().runForTesting(in: root, bytes: 1 << 20) { progress in
            guard progress.phase == .reading, progress.completedBytes == 0,
                  let scratch = try? benchmarkScratch(in: root) else { return }
            try? Data([9]).write(to: scratch.appendingPathComponent("unexpected"))
        }
        #expect(result.outcome == .failed && result.failure == .cleanup)
        let scratch = try #require(result.scratchURL)
        #expect(try Data(contentsOf: scratch.appendingPathComponent("unexpected")) == Data([9]))
        #expect(FileManager().fileExists(atPath: scratch.appendingPathComponent("generated.dat").path))
    }

    @Test func redirectedOrWrongVolumeInputCreatesNothing() async throws {
        let root = try LocalStorageTestFixtures.directory()
        defer { try? FileManager().removeItem(at: root) }
        let target = root.appendingPathComponent("target", isDirectory: true)
        try FileManager().createDirectory(at: target, withIntermediateDirectories: false)
        let link = root.appendingPathComponent("redirect", isDirectory: true)
        try FileManager().createSymbolicLink(at: link, withDestinationURL: target)
        let redirected = await DriveFileBenchmark().runForTesting(in: link, bytes: 1 << 20)
        #expect(redirected.failure == .invalidDirectory && redirected.scratchURL == nil)
        var info = stat()
        #expect(lstat(target.path, &info) == 0)
        let wrongVolume = await DriveFileBenchmark().runForTesting(in: target, bytes: 1 << 20,
                                                                  expectedFileSystemID: Int64(info.st_dev) + 1)
        #expect(wrongVolume.failure == .changed && wrongVolume.scratchURL == nil)
        #expect(try FileManager().contentsOfDirectory(atPath: target.path).isEmpty)

        let sentinel = target.appendingPathComponent("sentinel")
        try Data([4]).write(to: sentinel)
        let selected = try await DriveFileBenchmark.prepareDirectory(target)
        #expect(selected.fileSystemID == Int64(info.st_dev))
        #expect(!String(describing: selected).contains(target.path))
        #expect(!String(reflecting: selected).contains(target.path))
        let retained = root.appendingPathComponent("retained-original", isDirectory: true)
        try FileManager().moveItem(at: target, to: retained)
        try FileManager().createDirectory(at: target, withIntermediateDirectories: false)
        let replaced = await DriveFileBenchmark().runForTesting(in: selected, bytes: 1 << 20)
        #expect(replaced.failure == .changed && replaced.scratchURL == nil)
        #expect(replaced.bytesWritten == 0 && replaced.bytesRead == 0)
        #expect(try FileManager().contentsOfDirectory(atPath: target.path).isEmpty)
        #expect(try FileManager().contentsOfDirectory(atPath: retained.path) == ["sentinel"])
        #expect(try Data(contentsOf: retained.appendingPathComponent("sentinel")) == Data([4]))
        #expect(DriveBenchmarkSize.allCases.map(\.bytes) == [64 << 20, 256 << 20, 1024 << 20])
    }
}

private func benchmarkScratch(in root: URL) throws -> URL {
    let entries = try FileManager().contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
    return try #require(entries.first { $0.lastPathComponent.hasPrefix(".traverse-benchmark-") })
}

/// Installation can race the first callback; retain an early cancellation and
/// apply it as soon as the test's task exists. This owns no filesystem state.
private final class BenchmarkTaskCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<DriveBenchmarkResult, Never>?
    private var requested = false
    func install(_ task: Task<DriveBenchmarkResult, Never>) {
        lock.withLock { self.task = task; if requested { task.cancel() } }
    }
    func cancel() { lock.withLock { requested = true; task?.cancel() } }
}
