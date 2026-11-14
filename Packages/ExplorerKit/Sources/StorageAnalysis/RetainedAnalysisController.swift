import Foundation

// Analysis-specific orchestration only. Every native operation is an explicit
// backend seam; this file contains no filesystem, access, helper or UI code.
struct RetainedReadHandle: Equatable, Hashable, Sendable {
    let id: UInt64
    let catalogID: UUID
}
struct RetainedPublicationPin: Equatable, Sendable {
    let id: UInt64
    let catalogID: UUID
}
enum RetainedPinDisposition: Equatable, Sendable {
    case retained(epoch: UInt64), temporary, preserveUncertain
}
enum RetainedCommitOutcome: Sendable {
    // committed means EXACTLY the supplied whole index image was committed.
    case committed
    // The backend attests no write by this attempt and supplies current truth.
    case notCommitted(current: RetainedAnalysisIndex)
    case indeterminate
}
enum RetainedPinReceipt: Sendable {
    case resolved(RetainedPublicationPin, RetainedPinDisposition)
    case pending
}
enum RetainedReadCloseReceipt: Sendable {
    case closed(RetainedReadHandle)
    case pending
}
enum RetainedCleanupReceipt: Sendable {
    case removed(RetainedAnalysisRecord.Catalog)
    case verifiedAbsent(RetainedAnalysisRecord.Catalog)
    case partialUncertain(RetainedAnalysisRecord.Catalog, databaseRemoved: Bool, lockRemoved: Bool, directoryRemoved: Bool)
    case deferred, indeterminate
}
enum RetainedBackendRefusal: Equatable, Sendable { case busy, unavailable, accessDenied, changed, unsupported, cancelled }
enum RetainedPinAcquisition: Sendable {
    case pinned(RetainedPublicationPin, RetainedAnalysisRecord)
    case refused(RetainedBackendRefusal)
}
enum RetainedReadAcquisition: Sendable {
    case opened(RetainedReadHandle)
    case refused(RetainedBackendRefusal)
}
protocol RetainedAnalysisBackend: Sendable {
    // Refusal attests no pin handed to this controller. Native partial acquisition
    // remains the backend's owned responsibility; never leak it via cancellation.
    func pinPublication(_ candidate: RetainedDrainedCandidate) async -> RetainedPinAcquisition
    func commitIndex(_ proposed: RetainedAnalysisIndex, expectedEpoch: UInt64) async -> RetainedCommitOutcome
    func resolvePin(_ pin: RetainedPublicationPin, as disposition: RetainedPinDisposition) async -> RetainedPinReceipt
    // Establish current native/query-only admission or refuse. Records/handles
    // themselves are NOT filesystem access or mutation authority.
    func openCatalog(_ record: RetainedAnalysisRecord, expectedEpoch: UInt64) async -> RetainedReadAcquisition
    func closeRead(_ handle: RetainedReadHandle) async -> RetainedReadCloseReceipt
    func closeAllWarmRetaining() async -> Bool
    func closeWarmRetaining(_ catalog: RetainedAnalysisRecord.Catalog) async -> Bool
    // Must freshly require this exact evidence to remain durably pending at the
    // supplied epoch, and verify all real owners drained, before native deletion.
    func cleanup(_ catalog: RetainedAnalysisRecord.Catalog, expectedEpoch: UInt64) async -> RetainedCleanupReceipt
}

