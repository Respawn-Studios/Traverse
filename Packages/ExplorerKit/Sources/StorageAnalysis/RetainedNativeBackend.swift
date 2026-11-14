import Darwin
import ExplorerCore
import Foundation

/// App supplies a fresh access lifetime; the native layer verifies the roots.
/// A retained locator is never enough to reopen a source by itself.
enum RetainedCurrentRootAccess: Sendable {
    case single(URL, any Sendable)
    case startup(StartupStoragePlan, any Sendable)
}
enum RetainedPresentationValidation: Sendable {
    case valid(RetainedCurrentRootAccess)
    case refused(RetainedBackendRefusal)
}
protocol RetainedFreshAccessProvider: Sendable {
    func acquire(for record: RetainedAnalysisRecord) async throws -> RetainedCurrentRootAccess
}
private enum RetainedRootVerifier {
    static func verify(_ record: RetainedAnalysisRecord, grant: RetainedCurrentRootAccess) throws {
        switch (record.scope, grant) {
        case (.single(let expected), .single(let url, _)):
            guard url.standardizedFileURL.path == expected.locator else { throw StorageScanFailure.changed }
            let fd = open(url.path, O_EVTONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
            guard fd >= 0 else { throw StorageScanFailure.accessDenied }
            defer { close(fd) }
            guard try RetainedAnalysisRecord.Root.capture(url, descriptor: fd) == expected else {
                throw StorageScanFailure.changed
            }
        case (.startup(let expected), .startup(let plan, _)):
            try plan.revalidateNative()
            let data = try RetainedAnalysisRecord.Root.capture(plan.dataRoot, descriptor: plan.data.descriptor)
            let system = try RetainedAnalysisRecord.Root.capture(plan.systemRoot, descriptor: plan.system.descriptor)
            let facts = plan.facts
            let active: RetainedAnalysisRecord.ActiveSystem = facts.active.snapshot.map { .snapshot($0.value) } ?? .liveSystem
            let current = try RetainedAnalysisRecord.StartupPair(container: facts.membership.container.value,
                group: facts.membership.group.value,
                data: .init(root: data, physicalRootInode: plan.data.identity.realInode),
                system: .init(root: system, physicalRootInode: plan.system.identity.realInode,
                    backingVolume: facts.system.volume.value, activeDisk: facts.active.disk.value, active: active))
            guard current == expected else { throw StorageScanFailure.changed }
            try plan.revalidateNative()
        default: throw StorageScanFailure.unsupportedLocation
        }
    }
}

/// Native storage behind the App ownership SPI. Ordinary App composition keeps
/// explicit retained analysis separate from passive lookup and source access.
/// The pure controller owns serial request/fence decisions; this actor owns
/// actual warm pins, cold result handles and native index/store operations.
actor RetainedNativeBackend: RetainedAnalysisBackend {
    private struct Pin {
        let candidate: RetainedDrainedCandidate
        let record: RetainedAnalysisRecord
        var armed = false
        var publicationIntentDurable = false
        var restorable = true
    }
    private struct ReadSlot {
        let result: StorageAnalysisResult
        let warm: Bool
        // A warm result's original scan grant may have expired. Hold the new
        // current grant through every query and the exact read closure.
        let currentAccess: RetainedCurrentRootAccess
    }
    private let storage: AnalysisResultStorage
    private let index: RetainedNativeIndexStore
    private let workerURL: URL
    private let activityGate: FileActivityGate
    private let accessProvider: any RetainedFreshAccessProvider
    private let utility = DispatchQueue(label: "MacExplorer.RetainedColdOpen", qos: .utility)
    private var nextID: UInt64 = 1
    private var pins: [UInt64: Pin] = [:]
    private var warm: [UUID: StorageAnalysisResult] = [:]
    private var uncertain: [UUID: StorageAnalysisResult] = [:]
    private var reads: [UInt64: ReadSlot] = [:]
    private var closingReads: Set<UInt64> = []
    #if DEBUG
    private var beforePublicationIntentForQualification: (@Sendable () async -> Void)?
    private var afterPreservationForQualification: (@Sendable () async -> Void)?
    func installBeforePublicationIntentForQualification(_ hook: (@Sendable () async -> Void)?) {
        beforePublicationIntentForQualification = hook
    }
    func installAfterPreservationForQualification(_ hook: (@Sendable () async -> Void)?) {
        afterPreservationForQualification = hook
    }
    func setIndexFaultForQualification(_ fault: RetainedIndexFault?) async {
        await index.setFaultForQualification(fault)
    }
    #endif

    init(storage: AnalysisResultStorage, indexDirectory: URL, workerURL: URL,
         activityGate: FileActivityGate, accessProvider: any RetainedFreshAccessProvider) throws {
        guard storage.retentionStateDirectory == indexDirectory else { throw StorageScanFailure.changed }
        self.storage = storage; index = RetainedNativeIndexStore(directory: indexDirectory)
        self.workerURL = workerURL; self.activityGate = activityGate; self.accessProvider = accessProvider
    }
    func bootstrapForGeneratedQualification() async throws {
        let activity = try activityGate.begin()
        defer { withExtendedLifetime(activity) {} }
        try await index.bootstrap()
    }
    /// Explicit user scan/repair entry only. The App constructor and passive
    /// recorded lookup call loadCanonicalIndex, never this creating method.
    func prepareForExplicitApplicationUse() async throws {
        let activity = try activityGate.begin()
        defer { withExtendedLifetime(activity) {} }
        try await index.bootstrap()
    }
    func loadCanonicalIndex() async throws -> RetainedAnalysisIndex {
        let activity = try activityGate.begin()
        defer { withExtendedLifetime(activity) {} }
        return try await index.load()
    }
    func recoverInterruptedIndexStage() async throws {
        let activity = try activityGate.begin()
        defer { withExtendedLifetime(activity) {} }
        try await index.recoverInterruptedStage()
    }
    func recoverInterruptedPublication() async throws -> RetainedAnalysisIndex {
        let activity = try activityGate.begin()
        defer { withExtendedLifetime(activity) {} }
        return try await index.recoverInterruptedPublication(poolURL: storage.directory,
            quota: storage.sessionByteLimit, activityGate: activityGate, admittedBy: activity)
    }
    private func issueID() -> UInt64? {
        guard nextID < UInt64.max else { return nil }
        defer { nextID += 1 }; return nextID
    }

    func pinPublication(_ candidate: RetainedDrainedCandidate) async -> RetainedPinAcquisition {
        guard !Task.isCancelled else { return .refused(.cancelled) }
        guard let id = issueID(),
              candidate.capture.result.id != UUID(uuid: (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)) else {
            return .refused(.unsupported)
        }
        do {
            let catalog = try await candidate.capture.result.retainedCatalogFingerprint()
            // A closed gate must not consume the one-shot candidate before
            // its bounded native fingerprint was admitted and completed.
            guard candidate.claimOnce() else { return .refused(.busy) }
            let record = try candidate.capture.makeRecord(catalog: catalog)
            guard warm[record.catalogID] == nil, uncertain[record.catalogID] == nil,
                  !pins.values.contains(where: { $0.record.catalogID == record.catalogID }) else { return .refused(.busy) }
            let pin = RetainedPublicationPin(id: id, catalogID: record.catalogID)
            pins[id] = Pin(candidate: candidate, record: record)
            return .pinned(pin, record)
        } catch is FileActivityError { return .refused(.busy)
        } catch { return .refused(.changed) }
    }
    func commitIndex(_ proposed: RetainedAnalysisIndex, expectedEpoch: UInt64) async -> RetainedCommitOutcome {
        // One admitted lifetime spans preflight, preservation, the entire
        // sidecar transaction and any proven-no-write rollback.
        guard let activity = try? activityGate.begin() else { return .indeterminate }
        defer { withExtendedLifetime(activity) {} }
        // Refuse a stale native epoch before changing a warm store's retention
        // state. The sidecar still performs the final CAS after every await.
        guard let before = try? await index.load() else { return .indeterminate }
        guard before.epoch == expectedEpoch else { return .notCommitted(current: before) }
        let target = pins.first { proposed.visibleRecords.contains($0.value.record) }
        if let (id, pin) = target {
            #if DEBUG
            if let hook = beforePublicationIntentForQualification { await hook() }
            #endif
            // Durable catalog identity and expected epoch precede the warm
            // store's in-memory preservation barrier. No stage-zero crash can
            // leave a preserved catalog with no cleanup owner.
            let prepared: RetainedPreparedPublication
            switch await index.preparePublication(proposed, expectedEpoch: expectedEpoch,
                                                   record: pin.record) {
            case .prepared(let receipt): prepared = receipt
            case .notCommitted(let current): return .notCommitted(current: current)
            case .indeterminate: return .indeterminate
            }
            guard let heldBeforeArm = pins[id], heldBeforeArm.record == pin.record,
                  heldBeforeArm.candidate.capture.result === pin.candidate.capture.result else {
                return .indeterminate
            }
            pins[id]?.publicationIntentDurable = true
            do {
                try await pin.candidate.capture.result.armRetentionPreservation(admittedBy: activity)
                guard let held = pins[id], held.record == pin.record,
                      held.candidate.capture.result === pin.candidate.capture.result else { return .indeterminate }
                pins[id]?.armed = true
                #if DEBUG
                if let hook = afterPreservationForQualification { await hook() }
                #endif
            } catch { return .indeterminate }
            return await index.commitPreparedPublication(proposed,
                expectedEpoch: expectedEpoch, receipt: prepared)
        }
        return await index.commit(proposed, expectedEpoch: expectedEpoch)
    }
    func resolvePin(_ pin: RetainedPublicationPin, as disposition: RetainedPinDisposition) async -> RetainedPinReceipt {
        guard let held = pins[pin.id], held.record.catalogID == pin.catalogID else { return .pending }
        switch disposition {
        case .retained(let epoch):
            guard held.armed, let current = try? await index.load(), current.epoch == epoch,
                  current.visibleRecords.contains(held.record), warm[pin.catalogID] == nil else { return .pending }
            warm[pin.catalogID] = held.candidate.capture.result
            pins.removeValue(forKey: pin.id)
        case .temporary:
            guard !held.armed, held.restorable else { return .pending }
            pins.removeValue(forKey: pin.id) // App still owns its ordinary result.
        case .preserveUncertain:
            if !held.armed {
                // A failed intent write cannot authorize a new preserved
                // unindexed store. Keep this pin pending for explicit repair.
                guard held.publicationIntentDurable else { return .pending }
                do { try await held.candidate.capture.result.armRetentionPreservation() }
                catch { return .pending }
            }
            uncertain[pin.catalogID] = held.candidate.capture.result
            pins.removeValue(forKey: pin.id)
        }
        return .resolved(pin, disposition)
    }
    /// App revokes presentation before calling; this method joins native
    /// requests and returns only after the EX owner descriptors close.
    func closeAllWarmRetaining() async -> Bool {
        for (id, result) in Array(warm) {
            // Controller closes an admitted App read after its consumer drain.
            // Do not close the same object here before its read handle closes.
            if reads.values.contains(where: { $0.result === result }) { continue }
            guard let receipt = await result.closeAfterRevokingApplicationConsumersAndDrainRetaining(),
                  receipt.catalogID == id, receipt.originalSession == id, receipt.ownerDescriptorClosed else { return false }
            warm.removeValue(forKey: id)
        }
        for (id, result) in Array(uncertain) {
            guard let receipt = await result.closeAfterRevokingApplicationConsumersAndDrainRetaining(),
                  receipt.catalogID == id, receipt.originalSession == id, receipt.ownerDescriptorClosed else { return false }
            uncertain.removeValue(forKey: id)
        }
        return true
    }
    func closeWarmRetaining(_ catalog: RetainedAnalysisRecord.Catalog) async -> Bool {
        let id = catalog.catalogID
        if let result = warm[id] {
            guard !reads.values.contains(where: { $0.result === result }) else { return false }
            guard let receipt = await result.closeAfterRevokingApplicationConsumersAndDrainRetaining(),
                  receipt.catalogID == id, receipt.originalSession == id,
                  receipt.ownerDescriptorClosed else { return false }
            warm.removeValue(forKey: id)
        }
        if let result = uncertain[id] {
            guard let receipt = await result.closeAfterRevokingApplicationConsumersAndDrainRetaining(),
                  receipt.catalogID == id, receipt.originalSession == id,
                  receipt.ownerDescriptorClosed else { return false }
            uncertain.removeValue(forKey: id)
        }
        return true
    }
    func openCatalog(_ record: RetainedAnalysisRecord, expectedEpoch: UInt64) async -> RetainedReadAcquisition {
        guard !Task.isCancelled else { return .refused(.cancelled) }
        guard let id = issueID(), !reads.values.contains(where: { $0.result.id == record.catalogID }),
              uncertain[record.catalogID] == nil else { return .refused(.busy) }
        var coldResult: StorageAnalysisResult?
        do {
            // One admitted lease spans root observation, helper identity,
            // bounded catalog digest, post-open checks and native handoff.
            let activity = try activityGate.begin()
            defer { withExtendedLifetime(activity) {} }
            let current = try await index.load()
            guard current.epoch == expectedEpoch, current.visibleRecords.contains(record) else { return .refused(.changed) }
            let grant = try await accessProvider.acquire(for: record)
            guard !Task.isCancelled else { return .refused(.cancelled) }
            try await verifyCurrent(record, grant: grant)
            let storage = self.storage, workerURL = self.workerURL, activityGate = self.activityGate
            let existingWarm = warm[record.catalogID]
            let result: StorageAnalysisResult
            if let existingWarm {
                guard try await existingWarm.retainedCatalogFingerprint(admittedBy: activity) == record.catalog else {
                    return .refused(.changed)
                }
                result = existingWarm
            } else {
                result = try await withCheckedThrowingContinuation { continuation in
                    utility.async {
                        continuation.resume(with: Result {
                            try StorageAnalysisResult.openRetained(record, storage: storage,
                                workerURL: workerURL, activityGate: activityGate,
                                admittedBy: activity, retainingAccess: grant)
                        })
                    }
                }
                coldResult = result
            }
            try await verifyCurrent(record, grant: grant)
            let again: RetainedAnalysisIndex
            do { again = try await index.load() }
            catch {
                if let coldResult { _ = await coldResult.closeAfterRevokingApplicationConsumersAndDrainRetaining() }
                return .refused(.unavailable)
            }
            guard !Task.isCancelled, again.epoch == expectedEpoch, again.visibleRecords.contains(record) else {
                if let coldResult { _ = await coldResult.closeAfterRevokingApplicationConsumersAndDrainRetaining() }
                return .refused(Task.isCancelled ? .cancelled : .changed)
            }
            // The controller gives the App one handle per catalog; it shares
            // this exact result object across all App presentation consumers.
            reads[id] = .init(result: result, warm: existingWarm != nil, currentAccess: grant)
            return .opened(.init(id: id, catalogID: record.catalogID))
        } catch is FileActivityError {
            if let coldResult { _ = await coldResult.closeAfterRevokingApplicationConsumersAndDrainRetaining() }
            return .refused(.busy)
        } catch let failure as StorageScanFailure {
            if let coldResult { _ = await coldResult.closeAfterRevokingApplicationConsumersAndDrainRetaining() }
            return .refused(failure == .busy ? .busy : failure == .accessDenied ? .accessDenied : .changed)
        } catch {
            if let coldResult { _ = await coldResult.closeAfterRevokingApplicationConsumersAndDrainRetaining() }
            return .refused(.unavailable)
        }
    }
    private func verifyCurrent(_ record: RetainedAnalysisRecord,
                               grant: RetainedCurrentRootAccess) async throws {
        let workerURL = self.workerURL
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            utility.async {
                continuation.resume(with: Result {
                    try RetainedRootVerifier.verify(record, grant: grant)
                    guard try RetainedHelperObservation.read(workerURL, session: record.catalogID).sha256
                            == record.helperSHA256 else { throw StorageScanFailure.changed }
                })
            }
        }
    }
    func result(for handle: RetainedReadHandle) -> StorageAnalysisResult? {
        guard let slot = reads[handle.id], slot.result.id == handle.catalogID else { return nil }
        return slot.result
    }
    /// Every additional consumer of a cached native result obtains a new
    /// current grant and rechecks index, root, helper and sealed catalog.
    /// The returned grant is held by that consumer's revocable query view.
    func validateCurrentPresentation(_ record: RetainedAnalysisRecord,
                                     expectedEpoch: UInt64,
                                     result: StorageAnalysisResult) async -> RetainedPresentationValidation {
        guard !Task.isCancelled else { return .refused(.cancelled) }
        func stillOwned() -> Bool {
            reads.contains {
                !closingReads.contains($0.key) && $0.value.result === result &&
                    $0.value.result.id == record.catalogID
            } || warm[record.catalogID] === result
        }
        guard stillOwned() else { return .refused(.changed) }
        do {
            let activity = try activityGate.begin()
            defer { withExtendedLifetime(activity) {} }
            let before = try await index.load()
            guard before.epoch == expectedEpoch, before.visibleRecords.contains(record),
                  stillOwned() else { return .refused(.changed) }
            let grant = try await accessProvider.acquire(for: record)
            guard !Task.isCancelled, stillOwned() else { return .refused(.cancelled) }
            try await verifyCurrent(record, grant: grant)
            guard try await result.retainedCatalogFingerprint(admittedBy: activity) == record.catalog else {
                return .refused(.changed)
            }
            try await verifyCurrent(record, grant: grant)
            let after = try await index.load()
            guard !Task.isCancelled, after.epoch == expectedEpoch,
                  after.visibleRecords.contains(record), stillOwned() else {
                return .refused(Task.isCancelled ? .cancelled : .changed)
            }
            return .valid(grant)
        } catch is FileActivityError { return .refused(.busy)
        } catch let failure as StorageScanFailure {
            return .refused(failure == .busy ? .busy : failure == .accessDenied ? .accessDenied : .changed)
        } catch { return .refused(.unavailable) }
    }
    func closeRead(_ handle: RetainedReadHandle) async -> RetainedReadCloseReceipt {
        guard let slot = reads[handle.id], slot.result.id == handle.catalogID,
              closingReads.insert(handle.id).inserted else { return .pending }
        defer { closingReads.remove(handle.id) }
        guard let receipt = await slot.result.closeAfterRevokingApplicationConsumersAndDrainRetaining(),
              receipt.catalogID == handle.catalogID, receipt.originalSession == handle.catalogID,
              receipt.ownerDescriptorClosed else { return .pending }
        reads.removeValue(forKey: handle.id)
        if slot.warm, warm[handle.catalogID] === slot.result {
            warm.removeValue(forKey: handle.catalogID)
        }
        return .closed(handle)
    }
    func cleanup(_ catalog: RetainedAnalysisRecord.Catalog, expectedEpoch: UInt64) async -> RetainedCleanupReceipt {
        guard !reads.values.contains(where: { $0.result.id == catalog.catalogID }),
              warm[catalog.catalogID] == nil, uncertain[catalog.catalogID] == nil,
              !pins.values.contains(where: { $0.record.catalogID == catalog.catalogID }) else { return .deferred }
        return await index.cleanup(catalog, expectedEpoch: expectedEpoch, poolURL: storage.directory,
            quota: storage.sessionByteLimit, activityGate: activityGate)
    }
}
