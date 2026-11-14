import Darwin
import Foundation

/// Isolated selectionGroupV2 candidate. Member data is never a journal guard.
internal struct SelectionGroupManifest: Codable, Equatable, Sendable {
    let owner: UUID
    let id: UUID
    let createdAt: Date
    let parent: URL
    let parentIdentity: EntrySnapshot
    let volume: NativeRenameVolume
    let folderName: Data
    let areaName: String
    let members: [NativeRenameEntry]

    var folder: URL { parent.appendingPathComponent(String(decoding: folderName, as: UTF8.self)) }
    var area: URL { parent.appendingPathComponent(areaName) }
    func source(_ ordinal: Int) -> URL { parent.appendingPathComponent(members[ordinal].name) }
    func destination(_ ordinal: Int) -> URL { folder.appendingPathComponent(members[ordinal].name) }

    func validate() throws {
        try OperationJournal.validateLocation(parent)
        try volume.validateRepresentation()
        guard parent.path.utf8.count <= 8192, parentIdentity.isDirectory,
              parentIdentity.device == volume.device, (1...512).contains(members.count),
              folderName.count <= 255, let name = String(data: folderName, encoding: .utf8),
              Data(name.utf8) == folderName, areaName == ".mac-explorer-selection-" + id.uuidString,
              createdAt.timeIntervalSinceReferenceDate.isFinite else { throw FileOperationFailure.invalidRequest }
        try validateName(name)
        var slots = Set<Data>(), entries = Set<String>()
        for entry in members {
            try entry.validateRepresentation()
            guard entry.identity.device == volume.device, entry.parentID == UInt64(parentIdentity.inode),
                  entry.nameBytes != folderName, slots.insert(entry.nameBytes).inserted,
                  entries.insert("\(entry.fileID):\(entry.linkID)").inserted else { throw FileOperationFailure.invalidRequest }
        }
    }
}

internal enum SelectionGroupEventKind: String, Codable, Sendable {
    case created, publishIntent, published, publicationAtOriginal
    case moveIntent, moved, moveAtOriginal, finish, stop, beginUndo
    case returnIntent, returned, returnAtGroup, membersRestored, retireIntent, retired
    case retireAtPublic, closeUnpublished, closeReview, cleanupIntent, cleanupReturned, cleanupConfirmed
}

/// confirmed denotes explicit observed-disposition confirmation, not a native receipt.
internal struct SelectionGroupEvent: Codable, Equatable, Sendable {
    let kind: SelectionGroupEventKind
    var ordinal: Int? = nil
    var entry: NativeRenameEntry? = nil
    var area: EntrySnapshot? = nil
    var marker: NativeRenameEntry? = nil
    var confirmed = false
    var custody: SelectionGroupEmptyCustody? = nil
    var target: URL? = nil
}

internal enum SelectionGroupMemberPhase: String, Codable, Sendable { case unstarted, grouped, originalConfirmed, restored }
internal enum SelectionGroupContainerPhase: String, Codable, Sendable { case undeclaredObject, privateCandidate, publicFolder, retained }
internal enum SelectionGroupState: String, Codable, Sendable { case preparing, active, completed, stoppedSettled, undoing, membersRestored, undone, closedRetained, cleanupPending, cleaned }
internal enum SelectionGroupEdge: Equatable, Sendable { case publish, move(Int), restore(Int), retire }

internal struct SelectionGroupProjection: Equatable, Sendable {
    var state = SelectionGroupState.preparing
    var container = SelectionGroupContainerPhase.undeclaredObject
    var area: EntrySnapshot?
    var marker: NativeRenameEntry?
    var containerEntry: NativeRenameEntry?
    var memberPhases: [SelectionGroupMemberPhase]
    var memberEntries: [NativeRenameEntry]
    var pending: SelectionGroupEdge?
    var forwardClosed = false
    var cleanupCustody: SelectionGroupEmptyCustody?
    var cleanupTarget: URL?
    var canCloseUnpublished: Bool {
        [.preparing, .stoppedSettled].contains(state) && container == .privateCandidate &&
            pending == nil && memberPhases.allSatisfy { $0 == .unstarted }
    }
    var isTerminal: Bool { pending == nil && [.completed, .stoppedSettled, .undone, .closedRetained, .cleaned].contains(state) }
}

internal struct SelectionGroupRecord: Equatable, Sendable {
    let manifest: SelectionGroupManifest
    var events: [SelectionGroupEvent]
    static let maximumEventBytes = 16_384
    var maximumEvents: Int { 4 * manifest.members.count + 32 }
    var revision: Int { events.count + 1 }

    func reserveEdge(_ edge: SelectionGroupEdge) throws {
        let state = try project()
        let count: Int
        switch edge {
        case .publish: count = 4 * manifest.members.count + 10
        case .move(let ordinal): count = 4 * manifest.members.count - 2 * ordinal + 8
        case .restore: count = 2 * state.memberPhases.filter { $0 == .grouped }.count + 6
        case .retire: count = 6
        }
        guard maximumEvents - events.count >= count else { throw FileOperationFailure.unsupported }
    }


