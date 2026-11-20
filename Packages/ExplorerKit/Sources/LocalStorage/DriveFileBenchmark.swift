import Darwin
import ExplorerCore
import Foundation

public enum DriveBenchmarkSize: String, CaseIterable, Sendable {
    case compact, quick, standard, extended
    public var bytes: Int64 {
        switch self { case .compact: 16 << 20; case .quick: 64 << 20; case .standard: 256 << 20; case .extended: 1024 << 20 }
    }
}

public struct DriveBenchmarkProgress: Sendable {
    public enum Phase: String, Sendable { case preparing, writing, flushing, reading, cleaningUp }
    public let phase: Phase
    public let completedBytes: Int64
    public let totalBytes: Int64
    public var elapsedSeconds: Double = 0
    public var megabytesPerSecond: Double? = nil
}

public enum DriveBenchmarkFailure: String, Error, Sendable {
    case busy, invalidDirectory, insufficientSpace, preparation, write, read, verification, changed, cleanup, timedOut, close
}

/// A metadata-only selection sealed to the directory observed during Choose.
/// It conveys no access lease; the caller retains the selected security scope.
public struct DriveBenchmarkDirectory: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let url: URL
    public let fileSystemID: Int64
    public var description: String { "DriveBenchmarkDirectory(selected)" }
    public var debugDescription: String { description }
    private let device: dev_t
    private let inode: ino_t
    private let generation: UInt32
    private let mode: mode_t
    private let owner: uid_t
    private let group: gid_t

    fileprivate init(url: URL, observed: stat) {
        self.url = url
        fileSystemID = Int64(observed.st_dev)
        device = observed.st_dev; inode = observed.st_ino; generation = observed.st_gen
        mode = observed.st_mode; owner = observed.st_uid; group = observed.st_gid
    }

    fileprivate func matches(_ observed: stat) -> Bool {
        device == observed.st_dev && inode == observed.st_ino && generation == observed.st_gen &&
            mode == observed.st_mode && owner == observed.st_uid && group == observed.st_gid
    }
}

public struct DriveBenchmarkResult: Sendable {
    public enum Outcome: String, Sendable { case completed, cancelled, failed }
    public enum CacheBypass: String, Sendable { case notAttempted, enabled, unavailable }
    public enum Flush: String, Sendable { case notAttempted, fullSync, fileSyncOnly, failed }
    public fileprivate(set) var outcome: Outcome = .failed
    public fileprivate(set) var failure: DriveBenchmarkFailure?
    public fileprivate(set) var bytesWritten: Int64 = 0
    public fileprivate(set) var bytesRead: Int64 = 0
    /// End-to-end workload wall time includes validation, cancellation
    /// checks, progress callbacks, and (for reads) byte verification. These are
    /// generated-file measurements, not pure device throughput. Flush is
    /// separate; a displayed write-and-flush rate must add flushSeconds.
    public fileprivate(set) var writeSeconds: Double = 0
    public fileprivate(set) var readSeconds: Double = 0
    public fileprivate(set) var flushSeconds: Double = 0
    public fileprivate(set) var workload: DriveBenchmarkWorkload = .sequential
    public fileprivate(set) var blockBytes: Int = 1 << 20
    public fileprivate(set) var cacheMode: DriveBenchmarkCacheMode = .tryNoCache
    public fileprivate(set) var preparationBytesWritten: Int64 = 0
    public fileprivate(set) var preparationSeconds: Double = 0
    public fileprivate(set) var writeLatency = DriveBenchmarkLatency([])
    public fileprivate(set) var readLatency = DriveBenchmarkLatency([])
    public fileprivate(set) var samples: [DriveBenchmarkSample] = []
    /// F_NOCACHE applies only to this generated file's descriptor. It does not
    /// clear global caches or establish a cold hardware/device measurement.
    public fileprivate(set) var cacheBypass: CacheBypass = .notAttempted
    /// FULLFSYNC success is an OS acknowledgment, not proof that hardware
    /// honored the request. A failed FULLFSYNC falls back to ordinary fsync.
    public fileprivate(set) var flush: Flush = .notAttempted
    /// Present only when guarded cleanup could not remove the private stage.
    /// This user-visible recovery location must never enter diagnostics.
    public fileprivate(set) var scratchURL: URL?
}

