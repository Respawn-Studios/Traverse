#if DEBUG && !TRAVERSE_NETWORK_QUALIFICATION
import AppKit
import CryptoKit
import Darwin
import FileOperations

private final class RenameProfilePhases: @unchecked Sendable {
    private let lock = NSLock()
    private var phase: OperationProgressPhase?
    private var time: TimeInterval?
    private var durations: [String: Double] = [:]
    private var callbacks = 0

    func observe(_ update: OperationProgress) {
        let now = ProcessInfo.processInfo.systemUptime
        lock.withLock {
            if let phase, let time { durations[phase.rawValue, default: 0] += now - time }
            phase = update.phase; time = now; callbacks += 1
        }
    }

    var summary: [String: Any] { lock.withLock { ["phaseSeconds": durations, "callbacks": callbacks] } }
}

@MainActor
extension RenameWorkflowVerification {
    /// No windows, clipboard, owner files or production operation shortcuts.
    /// Public progress is coalesced; these are observed phase boundaries rather
    /// than exact syscall/hash timers. All durable engine checks remain enabled.
    static func profile(in testRoot: URL, output: URL) async throws -> [String] {
        guard let declared = ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"],
              testRoot.standardizedFileURL == URL(fileURLWithPath: declared, isDirectory: true).standardizedFileURL,
              testRoot.standardizedFileURL == testRoot.resolvingSymlinksInPath().standardizedFileURL else {
            throw UIVerification.Failure(message: "Rename profiling requires its unredirected generated fixture root")
        }
        let owned = testRoot.appendingPathComponent("rename-profile-\(UUID().uuidString)", isDirectory: true)
        let fixtures = try await Task.detached {
            let manager = FileManager()
            try manager.createDirectory(at: owned, withIntermediateDirectories: false)
            try Data("mac-explorer-rename-profile-v1".utf8).write(to: owned.appendingPathComponent(".fixture-owner"), options: .withoutOverwriting)
            var fixtures: [(URL, URL, URL, Int, Bool, String)] = []
            let block = Data(repeating: 0x51, count: 1_048_576)
            for megabytes in [0, 32, 128] {
                for directory in [false, true] {
                    let root = owned.appendingPathComponent("\(megabytes)-\(directory ? "folder" : "file")", isDirectory: true)
                    try manager.createDirectory(at: root, withIntermediateDirectories: false)
                    let source = root.appendingPathComponent("original")
                    if directory { try manager.createDirectory(at: source, withIntermediateDirectories: false) }
                    let rawParent = root.appendingPathComponent("syscall-only", isDirectory: true)
                    try manager.createDirectory(at: rawParent, withIntermediateDirectories: false)
                    let rawSource = rawParent.appendingPathComponent("original")
                    if directory { try manager.createDirectory(at: rawSource, withIntermediateDirectories: false) }
                    var hasher = SHA256()
                    for _ in 0..<megabytes { hasher.update(data: block) }
                    for input in [source, rawSource] {
                        let payload = directory ? input.appendingPathComponent("generated.bin") : input
                        try Data().write(to: payload, options: .withoutOverwriting)
                        let file = try FileHandle(forWritingTo: payload)
                        defer { try? file.close() }
                        for _ in 0..<megabytes { try file.write(contentsOf: block) }
                        try file.synchronize()
                    }
                    fixtures.append((root, source, rawSource, megabytes * 1_048_576, directory, String(describing: hasher.finalize())))
                }
            }
            return fixtures
        }.value
        var measurements: [[String: Any]] = []
        for (root, initial, rawInitial, bytes, directory, expectedDigest) in fixtures {
            let engine = RecoverableFileOperations(journalDirectory: root.appendingPathComponent("journal", isDirectory: true))
            var source = initial
            for index in 0..<3 {
                let destinationName = index.isMultiple(of: 2) ? "renamed" : "original"
                let phases = RenameProfilePhases()
                let admissionStarted = ProcessInfo.processInfo.systemUptime
                let observation = try await engine.observeSelection([source])
                let started = ProcessInfo.processInfo.systemUptime
                let outcome = await engine.perform(.rename(source: source, name: destinationName), observing: observation,
                                                   progress: { phases.observe($0) })
                let ended = ProcessInfo.processInfo.systemUptime
                try UIVerification.require(outcome.result.disposition == .succeeded && outcome.recordID != nil,
                                           "Generated rename profile did not commit a recoverable result")
                source = root.appendingPathComponent(destinationName)
                measurements.append(["kind": directory ? "folder" : "file", "logicalPayloadBytes": bytes, "sample": index + 1,
                                     "admissionMilliseconds": (started - admissionStarted) * 1000,
                                     "recoverableEngineMilliseconds": (ended - started) * 1000,
                                     "observedProgress": phases.summary, "recordCommitted": true])
            }
            let final = source
            let rawSamples = try await Task.detached {
                var rawSource = rawInitial
                var times: [Double] = []
                let parent = rawInitial.deletingLastPathComponent()
                for index in 0..<3 {
                    let destination = parent.appendingPathComponent(index.isMultiple(of: 2) ? "renamed" : "original")
                    let sourcePath = rawSource.path, destinationPath = destination.path
                    var before = stat(), after = stat()
                    guard lstat(sourcePath, &before) == 0 else { throw POSIXError(.EIO) }
                    let started = ProcessInfo.processInfo.systemUptime
                    let result = sourcePath.withCString { from in
                        destinationPath.withCString { to in renameatx_np(AT_FDCWD, from, AT_FDCWD, to, UInt32(RENAME_EXCL)) }
                    }
                    let ended = ProcessInfo.processInfo.systemUptime
                    guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                    guard lstat(destinationPath, &after) == 0 && before.st_dev == after.st_dev && before.st_ino == after.st_ino
                        && before.st_mode == after.st_mode else { throw POSIXError(.EIO) }
                    times.append((ended - started) * 1000)
                    rawSource = destination
                }
                return times
            }.value
            for (index, time) in rawSamples.enumerated() {
                measurements.append(["kind": directory ? "folder" : "file", "logicalPayloadBytes": bytes, "sample": index + 1,
                                     "syscallOnlyMilliseconds": time, "recordCommitted": false,
                                     "diagnosticOnly": "Separate generated fixture; exclusive native rename only, with no journal, fsync or integrity guards. Never a production operation path."])
            }
            let valid = try await Task.detached {
                let rawFinal = rawInitial.deletingLastPathComponent().appendingPathComponent("renamed")
                for input in [final, rawFinal] {
                    let payload = directory ? input.appendingPathComponent("generated.bin") : input
                    let file = try FileHandle(forReadingFrom: payload)
                    defer { try? file.close() }
                    var hasher = SHA256()
                    while let block = try file.read(upToCount: 1_048_576), !block.isEmpty { hasher.update(data: block) }
                    guard String(describing: hasher.finalize()) == expectedDigest else { return false }
                }
                return !FileManager().fileExists(atPath: initial.path) && !FileManager().fileExists(atPath: rawInitial.path)
            }.value
            try UIVerification.require(valid, "Generated rename profile payload changed")
            let records = try await engine.recoveryRecords()
            try UIVerification.require(records.records.count == 3 && records.records.allSatisfy { $0.state == "committed" },
                                       "Generated rename profile lost durable history")
        }
        let data = try JSONSerialization.data(withJSONObject: ["passed": true, "mode": "no-ui-public-recoverable-engine",
            "samples": measurements, "sampleCount": measurements.count,
            "limitations": "Debug native app; three serial samples per generated file/folder size and operation path; caches uncontrolled; public progress coalesced and not exact syscall or hash timing. Recoverable engine keeps every integrity guard and durable save. Separate syscall-only fixture has no recovery or durability guarantee and is not production behavior. No native sheet or browser relisting is timed."], options: [.prettyPrinted, .sortedKeys])
        try await Task.detached { try data.write(to: output.appendingPathComponent("rename-performance.json"), options: .withoutOverwriting) }.value
        return ["Generated0/32/128MiB file and folder renames profiled through the unchanged recoverable engine, three serial samples each, with separately owned syscall-only comparison; all payloads and18 durable engine records verified"]
    }
}
#endif
