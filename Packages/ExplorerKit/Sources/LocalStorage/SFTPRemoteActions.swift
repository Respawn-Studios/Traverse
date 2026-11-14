import CoreFoundation
import CryptoKit
import Foundation

@_spi(Qualification) public enum SFTPRemoteActionKind: String, Codable, Sendable {
    case newFolder, renameFile, deleteFilePermanently, deleteEmptyDirectoryPermanently, renameDirectory, moveFile, moveDirectory, copyFile
}

@_spi(Qualification) public enum SFTPRemoteActionOutcome: String, Codable, Sendable {
    case prepared, needsReview, confirmed, failedSafe
}
@_spi(Qualification) public enum SFTPRemoteActionRefusal: String, Codable, Sendable {
    case targetExists, sourceChanged, denied, unavailable, busy, notEmpty
}

/// A visible selection from one complete catalog. No caller supplies a remote
/// path: the authenticated worker resolves the selected observation again.
@_spi(Qualification) public struct SFTPRemoteActionIntent: Sendable, CustomDebugStringConvertible {
    public let request: UUID
    public let generation: UUID
    public let snapshot: SFTPStoredSnapshot
    public let kind: SFTPRemoteActionKind
    public let row: SFTPStoredRow?
    public let name: SFTPRemoteName?
    public let destinationName: SFTPRemoteName?
    public let destinationDirectory: SFTPDefaultDirectory?
    public var debugDescription: String { "<SFTP remote action intent>" }

    private init(kind: SFTPRemoteActionKind, generation: UUID, snapshot: SFTPStoredSnapshot,
                 row: SFTPStoredRow?, name: SFTPRemoteName?, destinationName: SFTPRemoteName?,
                 destinationDirectory: SFTPDefaultDirectory? = nil) throws {
        guard SFTPWire.validToken(generation), snapshot.state == .complete,
              snapshot.read > 0, snapshot.read <= UInt64(Int64.max),
              snapshot.revision <= UInt64(Int64.max) else { throw SFTPProtocolFailure.invalidInput }
        if let row {
            guard row.observation > 0, row.observation <= UInt64(Int64.max),
                  row.entry.permissions != nil,
                  row.entry.logicalBytes != nil, row.entry.modifiedSeconds != nil,
                  row.entry.name.wireUTF8.count <= 255 else { throw SFTPProtocolFailure.invalidInput }
        }
        switch kind {
        case .newFolder:
            guard row == nil, let name, name.wireUTF8.count <= 255, destinationName == nil,
                  destinationDirectory == nil else { throw SFTPProtocolFailure.invalidInput }
        case .renameFile:
            guard let row, name == nil, let destinationName, destinationName.wireUTF8.count <= 255,
                  row.entry.permissions.map({ $0 & 0o170000 == 0o100000 }) == true,
                  destinationName.wireUTF8 != row.entry.name.wireUTF8,
                  destinationDirectory == nil else { throw SFTPProtocolFailure.invalidInput }
        case .renameDirectory:
            guard let row, name == nil, let destinationName, destinationName.wireUTF8.count <= 255,
                  row.entry.permissions.map({ $0 & 0o170000 == 0o040000 }) == true,
                  destinationName.wireUTF8 != row.entry.name.wireUTF8,
                  destinationDirectory == nil else { throw SFTPProtocolFailure.invalidInput }
        case .moveFile, .moveDirectory:
            let requiredKind: UInt32 = kind == .moveFile ? 0o100000 : 0o040000
            guard let row, name == nil, destinationName == nil, let destinationDirectory,
                  destinationDirectory.root == .server,
                  destinationDirectory.components.count <= 127,
                  destinationDirectory.pathUTF8.count + 1 + row.entry.name.wireUTF8.count <= 8192,
                  row.entry.permissions.map({ $0 & 0o170000 == requiredKind }) == true else {
                throw SFTPProtocolFailure.invalidInput
            }
        case .copyFile:
            guard let row, name == nil, let destinationName, let destinationDirectory,
                  destinationName.wireUTF8.count <= 255, destinationDirectory.root == .server,
                  destinationDirectory.components.count <= 127,
                  destinationDirectory.pathUTF8.count + 1 + destinationName.wireUTF8.count <= 8192,
                  row.entry.permissions.map({ $0 & 0o170000 == 0o100000 && $0 & 0o7000 == 0 }) == true,
                  row.entry.logicalBytes.map({ $0 <= 64 << 30 }) == true else {
                throw SFTPProtocolFailure.invalidInput
            }
        case .deleteFilePermanently:
            guard row?.entry.permissions.map({ $0 & 0o170000 == 0o100000 }) == true,
                  name == nil, destinationName == nil, destinationDirectory == nil else { throw SFTPProtocolFailure.invalidInput }
        case .deleteEmptyDirectoryPermanently:
            guard row?.entry.permissions.map({ $0 & 0o170000 == 0o040000 }) == true,
                  name == nil, destinationName == nil, destinationDirectory == nil else { throw SFTPProtocolFailure.invalidInput }
        }
        self.request = UUID(); self.generation = generation; self.snapshot = snapshot
        self.kind = kind; self.row = row; self.name = name; self.destinationName = destinationName
        self.destinationDirectory = destinationDirectory
    }

