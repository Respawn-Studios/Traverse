import CryptoKit
import Darwin
import Foundation

private enum GroupedProductionHarnessFailure: Error { case unsafeFixture, io, bound, apiNotFrozen }

/// Generated-fixture primitives shared by each fresh worker invocation. No AppKit,
/// owner journal, source-body logs, fixture adoption or automatic recovery.
private struct GroupedProductionFixture {
    let root: URL
    var source: URL { root.appendingPathComponent("source", isDirectory: true) }
    var destination: URL { root.appendingPathComponent("destination", isDirectory: true) }
    var journal: URL { root.appendingPathComponent("journal", isDirectory: true) }
    static let marker = ".owned-grouped-production-fixture"
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
    static func directory(_ url: URL) throws {
        guard url.path == url.standardizedFileURL.path, url.resolvingSymlinksInPath().path == url.path else {
            throw GroupedProductionHarnessFailure.unsafeFixture
        }
        var s = stat()
        guard lstat(url.path, &s) == 0, s.st_mode & S_IFMT == S_IFDIR, s.st_uid == geteuid(), s.st_mode & 0o077 == 0 else {
            throw GroupedProductionHarnessFailure.unsafeFixture
        }
    }
    static func createDirectory(_ url: URL) throws {
        try directory(url.deletingLastPathComponent())
        guard mkdir(url.path, 0o700) == 0 else { throw GroupedProductionHarnessFailure.unsafeFixture }
        try directory(url)
    }
    static func read(_ url: URL, maximum: Int = 16_777_216) throws -> Data {
        try directory(url.deletingLastPathComponent())
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw GroupedProductionHarnessFailure.unsafeFixture }
        defer { close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG, before.st_uid == geteuid(),
              before.st_nlink == 1, before.st_mode & 0o077 == 0, before.st_size >= 0, before.st_size <= maximum else {
            throw GroupedProductionHarnessFailure.bound
        }
        var output = Data(), buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            guard count >= 0 else { throw GroupedProductionHarnessFailure.io }
            if count == 0 { break }
            guard output.count + count <= maximum else { throw GroupedProductionHarnessFailure.bound }
            output.append(contentsOf: buffer.prefix(count))
        }
        var after = stat()
        guard fstat(fd, &after) == 0, before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              before.st_size == after.st_size, before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else { throw GroupedProductionHarnessFailure.unsafeFixture }
        return output
    }
    static func write(_ data: Data, to url: URL) throws {
        try directory(url.deletingLastPathComponent())
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw GroupedProductionHarnessFailure.unsafeFixture }
        defer { close(fd) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                guard count > 0 else { throw GroupedProductionHarnessFailure.io }
                offset += count
            }
        }
        guard fsync(fd) == 0 else { throw GroupedProductionHarnessFailure.io }
    }
    init(_ argument: String, create: Bool = false) throws {
        let run = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        guard ProcessInfo.processInfo.environment["MAC_EXPLORER_GROUPED_PRODUCTION_RUN_ROOT"] == run.path,
              UUID(uuidString: run.lastPathComponent) != nil,
              run.deletingLastPathComponent().lastPathComponent == "grouped-copy-production",
              run.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == ".build" else {
            throw GroupedProductionHarnessFailure.unsafeFixture
        }
        try Self.directory(run)
        guard try Self.read(run.appendingPathComponent(".qualification-owner"), maximum: 256) ==
                Data("MacExplorer grouped production qualification v1\n\(run.lastPathComponent)\n".utf8) else {
            throw GroupedProductionHarnessFailure.unsafeFixture
        }
        let fixtures = run.appendingPathComponent("fixtures", isDirectory: true)
        try Self.directory(fixtures)
        let candidate = URL(fileURLWithPath: argument, isDirectory: true)
        guard candidate.path == argument, candidate.deletingLastPathComponent().path == fixtures.path,
              candidate.lastPathComponent.hasPrefix("copy-"),
              UUID(uuidString: String(candidate.lastPathComponent.dropFirst(5))) != nil else {
            throw GroupedProductionHarnessFailure.unsafeFixture
        }
        let token = Data("MacExplorer generated grouped production fixture v1\n\(candidate.lastPathComponent)\n".utf8)
        if create { try Self.createDirectory(candidate); try Self.write(token, to: candidate.appendingPathComponent(Self.marker)) }
        try Self.directory(candidate)
        guard try Self.read(candidate.appendingPathComponent(Self.marker), maximum: 256) == token else {
            throw GroupedProductionHarnessFailure.unsafeFixture
        }
        root = candidate
    }
    static func eachName(in fd: Int32, maximum: Int, _ body: (String) throws -> Void) throws {
        let cursorFD = openat(fd, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard cursorFD >= 0 else { throw GroupedProductionHarnessFailure.io }
        guard let cursor = fdopendir(cursorFD) else { close(cursorFD); throw GroupedProductionHarnessFailure.io }
        defer { closedir(cursor) }
        var count = 0
        while true {
            errno = 0
            guard let entry = readdir(cursor) else { guard errno == 0 else { throw GroupedProductionHarnessFailure.io }; return }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(validatingCString: $0) }
            }
            guard let name else { throw GroupedProductionHarnessFailure.unsafeFixture }
            if name == "." || name == ".." { continue }
            count += 1
            guard count <= maximum else { throw GroupedProductionHarnessFailure.bound }
            try body(name)
        }
    }
    static func fingerprint(_ root: URL) throws -> String {
        var rows: [String] = [], nodes = 0, total = 0
        func walk(_ url: URL, relative: String, depth: Int) throws {
            nodes += 1
            guard nodes <= 512, depth <= 16 else { throw GroupedProductionHarnessFailure.bound }
            var s = stat()
            guard lstat(url.path, &s) == 0, s.st_uid == geteuid(), s.st_mode & 0o077 == 0 else {
                throw GroupedProductionHarnessFailure.unsafeFixture
            }
            let kind = s.st_mode & S_IFMT
            guard kind == S_IFDIR || kind == S_IFREG else { throw GroupedProductionHarnessFailure.unsafeFixture }
            rows.append("\(relative)|\(s.st_dev)|\(s.st_ino)|\(s.st_mode)|\(s.st_size)|\(s.st_mtimespec.tv_sec)|\(s.st_mtimespec.tv_nsec)")
            if kind == S_IFDIR {
                try directory(url)
                let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard fd >= 0 else { throw GroupedProductionHarnessFailure.io }
                defer { close(fd) }
                var names: [String] = []
                try eachName(in: fd, maximum: 512) { names.append($0) }
                for name in names.sorted() { try walk(url.appendingPathComponent(name), relative: relative + "/" + name, depth: depth + 1) }
            } else {
                let data = try read(url); total += data.count
                guard total <= 67_108_864 else { throw GroupedProductionHarnessFailure.bound }
                rows.append(digest(data))
            }
        }
        try walk(root, relative: "", depth: 0)
        return digest(Data(rows.joined(separator: "\n").utf8))
    }
    static func inputName(_ ordinal: Int) -> String { ordinal % 2 == 0 ? "Case-\(ordinal).txt" : "caf\u{00E9}-\(ordinal).txt" }
    func requireJournalAbsent() throws {
        var info = stat()
        errno = 0
        let status = lstat(journal.path, &info), savedErrno = errno
        // Production owns exclusive journal creation and its owner marker. A
        // precreated unmarked directory would exercise a different refusal path.
        guard status == -1, savedErrno == ENOENT else { throw GroupedProductionHarnessFailure.unsafeFixture }
    }
    // Admission-only generated topology observations. Read no file bodies and
    // follow no symlink; ordinary engine execution is deliberately not invoked.
    static func metadataFingerprint(_ root: URL) throws -> String {
        var rows: [String] = [], nodes = 0
        func walk(_ url: URL, relative: String, depth: Int) throws {
            nodes += 1
            guard nodes <= 512, depth <= 16 else { throw GroupedProductionHarnessFailure.bound }
            var info = stat()
            guard lstat(url.path, &info) == 0, info.st_uid == geteuid() else { throw GroupedProductionHarnessFailure.unsafeFixture }
            let kind = info.st_mode & S_IFMT
            guard [S_IFDIR, S_IFREG, S_IFLNK].contains(kind), kind == S_IFLNK || info.st_mode & 0o077 == 0 else {
                throw GroupedProductionHarnessFailure.unsafeFixture
            }
            rows.append("\(relative)|\(info.st_dev)|\(info.st_ino)|\(info.st_nlink)|\(info.st_mode)|\(info.st_size)|\(info.st_mtimespec.tv_sec)|\(info.st_mtimespec.tv_nsec)")
            if kind == S_IFDIR {
                try directory(url)
                let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard fd >= 0 else { throw GroupedProductionHarnessFailure.io }
                defer { close(fd) }
                var names: [String] = []
                try eachName(in: fd, maximum: 512) { names.append($0) }
                for name in names.sorted() { try walk(url.appendingPathComponent(name), relative: relative + "/" + name, depth: depth + 1) }
            }
        }
        try walk(root, relative: "", depth: 0)
        return digest(Data(rows.joined(separator: "\n").utf8))
    }
    func seed(count: Int) throws {
        guard [1, 16, 17, 31, 33].contains(count) else { throw GroupedProductionHarnessFailure.bound }
        try Self.createDirectory(source); try Self.createDirectory(destination)
        try Self.write(GroupedCopyQualification.marker, to: root.appendingPathComponent(GroupedCopyQualification.markerName))
        for ordinal in 0..<count {
            try Self.write(Data(repeating: UInt8(ordinal), count: ordinal == 0 ? 0 : 4096),
                to: source.appendingPathComponent(Self.inputName(ordinal)))
        }
        try requireJournalAbsent()
        let manifest = ["count": String(count), "sourceFingerprint": try Self.fingerprint(source),
                        "emptyDestinationFingerprint": try Self.fingerprint(destination)]
        try Self.write(Self.encode(manifest), to: root.appendingPathComponent("seed.json"))
    }
    func seedManifest() throws -> [String: String] {
        try JSONDecoder().decode([String: String].self, from: Self.read(root.appendingPathComponent("seed.json"), maximum: 16_384))
    }
}