/// One explicit generated-file measurement, never a raw-device or health test.
/// The lock protects admission only; the private serial queue owns every file
/// descriptor and buffer. Cancellation is a locked flag checked between bounded
/// I/O calls. Completion waits for those calls and cleanup to drain, including
/// potentially slow/non-interruptible filesystem flushes. The 180-second ceiling
/// is cooperative: it cannot interrupt an outstanding kernel call. Keep the selected
/// directory's security scope and app activity lease alive until run returns.
public final class DriveFileBenchmark: @unchecked Sendable {
    private let lock = NSLock()
    private var running = false
    private let queue = DispatchQueue(label: "com.respawnstudios.traverse.file-benchmark", qos: .utility)
    private static let preparationQueue = DispatchQueue(label: "com.respawnstudios.traverse.file-benchmark-selection", qos: .utility)

    public init() {}

    /// Opens without following any symlink, observes exact directory identity,
    /// and admits only local writable filesystems. No file body is accessed.
    public static func prepareDirectory(_ url: URL) async throws -> DriveBenchmarkDirectory {
        try Task.checkCancellation()
        let selected: DriveBenchmarkDirectory = try await withCheckedThrowingContinuation { continuation in
            preparationQueue.async {
                do {
                    guard url.isFileURL, url.path.hasPrefix("/"), !url.path.utf8.contains(0) else {
                        throw DriveBenchmarkFailure.invalidDirectory
                    }
                    let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
                    guard descriptor >= 0 else { throw DriveBenchmarkFailure.invalidDirectory }
                    defer { close(descriptor) }
                    guard let witness = Witness(descriptor), witness.value.st_mode & S_IFMT == S_IFDIR else {
                        throw DriveBenchmarkFailure.invalidDirectory
                    }
                    _ = try localWritableSpace(descriptor)
                    continuation.resume(returning: .init(url: url, observed: witness.value))
                } catch { continuation.resume(throwing: error) }
            }
        }
        try Task.checkCancellation()
        return selected
    }

    public func run(in directory: DriveBenchmarkDirectory, size: DriveBenchmarkSize = .standard,
                    workload: DriveBenchmarkWorkload = .sequential,
                    sequentialBlockSize: DriveSequentialBlockSize = .mib1,
                    cacheMode: DriveBenchmarkCacheMode = .tryNoCache,
                    progress: @escaping @Sendable (DriveBenchmarkProgress) -> Void = { _ in }) async -> DriveBenchmarkResult {
        await run(in: directory, bytes: size.bytes, workload: workload,
                  sequentialBlockSize: sequentialBlockSize, cacheMode: cacheMode,
                  elapsedCeiling: 180, progress: progress)
    }

    // Internal qualification uses tiny generated fixtures; production callers
    // can choose only the three bounded sizes above.
    func runForTesting(in directory: URL, bytes: Int64, expectedFileSystemID: Int64? = nil,
                        workload: DriveBenchmarkWorkload = .sequential,
                       sequentialBlockSize: DriveSequentialBlockSize = .mib1,
                       cacheMode: DriveBenchmarkCacheMode = .tryNoCache,
                       elapsedCeiling: Double = 180,
                       progress: @escaping @Sendable (DriveBenchmarkProgress) -> Void = { _ in }) async -> DriveBenchmarkResult {
        do {
            let selected = try await Self.prepareDirectory(directory)
            guard expectedFileSystemID == nil || selected.fileSystemID == expectedFileSystemID else {
                return .init(failure: .changed)
            }
            return await runForTesting(in: selected, bytes: bytes, workload: workload,
                                       sequentialBlockSize: sequentialBlockSize, cacheMode: cacheMode,
                                       elapsedCeiling: elapsedCeiling, progress: progress)
        } catch is CancellationError { return .init(outcome: .cancelled) }
        catch let error as DriveBenchmarkFailure { return .init(failure: error) }
        catch { return .init(failure: .preparation) }
    }

    func runForTesting(in directory: DriveBenchmarkDirectory, bytes: Int64,
                       workload: DriveBenchmarkWorkload = .sequential,
                       sequentialBlockSize: DriveSequentialBlockSize = .mib1,
                       cacheMode: DriveBenchmarkCacheMode = .tryNoCache, elapsedCeiling: Double = 180,
                       progress: @escaping @Sendable (DriveBenchmarkProgress) -> Void = { _ in }) async -> DriveBenchmarkResult {
        let blockBytes = workload == .random4K ? workload.blockBytes : sequentialBlockSize.bytes
        guard bytes > 0, bytes <= 8 << 20, bytes % Int64(blockBytes) == 0,
              elapsedCeiling > 0, elapsedCeiling <= 180 else {
            return .init(failure: .preparation)
        }
        return await run(in: directory, bytes: bytes, workload: workload,
                         sequentialBlockSize: sequentialBlockSize, cacheMode: cacheMode,
                         elapsedCeiling: elapsedCeiling, progress: progress)
    }