    func appending(_ event: SelectionGroupEvent) throws -> Self {
        guard events.count < 4 * manifest.members.count + 32 else { throw FileOperationFailure.unsupported }
        var value = self; value.events.append(event); _ = try value.project(); return value
    }

    func project() throws -> SelectionGroupProjection {
        try manifest.validate()
        guard events.count <= 4 * manifest.members.count + 32 else { throw FileOperationFailure.recoveryUncertain }
        var value = SelectionGroupProjection(memberPhases: Array(repeating: .unstarted, count: manifest.members.count), memberEntries: manifest.members)
        func require(_ condition: Bool) throws { guard condition else { throw FileOperationFailure.recoveryUncertain } }
        for event in events {
            let nativeKinds: Set<SelectionGroupEventKind> = [.created, .published, .moved, .returned, .retired]
            let ordinalKinds: Set<SelectionGroupEventKind> = [.moveIntent, .moved, .moveAtOriginal, .returnIntent, .returned, .returnAtGroup]
            try require((event.entry != nil) == nativeKinds.contains(event.kind))
            try require((event.ordinal != nil) == ordinalKinds.contains(event.kind))
            try require((event.area != nil) == (event.kind == .created))
            try require((event.marker != nil) == (event.kind == .created))
            try require(!event.confirmed || [.published, .moved, .returned, .retired, .publicationAtOriginal, .moveAtOriginal, .returnAtGroup, .retireAtPublic, .cleanupConfirmed].contains(event.kind))
            try require((event.custody != nil) == (event.kind == .cleanupIntent))
            try require((event.target != nil) == (event.kind == .cleanupReturned))
            if let ordinal = event.ordinal { try require(manifest.members.indices.contains(ordinal)) }
            if let entry = event.entry { try entry.validateRepresentation() }
            switch event.kind {
            case .created:
                try require(value.state == .preparing && value.container == .undeclaredObject && value.pending == nil)
                let area = event.area!, entry = event.entry!
                try require(area.isDirectory && area.device == manifest.volume.device && entry.identity.isDirectory &&
                    entry.identity.device == manifest.volume.device && entry.parentID == UInt64(area.inode) && entry.nameBytes == Data("candidate".utf8))
                try event.marker!.validateRepresentation()
                try require(event.marker!.parentID == UInt64(area.inode) && event.marker!.nameBytes == Data("owner".utf8) && event.marker!.identity.type == S_IFREG)
                value.marker = event.marker
                value.area = area; value.containerEntry = entry; value.container = .privateCandidate
            case .publishIntent:
                try require(value.container == .privateCandidate && value.state == .preparing && value.pending == nil && !value.forwardClosed)
                value.pending = .publish; value.state = .active
            case .published:
                try require(value.pending == .publish && value.container == .privateCandidate)
                try Self.requireTransition(value.containerEntry!, event.entry!, parent: manifest.parentIdentity, name: manifest.folderName)
                value.containerEntry = event.entry; value.container = .publicFolder; value.pending = nil
            case .publicationAtOriginal:
                try require(value.pending == .publish && event.confirmed)
                value.pending = nil; value.state = .stoppedSettled; value.forwardClosed = true
            case .moveIntent:
                let ordinal = event.ordinal!
                try require(value.container == .publicFolder && value.state == .active && value.pending == nil && !value.forwardClosed &&
                    value.memberPhases.firstIndex(of: .unstarted) == ordinal && value.memberPhases.prefix(ordinal).allSatisfy { $0 == .grouped })
                value.pending = .move(ordinal)
            case .moved:
                let ordinal = event.ordinal!
                try require(value.pending == .move(ordinal))
                try Self.requireTransition(manifest.members[ordinal], event.entry!, parent: value.containerEntry!.identity, name: manifest.members[ordinal].nameBytes)
                value.memberEntries[ordinal] = event.entry!; value.memberPhases[ordinal] = .grouped; value.pending = nil
            case .moveAtOriginal:
                let ordinal = event.ordinal!
                try require(value.pending == .move(ordinal) && event.confirmed)
                value.memberPhases[ordinal] = .originalConfirmed; value.pending = nil; value.forwardClosed = true; value.state = .stoppedSettled
            case .finish:
                try require(value.state == .active && value.pending == nil && value.container == .publicFolder && value.memberPhases.allSatisfy { $0 == .grouped })
                value.state = .completed; value.forwardClosed = true
            case .stop:
                try require([.active, .preparing].contains(value.state) && value.pending == nil)
                value.state = .stoppedSettled; value.forwardClosed = true
            case .beginUndo:
                try require([.active, .completed, .stoppedSettled].contains(value.state) && value.pending == nil && value.container == .publicFolder)
                value.state = .undoing; value.forwardClosed = true
            case .returnIntent:
                let ordinal = event.ordinal!
                try require(value.state == .undoing && value.pending == nil && value.memberPhases.lastIndex(of: .grouped) == ordinal)
                value.pending = .restore(ordinal)
            case .returned:
                let ordinal = event.ordinal!
                try require(value.pending == .restore(ordinal))
                try Self.requireTransition(value.memberEntries[ordinal], event.entry!, parent: manifest.parentIdentity, name: manifest.members[ordinal].nameBytes)
                value.memberEntries[ordinal] = event.entry!; value.memberPhases[ordinal] = .restored; value.pending = nil
            case .returnAtGroup:
                try require(value.pending == .restore(event.ordinal!) && event.confirmed)
                value.pending = nil
            case .membersRestored:
                try require(value.state == .undoing && value.pending == nil && !value.memberPhases.contains(.grouped))
                value.state = .membersRestored
            case .retireIntent:
                try require(value.state == .membersRestored && value.pending == nil && value.container == .publicFolder)
                value.pending = .retire
            case .retired:
                try require(value.pending == .retire)
                try Self.requireTransition(value.containerEntry!, event.entry!, parent: value.area!, name: Data("retained".utf8))
                value.containerEntry = event.entry; value.container = .retained; value.pending = nil; value.state = .undone
            case .retireAtPublic:
                try require(value.pending == .retire && event.confirmed); value.pending = nil
            case .closeUnpublished:
                try require(value.canCloseUnpublished)
                value.state = .undone; value.forwardClosed = true
            case .closeReview:
                try require(value.pending == nil && [.active, .completed, .undoing, .membersRestored, .stoppedSettled].contains(value.state))
                value.state = .closedRetained; value.forwardClosed = true
            case .cleanupIntent:
                try require(value.pending == nil && [.completed, .undone, .membersRestored, .closedRetained].contains(value.state))
                let proof = event.custody!
                try proof.validate(record: manifest, state: value)
                value.cleanupCustody = proof; value.state = .cleanupPending; value.forwardClosed = true
            case .cleanupReturned:
                try require(value.state == .cleanupPending && value.cleanupCustody != nil && value.cleanupTarget == nil)
                try OperationJournal.validateLocation(event.target!)
                value.cleanupTarget = event.target
            case .cleanupConfirmed:
                try require(value.state == .cleanupPending && value.cleanupCustody != nil && value.cleanupTarget != nil)
                value.state = .cleaned
            }
        }
        return value
    }

