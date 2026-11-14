#if DEBUG
import ExplorerCore
@_spi(Qualification) import LocalStorage

// App-side source proposal for Main's v3 GateABackendObservationSource.
// The reviewedFactory remains nil until the exact source/image manifest binds
// this bridge and the LocalStorage observation patch. NOT COMPILED / NOT RUN.
@MainActor final class GateABackendObservationBridge: GateABackendObservationSource {
    private struct Failure: Error {}
    private var generatedCase: ConnectionWorkspaceGeneratedCase?
    private var backend: SFTPGeneratedBackendObservation?

    func startBeforeOwnerCreation(generatedCase: ConnectionWorkspaceGeneratedCase) async throws {
        guard self.generatedCase == nil, backend == nil else { throw Failure() }
        let armed = try await SFTPGeneratedBackendObservation.arm(generatedCase: generatedCase)
        self.generatedCase = generatedCase
        backend = armed
        _ = try await armed.snapshot(generatedCase: generatedCase)
    }

    func snapshot() async throws -> GateABackendCounters {
        guard let generatedCase, let backend else { throw Failure() }
        let actual = try await backend.snapshot(generatedCase: generatedCase)
        return .init(bodyReads: actual.bodyReads,
            payloadValidationReadEntries: actual.payloadValidationReadEntries,
            workerStarts: actual.workerStarts, workerIPC: actual.workerIPC,
            remoteWrites: actual.remoteWriteSubmissions,
            remoteSaveAcknowledgements: actual.remoteSaveAcknowledgements,
            outstandingOwners: actual.outstandingOwners)
    }

    func closeAndDrain() async throws {
        guard backend != nil else { return } // No owned work when arm refused.
        let actual = try await snapshot() // Lock-synchronized, cumulative history.
        guard actual.outstandingOwners == 0 else { throw Failure() }
    }
}
#endif