    public static func newFolder(generation: UUID, snapshot: SFTPStoredSnapshot,
                                 name: SFTPRemoteName) throws -> Self {
        try .init(kind: .newFolder, generation: generation, snapshot: snapshot, row: nil, name: name, destinationName: nil)
    }
    public static func renameFile(generation: UUID, snapshot: SFTPStoredSnapshot,
                                  row: SFTPStoredRow, newName: SFTPRemoteName) throws -> Self {
        try .init(kind: .renameFile, generation: generation, snapshot: snapshot, row: row, name: nil, destinationName: newName)
    }
    public static func renameDirectory(generation: UUID, snapshot: SFTPStoredSnapshot,
                                       row: SFTPStoredRow, newName: SFTPRemoteName) throws -> Self {
        try .init(kind: .renameDirectory, generation: generation, snapshot: snapshot,
                  row: row, name: nil, destinationName: newName)
    }
    public static func moveFile(generation: UUID, snapshot: SFTPStoredSnapshot,
                                row: SFTPStoredRow, destinationDirectory: SFTPDefaultDirectory) throws -> Self {
        try .init(kind: .moveFile, generation: generation, snapshot: snapshot,
                  row: row, name: nil, destinationName: nil, destinationDirectory: destinationDirectory)
    }
    public static func moveDirectory(generation: UUID, snapshot: SFTPStoredSnapshot,
                                     row: SFTPStoredRow, destinationDirectory: SFTPDefaultDirectory) throws -> Self {
        try .init(kind: .moveDirectory, generation: generation, snapshot: snapshot,
                  row: row, name: nil, destinationName: nil, destinationDirectory: destinationDirectory)
    }
    public static func copyFile(generation: UUID, snapshot: SFTPStoredSnapshot, row: SFTPStoredRow,
                                destinationDirectory: SFTPDefaultDirectory, newName: SFTPRemoteName) throws -> Self {
        try .init(kind: .copyFile, generation: generation, snapshot: snapshot,
                  row: row, name: nil, destinationName: newName, destinationDirectory: destinationDirectory)
    }
    public static func deleteFilePermanently(generation: UUID, snapshot: SFTPStoredSnapshot,
                                             row: SFTPStoredRow) throws -> Self {
        try .init(kind: .deleteFilePermanently, generation: generation, snapshot: snapshot, row: row, name: nil, destinationName: nil)
    }
    public static func deleteEmptyDirectoryPermanently(generation: UUID, snapshot: SFTPStoredSnapshot,
                                                        row: SFTPStoredRow) throws -> Self {
        try .init(kind: .deleteEmptyDirectoryPermanently, generation: generation, snapshot: snapshot,
                  row: row, name: nil, destinationName: nil)
    }
    var remoteName: String { String(decoding: (name ?? row!.entry.name).wireUTF8, as: UTF8.self) }
    var destination: String? { destinationName.map { String(decoding: $0.wireUTF8, as: UTF8.self) } }
    func command() throws -> Data {
        var bytes = SFTPWire.token(request) + SFTPWire.token(generation)
        SFTPWire.number(snapshot.read, bytes: 8, into: &bytes)
        SFTPWire.number(snapshot.revision, bytes: 8, into: &bytes)
        let kindCode: UInt8 = switch kind {
        case .newFolder: 1; case .renameFile: 2; case .deleteFilePermanently: 3
        case .deleteEmptyDirectoryPermanently: 4
        case .renameDirectory: 5
        case .moveFile: 6
        case .moveDirectory: 7
        case .copyFile: 8
        }
        bytes.append(kindCode)
        SFTPWire.number(row?.observation ?? 0, bytes: 8, into: &bytes)
        try SFTPWire.field((name ?? row!.entry.name).wireUTF8, into: &bytes)
        try SFTPWire.field(destinationName?.wireUTF8 ?? Data(), into: &bytes)
        SFTPWire.number(row?.entry.logicalBytes ?? 0, bytes: 8, into: &bytes)
        SFTPWire.number(UInt64(row?.entry.modifiedSeconds ?? 0), bytes: 4, into: &bytes)
        SFTPWire.number(UInt64(row?.entry.permissions ?? 0), bytes: 4, into: &bytes)
        if let destinationDirectory { try SFTPWire.field(destinationDirectory.pathUTF8, into: &bytes) }
        return bytes
    }
}

