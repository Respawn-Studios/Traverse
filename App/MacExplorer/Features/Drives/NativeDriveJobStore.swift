import Darwin
import Foundation
import LocalStorage

/// Reuses the app's path-pinned private snapshot writer, writer CAS, transaction
/// lock and file+directory sync. A missing or invalid existing document cannot
/// be interpreted as a clean slot. No user file body or raw diskutil output is
/// stored here.
final class NativeDriveJobStore: @unchecked Sendable {
    enum Failure: Error { case unavailable, invalid, unresolved, changed }
    struct Snapshot: Sendable { let record: APFSVolumeFormatJobRecord?; let bytes: Data? }
    struct Recording: APFSVolumeFormatRecording {
        let store: NativeDriveJobStore
        let owner: APFSVolumeFormatGeneratedOwner
        let jobID: UUID
        let attachmentCurrent: @Sendable () -> Bool
        func ownerStillCurrent() -> Bool {
            NativeDriveJobStore.currentBackingFile(owner) && attachmentCurrent()
        }
        func recordIntent(_ snapshot: APFSVolumeFormatSnapshot) async throws {
            try await store.recordIntent(snapshot, owner: owner, jobID: jobID)
        }
        func recordSubmitted() async throws { try await store.recordSubmitted(jobID: jobID) }
        func recordTerminal(_ terminal: APFSVolumeFormatRecoveryTerminal) async throws {
            try await store.recordTerminal(terminal, jobID: jobID)
        }
    }

    private let queue = DispatchQueue(label: "Traverse.NativeDriveJob", qos: .utility)
    private let directory: URL
    private let rootPreparation: PrivateStateDirectorySequence
    private let leafPreparation: PrivateStateDirectorySequence
    private var active: UUID? // serial worker only
    private var lease: BrowserSnapshotFile.LifetimeLease? // serial worker only
    private var failedWrite = false // serial worker only, cleared only by a fresh store instance
    private static let fileName = "native-drive-job-v1.json"
    private static let maximumBytes = 65_536

    init(directory: URL, rootPreparation: PrivateStateDirectorySequence,
         leafPreparation: PrivateStateDirectorySequence) {
        self.directory = directory; self.rootPreparation = rootPreparation; self.leafPreparation = leafPreparation
    }
    static func applicationStore() -> NativeDriveJobStore? {
        guard let root = AppStorageLocations.stateDirectory,
              let parent = try? AppStoragePreparation.owner(for: root),
              let leaf = try? PrivateStateDirectorySequence(
                directories: [root.appendingPathComponent("drive-jobs", isDirectory: true)],
                activity: ApplicationFileActivity.gate) else { return nil }
        return .init(directory: root.appendingPathComponent("drive-jobs", isDirectory: true),
                     rootPreparation: parent, leafPreparation: leaf)
    }
    func recording(owner: APFSVolumeFormatGeneratedOwner,
                   attachmentCurrent: @escaping @Sendable () -> Bool) -> Recording {
        .init(store: self, owner: owner, jobID: UUID(), attachmentCurrent: attachmentCurrent)
    }

    private static func currentBackingFile(_ owner: APFSVolumeFormatGeneratedOwner) -> Bool {
        guard owner.validate(), owner.ownerUID == geteuid() else { return false }
        let image = URL(fileURLWithPath: owner.imagePath)
        let root = image.deletingLastPathComponent()
        guard root.path == root.resolvingSymlinksInPath().path else { return false }
        var rootInfo = stat(), imageInfo = stat()
        return lstat(root.path, &rootInfo) == 0 && rootInfo.st_mode & S_IFMT == S_IFDIR
            && Int64(rootInfo.st_dev) == owner.rootDevice && rootInfo.st_ino == owner.rootInode
            && rootInfo.st_uid == owner.ownerUID
            && lstat(image.path, &imageInfo) == 0 && imageInfo.st_mode & S_IFMT == S_IFREG
            && Int64(imageInfo.st_dev) == owner.imageDevice && imageInfo.st_ino == owner.imageInode
            && imageInfo.st_uid == owner.ownerUID && imageInfo.st_nlink == 1
            && imageInfo.st_size == off_t(1 << 30)
    }

