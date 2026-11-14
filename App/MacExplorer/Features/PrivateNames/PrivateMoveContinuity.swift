import FileMemory
import FileOperations
import Foundation

enum PrivateMoveActivation {
    // Accepted root-only integration. Existing catalogs still need the explicit
    // Enable Move Following action; passive startup never upgrades storage.
    static let enabled = true
    static let membersEnabled = true // Explicit v4 opt-in; no passive catalog update.
}

struct PrivateMoveBatch: Sendable {
    let store: PersistentNameStore
    let handoffs: [RememberedMoveHandoff]
    var prepared: PreparedRememberedMove? = nil
    var restoredOriginals: [RememberedMoveHandoff] = []
    var plan: TransferPlan? { prepared?.plan }
}

/// Composition only. The engine owns file evidence; FileMemory owns reference
/// writes/revocation. A name-update problem never changes a file result.
@MainActor
extension ApplicationPrivateNames {
    func refreshMoveAttention(in store: PersistentNameStore) async {
        guard enablesMoveContinuity else { return }
        do {
            moveContinuityAvailable = try await store.supportsMoveContinuity()
            moveMembersAvailable = try await store.supportsMoveMembers()
            let pending = moveContinuityAvailable ? try await store.pendingMoveHandoffs(limit: 1) : []
            moveAttention = !pending.isEmpty || !moveGaps.isEmpty
            moveNotice = !pending.isEmpty ? "Some saved names need reconciliation. Files will not be moved or repaired by this action."
                : (moveGaps.isEmpty ? "" : (moveContinuityAvailable
                    ? "Some moved items need Relink. Their descriptions are still saved."
                    : "Enable Move Following to keep saved names with future moves. Existing descriptions are still saved."))
        } catch {
            moveAttention = true
            moveNotice = "Saved names need attention in Remembered Items. File operations keep their own results."
            recordMoveStorageFailure(error)
        }
    }

    func prepareMoveNames(plan: TransferPlan, choices: [UUID: TransferConflictResolution],
                          engine: RecoverableFileOperations) async -> PrivateMoveBatch? {
        guard enablesMoveContinuity, plan.isMove, directory != nil else { return nil }
        do {
            guard let readable = try await readableStore() else { return nil }
            if try await readable.supportsMoveMembers(), let store = try await writer() {
                let prepared = try await store.prepareMoveFollowing(plan, resolutions: choices, engine: engine)
                return PrivateMoveBatch(store: store, handoffs: prepared.handoffs, prepared: prepared)
            }
            var selected: [(RememberedItemID, URL)] = []
            // Only captured roots, not a catalog or filesystem crawl. Native
            // work remains on the existing bounded reference workers.
            for source in plan.sources {
                try Task.checkCancellation()
                do {
                    if let names = try await readable.lookup(source: source) {
                        let display = try await readable.resolveReference(names.id)
                        var available = false
                        guard display.publish({ available = $0.availability == .available }), available else { continue }
                        selected.append((names.id, source))
                    }
                } catch RememberedReferenceFailure.followingRequired {} // ordinary unremembered source
                catch RememberedReferenceFailure.unsupported {} // unsupported roots have no reference
            }
            guard !selected.isEmpty else { return nil }
            let tickets = try engine.moveReferenceTickets(for: plan, resolutions: choices)
            var ticketsBySource: [String: MoveReferenceTicket] = [:]
            for ticket in tickets {
                guard ticketsBySource.updateValue(ticket, forKey: ticket.source.path) == nil else { throw FileOperationFailure.invalidRequest }
            }
            guard try await readable.supportsMoveContinuity(), let store = try await writer() else {
                moveGaps.formUnion(selected.map(\.0)); await refreshMoveAttention(in: readable); return nil
            }
            var handoffs: [RememberedMoveHandoff] = []
            for (id, source) in selected {
                guard let ticket = ticketsBySource[source.path] else { moveGaps.insert(id); continue }
                do { handoffs.append(try await store.prepareMoveHandoff(id, ticket: ticket)) }
                catch {
                    recordMoveStorageFailure(error)
                    if let display = try? await store.resolveReference(id) {
                        var stillBound = false
                        display.publish { stillBound = $0.availability == .available && $0.location?.path == source.path }
                        if stillBound { moveGaps.insert(id) }
                    }
                }
            }
            if !moveGaps.isEmpty {
                moveAttention = true; moveNotice = "Some moved items may need Relink. Their descriptions stay saved."
            }
            return PrivateMoveBatch(store: store, handoffs: handoffs)
        } catch {
            recordMoveStorageFailure(error)
            moveAttention = true; moveNotice = "The transfer can continue; saved names may need Relink. Open Remembered Items to review."
            return nil
        }
    }