    static func requireTransition(_ before: NativeRenameEntry, _ after: NativeRenameEntry, parent: EntrySnapshot, name: Data) throws {
        guard before.identity.sameObject(as: after.identity), before.fileID == after.fileID, before.linkID == after.linkID,
              after.parentID == UInt64(parent.inode), after.identity.device == parent.device, after.nameBytes == name else {
            throw FileOperationFailure.recoveryUncertain
        }
    }
}

internal struct CoreSelectionGroupPlan: Sendable {
    let jobID = UUID()
    let parent: URL
    let parentIdentity: EntrySnapshot
    let volume: NativeRenameVolume
    let members: [NativeRenameEntry]
    let folderName: Data
    let engine: UUID
    let use: ContinuationUse
    var history: SelectionGroupHistoryIdentity? = nil
}

internal enum SelectionGroupObservedLocation: String, Sendable { case original, destination, unavailable, denied, disconnectedOrUnavailable, unsupported, changed, conflict, unreadable }
internal struct CoreSelectionGroupReview: Sendable {
    var locations: [URL] {
        [record.manifest.parent, record.manifest.folder, record.manifest.area] +
            ((try? record.project().cleanupTarget).map { [$0] } ?? [])
    }
    let record: SelectionGroupRecord
    let pendingLocation: SelectionGroupObservedLocation?
    let additionalItems: Bool
    var problem: SelectionGroupObservedLocation? = nil
    let engine: UUID
    let use: ContinuationUse
    var history: SelectionGroupHistoryIdentity? = nil
}

internal struct SelectionGroupHooks: Sendable {
    var checkpoint: (@Sendable (String, UUID, Int?) throws -> Void)?
    /// Generated repo-owned provider only; nil uses the unchanged native Trash API.
    var trash: (@Sendable (URL) throws -> SelectionGroupTrashReturn)?
}

internal struct SelectionGroupEmptyCustody: Codable, Equatable, Sendable {
    let area: NativeRenameEntry
    let marker: NativeRenameEntry
    let container: NativeRenameEntry?
    func validate(record: SelectionGroupManifest, state: SelectionGroupProjection) throws {
        try area.validateRepresentation(); try marker.validateRepresentation()
        guard let expected = state.area, area.identity.sameObject(as: expected), area.identity.isDirectory,
              area.parentID == UInt64(record.parentIdentity.inode), area.nameBytes == Data(record.areaName.utf8),
              marker.identity.type == S_IFREG, state.marker.map({ marker.sameEntry(as: $0) }) == true, marker.parentID == area.fileID, marker.nameBytes == Data("owner".utf8) else {
            throw FileOperationFailure.recoveryUncertain
        }
        let needsContainer = [.privateCandidate, .retained].contains(state.container)
        guard (container != nil) == needsContainer else { throw FileOperationFailure.recoveryUncertain }
        if let container, let expected = state.containerEntry {
            try container.validateRepresentation()
            guard container.sameEntry(as: expected), container.nameBytes == expected.nameBytes,
                  container.identity.isDirectory else { throw FileOperationFailure.recoveryUncertain }
        }
    }
}