/// Constant diagnostic labels may cross the asynchronous executor boundary.
/// A locked Sendable value avoids sharing a main-actor closure with worker work.
private final class ProductionDiagnosticStage: @unchecked Sendable {
    private let lock = NSLock()
    private var label: String
    init(_ label: String = "validate_arguments") { self.label = label }
    func set(_ next: String) { lock.lock(); label = next; lock.unlock() }
    var value: String { lock.lock(); defer { lock.unlock() }; return label }
}

private struct ProductionCheckpointReceipt: Codable, Sendable {
    let stage: String
    let jobID: UUID
    let recordID: UUID
    let group: Int?
    let member: Int?
}
private final class ProductionFaultGate: @unchecked Sendable {
    private let lock = NSLock()
    let mechanism: String
    let target: GroupedCopyCheckpointStage?
    let group: Int?
    let member: Int?
    private var events: [ProductionCheckpointReceipt] = []
    private var reached = false
    private var acknowledgementArmed = false
    private var acknowledgementLost = false
    private var sqliteCodes = Set<Int32>()
    init(mechanism: String, target: GroupedCopyCheckpointStage?, group: Int?, member: Int?) {
        self.mechanism = mechanism; self.target = target; self.group = group; self.member = member
    }
    func checkpoint(_ event: GroupedCopyCheckpoint, cancellation: OperationCancellation) throws {
        let receipt = ProductionCheckpointReceipt(stage: event.stage.rawValue, jobID: event.jobID,
            recordID: event.recordID, group: event.groupOrdinal, member: event.memberOrdinal)
        lock.lock()
        guard events.count < 512 else { lock.unlock(); throw GroupedProductionHarnessFailure.bound }
        events.append(receipt)
        let hit = !reached && event.stage == target && (group == nil || event.groupOrdinal == group) &&
            (member == nil || event.memberOrdinal == member)
        if hit { reached = true; acknowledgementArmed = mechanism == "lost_acknowledgement" }
        lock.unlock()
        guard hit else { return }
        switch mechanism {
        case "cooperative_stop": cancellation.cancel()
        case "injected_error": throw FileOperationFailure.ioFailure
        case "process_crash":
            try GroupedCopyProductionWorker.emit(["pid": getpid(), "mechanism": mechanism, "targetReached": true,
                "recordID": event.recordID.uuidString, "jobID": event.jobID.uuidString,
                "checkpoint": event.stage.rawValue, "group": event.groupOrdinal.map { $0 as Any } ?? NSNull(),
                "member": event.memberOrdinal.map { $0 as Any } ?? NSNull(), "termination": "_exit(86)"])
            _exit(86)
        case "lost_acknowledgement": break
        default: throw GroupedProductionHarnessFailure.unsafeFixture
        }
    }
    func afterCommit() throws {
        lock.lock()
        let fire = acknowledgementArmed
        if fire { acknowledgementArmed = false; acknowledgementLost = true }
        lock.unlock()
        if fire { throw FileOperationFailure.ioFailure }
    }
    func observedSQLite(_ code: Int32) { lock.lock(); sqliteCodes.insert(code); lock.unlock() }
    func snapshot() -> (events: [ProductionCheckpointReceipt], reached: Bool, acknowledgementLost: Bool, sqliteCodes: [Int32]) {
        lock.lock(); defer { lock.unlock() }
        return (events, reached, acknowledgementLost, sqliteCodes.sorted())
    }
}