@_spi(Qualification) public struct SFTPRemoteActionRecord: Identifiable, Codable, Sendable,
    CustomDebugStringConvertible {
    public let id: UUID
    public let kind: SFTPRemoteActionKind
    public private(set) var outcome: SFTPRemoteActionOutcome
    public private(set) var refusal: SFTPRemoteActionRefusal?
    public let remoteDirectory: String
    public let remoteName: String
    public let destinationName: String?
    public let destinationDirectory: String?
    /// The private stage is recorded before any remote OPEN can create it.
    public let copyStageName: String?
    public let createdAt: Date
    public private(set) var updatedAt: Date
    public var serverDisplay: String { host.host.contains(":") ? "[\(host.host)]:\(host.port)" : "\(host.host):\(host.port)" }
    public var displayRemoteName: String {
        (try? SFTPRemoteName(Data(remoteName.utf8)))?.displayName ?? "<invalid remote name>"
    }
    public var displayDestinationName: String? {
        destinationName.map { (try? SFTPRemoteName(Data($0.utf8)))?.displayName ?? "<invalid remote name>" }
    }
    public var displayRemoteDirectory: String {
        Self.displayDirectory(remoteDirectory)
    }
    public var displayDestinationDirectory: String? { destinationDirectory.map(Self.displayDirectory) }
    private static func displayDirectory(_ path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: false).map { component in
            guard !component.isEmpty else { return "" }
            return (try? SFTPRemoteName(Data(component.utf8)))?.displayName ?? "<invalid remote path>"
        }.joined(separator: "/")
    }
    let host: SFTPHostIdentity
    let account: String
    let hostKeyDigest: Data
    let routeKeyBinding: Data?
    let generation: UUID
    let catalogRead: UInt64
    let catalogRevision: UInt64
    let observation: UInt64?
    public var debugDescription: String { "<SFTP remote action record>" }
    init(intent: SFTPRemoteActionIntent, context: SFTPVerifiedSessionContext, directory: String) throws {
        let now = Date()
        id = intent.request; kind = intent.kind; outcome = .prepared; refusal = nil
        remoteDirectory = directory; remoteName = intent.remoteName; destinationName = intent.destination
        destinationDirectory = intent.destinationDirectory.map { String(decoding: $0.pathUTF8, as: UTF8.self) }
        copyStageName = intent.kind == .copyFile ? Self.stageName(for: intent.request) : nil
        createdAt = now; updatedAt = now
        host = try SFTPHostIdentity(canonicalHost: context.host, port: context.port, interfaceScope: context.requestedScopeID)
        account = context.account; hostKeyDigest = Data(SHA256.hash(data: context.key.bytes))
        routeKeyBinding = context.routeKeyBinding
        generation = intent.generation; catalogRead = intent.snapshot.read; catalogRevision = intent.snapshot.revision
        observation = intent.row?.observation
        try validate()
    }
    private func validName(_ name: String) -> Bool {
        guard let value = try? SFTPRemoteName(Data(name.utf8)) else { return false }
        return value.wireUTF8.count <= 255
    }
    static func stageName(for id: UUID) -> String {
        ".mac-explorer-copy-\(id.uuidString.replacingOccurrences(of: "-", with: "")).part"
    }
    private func validDirectory(_ path: String) -> Bool {
        path.hasPrefix("/") && path.utf8.count <= 8192 &&
        (path == "/" || !path.hasSuffix("/") && path.split(separator: "/", omittingEmptySubsequences: false)
            .dropFirst().allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })) &&
        path.split(separator: "/").count <= 127
    }
    func validate() throws {
        try host.validate()
        guard SFTPWire.validToken(id), SFTPWire.validToken(generation),
              catalogRead > 0, catalogRead <= UInt64(Int64.max), catalogRevision <= UInt64(Int64.max),
              !account.isEmpty, account.utf8.count <= 256, !account.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              hostKeyDigest.count == 32, routeKeyBinding == nil || routeKeyBinding?.count == 32,
              validDirectory(remoteDirectory),
              validName(remoteName), (destinationName == nil || validName(destinationName!)),
              destinationDirectory.map(validDirectory) ?? true,
              remoteDirectory.utf8.count + 1 + remoteName.utf8.count <= 8192,
              destinationName.map({ remoteDirectory.utf8.count + 1 + $0.utf8.count <= 8192 }) ?? true,
              destinationDirectory.map({ $0.utf8.count + 1 + remoteName.utf8.count <= 8192 }) ?? true,
              copyStageName == nil || validName(copyStageName!),
              createdAt.timeIntervalSince1970.isFinite, updatedAt.timeIntervalSince1970.isFinite,
              updatedAt >= createdAt, (outcome == .failedSafe || refusal == nil) else { throw RemoteSettingsFailure.invalidRecord }
        switch kind {
        case .newFolder: guard observation == nil, destinationName == nil, destinationDirectory == nil,
                               copyStageName == nil else { throw RemoteSettingsFailure.invalidRecord }
        case .renameFile: guard let observation, observation > 0, observation <= UInt64(Int64.max),
                                let destinationName, Data(destinationName.utf8) != Data(remoteName.utf8),
                                destinationDirectory == nil, copyStageName == nil else { throw RemoteSettingsFailure.invalidRecord }
        case .renameDirectory: guard let observation, observation > 0, observation <= UInt64(Int64.max),
                                    let destinationName, Data(destinationName.utf8) != Data(remoteName.utf8),
                                    destinationDirectory == nil, copyStageName == nil else { throw RemoteSettingsFailure.invalidRecord }
        case .moveFile, .moveDirectory:
            guard let observation, observation > 0, observation <= UInt64(Int64.max),
                  destinationName == nil, let destinationDirectory, copyStageName == nil else { throw RemoteSettingsFailure.invalidRecord }
            let sourceParent = Data(remoteDirectory.utf8)
            let destinationParent = Data(destinationDirectory.utf8)
            guard destinationParent != sourceParent else { throw RemoteSettingsFailure.invalidRecord }
            if kind == .moveDirectory {
                var source = sourceParent
                if source.last != 47 { source.append(47) }
                source.append(contentsOf: remoteName.utf8)
                var descendantPrefix = source
                descendantPrefix.append(47)
                guard destinationParent != source, !destinationParent.starts(with: descendantPrefix) else {
                    throw RemoteSettingsFailure.invalidRecord
                }
            }
        case .deleteFilePermanently: guard let observation, observation > 0, observation <= UInt64(Int64.max),
                                            destinationName == nil, destinationDirectory == nil, copyStageName == nil else { throw RemoteSettingsFailure.invalidRecord }
        case .deleteEmptyDirectoryPermanently: guard let observation, observation > 0, observation <= UInt64(Int64.max),
                                                     destinationName == nil, destinationDirectory == nil, copyStageName == nil else { throw RemoteSettingsFailure.invalidRecord }
        case .copyFile:
            guard let observation, observation > 0, observation <= UInt64(Int64.max),
                  let destinationName, let destinationDirectory,
                  copyStageName == Self.stageName(for: id),
                  destinationDirectory.utf8.count + 1 + destinationName.utf8.count <= 8192,
                  destinationDirectory.utf8.count + 1 + (copyStageName?.utf8.count ?? 0) <= 8192,
                  destinationDirectory != remoteDirectory || destinationName != remoteName else {
                throw RemoteSettingsFailure.invalidRecord
            }
        }
    }
    mutating func transition(to outcome: SFTPRemoteActionOutcome, refusal: SFTPRemoteActionRefusal?) {
        self.outcome = outcome; self.refusal = refusal; updatedAt = Date()
    }
}