    private func run(in directory: DriveBenchmarkDirectory, bytes: Int64, workload: DriveBenchmarkWorkload,
                     sequentialBlockSize: DriveSequentialBlockSize, cacheMode: DriveBenchmarkCacheMode,
                     elapsedCeiling: Double,
                     progress: @escaping @Sendable (DriveBenchmarkProgress) -> Void) async -> DriveBenchmarkResult {
        let blockBytes = workload == .random4K ? workload.blockBytes : sequentialBlockSize.bytes
        guard bytes > 0, bytes <= DriveBenchmarkSize.extended.bytes, bytes % Int64(blockBytes) == 0 else {
            return .init(failure: .preparation)
        }
        guard lock.withLock({ if running { return false }; running = true; return true }) else {
            return .init(failure: .busy)
        }
        let cancellation = Cancellation()
        let started = DispatchTime.now().uptimeNanoseconds
        if Task.isCancelled { cancellation.cancel() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.async { [self] in
                    let result = Self.measure(in: directory, bytes: bytes, workload: workload,
                                              blockBytes: blockBytes, cacheMode: cacheMode,
                                              cancellation: cancellation, started: started,
                                              elapsedCeiling: elapsedCeiling, progress: progress)
                    lock.withLock { running = false }
                    continuation.resume(returning: result)
                }
            }
        } onCancel: { cancellation.cancel() }
    }

    private final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        func cancel() { lock.withLock { cancelled = true } }
        func check() throws { if lock.withLock({ cancelled }) { throw CancellationError() } }
    }

    private struct Witness {
        let value: stat
        init?(_ descriptor: Int32) {
            var value = stat()
            guard fstat(descriptor, &value) == 0 else { return nil }
            self.value = value
        }
        func identity(_ other: stat) -> Bool {
            value.st_dev == other.st_dev && value.st_ino == other.st_ino && value.st_gen == other.st_gen &&
            value.st_mode == other.st_mode && value.st_uid == other.st_uid && value.st_gid == other.st_gid
        }
        func unchanged(_ other: stat) -> Bool {
            identity(other) && value.st_nlink == other.st_nlink && value.st_size == other.st_size &&
            value.st_mtimespec.tv_sec == other.st_mtimespec.tv_sec && value.st_mtimespec.tv_nsec == other.st_mtimespec.tv_nsec &&
            value.st_ctimespec.tv_sec == other.st_ctimespec.tv_sec && value.st_ctimespec.tv_nsec == other.st_ctimespec.tv_nsec
        }
    }

    private static func measure(in selection: DriveBenchmarkDirectory, bytes: Int64,
                                workload: DriveBenchmarkWorkload, blockBytes: Int,
                                cacheMode: DriveBenchmarkCacheMode, cancellation: Cancellation,
                                started: UInt64, elapsedCeiling: Double,
                                progress: @Sendable (DriveBenchmarkProgress) -> Void) -> DriveBenchmarkResult {
        let chunk = blockBytes
        let directory = selection.url
        let scratchName = ".traverse-benchmark-" + UUID().uuidString
        let fileName = "generated.dat"
        var result = DriveBenchmarkResult()
        result.workload = workload; result.blockBytes = chunk; result.cacheMode = cacheMode
        var writeLatencies: [Double] = [], readLatencies: [Double] = []
        var progressCadence = ProgressCadence(interval: 0.05, startingAt: 0)
        var previousBytes: Int64 = 0
        var parent: Int32 = -1, scratch: Int32 = -1, file: Int32 = -1
        var parentWitness: Witness?, scratchWitness: Witness?, fileWitness: Witness?
        var createdDirectory = false
        func check() throws {
            try cancellation.check()
            guard elapsed(started) < elapsedCeiling else { throw DriveBenchmarkFailure.timedOut }
        }
        func onSelectedVolume(_ observed: stat) -> Bool {
            guard let parentWitness else { return false }
            return observed.st_dev == parentWitness.value.st_dev &&
                Int64(observed.st_dev) == selection.fileSystemID
        }
        func report(_ phase: DriveBenchmarkProgress.Phase, _ completed: Int64 = 0) {
            let now = elapsed(started)
            let previousProgress = progressCadence.lastPublication ?? 0
            if completed == 0 { previousBytes = 0 }
            // Keep phase boundaries and first/final blocks immediate. Coalesce
            // intermediate UI updates for every workload; I/O latency capture
            // still records every operation before reaching this callback.
            let boundary = completed <= Int64(chunk) || completed == bytes
            guard progressCadence.shouldPublish(at: now, immediately: boundary) else { return }
            let interval = now - previousProgress
            let rate = completed > previousBytes && interval > 0
                ? Double(completed - previousBytes) / 1_000_000 / interval : nil
            progress(.init(phase: phase, completedBytes: completed, totalBytes: bytes,
                elapsedSeconds: now, megabytesPerSecond: rate))
            if let rate, phase == .writing || phase == .reading {
                // At most 600 points. Coarsen older history without discarding
                // its early part when a slow external device needs longer.
                if result.samples.count == 600 {
                    result.samples = result.samples.enumerated().compactMap { $0.offset.isMultiple(of: 2) ? $0.element : nil }
                }
                result.samples.append(.init(phase: phase, elapsedSeconds: now, megabytesPerSecond: rate))
            }
            previousBytes = completed
        }
        func selectedDirectoryUnchanged() -> Bool {
            let check = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
            guard check >= 0 else { return false }
            defer { close(check) }
            guard let observed = Witness(check), let parentWitness else { return false }
            return parentWitness.identity(observed.value) && selection.matches(observed.value)
        }
        func scratchNamespaceUnchanged() -> Bool {
            var observed = stat()
            return scratch >= 0 && fstatat(parent, scratchName, &observed, AT_SYMLINK_NOFOLLOW) == 0 &&
                scratchWitness?.identity(observed) == true && observed.st_mode & S_IFMT == S_IFDIR && onSelectedVolume(observed)
        }
        do {
            try check()
            report(.preparing)
            guard directory.isFileURL, directory.path.hasPrefix("/"), !directory.path.utf8.contains(0) else {
                throw DriveBenchmarkFailure.invalidDirectory
            }
            // Darwin's public O_NOFOLLOW_ANY rejects symlinks in every path
            // component. Retain the selected directory descriptor throughout.
            parent = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
            guard parent >= 0, let witness = Witness(parent) else { throw DriveBenchmarkFailure.invalidDirectory }
            parentWitness = witness
            guard selection.matches(witness.value) else { throw DriveBenchmarkFailure.changed }
            try check()
            guard selectedDirectoryUnchanged() else { throw DriveBenchmarkFailure.changed }
            let space = try localWritableSpace(parent)
            let available = space.f_bavail.multipliedReportingOverflow(by: UInt64(space.f_bsize))
            guard !available.overflow, available.partialValue >= UInt64(bytes) + (16 << 20) else {
                throw DriveBenchmarkFailure.insufficientSpace
            }
            try check()
            guard mkdirat(parent, scratchName, 0o700) == 0 else { throw DriveBenchmarkFailure.preparation }
            createdDirectory = true
            scratch = openat(parent, scratchName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard scratch >= 0, let witness = Witness(scratch), witness.value.st_mode & 0o777 == 0o700 else {
                throw DriveBenchmarkFailure.preparation
            }
            scratchWitness = witness
            guard onSelectedVolume(witness.value), scratchNamespaceUnchanged() else { throw DriveBenchmarkFailure.changed }
            file = openat(scratch, fileName, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard file >= 0, let witness = Witness(file), witness.value.st_mode & S_IFMT == S_IFREG,
                  witness.value.st_nlink == 1 else { throw DriveBenchmarkFailure.preparation }
            fileWitness = witness
            guard onSelectedVolume(witness.value) else { throw DriveBenchmarkFailure.changed }
            if cacheMode == .tryNoCache {
                result.cacheBypass = fcntl(file, F_NOCACHE, 1) == 0 ? .enabled : .unavailable
            }

            let writeBuffer = UnsafeMutableRawPointer.allocate(byteCount: chunk, alignment: 4096)
            let readBuffer = UnsafeMutableRawPointer.allocate(byteCount: chunk, alignment: 4096)
            defer { writeBuffer.deallocate(); readBuffer.deallocate() }
            arc4random_buf(writeBuffer, chunk)
            let blocks = Int(bytes / Int64(chunk))
            var writeOrder = Array(0..<blocks)
            var readOrder = writeOrder
            if workload == .random4K {
                // Fully populate the private file before timing random access.
                // This preparation write is reported separately and never
                // hidden inside the nominal benchmark byte count.
                writeOrder.shuffle(); readOrder.shuffle()
                let preparing = DispatchTime.now().uptimeNanoseconds
                defer { result.preparationSeconds = elapsed(preparing) }
                for index in 0..<blocks {
                    try check()
                    guard scratchNamespaceUnchanged() else { throw DriveBenchmarkFailure.changed }
                    let base = Int64(index * chunk)
                    writeBuffer.storeBytes(of: UInt64(base), as: UInt64.self)
                    var done = 0
                    while done < chunk {
                        try check()
                        let count = Darwin.pwrite(file, writeBuffer.advanced(by: done), chunk - done, off_t(base + Int64(done)))
                        if count < 0 && errno == EINTR { continue }
                        guard count > 0 else { throw DriveBenchmarkFailure.write }
                        done += count; result.preparationBytesWritten += Int64(count)
                        guard let observed = Witness(file), fileWitness?.identity(observed.value) == true,
                              observed.value.st_nlink == 1, observed.value.st_size == base + Int64(done) else {
                            throw DriveBenchmarkFailure.changed
                        }
                        fileWitness = observed
                    }
                    report(.preparing, result.preparationBytesWritten)
                }
            }
            report(.writing)
            guard selectedDirectoryUnchanged() else { throw DriveBenchmarkFailure.changed }
            let writeStart = DispatchTime.now().uptimeNanoseconds
            defer { if result.writeSeconds == 0 { result.writeSeconds = elapsed(writeStart) } }
            for index in writeOrder {
                try check()
                guard scratchNamespaceUnchanged() else { throw DriveBenchmarkFailure.changed }
                let base = Int64(index * chunk)
                writeBuffer.storeBytes(of: UInt64(base), as: UInt64.self)
                var done = 0, ioSeconds = 0.0
                while done < chunk {
                    try check()
                    let began = DispatchTime.now().uptimeNanoseconds
                    let count = Darwin.pwrite(file, writeBuffer.advanced(by: done), chunk - done, off_t(base + Int64(done)))
                    ioSeconds += elapsed(began)
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0 else { throw DriveBenchmarkFailure.write }
                    done += count; result.bytesWritten += Int64(count)
                    let expectedSize = workload == .sequential ? base + Int64(done) : bytes
                    guard let observed = Witness(file), fileWitness?.identity(observed.value) == true,
                          observed.value.st_nlink == 1, observed.value.st_size == expectedSize else {
                        throw DriveBenchmarkFailure.changed
                    }
                    fileWitness = observed
                }
                writeLatencies.append(ioSeconds)
                report(.writing, result.bytesWritten)
            }
            result.writeSeconds = elapsed(writeStart)
            try check()
            report(.flushing, bytes)
            try check()
            guard selectedDirectoryUnchanged(), scratchNamespaceUnchanged() else { throw DriveBenchmarkFailure.changed }
            let flushStart = DispatchTime.now().uptimeNanoseconds
            result.flush = .failed
            if fcntl(file, F_FULLFSYNC) == 0 { result.flush = .fullSync }
            else {
                result.flushSeconds = elapsed(flushStart)
                try check()
                result.flush = fsync(file) == 0 ? .fileSyncOnly : .failed
            }
            result.flushSeconds = elapsed(flushStart)
            guard result.flush != .failed else { throw DriveBenchmarkFailure.write }
            try check()
            guard let observed = Witness(file), fileWitness?.unchanged(observed.value) == true else {
                throw DriveBenchmarkFailure.changed
            }
            guard lseek(file, 0, SEEK_SET) == 0 else { throw DriveBenchmarkFailure.read }
            report(.reading)
            try check()
            guard selectedDirectoryUnchanged(), scratchNamespaceUnchanged() else { throw DriveBenchmarkFailure.changed }
            let readStart = DispatchTime.now().uptimeNanoseconds
            defer { if result.readSeconds == 0 { result.readSeconds = elapsed(readStart) } }
            for index in readOrder {
                try check()
                let blockOffset = Int64(index * chunk)
                var done = 0, ioSeconds = 0.0
                while done < chunk {
                    try check()
                    let began = DispatchTime.now().uptimeNanoseconds
                    let count = Darwin.pread(file, readBuffer.advanced(by: done), chunk - done, off_t(blockOffset + Int64(done)))
                    ioSeconds += elapsed(began)
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0 else { throw DriveBenchmarkFailure.read }
                    done += count; result.bytesRead += Int64(count)
                }
                readLatencies.append(ioSeconds)
                writeBuffer.storeBytes(of: UInt64(blockOffset), as: UInt64.self)
                guard memcmp(writeBuffer, readBuffer, chunk) == 0 else { throw DriveBenchmarkFailure.verification }
                report(.reading, result.bytesRead)
            }
            result.readSeconds = elapsed(readStart)
            guard let observed = Witness(file), fileWitness?.unchanged(observed.value) == true,
                  onSelectedVolume(observed.value), let observedScratch = Witness(scratch), onSelectedVolume(observedScratch.value),
                  selectedDirectoryUnchanged(), scratchNamespaceUnchanged() else { throw DriveBenchmarkFailure.changed }
            try check()
            result.outcome = .completed
        } catch is CancellationError { result.outcome = .cancelled }
        catch let error as DriveBenchmarkFailure { result.failure = error }
        catch { result.failure = .preparation }

        result.writeLatency = .init(writeLatencies)
        result.readLatency = .init(readLatencies)
        report(.cleaningUp)
        if createdDirectory {
            // Never recursively remove a stage. Unexpected entries, links,
            // changed file metadata, or a renamed namespace preserve it whole.
            var safe = selectedDirectoryUnchanged() && scratchNamespaceUnchanged()
            if safe { safe = hasOnlyOwnedFile(scratch, fileName: file >= 0 ? fileName : nil) }
            if safe && file >= 0 {
                var observed = stat()
                safe = fstatat(scratch, fileName, &observed, AT_SYMLINK_NOFOLLOW) == 0 &&
                    fileWitness?.unchanged(observed) == true && observed.st_nlink == 1 && onSelectedVolume(observed)
                if safe { safe = unlinkat(scratch, fileName, 0) == 0 }
            }
            if safe && scratchNamespaceUnchanged() { safe = unlinkat(parent, scratchName, AT_REMOVEDIR) == 0 }
            else { safe = false }
            if !safe {
                result.scratchURL = recoveryURL(parent: parent, scratch: scratch, directory: directory, name: scratchName)
                if result.outcome == .completed { result.outcome = .failed; result.failure = .cleanup }
                else if result.failure == nil { result.failure = .cleanup }
            }
        }
        // An acknowledged transfer still fails if the file's final close
        // reports an error. A stage already removed has no residue to report.
        // Do not retry close: the descriptor's state after failure is uncertain.
        if file >= 0, Darwin.close(file) != 0, result.outcome == .completed {
            result.outcome = .failed
            result.failure = .close
        }
        if scratch >= 0 { close(scratch) }
        if parent >= 0 { close(parent) }
        return result
    }

    private static func elapsed(_ start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
    }

    private static func localWritableSpace(_ descriptor: Int32) throws -> statfs {
        var space = statfs()
        guard fstatfs(descriptor, &space) == 0, space.f_bsize > 0 else { throw DriveBenchmarkFailure.preparation }
        guard space.f_flags & UInt32(MNT_LOCAL) != 0, space.f_flags & UInt32(MNT_RDONLY) == 0,
              faccessat(descriptor, ".", W_OK | X_OK, AT_EACCESS) == 0 else {
            throw DriveBenchmarkFailure.invalidDirectory
        }
        return space
    }

    private static func hasOnlyOwnedFile(_ descriptor: Int32, fileName: String?) -> Bool {
        let copy = dup(descriptor)
        guard copy >= 0 else { return false }
        guard let directory = fdopendir(copy) else { close(copy); return false }
        defer { closedir(directory) }
        errno = 0
        var found = false
        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            guard name == fileName, !found else { return false }
            found = true
            errno = 0
        }
        return errno == 0 && found == (fileName != nil)
    }

    private static func recoveryURL(parent: Int32, scratch: Int32, directory: URL, name: String) -> URL {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        if scratch >= 0, fcntl(scratch, F_GETPATH, &buffer) == 0 {
            return URL(fileURLWithPath: String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self),
                       isDirectory: true)
        }
        if parent >= 0, fcntl(parent, F_GETPATH, &buffer) == 0 {
            return URL(fileURLWithPath: String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self),
                       isDirectory: true).appendingPathComponent(name)
        }
        return directory.appendingPathComponent(name, isDirectory: true)
    }
}