    func prepareMoveUndoNames(operationID: UUID, engine: RecoverableFileOperations) async -> PrivateMoveBatch? {
        guard enablesMoveContinuity, directory != nil else { return nil }
        do {
            guard let readable = try await readableStore(), try await readable.supportsMoveContinuity(),
                  let store = try await writer() else { return nil }
            var after: UUID?, handles: [RememberedMoveHandoff] = [], originals: [RememberedMoveHandoff] = []
            // A transfer admits at most 1,024 roots. Page rather than silently
            // truncating Undo at the old 64/128-row API boundary.
            for _ in 0..<32 {
                let page = try await store.moveHandoffs(for: operationID, limit: 64, after: after)
                for row in page where row.direction == .forward {
                    do {
                        let proof = try await engine.inspectMoveReference(row.ticket, direction: .forward, receipt: row.receipt)
                        if try await store.pendingMoveHandoff(for: row.itemID)?.id == row.id {
                            _ = try await store.applyMoveHandoff(row, evidence: proof)
                        }
                        handles.append(try await store.prepareMoveUndo(row, evidence: proof))
                    } catch {
                        recordMoveStorageFailure(error)
                        if try await store.pendingMoveHandoff(for: row.itemID)?.id == row.id { originals.append(row) }
                        if (try? await store.retainsMoveHandoff(row)) == true { moveGaps.insert(row.itemID) }
                    }
                }
                for row in page where row.direction == .undo {
                    if try await store.pendingMoveHandoff(for: row.itemID)?.id == row.id { handles.append(row) }
                }
                after = page.last?.id
                if page.count < 64 { break }
            }
            if !moveGaps.isEmpty { moveAttention = true; moveNotice = "Undo can continue; some saved names may need review." }
            return PrivateMoveBatch(store: store, handoffs: handles, restoredOriginals: originals)
        } catch {
            recordMoveStorageFailure(error)
            moveAttention = true; moveNotice = "Undo can continue; saved names may need reconciliation."; return nil
        }
    }

    func finishMoveNames(_ batch: PrivateMoveBatch?, engine: RecoverableFileOperations,
                         result: RecoverableOperationResult? = nil) async {
        // Unstructured settlement drains even if the file task was stopped.
        // It never starts file recovery or resumes cancelled work.
        await Task { @MainActor in
            await self.settleMoveNames(batch, engine: engine, result: result)
        }.value
    }

    private func settleMoveNames(_ batch: PrivateMoveBatch?, engine: RecoverableFileOperations,
                                result: RecoverableOperationResult?) async {
        guard let batch else { return }
        if let prepared = batch.prepared {
            let report = await batch.store.finishMoveFollowing(prepared, result: result, engine: engine)
            moveGaps.subtract(prepared.handoffs.map(\.itemID)); moveGaps.formUnion(report.unresolved)
            if let error = report.storageFailure { recordMoveStorageFailure(error) }
            moveCoverageNotice = report.coverageLimited
                ? "More saved locations were not checked. Some descriptions may need Relink; files keep their own transfer results." : ""
            if let current = try? await readableStore() { await refreshMoveAttention(in: current) }
            moveReferencesChanged(); return
        }
        for row in batch.handoffs {
            do {
                let proof = try await engine.inspectMoveReference(row.ticket, direction: row.direction, receipt: row.receipt)
                _ = try await batch.store.applyMoveHandoff(row, evidence: proof)
                moveGaps.remove(row.itemID)
            } catch {
                // A clean committed prefix may leave later units untouched.
                // Retire those intents only with fresh original-object proof so
                // Continue Remaining can admit a new independent reservation.
                if row.direction == .forward, let original = try? await engine.inspectUnstartedMove(row.ticket) {
                    do { try await batch.store.retireUnstartedMove(row, evidence: original); moveGaps.remove(row.itemID) }
                    catch { recordMoveStorageFailure(error) }
                } else { recordMoveStorageFailure(error) }
            }
        }
        for row in batch.restoredOriginals {
            do {
                let original = try await engine.inspectRestoredMoveOriginal(row.ticket)
                try await batch.store.retireUnstartedMove(row, evidence: original); moveGaps.remove(row.itemID)
            } catch { recordMoveStorageFailure(error) }
        }
        if let current = try? await readableStore() { await refreshMoveAttention(in: current) }
        moveReferencesChanged()
    }

    func reconcileMoveNames(_ item: RememberedItemID, engine: RecoverableFileOperations) async throws {
        guard enablesMoveContinuity else { throw NameStoreFailure.unavailable }
        guard let store = try await writer(), let row = try await store.pendingMoveHandoff(for: item) else {
            throw RememberedReferenceFailure.stale
        }
        // A private-storage failure must retain its own recovery action, rather
        // than being mistaken for evidence that the file move never started.
        let proof: MoveReferenceEvidence
        do { proof = try await engine.inspectMoveReference(row.ticket, direction: row.direction, receipt: row.receipt) }
        catch {
            guard row.direction == .forward else { throw error }
            let original: UnstartedMoveEvidence
            if let unchanged = try? await engine.inspectUnstartedMove(row.ticket) { original = unchanged }
            else { original = try await engine.inspectRestoredMoveOriginal(row.ticket) }
            do { try await store.retireUnstartedMove(row, evidence: original) }
            catch { recordMoveStorageFailure(error); throw error }
            moveGaps.remove(item); await refreshMoveAttention(in: store); moveReferencesChanged(); return
        }
        do { _ = try await store.applyMoveHandoff(row, evidence: proof) }
        catch { recordMoveStorageFailure(error); throw error }
        moveGaps.remove(item); await refreshMoveAttention(in: store); moveReferencesChanged()
    }
}
