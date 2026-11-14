import ExplorerCore
import Foundation

extension PersistentNameStore {
    internal func qualificationReferenceFormat() throws -> Bool { try database.hasReferenceFormat }
    /// Explicit first Remember. Source following is opt-in and distinct from
    /// the durable names transaction; failure may leave the native flag set.
    public static func createRemembering(directory: URL, first: AuthoredNames, source: URL,
        retaining access: (any Sendable)? = nil, activity: FileActivityGate? = nil,
        allowDocumentFollowing: Bool = false) async throws -> PersistentNameStore {
        try await createRemembering(directory: directory, first: first, source: source, retaining: access,
            activity: activity, allowDocumentFollowing: allowDocumentFollowing, probe: nil, vfs: nil)
    }
    internal static func createRemembering(directory: URL, first: AuthoredNames, source: URL,
        retaining access: (any Sendable)? = nil, activity: FileActivityGate? = nil,
        allowDocumentFollowing: Bool, probe: NameStoreProbe?, vfs: String?) async throws -> PersistentNameStore {
        defer { withExtendedLifetime(access) {} }
        try probe?(.sourceCapture)
        let reader = NativeDocumentReferenceReader(activity: activity)
        let observed = try await reader.capture(source, scope: .readOnly, allowDocumentFollowing: allowDocumentFollowing, cancellation: .init())
        try probe?(.sourcePrepared)
        return try await create(directory: directory, first: first, activity: activity, probe: probe, vfs: vfs, reference: observed.reference)
    }

    public func prepareRemembering(_ names: AuthoredNames, source: URL,
                                  retaining access: (any Sendable)? = nil, allowDocumentFollowing: Bool = false) async throws -> PreparedReferenceChange {
        let activityLease = try activity?.begin(); defer { withExtendedLifetime(activityLease) {} }
        try requireWrite()
        let edit = try core.prepareNew(names)
        do {
            let use = try publication.beginReferenceUse(edit.itemID)
            let request = try references.begin(edit.itemID)
            defer { references.finish(request); withExtendedLifetime(use) {}; withExtendedLifetime(access) {} }
            let observed = try await referenceReader.capture(source, scope: .readOnly, allowDocumentFollowing: allowDocumentFollowing, cancellation: request.cancellation)
            try requireWrite()
            guard references.current(request), publication.allows(edit.itemID) else { throw RememberedReferenceFailure.stale }
            if let collision = try database.referenceCollision(observed.reference, excluding: edit.itemID) {
                throw RememberedReferenceFailure.alreadyRemembered(collision)
            }
            let handle = PreparedReferenceChange(edit.itemID, mutationID: edit.mutationID)
            return try references.keep(ReferenceProposal(handle: handle, evidence: observed.reference, revision: nil,
                authoredRevision: nil, newNames: edit, previous: nil), work: request)
        } catch { core.cancel(edit); throw error }
    }

    public func prepareRelink(_ id: RememberedItemID, source: URL,
                              retaining access: (any Sendable)? = nil, allowDocumentFollowing: Bool = false) async throws -> PreparedReferenceChange {
        let activityLease = try activity?.begin(); defer { withExtendedLifetime(activityLease) {} }
        try requireWrite()
        guard !references.hasRemoval(id) else { throw NameStoreFailure.busy }
        guard publication.allows(id), let authored = try database.revision(id) else { throw NameIndexFailure.missingRecord }
        let previous = try database.reference(id)
        guard previous?.access != 1 else { throw NameStoreFailure.recoveryRequired }
        let use = try publication.beginReferenceUse(id)
        let request = try references.begin(id, allowBlocked: true)
        defer { references.finish(request); withExtendedLifetime(use) {}; withExtendedLifetime(access) {} }
        let observed = try await referenceReader.capture(source, scope: .readOnly, allowDocumentFollowing: allowDocumentFollowing, cancellation: request.cancellation)
        try requireWrite()
        guard references.current(request), publication.allows(id), try database.revision(id) == authored,
              try database.reference(id)?.revision == previous?.revision else { throw RememberedReferenceFailure.stale }
        guard previous == nil || previous?.kind == observed.reference.kind else { throw RememberedReferenceFailure.unsupported }
        if let collision = try database.referenceCollision(observed.reference, excluding: id) {
            throw RememberedReferenceFailure.alreadyRemembered(collision)
        }
        let handle = PreparedReferenceChange(id)
        return try references.keep(ReferenceProposal(handle: handle, evidence: observed.reference, revision: previous?.revision,
            authoredRevision: authored, newNames: nil, previous: previous?.hint), work: request)
    }

