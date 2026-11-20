import Darwin
import ExplorerCore
import Foundation

/// One-shot engine authority. Allocating the future ID performs no history I/O.
internal final class MoveRecordReservation: @unchecked Sendable {
    let recordID = UUID()
    let owner: UUID
    private let lock = NSLock()
    private var consumed = false
    init(owner: UUID) { self.owner = owner }
    func claim(owner: UUID) throws {
        try lock.withLock {
            guard self.owner == owner, !consumed else { throw FileOperationFailure.invalidRequest }
            consumed = true
        }
    }
}

public enum MoveReferenceDirection: Int, Codable, Sendable { case forward, undo }

/// Exact original still present, with no mutation of this unit in the reserved
/// operation. An absent record or an unrelated committed prefix can prove this.
/// This can retire a private pending intent; it never starts a file operation.
public struct UnstartedMoveEvidence: Sendable {
    public let ticket: MoveReferenceTicket
}

/// Durable read-only correlation, not permission to mutate history or files.
/// Constructed only from a plan; decoded tickets must still prove their journal
/// and live objects. No content digest or recovery payload leaves this module.
public struct MoveReferenceTicket: Sendable, Equatable, Codable {
    internal let version: Int
    public let operationID: UUID
    public let unitID: UUID
    public let source: URL
    public let historyDirectory: URL
    internal let sourceIdentity: EntrySnapshot
    internal let sourceParent: EntrySnapshot
    internal let destinationDirectory: URL
    internal let destinationParent: EntrySnapshot
    internal let inputCount: Int
    internal let member: MoveReferenceChain?
    public var isMember: Bool { member != nil }

    internal init(_ entry: TransferEntry, plan: TransferPlan, history: URL, reservation: MoveRecordReservation) {
        version = 1; operationID = reservation.recordID; unitID = entry.id
        source = entry.source; historyDirectory = history
        sourceIdentity = entry.sourceIdentity; sourceParent = entry.sourceParent
        destinationDirectory = entry.destination.deletingLastPathComponent(); destinationParent = entry.destinationParent
        inputCount = plan.entries.count; member = nil
    }
    internal init(root: MoveReferenceTicket, member: MoveReferenceChain?, source: URL, identity: EntrySnapshot,
                  parent: EntrySnapshot, inputCount: Int) {
        version = 2; operationID = root.operationID; unitID = root.unitID; self.source = source
        historyDirectory = root.historyDirectory; sourceIdentity = identity; sourceParent = parent
        destinationDirectory = root.destinationDirectory; destinationParent = root.destinationParent
        self.inputCount = inputCount; self.member = member
    }
    internal var rootTicket: MoveReferenceTicket {
        guard let member else { return self }
        return MoveReferenceTicket(root: self, member: nil, source: member.root,
            identity: member.ancestors[0], parent: member.rootParent, inputCount: inputCount)
    }
    public func encoded() throws -> Data {
        guard (version == 1 && member == nil || version == 2),
              (1...(version == 1 ? OperationJournal.maximumInputs : OperationLimits.maximumNodes)).contains(inputCount),
              [sourceIdentity.type].allSatisfy({ $0 == S_IFREG || $0 == S_IFDIR }),
              sourceParent.isDirectory, destinationParent.isDirectory else { throw FileOperationFailure.invalidRequest }
        for url in [source, historyDirectory, destinationDirectory] {
            guard url.hasStandardizedFilePath, url.path.hasPrefix("/"),
                  url.path.utf8.count <= 8_192, !url.path.utf8.contains(0) else { throw FileOperationFailure.invalidRequest }
        }
        if let member {
            try member.validateFormat()
            guard member.location == source, member.ancestors.last?.sameObject(as: sourceParent) == true else {
                throw FileOperationFailure.invalidRequest
            }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        guard data.count <= 32_768 else { throw FileOperationFailure.unsupported }
        return data
    }
    public init(encoded data: Data) throws {
        guard data.count <= 32_768 else { throw FileOperationFailure.invalidRequest }
        self = try JSONDecoder().decode(Self.self, from: data)
        guard try encoded() == data else { throw FileOperationFailure.invalidRequest }
    }
    /// Called on an already admitted native reference worker, before and after
    /// bookmark/tracking work. No source-body read occurs here.
    public func validateSourceDescriptor(_ fd: Int32, at url: URL) throws {
        try validateReferenceObject(fd: fd, url: url, expectedURL: source,
                                    identity: sourceIdentity, parentIdentity: sourceParent)
        try member?.validate(object: sourceIdentity)
    }
}

/// Ephemeral, opaque evidence minted by the engine's passive committed reader.
/// Public outcomes and caller-selected URLs cannot construct this type.
public struct MoveReferenceEvidence: Sendable {
    public let ticket: MoveReferenceTicket
    public let direction: MoveReferenceDirection
    public let location: URL
    internal let object: EntrySnapshot
    internal let parent: EntrySnapshot
    internal var chain: MoveReferenceChain? = nil
    public func validateDescriptor(_ fd: Int32, at url: URL) throws {
        try validateReferenceObject(fd: fd, url: url, expectedURL: location, identity: object, parentIdentity: parent)
        try chain?.validate(object: object)
    }
}

private func validateReferenceObject(fd: Int32, url: URL, expectedURL: URL,
                                     identity: EntrySnapshot, parentIdentity: EntrySnapshot) throws {
    guard url.isFileURL, url.path == expectedURL.path, identity.sameObject(as: try EntrySnapshot(fd: fd)) else {
        throw FileOperationFailure.sourceChanged
    }
    let parent = try DirectoryAnchor(url.deletingLastPathComponent(), resolve: false)
    guard parent.identity.sameObject(as: parentIdentity),
          try EntrySnapshot(parent: parent.fd, name: url.lastPathComponent).sameObject(as: identity) else {
        throw FileOperationFailure.sourceChanged
    }
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_mode & S_IFMT != S_IFREG || info.st_nlink == 1 else {
        throw FileOperationFailure.unsupported
    }
    try parent.validate()
}

extension RecoverableFileOperations {
    /// A complete guarded Undo can restore the exact original even when a copied
    /// member's forward receipt was lost. This proves only safe retirement of a
    /// pending original binding; it cannot discover a destination or start Undo.
    public func inspectRestoredMoveOriginal(_ ticket: MoveReferenceTicket) async throws -> UnstartedMoveEvidence {
        try await worker { cancellation in
            guard ticket.historyDirectory == self.directory else { throw FileOperationFailure.invalidRequest }
            _ = try ticket.encoded()
            guard let before = try OperationHistoryInspector.record(self.directory,
                id: ticket.operationID, cancellation: cancellation).treeRecord else { throw FileOperationFailure.unsupported }
            _ = try Self.moveReference(ticket.rootTicket, direction: .undo, record: before)
            let parent = try DirectoryAnchor(ticket.source.deletingLastPathComponent(), resolve: false)
            let flags = ticket.sourceIdentity.isDirectory ? O_DIRECTORY : 0
            let fd = openat(parent.fd, ticket.source.lastPathComponent, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC | flags)
            guard fd >= 0 else { throw posixFailure() }; defer { close(fd) }
            try ticket.validateSourceDescriptor(fd, at: ticket.source)
            guard let after = try OperationHistoryInspector.record(self.directory,
                id: ticket.operationID, cancellation: cancellation).treeRecord, before.owner == after.owner,
                  before.revision == after.revision, before.state == after.state, before.steps == after.steps else {
                throw FileOperationFailure.recoveryUncertain
            }
            try ticket.validateSourceDescriptor(fd, at: ticket.source)
            return UnstartedMoveEvidence(ticket: ticket)
        }
    }