@_spi(Qualification) public struct SFTPRemoteActionSnapshot: Sendable {
    public let revision: UInt64
    public let records: [SFTPRemoteActionRecord]
    public let active: Set<UUID>
}

@_spi(Qualification) public struct SFTPRemoteActionResult: Sendable {
    public let record: SFTPRemoteActionRecord
    public let completedAfterCancellation: Bool
}

private struct SFTPRemoteActionDocument: Sendable, Codable, RemoteSettingsDocument {
    // Unknown action kinds fail Codable decoding closed, including in older
    // writers opening a document with a directory Rename receipt. Those
    // writers cannot review or clear this history; they must not rewrite it.
    var format = 1, protocolIdentity = "sftp-remote-actions"
    var revision: UInt64 = 0
    var records: [SFTPRemoteActionRecord] = []
    init() {}
    func encoded() throws -> Data {
        guard (format == 1 || format == 2), protocolIdentity == "sftp-remote-actions", records.count <= 64,
              (format == 2 || !records.contains(where: { $0.kind == .copyFile })),
              Set(records.map(\.id)).count == records.count else { throw RemoteSettingsFailure.invalidRecord }
        try records.forEach { try $0.validate() }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var bytes = try encoder.encode(self); bytes.append(10)
        guard bytes.count <= RemoteSettingsFile<Self>.maximumBytes else { throw RemoteSettingsFailure.capacity }
        return bytes
    }
    static func decode(_ bytes: Data) throws -> Self {
        do {
            let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any]
            guard let number = object?["format"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  (number.intValue == 1 || number.intValue == 2), object?["protocolIdentity"] as? String == "sftp-remote-actions" else {
                throw RemoteSettingsFailure.incompatibleVersion
            }
            let value = try JSONDecoder().decode(Self.self, from: bytes)
            guard try value.encoded() == bytes else { throw RemoteSettingsFailure.invalidRecord }
            return value
        } catch let failure as RemoteSettingsFailure { throw failure }
        catch { throw RemoteSettingsFailure.invalidRecord }
    }
}

