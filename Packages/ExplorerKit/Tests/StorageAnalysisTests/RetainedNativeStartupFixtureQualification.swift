import ExplorerCore
import Foundation
@testable import StorageAnalysis

/// Source-only adapter for Main's generated startup-plan fixture. It never
/// discovers or scans a personal root on its own. Separate-process startup18
/// cold admission remains a native gate after the plan injector is wired.
struct RetainedNativeStartupFixtureQualification {
    private struct NoConsumers: RetainedApplicationConsumerDrain {
        func revokeAndJoin() async throws {}
    }
    private struct ProvidedAccess: RetainedFreshAccessProvider {
        let plan: StartupStoragePlan
        let lifetime: any Sendable
        func acquire(for record: RetainedAnalysisRecord) async throws -> RetainedCurrentRootAccess {
            guard case .startup = record.scope else { throw StorageScanFailure.changed }
            return .startup(plan, lifetime)
        }
    }
    static func run(plan: StartupStoragePlan, discovery: StartupVolumeDiscovery,
                    workerURL: URL, storage: AnalysisResultStorage,
                    indexDirectory: URL, retainingAccess: any Sendable,
                    activityGate: FileActivityGate) async throws {
        let backend = try RetainedNativeBackend(storage: storage, indexDirectory: indexDirectory,
            workerURL: workerURL, activityGate: activityGate,
            accessProvider: ProvidedAccess(plan: plan, lifetime: retainingAccess))
        try await backend.bootstrapForGeneratedQualification()
        let scanner = StorageScanner(workerURL: workerURL, activityGate: activityGate)
        let session = try scanner.startStartupRetainedCandidate(plan: plan, discovery: discovery, storage: storage,
            retainingAccess: retainingAccess)
        var terminal: PagedStorageScanUpdate?
        for await update in session.updates where update.workerDrained { terminal = update }
        guard let warmResult = terminal?.result, terminal?.isStartupPair == true else {
            throw StorageScanFailure.invalidOutput
        }
        let before = try await warmResult.summary()
        guard let candidate = await session.drainedRetainedCandidate() else { throw StorageScanFailure.changed }
        let controller = RetainedAnalysisController(initial: try await backend.loadCanonicalIndex(), backend: backend)
        guard let ticket = await controller.publicationTicket() else { throw StorageScanFailure.busy }
        guard case .publication(.committed(_), let allowed, let pending) = await controller.publish(candidate, ticket: ticket),
              allowed, !pending else { throw StorageScanFailure.changed }
        let current = try await backend.loadCanonicalIndex()
        guard let record = current.visibleRecords.first(where: { $0.catalogID == session.id }),
              record.profile.schema == 18, record.scope.isStartup else { throw StorageScanFailure.changed }
        guard await backend.closeAllWarmRetaining() else { throw StorageScanFailure.busy }
        guard case .opened(let handle) = await backend.openCatalog(record, expectedEpoch: current.epoch),
              let cold = await backend.result(for: handle) else { throw StorageScanFailure.changed }
        let after = try await cold.summary()
        guard after.value == before.value, after.sources.count == before.sources.count,
              after.complete == before.complete else { throw StorageScanFailure.changed }
        guard case .closed(let closed) = await backend.closeRead(handle), closed == handle else {
            throw StorageScanFailure.busy
        }
        guard let revoke = await controller.beginRevocation(.forgetAll) else { throw StorageScanFailure.busy }
        let outcome = await controller.completeRevocation(revoke, consumers: NoConsumers())
        guard case .coordinationComplete = outcome else { throw StorageScanFailure.changed }
        let empty = try await backend.loadCanonicalIndex()
        guard empty.visibleRecords.isEmpty, empty.pendingForget.isEmpty else { throw StorageScanFailure.changed }
    }
}