@main private enum GroupedCopyProductionWorker {
    static func emit(_ value: [String: Any]) throws {
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]))
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
    static func main() async {
        let stage = ProductionDiagnosticStage()
        do { try await execute(stage: stage) }
        catch {
            try? emit(["pid": getpid(), "failed": true, "stage": stage.value,
                       "failureKind": error is GroupedProductionHarnessFailure ? "harness_failure" : "production_failure"])
            exit(1)
        }
    }
    static func execute(stage: ProductionDiagnosticStage) async throws {
        let args = CommandLine.arguments
        guard args.count >= 3 else { throw GroupedProductionHarnessFailure.unsafeFixture }
        switch args[1] {
        case "seed":
            stage.set("fixture_seed")
            guard args.count == 4, let count = Int(args[3]) else { throw GroupedProductionHarnessFailure.unsafeFixture }
            let fixture = try GroupedProductionFixture(args[2], create: true)
            try fixture.seed(count: count)
            try emit(["pid": getpid(), "seeded": true, "members": count])
        case "inspect-fixture":
            stage.set("fixture_inspection")
            guard args.count == 3 else { throw GroupedProductionHarnessFailure.unsafeFixture }
            let fixture = try GroupedProductionFixture(args[2])
            let manifest = try fixture.seedManifest()
            try emit(["pid": getpid(), "sourceUnchanged": try GroupedProductionFixture.fingerprint(fixture.source) == manifest["sourceFingerprint"],
                      "destinationFingerprint": try GroupedProductionFixture.fingerprint(fixture.destination)])
        case "forward":
            guard args.count == 9, let policy = TransferMetadataPolicy(rawValue: args[3]),
                  ["none", "cooperative_stop", "injected_error", "process_crash", "lost_acknowledgement", "sqlite_full"].contains(args[7]) else {
                throw GroupedProductionHarnessFailure.unsafeFixture
            }
            let target = args[4] == "none" ? nil : GroupedCopyCheckpointStage(rawValue: args[4])
            let group = args[5] == "-" ? nil : Int(args[5]), member = args[6] == "-" ? nil : Int(args[6])
            let pages = args[8] == "-" ? nil : Int64(args[8])
            guard (["none", "sqlite_full"].contains(args[7]) && target == nil) || (!["none", "sqlite_full"].contains(args[7]) && target != nil),
                  args[5] == "-" || (group != nil && (0..<3).contains(group!)),
                  args[6] == "-" || (member != nil && (0..<33).contains(member!)) else { throw GroupedProductionHarnessFailure.unsafeFixture }
            guard args[7] == "sqlite_full" ? (pages != nil && (1...256).contains(pages!)) : pages == nil else {
                throw GroupedProductionHarnessFailure.unsafeFixture
            }
            if args[7] == "lost_acknowledgement" {
                guard [.manifestWillCommit, .groupWillDeclare, .groupWillSeal, .groupWillRecordOutcomes, .terminalWillCommit].contains(target!) else {
                    throw GroupedProductionHarnessFailure.unsafeFixture
                }
            }
            stage.set("production_prepare")
            let fixture = try GroupedProductionFixture(args[2])
            try await forward(fixture, policy: policy, gate: ProductionFaultGate(mechanism: args[7], target: target, group: group, member: member), maximumPages: pages, stage: stage)
        case "cold-inspect":
            guard args.count == 4, args[3] == "-" || UUID(uuidString: args[3]) != nil else { throw GroupedProductionHarnessFailure.unsafeFixture }
            stage.set("production_cold_inspect")
            try coldInspect(GroupedProductionFixture(args[2]), recordID: UUID(uuidString: args[3]))
        case "admission":
            guard args.count == 4, ["folder", "symlink", "hardlink", "conflict", "duplicate"].contains(args[3]) else {
                throw GroupedProductionHarnessFailure.unsafeFixture
            }
            stage.set("production_admission")
            try await admission(GroupedProductionFixture(args[2]), variant: args[3])
        default:
            stage.set("production_api_not_frozen")
            throw GroupedProductionHarnessFailure.apiNotFrozen
        }
    }
    static func admission(_ fixture: GroupedProductionFixture, variant: String) async throws {
        let original = fixture.source.appendingPathComponent(GroupedProductionFixture.inputName(0))
        var inputs = [original]
        switch variant {
        case "folder":
            let folder = fixture.source.appendingPathComponent("generated-folder", isDirectory: true)
            try GroupedProductionFixture.createDirectory(folder); inputs = [folder]
        case "symlink":
            let alias = fixture.source.appendingPathComponent("generated-link")
            guard symlink(original.lastPathComponent, alias.path) == 0 else { throw GroupedProductionHarnessFailure.io }
            inputs = [alias]
        case "hardlink":
            guard link(original.path, fixture.source.appendingPathComponent("generated-hardlink").path) == 0 else { throw GroupedProductionHarnessFailure.io }
        case "conflict":
            try GroupedProductionFixture.write(Data("generated conflict".utf8), to: fixture.destination.appendingPathComponent(original.lastPathComponent))
        case "duplicate": inputs = [original, original]
        default: throw GroupedProductionHarnessFailure.unsafeFixture
        }
        let before = try GroupedProductionFixture.metadataFingerprint(fixture.root)
        var hooks = RecoveryHooks()
        hooks.groupedCopy.qualification = try GroupedCopyQualification(root: fixture.root)
        let engine = RecoverableFileOperations(journalDirectory: fixture.journal, hooks: hooks)
        let route: String
        do {
            let plan = try await engine.prepareTransfer(sources: inputs, destinationDirectory: fixture.destination, move: false)
            guard plan.groupedCopy == nil, variant != "conflict" || !plan.conflicts.isEmpty else {
                throw GroupedProductionHarnessFailure.unsafeFixture
            }
            route = "ordinary_plan"
        } catch let error as FileOperationFailure {
            guard [.invalidRequest, .unsupported, .recoveryUncertain].contains(error), variant != "conflict" else { throw error }
            route = "refused_" + error.rawValue
        }
        guard before == (try GroupedProductionFixture.metadataFingerprint(fixture.root)) else { throw FileOperationFailure.recoveryUncertain }
        try fixture.requireJournalAbsent()
        try emit(["pid": getpid(), "variant": variant, "route": route, "groupedSelected": false,
                  "namespaceUnchanged": true, "journalCreated": false, "executionPerformed": false])
    }
    static func forward(_ fixture: GroupedProductionFixture, policy: TransferMetadataPolicy,
                        gate: ProductionFaultGate, maximumPages: Int64?, stage: ProductionDiagnosticStage) async throws {
        let manifest = try fixture.seedManifest()
        guard let text = manifest["count"], let count = Int(text), [1, 16, 17, 31, 33].contains(count),
              try GroupedProductionFixture.fingerprint(fixture.source) == manifest["sourceFingerprint"],
              try GroupedProductionFixture.fingerprint(fixture.destination) == manifest["emptyDestinationFingerprint"] else {
            throw GroupedProductionHarnessFailure.unsafeFixture
        }
        try fixture.requireJournalAbsent()
        var hooks = RecoveryHooks()
        hooks.groupedCopy = GroupedCopyHooks(qualification: try GroupedCopyQualification(root: fixture.root),
            checkpoint: { try gate.checkpoint($0, cancellation: $1) })
        hooks.journalHooks.afterCommitBeforeAcknowledgement = { try gate.afterCommit() }
        hooks.journalHooks.maximumPageCount = maximumPages
        hooks.journalHooks.observedSQLiteFailureCode = { gate.observedSQLite($0) }
        let engine = RecoverableFileOperations(journalDirectory: fixture.journal, hooks: hooks)
        let inputs = (0..<count).map { fixture.source.appendingPathComponent(GroupedProductionFixture.inputName($0)) }
        let plan = try await engine.prepareTransfer(sources: inputs, destinationDirectory: fixture.destination, move: false, metadataPolicy: policy)
        guard plan.groupedCopy != nil, plan.conflicts.isEmpty else { throw FileOperationFailure.unsupported }
        stage.set("production_perform")
        let result = await engine.perform(plan)
        let captured = gate.snapshot()
        guard ["none", "sqlite_full"].contains(gate.mechanism) || captured.reached,
              gate.mechanism != "lost_acknowledgement" || captured.acknowledgementLost,
              try GroupedProductionFixture.fingerprint(fixture.source) == manifest["sourceFingerprint"] else {
            throw GroupedProductionHarnessFailure.unsafeFixture
        }
        if gate.mechanism == "sqlite_full" {
            guard captured.sqliteCodes.contains(where: { $0 & 0xff == 13 }) else { throw GroupedProductionHarnessFailure.unsafeFixture }
        }
        let events = try JSONSerialization.jsonObject(with: GroupedProductionFixture.encode(captured.events))
        let failures = result.result.items.compactMap { item -> String? in
            if case .failed(let failure) = item.status { return failure.rawValue }; return nil
        }
        stage.set("production_result_receipt")
        try emit(["pid": getpid(), "mechanism": gate.mechanism, "targetReached": captured.reached,
                  "acknowledgementLost": captured.acknowledgementLost, "recordID": result.recordID.map { $0.uuidString as Any } ?? NSNull(),
                  "jobID": plan.jobID.uuidString, "disposition": result.result.disposition.rawValue,
                  "cancellationRequested": result.result.cancellationRequested,
                  "reportedSucceeded": result.result.items.filter { $0.role == .transfer && $0.status == .succeeded }.count,
                  "failureCodes": failures, "checkpoints": events, "sourceUnchanged": true,
                  "observedSQLiteFailureCodes": captured.sqliteCodes,
                  "genuineSQLiteFullObserved": captured.sqliteCodes.contains(where: { $0 & 0xff == 13 }),
                  "realProductionEngine": true])
    }
    static func coldInspect(_ fixture: GroupedProductionFixture, recordID: UUID?) throws {
        let manifest = try fixture.seedManifest()
        guard try GroupedProductionFixture.fingerprint(fixture.source) == manifest["sourceFingerprint"] else {
            throw GroupedProductionHarnessFailure.unsafeFixture
        }
        let before = try GroupedProductionFixture.fingerprint(fixture.destination)
        var journalInfo = stat()
        if lstat(fixture.journal.path, &journalInfo) != 0 {
            guard errno == ENOENT else { throw GroupedProductionHarnessFailure.unsafeFixture }
            try emit(["pid": getpid(), "recordStatus": "no_journal", "sourceUnchanged": true,
                      "destinationFingerprint": before, "noForwardAutoAction": true])
            return
        }
        let journal = try OperationJournal(fixture.journal)
        let id: UUID?
        if let recordID { id = recordID }
        else {
            let page = try journal.inspectSummaries(limit: 2)
            guard page.refused.isEmpty, page.next == nil, page.records.count <= 1 else { throw FileOperationFailure.recoveryUncertain }
            id = page.records.first?.id
        }
        guard let id, let catalog = try journal.inspectCatalogRecord(id) else {
            guard before == (try GroupedProductionFixture.fingerprint(fixture.destination)) else { throw FileOperationFailure.recoveryUncertain }
            try emit(["pid": getpid(), "recordStatus": "missing", "sourceUnchanged": true,
                      "destinationFingerprint": before, "noForwardAutoAction": true])
            return
        }
        guard case .groupedCopyV1(let record) = catalog else { throw FileOperationFailure.recoveryUncertain }
        let inventory = try GroupedCopyFilesystemEvidence.inspect(record, cancellation: OperationCancellation())
        var rows: [[String: Any]] = [], counts: [String: Int] = [:]
        for member in record.members {
            let observed = inventory.members[member.ordinal], phase = member.progress.phase
            let classification: String
            switch observed.publicSlot {
            case .verified(let tree, _):
                if let seal = member.progress.seal, seal.proof.payload.matches(tree) {
                    classification = member.progress.publication == nil ? "uncommitted_public" : "confirmed_public"
                    let source = CopyComparison(), destination = CopyComparison()
                    _ = try verifiedTree(member.manifest.source.url, cancellation: OperationCancellation(), copyComparison: source)
                    _ = try verifiedTree(member.manifest.destination.url, cancellation: OperationCancellation(), copyComparison: destination)
                    guard source.contentDigest == destination.contentDigest, source.metadataDigest == destination.metadataDigest,
                          record.head.metadataPolicy == .destinationOwnership || source.ownershipDigest == destination.ownershipDigest else {
                        throw FileOperationFailure.copyMetadataMismatch
                    }
                } else { classification = "protected_changed" }
            case .absent:
                if phase == "notDeclared" { classification = "never_declared" }
                else if phase == "neverStaged" { classification = "never_staged" }
                else if case .verified(let tree, _)? = observed.privateSlot, let seal = member.progress.seal, seal.proof.payload.matches(tree) {
                    classification = "sealed_private"
                } else { classification = "protected_unsealed" }
            case .occupied: classification = "protected_occupied"
            case .unavailable: classification = "protected_unavailable"
            }
            counts[classification, default: 0] += 1
            rows.append(["ordinal": member.ordinal, "phase": phase, "classification": classification])
        }
        guard before == (try GroupedProductionFixture.fingerprint(fixture.destination)),
              try GroupedProductionFixture.fingerprint(fixture.source) == manifest["sourceFingerprint"] else {
            throw FileOperationFailure.recoveryUncertain
        }
        try emit(["pid": getpid(), "recordStatus": "grouped", "recordID": id.uuidString,
                  "state": record.head.state.rawValue, "revision": record.head.revision, "groups": record.groups.map { $0.members },
                  "members": rows, "classificationCounts": counts, "inventoryDigest": inventory.inventoryDigest,
                  "destinationFingerprint": before, "sourceUnchanged": true, "noForwardAutoAction": true,
                  "undoInvalidated": record.head.undoInvalidated])
    }
}
