import Foundation

/// Explicit current selection, carrying no file, reference or authored text.
/// Every revision/visibility check is repeated by one catalog owner message.
public struct NameLabelTarget: Sendable, Equatable {
    public let id: RememberedItemID
    public let revision: UInt64
    public init(id: RememberedItemID, revision: UInt64) { self.id = id; self.revision = revision }
}

/// One-use review capture. Authored text stays in the owning session so Forget
/// and close can destroy it even when a caller retains this opaque handle.
public final class PreparedNameLabelAddition: Sendable {
    public let itemIDs: [RememberedItemID]
    public let changedCount: Int
    public let labelCount: Int
    internal let owner: UUID
    internal let token = UUID()
    internal let changedIDs: [RememberedItemID]
    internal init(owner: UUID, ids: [RememberedItemID], changed: [RememberedItemID], labelCount: Int) {
        self.owner = owner; itemIDs = ids; changedIDs = changed
        changedCount = changed.count; self.labelCount = labelCount
    }
}

public struct NameLabelAdditionResult: Sendable, Equatable {
    public let selectedItems: Int
    public let changedItems: Int
    public var unchangedItems: Int { selectedItems - changedItems }
}

extension PersistentNameStore {
    /// Only already-authored records are admitted. This reads no native file or
    /// reference, and preserves every unrelated authored field and access row.
    public func prepareLabelAddition(_ targets: [NameLabelTarget], labels: [String]) throws -> PreparedNameLabelAddition {
        let lease = try activity?.begin(); defer { withExtendedLifetime(lease) {} }
        try requireWrite()
        guard (1...64).contains(targets.count), Set(targets.map(\.id)).count == targets.count else { throw NameIndexFailure.invalidInput }
        for target in targets {
            guard publication.allows(target.id), try database.revision(target.id) == target.revision else { throw NameIndexFailure.staleEdit }
        }
        return try core.prepareLabelAddition(targets.map(\.id), labels: labels)
    }
    public func cancelLabelAddition(_ preview: PreparedNameLabelAddition) { core.cancelLabelAddition(preview) }
    public func applyLabelAddition(_ preview: PreparedNameLabelAddition) throws -> NameLabelAdditionResult {
        let lease = try activity?.begin(); defer { withExtendedLifetime(lease) {} }
        defer { core.cancelLabelAddition(preview) }
        try Task.checkCancellation(); try requireWrite()
        guard preview.itemIDs.allSatisfy({ publication.allows($0) }) else { throw NameIndexFailure.staleEdit }
        try core.validateLabelAddition(preview)
        if preview.changedCount == 0 { return try core.applyLabelAddition(preview) }
        var committed = false
        do {
            try publication.advance(); try catalog.beginWrite()
            let result = try core.applyLabelAddition(preview)
            committed = true
            try catalog.synchronize(); try catalog.endWrite(); try database.probe?(.saveCommit)
            return result
        } catch {
            if committed || database.commitUncertain { suspended = true }
            do { try catalog.endWrite() } catch { suspended = true }
            if suspended { throw NameStoreFailure.uncertainCommit }
            throw error
        }
    }
    /// Current durable evidence only, never authority to replay a failed Save.
    public func resolveLabelAddition(_ preview: PreparedNameLabelAddition) throws -> SaveResolution {
        let lease = try activity?.begin(); defer { withExtendedLifetime(lease) {} }
        try requireOpen(); try catalog.validate()
        guard !preview.changedIDs.isEmpty, try !database.hasAllFence(),
              preview.itemIDs.allSatisfy({ publication.allows($0) }) else { return .notCurrent }
        for id in preview.changedIDs {
            guard try database.hasMutation(id, nonce: preview.token) else { return .notCurrent }
        }
        return .saved
    }
    internal func qualificationLabelBatchCount() -> Int { core.pendingLabelAdditionCount }
}
