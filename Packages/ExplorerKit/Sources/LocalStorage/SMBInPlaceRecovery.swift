import CryptoKit
import Darwin
import FileOperations
import Foundation

@_spi(Qualification) public struct SMBInPlaceRecoveryPresentation: Sendable, CustomDebugStringConvertible {
    public let fileName: String, server: String, account: String
    public var debugDescription: String { "<retained SMB presentation>" }
    init(_ record: SMBInPlaceRecord) {
        func display(_ input: String, limit: Int, fallback: String) -> String {
            let clean = String(input.unicodeScalars.filter {
                !CharacterSet.controlCharacters.contains($0)
                    && !(0x202A...0x202E).contains($0.value)
                    && !(0x2066...0x2069).contains($0.value)
            })
            guard !clean.isEmpty else { return fallback }
            return String(clean.prefix(limit)) + (clean.count > limit ? "…" : "")
        }
        fileName = display(record.fileName, limit: 160, fallback: "File name unavailable")
        server = display(record.server, limit: 300, fallback: "Server unavailable")
        account = display(record.account, limit: 256, fallback: "Account unavailable")
    }
}
@_spi(Qualification) public final class SMBInPlaceRecoveryChoice: Sendable, CustomDebugStringConvertible {
    public let presentation: SMBInPlaceRecoveryPresentation
    public let availableVersions: [SMBInPlaceRecoveryVersion] = [.before, .edited]
    public let outcome: SMBInPlaceRecoveryOutcome, capturedEditorGeneration: UUID
    fileprivate let record: SMBInPlaceRecord, layout: SMBInPlaceLayout, journalRevision: UInt64
    private let reader: SMBInPlaceRecoveryReadOwner?
    public var debugDescription: String { "<opaque retained SMB recovery choice>" }
    init(record: SMBInPlaceRecord, layout: SMBInPlaceLayout, journalRevision: UInt64,
         reader: SMBInPlaceRecoveryReadOwner?) {
        self.record = record; self.layout = layout; self.journalRevision = journalRevision; self.reader = reader
        capturedEditorGeneration = record.editorGeneration; presentation = .init(record)
        switch record.outcome {
        case .verified: outcome = .verified
        case .notStarted: outcome = .notStarted
        default: outcome = .needsReview
        }
    }
    public func readVersion(_ version: SMBInPlaceRecoveryVersion) async throws -> TextDocumentValue {
        if let reader { return try await reader.read(self, version: version) }
        let view = try await readPinnedVersion(version)
        let contents = view.contents
        guard await view.closeAndDrain() else { throw SMBTextFailure.reviewRequired }
        return contents
    }
    public func readPinnedVersion(_ version: SMBInPlaceRecoveryVersion) async throws -> SMBInPlaceViewedVersion {
        if let reader { return try await reader.readPinned(self, version: version) }
        return try await readPinnedDirect(version)
    }
    fileprivate func readPinnedDirect(_ version: SMBInPlaceRecoveryVersion) async throws -> SMBInPlaceViewedVersion {
        let current = try await SMBInPlaceJournal(layout: layout).inspect()
        guard current.revision == journalRevision,
              current.records.contains(record) else { throw RemoteSettingsFailure.staleRevision }
        let reference = version == .before ? record.before : record.edited
        let pin = try await SMBInPlaceColdBody.open(layout: layout, reference: reference)
        do { return .init(contents: try await pin.read(), pin: pin) }
        catch { _ = await pin.closeAndDrain(); throw error }
    }
}
@_spi(Qualification) public final class SMBInPlaceViewedVersion: Sendable {
    public let contents: TextDocumentValue
    private let pin: SMBInPlaceColdBody
    fileprivate init(contents: TextDocumentValue, pin: SMBInPlaceColdBody) {
        self.contents = contents; self.pin = pin
    }
    public func closeAndDrain() async -> Bool { await pin.closeAndDrain() }
}
/// Explicit cold local read. The journal must mint the reference; no caller
/// can supply a path or ID, and no network handle is opened.
private final class SMBInPlaceColdBody: @unchecked Sendable {
    private let layout: SMBInPlaceLayout, reference: SMBInPlaceBodyReference
    private let executor = DownloadExecutor(), state = NSLock()
    private let pool: Int32, folder: Int32, lease: Int32, payload: Int32
    private let workspace: ConnectionWorkspaceRecordLease?
    private let record: DownloadDisk.Record, stamp: DownloadDisk.Stamp
    private var closed = false, closeConfirmed: Bool?
    private init(layout: SMBInPlaceLayout, reference: SMBInPlaceBodyReference) throws {
        guard !Thread.isMainThread else { throw SMBTextFailure.busy }
        try reference.validate()
        var keep = false
        let workspace = try layout.storage.beginWorkspaceTransaction()
        do { try workspace?.validateCurrent() }
        catch { workspace?.close(); throw error }
        defer { if !keep { workspace?.close() } }
        guard let pool = try SMBCatalogFiles.openPool(layout.bodies, create: false) else {
            throw SMBTextFailure.unavailable
        }
        var descriptors = [pool]
        defer { if !keep { descriptors.forEach { Darwin.close($0) } } }
        let poolLock = try SMBCatalogFiles.lockPool(pool, create: false)
        defer { Darwin.close(poolLock) }
        try SMBCatalogFiles.validatePool(pool, at: layout.bodies)
        let name = "download-" + reference.id.uuidString
        let before = try DownloadDisk.record(pool, name: name)
        guard !before.summary.active, !before.summary.isFolder,
              (try JSONDecoder().decode(DownloadDisk.Marker.self, from: before.marker)).version == 1,
              before.summary.expectedBytes == reference.logicalBytes,
              before.files["payload"] != nil else { throw SMBTextFailure.changed }
        let folder = openat(pool, name, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
        guard folder >= 0 else { throw SMBTextFailure.changed }; descriptors.append(folder)
        guard try DownloadDisk.identity(folder) == before.folder else { throw SMBTextFailure.changed }
        let lease = openat(folder, "owner.lock", O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard lease >= 0 else { throw SMBTextFailure.changed }; descriptors.append(lease)
        guard try DownloadDisk.identity(lease) == before.files["owner.lock"],
              flock(lease, LOCK_EX | LOCK_NB) == 0 else { throw SMBTextFailure.busy }
        let actual = try DownloadDisk.record(pool, name: name, heldLease: lease)
        guard actual.folder == before.folder, actual.marker == before.marker,
              actual.files == before.files else { throw SMBTextFailure.changed }
        let payload = openat(folder, "payload", O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard payload >= 0 else { throw SMBTextFailure.changed }; descriptors.append(payload)
        var facts = stat()
        guard fstat(payload, &facts) == 0, DownloadDisk.privateFile(facts),
              facts.st_size == Int64(reference.logicalBytes),
              try DownloadDisk.identity(payload) == actual.files["payload"] else {
            throw SMBTextFailure.changed
        }
        self.layout = layout; self.reference = reference; self.pool = pool; self.workspace = workspace
        self.folder = folder; self.lease = lease; self.payload = payload
        record = actual; stamp = try DownloadDisk.stamp(payload); keep = true
    }
    static func open(layout: SMBInPlaceLayout, reference: SMBInPlaceBodyReference) async throws -> Self {
        try await DownloadExecutor().perform { try .init(layout: layout, reference: reference) }
    }
    private func validate() throws {
        guard !closed else { throw SMBTextFailure.closed }
        try workspace?.validateCurrent()
        try SMBCatalogFiles.validatePool(pool, at: layout.bodies)
        let actual = try DownloadDisk.record(pool, name: record.name, heldLease: lease)
        guard actual.folder == record.folder, actual.marker == record.marker, actual.files == record.files,
              try DownloadDisk.identity(folder) == record.folder,
              try DownloadDisk.stamp(payload) == stamp else { throw SMBTextFailure.changed }
    }
    func read() async throws -> TextDocumentValue {
        try await executor.perform { [self] in try state.withLock {
            try validate()
            var bytes = Data(count: Int(reference.logicalBytes)), offset = 0
            while offset < bytes.count {
                try validate()
                let count = min(32768, bytes.count - offset)
                let found = bytes.withUnsafeMutableBytes {
                    pread(payload, $0.baseAddress!.advanced(by: offset), count, off_t(offset))
                }
                if found < 0 && errno == EINTR { continue }
                guard found == count else { throw SMBTextFailure.changed }
                offset += found
            }
            try validate()
            guard Data(SHA256.hash(data: bytes)) == reference.digest else { throw SMBTextFailure.changed }
            return try TextDocumentValue.original(bytes)
        } }
    }
    func closeAndDrain() async -> Bool {
        await executor.drain { [self] in state.withLock {
            guard !closed else { return }
            closed = true
            var confirmed = flock(lease, LOCK_UN) == 0
            for fd in [payload, lease, folder, pool] { if Darwin.close(fd) != 0 { confirmed = false } }
            workspace?.close()
            closeConfirmed = confirmed
        } }
        return state.withLock { closeConfirmed == true }
    }
    deinit {
        let descriptors = state.withLock { closed ? [] : [payload, lease, folder, pool] }
        if !descriptors.isEmpty {
            _ = flock(descriptors[1], LOCK_UN); descriptors.forEach { Darwin.close($0) }; workspace?.close()
        }
    }
}

/// One registered cold review operation at a time. Stop captures the actual
/// detached task before waiting, including metadata discovery and body reads.
final class SMBInPlaceRecoveryReadOwner: @unchecked Sendable {
    private enum Value: Sendable {
        case choices([SMBInPlaceRecoveryChoice]), viewed(SMBInPlaceViewedVersion), contents(TextDocumentValue)
    }
    private let lock = NSLock()
    private var active: (UUID, Task<Value, Error>)?
    private var sealedTask: (UUID, Task<Value, Error>)?
    private var drainers = 0, sealed = false, drainUncertain = false
    private func markDrainUncertain() { lock.withLock { drainUncertain = true } }

    func discoverPrepared(_ prepare: @escaping @Sendable () throws -> SMBInPlaceWorkingCopyStorage?) async throws -> [SMBInPlaceRecoveryChoice] {
        let value = try await perform { [self] in
            guard let storage = try prepare() else { return .choices([]) }
            return .choices(try await storage.recoveryChoicesAfterExplicitRequest(reader: self))
        }
        guard case .choices(let choices) = value else { throw SMBTextFailure.changed }
        return choices
    }
    func read(_ choice: SMBInPlaceRecoveryChoice, version: SMBInPlaceRecoveryVersion) async throws -> TextDocumentValue {
        let value = try await perform { [self] in
            let viewed = try await choice.readPinnedDirect(version)
            guard await viewed.closeAndDrain() else { markDrainUncertain(); throw SMBTextFailure.reviewRequired }
            return .contents(viewed.contents)
        }
        guard case .contents(let contents) = value else { throw SMBTextFailure.changed }
        return contents
    }
    func readPinned(_ choice: SMBInPlaceRecoveryChoice, version: SMBInPlaceRecoveryVersion) async throws -> SMBInPlaceViewedVersion {
        let value = try await perform { .viewed(try await choice.readPinnedDirect(version)) }
        guard case .viewed(let viewed) = value else { throw SMBTextFailure.changed }
        return viewed
    }
    private func perform(_ work: @escaping @Sendable () async throws -> Value) async throws -> Value {
        try Task.checkCancellation()
        let (id, task) = try lock.withLock { () throws -> (UUID, Task<Value, Error>) in
            guard !sealed else { throw SMBTextFailure.closed }
            guard !drainUncertain else { throw SMBTextFailure.reviewRequired }
            guard active == nil, drainers == 0 else { throw SMBTextFailure.busy }
            let id = UUID()
            let task = Task.detached(priority: .utility) { try Task.checkCancellation(); return try await work() }
            active = (id, task)
            return (id, task)
        }
        defer { lock.withLock { if active?.0 == id { active = nil } } }
        return try await withTaskCancellationHandler {
            let value = try await task.value
            let stopped = lock.withLock { sealed || drainers > 0 }
            if Task.isCancelled || stopped {
                if case .viewed(let viewed) = value,
                   !(await viewed.closeAndDrain()) { markDrainUncertain() }
                throw CancellationError()
            }
            return value
        } onCancel: { task.cancel() }
    }
    func seal() {
        let task = lock.withLock { () -> Task<Value, Error>? in
            sealed = true
            if sealedTask == nil { sealedTask = active }
            return sealedTask?.1
        }
        task?.cancel()
    }
    func sealAndDrain() async -> Bool {
        seal()
        let held = lock.withLock { drainers += 1; return sealedTask }
        let drained = await drain(held)
        lock.withLock {
            if active?.0 == held?.0 { active = nil }
            if sealedTask?.0 == held?.0 { sealedTask = nil }
            drainers -= 1
        }
        return drained && !lock.withLock { drainUncertain }
    }
    func stopAndDrain() async {
        let held = lock.withLock { drainers += 1; return active }
        _ = await drain(held)
        lock.withLock { if active?.0 == held?.0 { active = nil }; drainers -= 1 }
    }
    private func drain(_ held: (UUID, Task<Value, Error>)?) async -> Bool {
        guard let task = held?.1 else { return true }
        task.cancel()
        if let value = try? await task.value, case .viewed(let viewed) = value {
            let closed = await viewed.closeAndDrain()
            if !closed { markDrainUncertain() }
            return closed
        }
        return true
    }
}