enum RetainedControllerReason: Equatable, Sendable {
    case busy, closed, stale, cancelled, invalid, pendingPin, pendingReadClose, pendingCleanup, overflow
}
enum RetainedPublicationStatus: Equatable, Sendable { case committed(epoch: UInt64), notCommitted, indeterminate }
enum RetainedControllerOutcome: Sendable {
    case publication(RetainedPublicationStatus, deliveryAllowed: Bool, pinPending: Bool)
    case opened(RetainedReadHandle)
    case readClosed, pinResolved(RetainedPublicationPin, RetainedPinDisposition), coordinationComplete
    case backendRefused(RetainedBackendRefusal)
    case refused(RetainedControllerReason), pending(RetainedControllerReason), indexIndeterminate
}
enum RetainedRevocationIntent: Sendable { case retainOnClose, forgetAll }
/// App-owned callback must revoke presentation and join its real consumers.
/// Controller invokes it after fencing admissions and before native closure.
protocol RetainedApplicationConsumerDrain: Sendable {
    func revokeAndJoin() async throws
}
/// Scoped to the hidden old generation of one successful replacement.
protocol RetainedRetiredConsumerDrain: Sendable {
    func revokeAndJoin(catalogID: UUID) async throws
}
struct RetainedPublicationTicket: Equatable, Sendable {
    fileprivate let owner: UUID, request: UUID, fence: UUID
    fileprivate let epoch: UInt64
}
struct RetainedRevocationTicket: Equatable, Sendable {
    fileprivate let owner: UUID, request: UUID, fence: UUID
}
struct RetainedControllerSnapshot: Sendable {
    let epoch: UInt64
    let fence: UUID
    let indexKnown: Bool, admissionsOpen: Bool, hasWork: Bool
    let visible: Int, pendingForget: Int, retiring: Int, reads: Int, pins: Int
}