    public func inspectUnstartedMove(_ ticket: MoveReferenceTicket) async throws -> UnstartedMoveEvidence {
        try await worker { cancellation in
            guard ticket.historyDirectory == self.directory else { throw FileOperationFailure.invalidRequest }
            _ = try ticket.encoded()
            let before = try self.unchangedMoveRecord(ticket, cancellation: cancellation)
            let parent = try DirectoryAnchor(ticket.source.deletingLastPathComponent(), resolve: false)
            let flags = ticket.sourceIdentity.isDirectory ? O_DIRECTORY : 0
            let fd = openat(parent.fd, ticket.source.lastPathComponent, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC | flags)
            guard fd >= 0 else { throw posixFailure() }; defer { close(fd) }
            try ticket.validateSourceDescriptor(fd, at: ticket.source)
            let after = try self.unchangedMoveRecord(ticket, cancellation: cancellation)
            guard before?.owner == after?.owner, before?.revision == after?.revision,
                  before?.state == after?.state, before?.steps == after?.steps else {
                throw FileOperationFailure.recoveryUncertain
            }
            try ticket.validateSourceDescriptor(fd, at: ticket.source)
            return UnstartedMoveEvidence(ticket: ticket)
        }
    }

    private func unchangedMoveRecord(_ ticket: MoveReferenceTicket, cancellation: OperationCancellation) throws -> JournalRecord? {
        guard let observed = try OperationHistoryInspector.recordIfPresent(directory, id: ticket.operationID,
            cancellation: cancellation) else { return nil }
        guard let record = observed.treeRecord, record.id == ticket.operationID,
              [1, 3].contains(record.version), record.operation == "Move", record.state == "committed",
              record.nameRename == nil, record.trashIntents.isEmpty,
              record.steps.allSatisfy({ $0.after != nil && !$0.undone }) else { throw FileOperationFailure.recoveryUncertain }
        func overlaps(_ url: URL) -> Bool {
            url.path == ticket.source.path || url.path.hasPrefix(ticket.source.path + "/")
                || ticket.source.path.hasPrefix(url.path + "/")
        }
        guard !record.steps.contains(where: { overlaps($0.source) || overlaps($0.destination) }),
              !record.areas.contains(where: { overlaps($0.url) }) else { throw FileOperationFailure.recoveryUncertain }
        return record
    }

