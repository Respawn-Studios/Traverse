import FileOperations
import Foundation

/// Opaque reference work only. The plan belongs to the same engine/reservation;
/// a private preparation failure never authorizes or repeats a file mutation.
public struct PreparedRememberedMove: Sendable {
    public let plan: TransferPlan
    public let handoffs: [RememberedMoveHandoff]
    internal let unchecked: [RememberedItemID]
    public let coverageLimited: Bool
    internal var preparationFailure: NameStoreFailure? = nil
}

public struct RememberedMoveReport: Sendable {
    public let applied: Int
    public let unchanged: Int
    public let unresolved: [RememberedItemID]
    public let coverageLimited: Bool
    public let storageFailure: NameStoreFailure?
}

extension PersistentNameStore {
    /// One reusable owner for candidate selection, fresh native access and intent
    /// admission. Native callers do not implement identity/receipt policies.
    public func prepareMoveFollowing(_ plan: TransferPlan,
        resolutions: [UUID: TransferConflictResolution], engine: RecoverableFileOperations) async throws -> PreparedRememberedMove {
        try requireMoveWrite()
        guard plan.isMove else { return PreparedRememberedMove(plan: plan, handoffs: [], unchecked: [], coverageLimited: false) }
        var ids: [RememberedItemID] = [], seen = Set<RememberedItemID>(), limited = false
        for root in plan.sources {
            try Task.checkCancellation()
            do {
                if let value = try await lookup(source: root), seen.insert(value.id).inserted { ids.append(value.id) }
            } catch RememberedReferenceFailure.followingRequired {} // ordinary unremembered roots
            catch RememberedReferenceFailure.unsupported {}
        }
        let members = try database.hasMemberFormat
        if members {
            let candidates = try moveCandidateIDs(beneath: plan.sources)
            limited = candidates.limited
            for id in candidates.ids where seen.insert(id).inserted {
                if ids.count == 2_048 { limited = true; break }; ids.append(id)
            }
        }
        var selected: [(RememberedItemID, URL)] = [], unchecked: [RememberedItemID] = []
        for id in ids {
            try Task.checkCancellation()
            if let pending = try pendingMoveHandoff(for: id) {
                // A previous clean Stop must not trap an untouched item forever.
                do {
                    guard pending.direction == .forward else { throw RememberedReferenceFailure.stale }
                    try await retireUnstartedMove(pending, evidence: engine.inspectUnstartedMove(pending.ticket))
                } catch { unchecked.append(id); continue }
            }
            do {
                let display = try await resolveReference(id)
                var location: URL?
                guard display.publish({ if $0.availability == .available { location = $0.location } }), let location,
                      plan.sources.contains(where: { location == $0 || location.path.hasPrefix($0.path + "/") }) else { continue }
                selected.append((id, location))
            } catch { unchecked.append(id) }
        }
        let returned: TransferPlan, tickets: [MoveReferenceTicket]
        if members {
            let admission = try await engine.observingMoveReferences(plan, candidates: selected.map(\.1), resolutions: resolutions)
            returned = admission.plan; tickets = admission.tickets
        } else {
            returned = plan; tickets = try engine.moveReferenceTickets(for: plan, resolutions: resolutions)
        }
        let bySource = Dictionary(uniqueKeysWithValues: tickets.map { ($0.source.path, $0) })
        var handoffs: [RememberedMoveHandoff] = [], failure: NameStoreFailure?
        for (id, source) in selected {
            guard let ticket = bySource[source.path] else { unchecked.append(id); continue }
            do { handoffs.append(try await prepareMoveHandoff(id, ticket: ticket)) }
            catch { unchecked.append(id); if let value = error as? NameStoreFailure { failure = value } }
        }
        return PreparedRememberedMove(plan: returned, handoffs: handoffs, unchecked: unchecked,
            coverageLimited: limited, preparationFailure: failure)
    }

    /// Settlement is metadata-only and drains independently of a caller's Stop.
    /// It never calls file recovery, retries a Move or changes a file outcome.
    public nonisolated func finishMoveFollowing(_ prepared: PreparedRememberedMove,
        result: RecoverableOperationResult?, engine: RecoverableFileOperations) async -> RememberedMoveReport {
        await Task.detached(priority: .utility) {
            await self.settleMoveFollowing(prepared, result: result, engine: engine)
        }.value
    }

    private func settleMoveFollowing(_ prepared: PreparedRememberedMove,
        result: RecoverableOperationResult?, engine: RecoverableFileOperations) async -> RememberedMoveReport {
        var applied = 0, unchanged = 0, unresolved: [RememberedItemID] = [], storageFailure = prepared.preparationFailure
        let receipts = Dictionary(grouping: result?.referenceReceipts ?? [], by: { $0.ticket.source.path })
        for original in prepared.handoffs {
            var row = original
            do {
                if let values = receipts[row.ticket.source.path], values.count == 1, let receipt = values.first,
                   row.ticket.isMember {
                    row = try retainMoveReceipt(row, receipt: receipt)
                }
                let proof = try await engine.inspectMoveReference(row.ticket, direction: row.direction, receipt: row.receipt)
                _ = try await applyMoveHandoff(row, evidence: proof); applied += 1
            } catch {
                if let failure = error as? NameStoreFailure { storageFailure = failure }
                do {
                    guard row.direction == .forward else { throw RememberedReferenceFailure.stale }
                    try await retireUnstartedMove(row, evidence: engine.inspectUnstartedMove(row.ticket)); unchanged += 1
                } catch {
                    if let failure = error as? NameStoreFailure { storageFailure = failure }
                    if (try? retainsMoveHandoff(row)) == true { unresolved.append(row.itemID) }
                }
            }
        }
        for id in prepared.unchecked {
            do {
                let display = try await resolveReference(id)
                var available = false
                if !display.publish({ available = $0.availability == .available }) || !available { unresolved.append(id) }
            } catch { if publication.allows(id) { unresolved.append(id) } }
        }
        return RememberedMoveReport(applied: applied, unchanged: unchanged, unresolved: unresolved,
            coverageLimited: prepared.coverageLimited, storageFailure: storageFailure)
    }
}