    private func file(strict: Bool) -> BrowserSnapshotFile {
        .init(directory: directory, name: Self.fileName, maximumBytes: Self.maximumBytes,
              requiresPrivateDurability: true, requiresExistingWriterLock: strict)
    }
    private func decode(_ bytes: Data) throws -> APFSVolumeFormatJobRecord {
        guard bytes.count <= Self.maximumBytes,
              let record = try? JSONDecoder().decode(APFSVolumeFormatJobRecord.self, from: bytes),
              record.validate() else { throw Failure.invalid }
        return record
    }
    private func read(allowMissingDocument: Bool = false) throws -> Snapshot {
        let bytes = try file(strict: true).read(expectDocumentInExistingDirectory: !allowMissingDocument)
        return .init(record: try bytes.map(decode), bytes: bytes)
    }
    private func write(_ record: APFSVolumeFormatJobRecord, replacing before: Snapshot) throws {
        guard record.validate() else { throw Failure.invalid }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(record)
        let writer = file(strict: before.bytes != nil)
        try writer.write(bytes, replacing: before.bytes.map(BrowserSnapshotFile.ExpectedVersion.bytes) ?? .absent) {
            _ = try self.decode($0)
        }
        guard try read().bytes == bytes else { throw Failure.unavailable }
    }
    func load() async throws -> Snapshot { try await perform { try self.read() } }

    private func recordIntent(_ snapshot: APFSVolumeFormatSnapshot,
                              owner: APFSVolumeFormatGeneratedOwner, jobID: UUID) async throws {
        guard snapshot.validate(), Self.currentBackingFile(owner) else { throw Failure.invalid }
        let baseline = try await load()
        guard baseline.record?.isUnresolved != true else { throw Failure.unresolved }
        try await rootPreparation.prepare()
        try await leafPreparation.prepare()
        try await perform {
            guard !self.failedWrite, self.active == nil, Self.currentBackingFile(owner) else { throw Failure.unresolved }
            let before = try self.read(allowMissingDocument: baseline.bytes == nil)
            guard before.bytes == baseline.bytes else { throw Failure.changed }
            guard before.record?.isUnresolved != true else { throw Failure.unresolved }
            guard let lease = try self.file(strict: false).acquireMutationLease(create: true) else { throw Failure.unavailable }
            self.lease = lease
            do {
                let record = APFSVolumeFormatJobRecord(id: jobID, owner: owner,
                    snapshot: snapshot, phase: .intent)
                try self.write(record, replacing: before)
                try lease.validate(); self.active = jobID
            } catch {
                self.failedWrite = true; self.lease = nil
                throw error
            }
        }
    }
    private func recordSubmitted(jobID: UUID) async throws {
        try await perform {
            guard !self.failedWrite, self.active == jobID, let lease = self.lease else { throw Failure.unresolved }
            do {
                try lease.validate()
                let before = try self.read()
                guard var record = before.record, record.id == jobID, record.phase == .intent else { throw Failure.changed }
                record.phase = .submitted
                try self.write(record, replacing: before)
            } catch { self.failedWrite = true; throw error }
        }
    }
    private func recordTerminal(_ terminal: APFSVolumeFormatRecoveryTerminal, jobID: UUID) async throws {
        try await perform {
            guard self.active == jobID, let lease = self.lease else { throw Failure.unresolved }
            defer { self.active = nil; self.lease = nil }
            guard !self.failedWrite else { throw Failure.unresolved }
            do {
                try lease.validate()
                let before = try self.read()
                guard var record = before.record, record.id == jobID,
                      [.intent, .submitted].contains(record.phase) else { throw Failure.changed }
                switch terminal {
                case .notSubmitted:
                    guard record.phase == .intent else { throw Failure.changed }
                    record.phase = .notSubmitted
                case let .compatibleReplacement(replacement):
                    guard record.phase == .submitted, replacement != record.snapshot.targetID,
                          Self.currentBackingFile(record.owner) else { throw Failure.changed }
                    // Backend APFS identity is only provisional; target and
                    // sibling marker witnesses have not been verified here.
                    record.phase = .compatibleReplacement; record.replacementID = replacement
                case .uncertain: record.phase = .uncertain
                }
                try self.write(record, replacing: before)
            } catch { self.failedWrite = true; throw error }
        }
    }

    /// Read-only cold inspection can report a compatible current replacement,
    /// but never clears the job: the record does not contain the generated
    /// target/sibling marker witnesses needed to establish the loss outcome.
    func inspectUnresolvedCompatibleReplacement(owner: APFSVolumeFormatGeneratedOwner, backend: APFSVolumeFormat,
        ownerStillCurrent: @escaping @Sendable () -> Bool) async throws -> Bool {
        let before = try await load()
        guard let record = before.record, record.isUnresolved, record.owner == owner,
              Self.currentBackingFile(owner), ownerStillCurrent() else { return false }
        let result = await backend.inspectRecovery(record.snapshot, ownerStillCurrent: ownerStillCurrent)
        guard case .compatibleReplacement = result,
              Self.currentBackingFile(owner), ownerStillCurrent() else { return false }
        // A concurrent writer or changed record also invalidates this narrow
        // observation. It is never authority to retry or clear the intent.
        let current = try await load()
        return current.bytes == before.bytes
    }

    private func perform<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try body() }) }
        }
    }
}