/// A private local receipt. It is never authority to replay a remote command.
@_spi(Qualification) public final class SFTPRemoteActionStore: @unchecked Sendable {
    private typealias File = RemoteSettingsFile<SFTPRemoteActionDocument>
    private let directory: URL
    private let executor = UploadLocalExecutor(label: "MacExplorer.SFTP.RemoteActions")
    private var owner: File?
    private var active = Set<UUID>()
    public init(directory: URL) { self.directory = directory }
    deinit { let held = owner; executor.enqueueDrain { held?.close() } }

    public func inspect() async throws -> SFTPRemoteActionSnapshot {
        let (value, late) = try await executor.perform { [self] in
            if let owner {
                try owner.validateCurrent()
                return SFTPRemoteActionSnapshot(revision: owner.snapshot.revision, records: owner.snapshot.records, active: active)
            }
            guard let file = try File.open(directory, writing: false) else { return .init(revision: 0, records: [], active: []) }
            defer { file.close() }
            return .init(revision: file.snapshot.revision, records: file.snapshot.records, active: [])
        }
        guard !late else { throw RemoteSettingsFailure.cancelled }
        return value
    }
    func prepare(_ intent: SFTPRemoteActionIntent, context: SFTPVerifiedSessionContext,
                 directory: String) async throws -> SFTPRemoteActionResult {
        let record = try SFTPRemoteActionRecord(intent: intent, context: context, directory: directory)
        let (value, late) = try await mutate(revision: nil) { [self] document in
            guard document.records.count < 64, active.count < 2 else { throw RemoteSettingsFailure.capacity }
            if record.kind == .copyFile { document.format = 2 }
            document.records.append(record); return record
        } afterCommit: { [self] in active.insert(record.id) }
        guard let value else { throw RemoteSettingsFailure.invalidRecord }
        return .init(record: value, completedAfterCancellation: late)
    }
    func update(_ id: UUID, outcome: SFTPRemoteActionOutcome,
                refusal: SFTPRemoteActionRefusal? = nil) async throws -> SFTPRemoteActionResult {
        let (value, late) = try await mutate(revision: nil) { [self] document in
            guard active.contains(id), let index = document.records.firstIndex(where: { $0.id == id }) else { throw RemoteSettingsFailure.missing }
            let prior = document.records[index].outcome
            guard prior == .prepared && (outcome == .needsReview || outcome == .failedSafe)
                    || prior == .needsReview && (outcome == .confirmed || outcome == .failedSafe) else {
                throw RemoteSettingsFailure.invalidRecord
            }
            document.records[index].transition(to: outcome, refusal: refusal)
            return document.records[index]
        } afterCommit: { [self] in if outcome != .needsReview { active.remove(id) } }
        guard let value else { throw RemoteSettingsFailure.invalidRecord }
        return .init(record: value, completedAfterCancellation: late)
    }
    /// Forget is local only. An uncertain outcome must be reviewed explicitly.
    public func forgetReviewed(_ id: UUID, revision: UInt64) async throws {
        _ = try await mutate(revision: revision) { [self] document in
            guard !active.contains(id) else { throw RemoteSettingsFailure.busy }
            guard let index = document.records.firstIndex(where: { $0.id == id }) else { throw RemoteSettingsFailure.missing }
            document.records.remove(at: index); return nil
        }
    }
    /// One explicit local commit. Uncertain and active records are retained.
    public func forgetCompleted(revision: UInt64) async throws {
        _ = try await mutate(revision: revision) { [self] document in
            document.records.removeAll { record in
                !active.contains(record.id) && (record.outcome == .confirmed || record.outcome == .failedSafe)
            }
            return nil
        }
    }
    private func mutate(revision: UInt64?, change: @escaping @Sendable (inout SFTPRemoteActionDocument) throws -> SFTPRemoteActionRecord?,
                        afterCommit: @escaping @Sendable () -> Void = {}) async throws -> (SFTPRemoteActionRecord?, Bool) {
        let (value, late) = try await executor.perform { [self] in
            if owner == nil { owner = try File.open(directory, writing: true) }
            guard let owner else { throw RemoteSettingsFailure.unavailable }
            try owner.validateCurrent()
            if let revision { guard owner.snapshot.revision == revision else { throw RemoteSettingsFailure.staleRevision } }
            var next = owner.snapshot
            let record = try change(&next)
            guard next.revision < UInt64.max else { throw RemoteSettingsFailure.capacity }
            next.revision += 1; try owner.commit(next); afterCommit()
            return record
        }
        return (value, late)
    }
    public func recoverUncommittedLocalStage() async throws {
        let (_, late) = try await executor.perform { [self] in
            guard active.isEmpty else { throw RemoteSettingsFailure.busy }
            owner?.close(); owner = nil
            owner = try File.open(directory, writing: true, discardStage: true)
        }
        if late { throw RemoteSettingsFailure.cancelled }
    }
    /// Release only local in-process ownership after an observed worker drain.
    /// Never rewrites a Prepared or Needs Review receipt or infers a server result.
    func releaseAfterDrain(_ id: UUID) async {
        _ = try? await executor.perform { [self] in active.remove(id) }
    }
    public func close() async -> Bool {
        await withCheckedContinuation { continuation in executor.enqueueDrain { [self] in
            guard active.isEmpty else { continuation.resume(returning: false); return }
            owner?.close(); owner = nil; continuation.resume(returning: true)
        } }
    }
}