    /// Whole transfer roots, including Replace and fresh continuation plans.
    /// A skipped/Merge container is not a positive source-document mapping.
    public func moveReferenceTickets(for plan: TransferPlan,
        resolutions: [UUID: TransferConflictResolution] = [:]) throws -> [MoveReferenceTicket] {
        guard plan.isMove, let reservation = plan.moveReservation,
              reservation.owner == continuationSession else { return [] }
        return plan.entries.filter { entry in
            (entry.sourceIdentity.type == S_IFREG || entry.sourceIdentity.type == S_IFDIR)
                && (entry.destinationIdentity == nil || [.replace, .keepBoth].contains(resolutions[entry.id]))
        }.map { MoveReferenceTicket($0, plan: plan, history: directory, reservation: reservation) }
    }

    /// Explicit inspection only: does not import, repair, upgrade or resume history.
    public func inspectMoveReference(_ ticket: MoveReferenceTicket,
                                    direction: MoveReferenceDirection,
                                    receipt: MoveReferenceReceipt? = nil) async throws -> MoveReferenceEvidence {
        try await worker { cancellation in
            guard ticket.historyDirectory == self.directory else { throw FileOperationFailure.invalidRequest }
            _ = try ticket.encoded()
            guard let record = try OperationHistoryInspector.record(self.directory,
                id: ticket.operationID, cancellation: cancellation).treeRecord else { throw FileOperationFailure.unsupported }
            let rootTicket = ticket.rootTicket
            let rootProof = try Self.moveReference(rootTicket, direction: direction, record: record)
            let proof = try Self.memberEvidence(ticket, rootProof: rootProof, receipt: receipt)
            let parent = try DirectoryAnchor(proof.location.deletingLastPathComponent(), resolve: false)
            let flags = proof.object.isDirectory ? O_DIRECTORY : 0
            let fd = openat(parent.fd, proof.location.lastPathComponent, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC | flags)
            guard fd >= 0 else { throw posixFailure() }; defer { close(fd) }
            try proof.validateDescriptor(fd, at: proof.location)
            let segment = try Self.publishedDestination(rootTicket, record: record)
            let absentURL = direction == .forward ? Self.relocatedSource(rootTicket.source, record: record) : segment.publication.destination
            let absentParent = try DirectoryAnchor(absentURL.deletingLastPathComponent(), resolve: false)
            let expectedParent = direction == .forward ? rootTicket.sourceParent : ticket.destinationParent
            guard absentParent.identity.sameObject(as: expectedParent) else { throw FileOperationFailure.sourceChanged }
            var info = stat()
            if direction == .undo, let displaced = segment.displacement {
                guard try EntrySnapshot(parent: absentParent.fd, name: absentURL.lastPathComponent)
                    .sameObject(as: displaced.before.identity) else { throw FileOperationFailure.destinationChanged }
            } else {
                guard fstatat(absentParent.fd, absentURL.lastPathComponent, &info, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT else {
                    throw FileOperationFailure.recoveryUncertain
                }
            }
            try absentParent.validate()
            guard let after = try OperationHistoryInspector.record(self.directory,
                id: ticket.operationID, cancellation: cancellation).treeRecord,
                  after.owner == record.owner, after.revision == record.revision,
                  after.state == record.state, after.steps == record.steps else { throw FileOperationFailure.recoveryUncertain }
            try proof.validateDescriptor(fd, at: proof.location)
            return proof
        }
    }

    internal struct MovePublication {
        let publication: JournalStep
        let displacement: JournalStep?
    }

    /// Compose acknowledged Merge ancestor renames; names alone never identify
    /// a retained container. The selected parent must still match its exact ID.
    private static func relocatedSource(_ source: URL, record: JournalRecord) -> URL {
        var current = source
        for step in record.steps where step.destination.lastPathComponent == "merged-source"
            && record.areas.contains(where: { $0.url == step.destination.deletingLastPathComponent() }) {
            if current == step.source { current = step.destination }
            else if current.path.hasPrefix(step.source.path + "/") {
                current = step.destination.appendingPathComponent(String(current.path.dropFirst(step.source.path.count + 1)))
            }
        }
        return current
    }

    internal static func publishedDestination(_ ticket: MoveReferenceTicket, record: JournalRecord) throws -> MovePublication {
        func inArea(_ url: URL) -> Bool { record.areas.contains { $0.url == url.deletingLastPathComponent() } }
        func acknowledged(_ step: JournalStep) -> Bool {
            step.after?.identity.sameObject(as: step.before.identity) == true
        }
        var publications: [JournalStep] = [], selected: MovePublication?
        var index = 0
        var sources = Set<URL>(), destinations = Set<URL>()
        // Validate every acknowledged segment; a committed between-item Stop
        // may contain fewer publications than the original plan. No unfinished
        // mutation is admitted. Merge-container retirement is an ancestor
        // relocation, never a source-to-existing-destination document mapping.
        while index < record.steps.count {
            let container = record.steps[index]
            if inArea(container.destination), container.destination.lastPathComponent == "merged-source" {
                guard !inArea(container.source), acknowledged(container), container.before.identity.isDirectory,
                      container.before.identity.device == container.destinationParent.device,
                      sources.insert(container.source).inserted else { throw FileOperationFailure.recoveryUncertain }
                index += 1; continue
            }
            var displaced: JournalStep?
            if inArea(record.steps[index].destination) {
                let step = record.steps[index]
                guard step.destination.lastPathComponent == "displaced", !inArea(step.source), acknowledged(step) else {
                    throw FileOperationFailure.recoveryUncertain
                }
                displaced = step; index += 1
                guard index < record.steps.count else { throw FileOperationFailure.recoveryUncertain }
            }
            let step = record.steps[index]
            guard let after = step.after, after.identity.sameObject(as: step.before.identity),
                  !inArea(step.destination), destinations.insert(step.destination).inserted else {
                throw FileOperationFailure.recoveryUncertain
            }
            if let displaced {
                guard displaced.source == step.destination,
                      displaced.sourceParent.sameObject(as: step.destinationParent) else { throw FileOperationFailure.recoveryUncertain }
            }
            if inArea(step.source) {
                guard step.source.lastPathComponent == "payload", index + 1 < record.steps.count else {
                    throw FileOperationFailure.recoveryUncertain
                }
                let retained = record.steps[index + 1]
                guard retained.after != nil, retained.after!.identity.sameObject(as: retained.before.identity),
                      !inArea(retained.source), inArea(retained.destination), retained.destination.lastPathComponent == "source",
                      retained.before.identity.device != after.identity.device,
                      sources.insert(retained.source).inserted else { throw FileOperationFailure.recoveryUncertain }
                if retained.source == ticket.source {
                    guard retained.before.identity.sameObject(as: ticket.sourceIdentity),
                          retained.sourceParent.sameObject(as: ticket.sourceParent) else { throw FileOperationFailure.sourceChanged }
                    selected = MovePublication(publication: step, displacement: displaced)
                }
                index += 2
            } else {
                guard sources.insert(step.source).inserted,
                      step.before.identity.device == step.destinationParent.device else { throw FileOperationFailure.recoveryUncertain }
                if step.source == ticket.source {
                    guard step.before.identity.sameObject(as: ticket.sourceIdentity),
                          step.sourceParent.sameObject(as: ticket.sourceParent) else { throw FileOperationFailure.sourceChanged }
                    selected = MovePublication(publication: step, displacement: displaced)
                }
                index += 1
            }
            publications.append(step)
        }
        guard !publications.isEmpty, publications.count <= ticket.inputCount, let selected,
              selected.publication.destination.deletingLastPathComponent() == ticket.destinationDirectory,
              selected.publication.destinationParent.sameObject(as: ticket.destinationParent) else { throw FileOperationFailure.recoveryUncertain }
        return selected
    }

    private static func moveReference(_ ticket: MoveReferenceTicket, direction: MoveReferenceDirection,
                                      record: JournalRecord) throws -> MoveReferenceEvidence {
        guard record.id == ticket.operationID, [1, 3].contains(record.version), record.operation == "Move",
              record.state == (direction == .forward ? "committed" : "undone"),
              record.nameRename == nil, record.trashIntents.isEmpty,
              record.steps.allSatisfy({ $0.after != nil && $0.undone == (direction == .undo) }) else {
            throw FileOperationFailure.recoveryUncertain
        }
        let publication = try publishedDestination(ticket, record: record).publication
        return MoveReferenceEvidence(ticket: ticket, direction: direction,
            location: direction == .forward ? publication.destination : ticket.source,
            object: direction == .forward ? publication.after!.identity : ticket.sourceIdentity,
            parent: direction == .forward ? publication.destinationParent : ticket.sourceParent)
    }
}