    public func preview(_ handle: PreparedReferenceChange) throws -> ReferenceChangePreview {
        try requireOpen()
        guard publication.allows(handle.itemID) else { throw RememberedReferenceFailure.stale }
        let proposal = try references.proposal(handle)
        return ReferenceChangePreview(previousLocation: proposal.previous.map { URL(fileURLWithPath: $0) },
                                      chosenLocation: URL(fileURLWithPath: proposal.evidence.path))
    }
    public func cancel(_ handle: PreparedReferenceChange) {
        if let proposal = try? references.proposal(handle, consume: true), let edit = proposal.newNames { core.cancel(edit) }
    }

    /// Caller invokes only after explicit Relink/Remember confirmation. Names and
    /// initial binding commit together; existing Relink never rewrites names.
    @discardableResult public func apply(_ handle: PreparedReferenceChange) async throws -> RememberedItemID {
        let activityLease = try activity?.begin(); defer { withExtendedLifetime(activityLease) {} }
        try requireWrite()
        let proposal = try references.proposal(handle, consume: true)
        defer { if let edit = proposal.newNames { core.cancel(edit) } }
        let use = try publication.beginReferenceUse(handle.itemID)
        let request = try references.begin(handle.itemID, allowBlocked: true)
        defer { references.finish(request); withExtendedLifetime(use) {} }
        var committed = false
        var began = false
        do {
            let observation = try await referenceReader.resolve(proposal.evidence, cancellation: request.cancellation)
            try requireWrite()
            let currentAuthored = try database.revision(handle.itemID)
            guard references.current(request), publication.allows(handle.itemID),
                  try database.reference(handle.itemID)?.revision == proposal.revision,
                  proposal.newNames != nil || currentAuthored == proposal.authoredRevision else {
                throw RememberedReferenceFailure.stale
            }
            try publication.advance(); try catalog.beginWrite(); began = true
            if let edit = proposal.newNames {
                _ = try core.applyRemembered(edit, reference: observation.reference)
            } else {
                try database.transaction {
                    try database.saveReference(handle.itemID, evidence: observation.reference,
                        expected: proposal.revision, nonce: handle.mutationID)
                }
            }
            committed = true
            try catalog.synchronize(); try catalog.endWrite(); try database.probe?(.referenceCommit)
            references.invalidate(handle.itemID); references.regrant(handle.itemID)
            return handle.itemID
        } catch {
            if committed || database.commitUncertain { suspended = true }
            if began { do { try catalog.endWrite() } catch { suspended = true } }
            if suspended { throw NameStoreFailure.uncertainCommit }; throw error
        }
    }
    public func resolve(_ handle: PreparedReferenceChange) throws -> SaveResolution {
        let activityLease = try activity?.begin(); defer { withExtendedLifetime(activityLease) {} }
        try requireOpen(); try catalog.validate()
        guard publication.allows(handle.itemID), let row = try database.reference(handle.itemID) else { return .notCurrent }
        return row.nonce == handle.mutationID ? .saved : .notCurrent
    }

    public func resolveReference(_ id: RememberedItemID) async throws -> StoredRememberedReference {
        let activityLease = try activity?.begin(); defer { withExtendedLifetime(activityLease) {} }
        try requireOpen(); try catalog.validate()
        guard publication.allows(id), try !database.hasAllFence(), try database.revision(id) != nil else { throw NameIndexFailure.missingRecord }
        let row = try database.reference(id)
        let use = try publication.beginReferenceUse(id)
        let request = try references.begin(id, allowBlocked: true)
        defer { references.finish(request); withExtendedLifetime(use) {} }
        var state: RememberedReferenceAvailability = .needsRelink
        var location = row.map { URL(fileURLWithPath: $0.hint) }
        if references.isBlocked(id) || row?.access != nil && row?.access != 0 { state = .accessRemoved }
        else if try database.hasPendingMoveHandoff(id) { state = .needsReconciliation }
        else if let evidence = row?.evidence {
            do {
                let value = try await referenceReader.resolve(evidence, cancellation: request.cancellation)
                state = .available; location = value.url
            } catch {
                switch NativeDocumentReferenceReader.classify(error) {
                case .changed: state = .needsRelink
                case .accessNeeded: state = .accessNeeded
                case .unsupported: state = .unsupported
                case .followingRequired: state = .needsRelink
                case .cancelled, .stale: throw RememberedReferenceFailure.stale
                default: state = .unavailable
                }
            }
        }
        try requireOpen(); try catalog.validate()
        guard references.current(request), publication.allows(id), try database.reference(id)?.revision == row?.revision else {
            throw RememberedReferenceFailure.stale
        }
        return try references.capture(RememberedReferenceDisplay(id: id, availability: state, location: location), work: request, names: publication)
    }

