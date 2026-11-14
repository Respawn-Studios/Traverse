#if DEBUG && TRAVERSE_GATEB_NATIVE_QUALIFICATION
import AppKit
import ExplorerCore
import FileOperations
@_spi(Qualification) import LocalStorage

// SOURCE ONLY. A separately reviewed exact image/entry owner must validate
// before calling this factory, then create BOTH this adapter and the ordinary
// App fixture. No default route, nil fallback or ordinary remote Save toggle.
@MainActor final class GateBGeneratedBackendAdapter: GateBBackendAdapter {
    let owner: GateBGeneratedBackend
    init(owner: GateBGeneratedBackend) { self.owner = owner }
    var schema: String { "traverse.gateb.native-close.v1" }
    var initialContents: TextDocumentValue { owner.initialContents }
    var connectionID: UUID { owner.connectionID }
    func makeDocumentSession() async throws -> SFTPInPlaceDocumentSession {
        try owner.makeDocumentSession()
    }
    func requireCrossProcessOwnerPin(held: Bool) async throws {
        try await owner.requireCrossProcessOwnerPin(held: held)
    }
    func armUnusedRemovalFailure(nativeCloseCount: @escaping @Sendable () -> Int) async throws {
        try await owner.armUnusedRemovalFailure(nativeCloseCount: nativeCloseCount)
    }
    func waitForActualPinDrainBeforeCatalogCommit() async throws {
        try await owner.waitForActualPinDrainBeforeCatalogCommit()
    }
    func releaseOneCatalogFailure() async throws { try owner.releaseOneCatalogFailure() }
    func abortOwnedFailureHold() { owner.abortOwnedFailureHold() }
    func waitForFailureHoldDrain() async throws { try await owner.waitForFailureHoldDrain() }
    func observations() async throws -> GateBBackendObservations {
        let value = try owner.observations()
        return .init(instrumentationArmed: value.instrumentationArmed,
            nativeBufferCloseEntries: value.nativeBufferCloseEntries,
            actualPinDrains: value.actualPinDrains,
            scopedRemovalCommitEntries: value.scopedRemovalCommitEntries,
            injectedBeforeRenameFailures: value.injectedBeforeRenameFailures,
            checkedBodyReadEntries: value.checkedBodyReadEntries,
            remoteSaveEntries: value.remoteSaveEntries,
            remoteStopEntries: value.remoteStopEntries,
            workerLaunchAttempts: value.workerLaunchAttempts,
            workerIPC: value.workerIPC, remoteWrites: value.remoteWrites,
            saveAcknowledgements: value.saveAcknowledgements,
            outstandingOwners: value.outstandingOwners)
    }
    func requireExactRetainedGraph() async throws { try await owner.requireExactRetainedGraph() }
    func inspectFreshRemovalAfterDetachment() async throws -> GateBRemovalOutcome {
        let raw = try await owner.inspectFreshRemovalAfterDetachment()
        guard let result = GateBRemovalOutcome(rawValue: raw) else {
            throw GateBGeneratedAdapterFailure(stage: "backend-remove-result-invalid")
        }
        return result
    }
    func closeAndDrain() async throws { try await owner.closeAndDrain() }
}
struct GateBGeneratedAdapterFailure: Error { let stage: String }

@MainActor enum GateBGeneratedBackendFactory {
    static func make(validatedEntry: any GateBReviewedEntryImageAdmission) async throws -> any GateBBackendAdapter {
        try await validatedEntry.requireCurrentEntryAndImage()
        guard Bundle.main.bundleIdentifier == "local.macexplorer.development",
              ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"] == validatedEntry.generatedCaseURL.path,
              ProcessInfo.processInfo.arguments.filter({ $0 == "--verify-ui" }).count == 1,
              ProcessInfo.processInfo.arguments.filter({ $0 == "--check-security-remote-close" }).count == 1,
              !RemoteTextEditorFeature.ordinaryEnabled else {
            throw GateBGeneratedAdapterFailure(stage: "backend-adapter-guard-refused")
        }
        let root = validatedEntry.generatedCaseURL
        let owner = try await Task.detached { try await GateBGeneratedBackend.make(generatedCase: root) }.value
        return GateBGeneratedBackendAdapter(owner: owner)
    }
}
#endif