actor RetainedAnalysisController {
    private enum Operation: Sendable {
        case publish(RetainedDrainedCandidate, UUID?, RetainedPublicationTicket)
        case open(UUID, UUID, UInt64)
        case closeRead(RetainedReadHandle, UUID, any RetainedApplicationConsumerDrain)
        case closeWarm(RetainedAnalysisRecord.Catalog, UUID, any RetainedApplicationConsumerDrain)
        case resolvePin, revoke(RetainedRevocationTicket)
        case retire(any RetainedRetiredConsumerDrain)
    }
    private struct Work { let id: UUID; let task: Task<RetainedControllerOutcome, Never> }
    private struct Revocation {
        let ticket: RetainedRevocationTicket, intent: RetainedRevocationIntent
        var hiddenCommitted = false
    }
    private let owner: UUID
    private let backend: any RetainedAnalysisBackend
    private var index: RetainedAnalysisIndex
    private var indexKnown = true
    private var admissionsOpen: Bool
    private var fence = UUID()
    private var issuedPublication: RetainedPublicationTicket?
    private var work: Work?
    private var revocation: Revocation?
    private var completingRevocation = false
    private var reads: [UUID: RetainedReadHandle] = [:]
    private var unexpectedRead: RetainedReadHandle?
    private var pendingPin: (pin: RetainedPublicationPin, disposition: RetainedPinDisposition)?

    // Caller must obtain this initial index from separately validated native
    // loading. After indeterminate commit, reconstruct from fresh native truth;
    // this instance deliberately cannot guess/reload itself back into authority.
    init(initial: RetainedAnalysisIndex, backend: any RetainedAnalysisBackend) {
        owner = UUID(); index = initial; self.backend = backend
        admissionsOpen = initial.pendingForget.isEmpty
    }
    func snapshot() -> RetainedControllerSnapshot {
        .init(epoch: index.epoch, fence: fence, indexKnown: indexKnown, admissionsOpen: admissionsOpen,
              hasWork: work != nil || completingRevocation || issuedPublication != nil || revocation != nil,
              visible: index.visibleRecords.count,
              pendingForget: index.pendingForget.count, retiring: index.retiring == nil ? 0 : 1,
              reads: reads.count + (unexpectedRead == nil ? 0 : 1), pins: pendingPin == nil ? 0 : 1)
    }
    func recordedIndex() -> RetainedAnalysisIndex? { indexKnown ? index : nil } // Sensitive; do not log.
    func hasRead(_ catalogID: UUID) -> Bool { reads[catalogID] != nil }
    func waitForActiveWork() async {
        if let current = work { _ = await current.task.value }
    }

    func publicationTicket() -> RetainedPublicationTicket? {
        guard canAdmit, issuedPublication == nil else { return nil }
        let ticket = RetainedPublicationTicket(owner: owner, request: UUID(), fence: fence, epoch: index.epoch)
        issuedPublication = ticket; return ticket
    }
    func abandonPublicationTicket(_ ticket: RetainedPublicationTicket) {
        if issuedPublication == ticket, work == nil { issuedPublication = nil }
    }
    func publish(_ candidate: RetainedDrainedCandidate, replacing: UUID? = nil,
                 ticket: RetainedPublicationTicket) async -> RetainedControllerOutcome {
        guard issuedPublication == ticket, ticket.owner == owner, ticket.fence == fence, ticket.epoch == index.epoch else { return .refused(.stale) }
        guard canAdmit else { return .refused(.closed) }
        if Task.isCancelled { issuedPublication = nil; return .refused(.cancelled) }
        return await perform(.publish(candidate, replacing, ticket))
    }
    func openPrevious(_ catalogID: UUID) async -> RetainedControllerOutcome {
        guard canAdmit else { return .refused(.closed) }
        guard reads[catalogID] == nil else { return .refused(.busy) }
        guard index.visibleRecords.contains(where: { $0.catalogID == catalogID }) else { return .refused(.invalid) }
        guard !Task.isCancelled else { return .refused(.cancelled) }
        return await perform(.open(catalogID, fence, index.epoch))
    }
    // Caller must revoke ALL consumers of this one concrete read handle first.
    // No implicit per-view sharing/refcount or stale-handle resurrection.
    func closeRead(_ catalogID: UUID, consumers: any RetainedApplicationConsumerDrain) async -> RetainedControllerOutcome {
        guard work == nil, revocation == nil,
              !completingRevocation else { return .refused(.busy) }
        guard let handle = reads[catalogID] else { return .readClosed }
        return await perform(.closeRead(handle, fence, consumers))
    }
    func closeIdleWarm(_ catalogID: UUID,
                       consumers: any RetainedApplicationConsumerDrain) async -> RetainedControllerOutcome {
        guard work == nil, !completingRevocation, revocation == nil,
              issuedPublication == nil, pendingPin == nil,
              indexKnown else { return .refused(.busy) }
        guard reads[catalogID] == nil,
              let record = index.visibleRecords.first(where: { $0.catalogID == catalogID }) else {
            return .refused(.invalid)
        }
        return await perform(.closeWarm(record.catalog, fence, consumers))
    }
    func retryPublicationPin() async -> RetainedControllerOutcome {
        guard work == nil, revocation == nil, !completingRevocation else { return .refused(.busy) }
        return await perform(.resolvePin)
    }
    // This synchronous actor turn fences admission before its caller awaits
    // App consumer revocation. No index/disk operation occurs here.
    func beginRevocation(_ intent: RetainedRevocationIntent) -> RetainedRevocationTicket? {
        guard revocation == nil, !completingRevocation else { return nil }
        fence = UUID(); admissionsOpen = false; issuedPublication = nil
        let ticket = RetainedRevocationTicket(owner: owner, request: UUID(), fence: fence)
        revocation = .init(ticket: ticket, intent: intent); work?.task.cancel(); return ticket
    }
    // Call only AFTER App revoked/drained its presentation and original scan
    // result consumers. This controller owns pins + cold read handles, not App UI.
    func completeRevocation(_ ticket: RetainedRevocationTicket,
                            consumers: any RetainedApplicationConsumerDrain) async -> RetainedControllerOutcome {
        guard revocation?.ticket == ticket, !completingRevocation else { return .refused(.stale) }
        completingRevocation = true; defer { completingRevocation = false }
        if let previous = work { previous.task.cancel(); _ = await previous.task.value }
        guard revocation?.ticket == ticket, work == nil else { return .refused(.stale) }
        do { try await consumers.revokeAndJoin() }
        catch { return .pending(.pendingReadClose) }
        guard revocation?.ticket == ticket else { return .refused(.stale) }
        return await perform(.revoke(ticket))
    }
    /// Replacement already made the old catalog invisible in one index image.
    /// The App must revoke and join its exact old-result consumers before this
    /// narrow retirement; current visible records remain admitted afterward.
    func reconcileRetiring(consumers: any RetainedRetiredConsumerDrain) async -> RetainedControllerOutcome {
        guard indexKnown, index.retiring != nil, work == nil, revocation == nil,
              !completingRevocation else { return .refused(.busy) }
        // Retirement is owned work. Quit/Forget fences and cancels it, then
        // joins it before any broad App consumer drain or native closure.
        return await perform(.retire(consumers))
    }
    private func runRetirement(_ consumers: any RetainedRetiredConsumerDrain) async -> RetainedControllerOutcome {
        guard indexKnown, let retiring = index.retiring, revocation == nil,
              !Task.isCancelled else { return .refused(.cancelled) }
        let catalog = retiring.catalog
        do { try await consumers.revokeAndJoin(catalogID: catalog.catalogID) }
        catch { return Task.isCancelled ? .refused(.cancelled) : .pending(.pendingReadClose) }
        guard !Task.isCancelled, indexKnown, index.retiring?.catalog == catalog,
              revocation == nil else { return .refused(.cancelled) }
        if pendingPin != nil { return .pending(.pendingPin) }
        guard await closeManagedRead(catalog.catalogID) else { return .pending(.pendingReadClose) }
        if unexpectedRead?.catalogID == catalog.catalogID {
            guard await closeUnexpectedRead() else { return .pending(.pendingReadClose) }
        }
        guard await backend.closeWarmRetaining(catalog) else { return .pending(.pendingReadClose) }
        guard !Task.isCancelled, revocation == nil else { return .refused(.cancelled) }
        let receipt = await backend.cleanup(catalog, expectedEpoch: index.epoch)
        switch receipt {
        case .removed(let actual), .verifiedAbsent(let actual):
            guard actual == catalog else { indexKnown = false; admissionsOpen = false; return .indexIndeterminate }
        case .partialUncertain, .deferred, .indeterminate: return .pending(.pendingCleanup)
        }
        // If revocation arrived during cleanup, its durable retiring
        // tombstone remains for the revocation path to acknowledge.
        guard !Task.isCancelled, revocation == nil else { return .refused(.cancelled) }
        do {
            let proposed = try index.acknowledgingRetirement(catalog, expectedEpoch: index.epoch)
            let status = install(await backend.commitIndex(proposed, expectedEpoch: index.epoch), proposed: proposed)
            guard case .committed = status else { return indexKnown ? .pending(.pendingCleanup) : .indexIndeterminate }
            return .coordinationComplete
        } catch { return .pending(.pendingCleanup) }
    }
    func resumeAdmissions() -> Bool {
        guard indexKnown, work == nil, revocation == nil, !completingRevocation,
              pendingPin == nil, issuedPublication == nil, reads.isEmpty,
              unexpectedRead == nil, index.pendingForget.isEmpty else { return false }
        admissionsOpen = true; return true
    }
    private var canAdmit: Bool {
        indexKnown && admissionsOpen && work == nil && !completingRevocation && revocation == nil && pendingPin == nil
    }
    private func perform(_ operation: Operation) async -> RetainedControllerOutcome {
        guard work == nil else { return .refused(.busy) }
        let id = UUID()
        let task = Task { await self.executeAndFinish(operation, id: id) }
        work = Work(id: id, task: task)
        return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }
    private func executeAndFinish(_ operation: Operation, id: UUID) async -> RetainedControllerOutcome {
        defer { if work?.id == id { work = nil } }
        switch operation {
        case .publish(let candidate, let old, let ticket): return await runPublication(candidate, replacing: old, ticket: ticket)
        case .open(let catalog, let fence, let epoch): return await runOpen(catalog, expectedFence: fence, expectedEpoch: epoch)
        case .closeRead(let handle, let expectedFence, let consumers):
            return await runCloseRead(handle, expectedFence: expectedFence, consumers: consumers)
        case .closeWarm(let catalog, let expectedFence, let consumers):
            return await runCloseWarm(catalog, expectedFence: expectedFence, consumers: consumers)
        case .resolvePin:
            guard let pending = pendingPin else { return .refused(.invalid) }
            return await resolvePendingPin()
                ? .pinResolved(pending.pin, pending.disposition) : .pending(.pendingPin)
        case .revoke(let ticket): return await runRevocation(ticket)
        case .retire(let consumers): return await runRetirement(consumers)
        }
    }
    private func runPublication(_ candidate: RetainedDrainedCandidate, replacing old: UUID?,
                                ticket: RetainedPublicationTicket) async -> RetainedControllerOutcome {
        defer { if issuedPublication == ticket { issuedPublication = nil } }
        guard !Task.isCancelled, ticket.fence == fence, ticket.epoch == index.epoch else { return .refused(.stale) }
        let pin: RetainedPublicationPin, record: RetainedAnalysisRecord
        switch await backend.pinPublication(candidate) {
        case .pinned(let value, let nativeRecord): pin = value; record = nativeRecord
        case .refused(let reason): return .backendRefused(reason)
        }
        guard pin.catalogID == record.catalogID, record.catalogID == candidate.capture.result.id else {
            indexKnown = false; admissionsOpen = false
            _ = await resolve(pin, as: .preserveUncertain)
            return .publication(.indeterminate, deliveryAllowed: false, pinPending: pendingPin != nil)
        }
        let proposed: RetainedAnalysisIndex
        do {
            if let old { proposed = try index.replacing(old, with: record, expectedEpoch: ticket.epoch) }
            else { proposed = try index.publishing(record, expectedEpoch: ticket.epoch) }
            _ = try proposed.encoded()
        } catch {
            _ = await resolve(pin, as: .temporary)
            return .refused(error as? RetainedAnalysisFailure == .overflow ? .overflow : .invalid)
        }
        guard !Task.isCancelled, ticket.fence == fence, ticket.epoch == index.epoch, indexKnown else {
            _ = await resolve(pin, as: .temporary)
            return .publication(.notCommitted, deliveryAllowed: false, pinPending: pendingPin != nil)
        }
        // Backend arms warm-store preservation before index stage creation.
        let commit = await backend.commitIndex(proposed, expectedEpoch: ticket.epoch)
        let status = install(commit, proposed: proposed)
        let disposition: RetainedPinDisposition
        switch status {
        case .committed(let epoch): disposition = .retained(epoch: epoch)
        case .notCommitted: disposition = knowsCatalog(record.catalogID) ? .preserveUncertain : .temporary
        case .indeterminate: disposition = .preserveUncertain
        }
        _ = await resolve(pin, as: disposition)
        let allowed: Bool
        if case .committed = status { allowed = pendingPin == nil && !Task.isCancelled && ticket.fence == fence && revocation == nil }
        else { allowed = false }
        return .publication(status, deliveryAllowed: allowed, pinPending: pendingPin != nil)
    }
    private func runOpen(_ catalogID: UUID, expectedFence: UUID, expectedEpoch: UInt64) async -> RetainedControllerOutcome {
        guard let record = index.visibleRecords.first(where: { $0.catalogID == catalogID }), reads.count < 3 else { return .refused(.invalid) }
        let handle: RetainedReadHandle
        switch await backend.openCatalog(record, expectedEpoch: expectedEpoch) {
        case .opened(let value): handle = value
        case .refused(let reason): return .backendRefused(reason)
        }
        // Even a late/mismatching backend handle remains owned until closed.
        guard reads[handle.catalogID] == nil else {
            // Backend contract forbids returning another already-owned handle.
            // Mark uncertain; do not overwrite the registered original owner.
            indexKnown = false; admissionsOpen = false
            if reads[handle.catalogID] != handle {
                unexpectedRead = handle; _ = await closeUnexpectedRead()
            }
            return .indexIndeterminate
        }
        reads[handle.catalogID] = handle
        if handle.catalogID != catalogID || handle.id == 0 { indexKnown = false; admissionsOpen = false }
        guard handle.catalogID == catalogID, handle.id > 0, !Task.isCancelled, expectedFence == fence,
              expectedEpoch == index.epoch, indexKnown, revocation == nil else {
            _ = await closeManagedRead(handle.catalogID)
            return indexKnown ? .refused(.stale) : .indexIndeterminate
        }
        return .opened(handle)
    }
    private func runCloseRead(_ handle: RetainedReadHandle, expectedFence: UUID,
                              consumers: any RetainedApplicationConsumerDrain) async -> RetainedControllerOutcome {
        guard !Task.isCancelled, expectedFence == fence, revocation == nil,
              reads[handle.catalogID] == handle else { return .refused(.stale) }
        do { try await consumers.revokeAndJoin() }
        catch { return Task.isCancelled ? .refused(.cancelled) : .pending(.pendingReadClose) }
        guard !Task.isCancelled, expectedFence == fence, revocation == nil,
              reads[handle.catalogID] == handle else { return .refused(.stale) }
        return await closeManagedRead(handle) ? .readClosed : .pending(.pendingReadClose)
    }
    private func runCloseWarm(_ catalog: RetainedAnalysisRecord.Catalog, expectedFence: UUID,
                              consumers: any RetainedApplicationConsumerDrain) async -> RetainedControllerOutcome {
        guard !Task.isCancelled, expectedFence == fence, revocation == nil else { return .refused(.stale) }
        do { try await consumers.revokeAndJoin() }
        catch { return Task.isCancelled ? .refused(.cancelled) : .pending(.pendingReadClose) }
        guard !Task.isCancelled, expectedFence == fence, revocation == nil else { return .refused(.stale) }
        guard await backend.closeWarmRetaining(catalog) else { return .pending(.pendingReadClose) }
        guard expectedFence == fence, revocation == nil else { return .refused(.stale) }
        return .readClosed
    }
    private func closeManagedRead(_ catalogID: UUID) async -> Bool {
        guard let handle = reads[catalogID] else { return true }
        return await closeManagedRead(handle)
    }
    private func closeManagedRead(_ handle: RetainedReadHandle) async -> Bool {
        guard reads[handle.catalogID] == handle else { return false }
        if case .closed(let receipt) = await backend.closeRead(handle), receipt == handle {
            guard reads[handle.catalogID] == handle else { return false }
            reads.removeValue(forKey: handle.catalogID); return true
        }
        return false
    }
    private func closeUnexpectedRead() async -> Bool {
        guard let handle = unexpectedRead else { return true }
        if case .closed(let receipt) = await backend.closeRead(handle), receipt == handle {
            unexpectedRead = nil; return true
        }
        return false
    }
    private func resolve(_ pin: RetainedPublicationPin, as disposition: RetainedPinDisposition) async -> Bool {
        pendingPin = (pin, disposition)
        if case .resolved(let receipt, let resolvedAs) = await backend.resolvePin(pin, as: disposition),
           receipt == pin, resolvedAs == disposition { pendingPin = nil; return true }
        return false
    }
    private func resolvePendingPin() async -> Bool {
        guard let pending = pendingPin else { return true }; return await resolve(pending.pin, as: pending.disposition)
    }
    private func install(_ outcome: RetainedCommitOutcome, proposed: RetainedAnalysisIndex) -> RetainedPublicationStatus {
        switch outcome {
        case .committed: index = proposed; return .committed(epoch: proposed.epoch)
        case .notCommitted(let current):
            guard (try? current.encoded()) != nil else { indexKnown = false; admissionsOpen = false; return .indeterminate }
            index = current; return .notCommitted
        case .indeterminate: indexKnown = false; admissionsOpen = false; return .indeterminate
        }
    }
    private func knowsCatalog(_ id: UUID) -> Bool {
        index.visibleRecords.contains { $0.catalogID == id } || index.retiring?.catalog.catalogID == id ||
            index.pendingForget.contains { $0.catalog.catalogID == id }
    }
    private func runRevocation(_ ticket: RetainedRevocationTicket) async -> RetainedControllerOutcome {
        guard var current = revocation, current.ticket == ticket else { return .refused(.stale) }
        var transitionFailure: RetainedControllerReason?
        if case .forgetAll = current.intent, !current.hiddenCommitted {
            guard indexKnown else { return .indexIndeterminate }
            do {
                let proposed = try index.beginningForgetAll(expectedEpoch: index.epoch)
                let result = install(await backend.commitIndex(proposed, expectedEpoch: index.epoch), proposed: proposed)
                if case .committed = result { current.hiddenCommitted = true; revocation = current }
            } catch { transitionFailure = error as? RetainedAnalysisFailure == .overflow ? .overflow : .invalid }
            if let transitionFailure { return .refused(transitionFailure) }
            if !indexKnown { return .indexIndeterminate }
            guard current.hiddenCommitted else { return .pending(.pendingCleanup) }
        }
        if case .forgetAll = current.intent, current.hiddenCommitted,
           let pending = pendingPin, case .retained = pending.disposition,
           knowsCatalog(pending.pin.catalogID) {
            // A publication may have committed yet its pin receipt was
            // delayed. Once Forget hides that record, it can no longer be
            // adopted as visible warm state; preserve its native owner until
            // the close receipt instead.
            _ = await resolve(pending.pin, as: .preserveUncertain)
        } else {
            _ = await resolvePendingPin()
        }
        let warmClosed = await backend.closeAllWarmRetaining()
        for handle in reads.values.sorted(by: { $0.id < $1.id }) { _ = await closeManagedRead(handle.catalogID) }
        _ = await closeUnexpectedRead()
        if !indexKnown { return .indexIndeterminate }
        if pendingPin != nil { return .pending(.pendingPin) }
        if !warmClosed { return .pending(.pendingReadClose) }
        if !reads.isEmpty || unexpectedRead != nil { return .pending(.pendingReadClose) }
        if case .forgetAll = current.intent {
            guard current.hiddenCommitted else { return .pending(.pendingCleanup) }
            // Fixed maximum3 entries. Never delete before managed read closure;
            // native backend must ALSO check all actual external/scan owners.
            let cleanup = index.pendingForget.map(\.catalog) + (index.retiring.map { [$0.catalog] } ?? [])
            for catalog in cleanup {
                let receipt = await backend.cleanup(catalog, expectedEpoch: index.epoch)
                let verified: Bool
                switch receipt {
                case .removed(let actual), .verifiedAbsent(let actual): verified = actual == catalog
                case .partialUncertain, .deferred, .indeterminate: verified = false
                }
                guard verified else { return .pending(.pendingCleanup) }
                do {
                    let proposed: RetainedAnalysisIndex
                    if index.retiring?.catalog == catalog { proposed = try index.acknowledgingRetirement(catalog, expectedEpoch: index.epoch) }
                    else { proposed = try index.acknowledgingForget(catalog, expectedEpoch: index.epoch) }
                    let status = install(await backend.commitIndex(proposed, expectedEpoch: index.epoch), proposed: proposed)
                    guard case .committed = status else { return indexKnown ? .pending(.pendingCleanup) : .indexIndeterminate }
                } catch { return .pending(.pendingCleanup) }
            }
        }
        revocation = nil; return .coordinationComplete // Admissions remain closed until explicit resume.
    }
}