    public nonisolated func prepareRemoveAccess(_ id: RememberedItemID) throws -> PreparedAccessRemoval {
        guard publication.allows(id) else { throw NameIndexFailure.missingRecord }
        return try references.removeAccess(id)
    }
    /// Explicit maintenance in an already writable session. A supported stale
    /// locator can be renewed without changing authored revisions or their edit
    /// captures. Startup/read-only queries never call this writing path.
    public func refreshVerifiedReference(_ id: RememberedItemID) async throws {
        let lease = try activity?.begin(); defer { withExtendedLifetime(lease) {} }
        try requireWrite()
        guard !references.hasRemoval(id), !references.isBlocked(id), publication.allows(id),
              try !database.hasPendingMoveHandoff(id),
              let previous = try database.reference(id), previous.access == 0, let evidence = previous.evidence else {
            throw RememberedReferenceFailure.stale
        }
        let use = try publication.beginReferenceUse(id), request = try references.begin(id)
        defer { references.finish(request); withExtendedLifetime(use) {} }
        let resolved = try await referenceReader.resolve(evidence, cancellation: request.cancellation)
        let fresh = try await referenceReader.capture(resolved.url, scope: evidence.scope, cancellation: request.cancellation)
        try requireWrite()
        guard references.current(request), publication.allows(id),
              try database.reference(id)?.revision == previous.revision,
              fresh.reference.volume == evidence.volume, fresh.reference.document == evidence.document,
              fresh.reference.kind == evidence.kind else { throw RememberedReferenceFailure.stale }
        var began = false, committed = false
        do {
            try catalog.beginWrite(); began = true
            try database.transaction { try database.saveReference(id, evidence: fresh.reference, expected: previous.revision, nonce: UUID()) }
            committed = true
            try catalog.synchronize(); try catalog.endWrite(); references.invalidate(id)
        } catch {
            if committed || database.commitUncertain { suspended = true }
            if began { do { try catalog.endWrite() } catch { suspended = true } }
            if suspended { throw NameStoreFailure.uncertainCommit }; throw error
        }
    }
    public func finishRemoveAccess(_ request: PreparedAccessRemoval) async throws -> RememberedAccessRemovalOutcome {
        try requireWrite()
        guard references.owns(request) else { throw NameStoreFailure.invalidRequest }
        try core.invalidate(request.itemID)
        let lease = try activity?.begin(); defer { withExtendedLifetime(lease) {} }
        do {
            if let row = try database.reference(request.itemID), row.access == 0 {
                try catalog.beginWrite(); try database.disableReference(request.itemID, expected: row.revision, nonce: request.token)
                try catalog.synchronize(); try catalog.endWrite()
            }
        } catch { suspended = true; return .sessionDisabledOnly }
        do {
            try catalog.beginWrite(); try database.purgeDisabledReferences(request.itemID)
            try catalog.synchronize(); try catalog.endWrite()
            await references.waitForDrain(request.itemID)
            try requireOpen(); try catalog.validate(); references.complete(request)
            return .removed
        } catch {
            suspended = true
            return .disabledPending
        }
    }
    public func finishPendingAccessRemoval() async throws {
        try requireWrite(); references.invalidate(nil)
        let lease = try activity?.begin(); defer { withExtendedLifetime(lease) {} }
        do {
            try catalog.beginWrite(); try database.purgeDisabledReferences()
            try catalog.synchronize(); try catalog.endWrite(); await references.waitForDrain(nil)
            try requireOpen(); try catalog.validate()
        } catch {
            // An unacknowledged durable purge must not leave this owner writing.
            // Reopening explicitly determines what reached disk.
            suspended = true
            throw NameStoreFailure.uncertainCommit
        }
    }
}
