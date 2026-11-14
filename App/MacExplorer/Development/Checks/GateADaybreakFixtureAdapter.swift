#if DEBUG
import AppKit
import CryptoKit
import ExplorerCore
import FileOperations
@_spi(Qualification) import LocalStorage

// App-side bridge to the reviewed Daybreak GateA seed and observer-v2 candidates. This file
// requires that reviewed LocalStorage candidate, but never implements its seed,
// catalogs, lock protocol or filesystem mutations. NOT COMPILED / NOT RUN.
typealias GateAFixtureAdapterFactory = @MainActor (URL, ApplicationStorageLayout) async throws -> any GateAFixtureAdapter

@MainActor enum GateAAppAdapterFactory {
    // Explicit native-qualification compilation condition must be bound in
    // the later exact source/image admission. Normal DEBUG/Release stays nil.
    static var reviewedFactory: GateAFixtureAdapterFactory? {
        #if TRAVERSE_GATEA_NATIVE_QUALIFICATION && !MAC_EXPLORER_DISTRIBUTION
        return { root, layout in
            try await GateADaybreakFixtureAdapter(root: root, layout: layout,
                observation: GateABackendObservationBridge())
        }
        #else
        return nil
        #endif
    }
}

// Required, not optional. The separately reviewed observation bridge provides
// actual case-bound backend snapshots with no default zeros. Counts cannot come
// from App method invocations, button presses or expected operation counts.
@MainActor protocol GateABackendObservationSource: AnyObject {
    // Must install real instrumentation before any App connection owner exists.
    // It must also cover this adapter's seed/cold assertion operations. Failure
    // must join its own partial registration before throwing.
    func startBeforeOwnerCreation(generatedCase: ConnectionWorkspaceGeneratedCase) async throws
    // bodyReads: entry into actual checked production body-read execution,
    // including attempts which later fail/cancel. All counters are monotonic.
    // outstandingOwners counts actual pending tasks/pins/resources, not objects.
    // Snapshots remain queryable after closeAndDrain; drain cannot reset counts.
    func snapshot() async throws -> GateABackendCounters
    func closeAndDrain() async throws
}

@MainActor final class GateADaybreakFixtureAdapter: GateAFixtureAdapter {
    // An honest protocol/schema identity, not a claim to hash its own source.
    // Exact App/backend source and image hashes belong to the external manifest.
    var sourceIdentity: String { "traverse.gatea.app-bridge.v3" }
    private let root: URL, layout: ApplicationStorageLayout
    private let generated: ConnectionWorkspaceGeneratedCase
    private let observation: any GateABackendObservationSource
    private var seed: ConnectionWorkspaceGeneratedSeed?
    private var refusal: ConnectionWorkspaceGeneratedRefusal?
    private var observationDrained = false
    // Only literal stage codes reach the App result; underlying errors stay private.
    struct Failure: Error { let stage: String }

    init(root: URL, layout: ApplicationStorageLayout,
         observation: any GateABackendObservationSource) async throws {
        self.root = root; self.layout = layout; self.observation = observation
        generated = try .init(root: root, layout: layout)
        do {
            try await observation.startBeforeOwnerCreation(generatedCase: generated)
            // No zero fallback: unavailable/incomplete observation throws here,
            // before the App owner or any fixture mutation is constructed.
            _ = try await observation.snapshot()
        } catch {
            do { try await observation.closeAndDrain() }
            catch { throw Failure(stage: "observation-startup-drain-failed") }
            throw error
        }
    }
    private func requireScope(_ caseRoot: URL, _ chosen: ApplicationStorageLayout? = nil) throws {
        guard caseRoot == root, chosen == nil || chosen == layout else { throw Failure(stage: "adapter-scope-changed") }
    }
    private static func digest(_ value: Data) -> String {
        SHA256.hash(data: value).map { String(format: "%02x", $0) }.joined()
    }
    private static func expectation() throws -> GateAExpectedText {
        let value = try ConnectionWorkspaceGeneratedSeed.expectedText()
        guard value.before.encoded.count == value.beforeBytes,
              value.edited.encoded.count == value.editedBytes,
              digest(value.before.encoded) == value.beforeSHA256,
              digest(value.edited.encoded) == value.editedSHA256,
              value.before != value.edited else { throw Failure(stage: "backend-expectation-count-hash-or-order") }
        return .init(before: value.before, edited: value.edited,
            beforeSHA256: value.beforeSHA256, editedSHA256: value.editedSHA256,
            beforeBytes: value.beforeBytes, editedBytes: value.editedBytes)
    }
    func seedAfterActualAdmission(_ admission: ConnectionWorkspaceAdmission,
        layout: ApplicationStorageLayout, caseRoot: URL) async throws {
        try requireScope(caseRoot, layout)
        guard seed == nil, refusal == nil, !observationDrained else { throw Failure(stage: "seed-reused-or-drained") }
        let value = try await ConnectionWorkspaceGeneratedSeed.seedAfterActualAdmission(admission, generatedCase: generated)
        seed = value // Retain real pin even if a following check fails.
        let expected = try Self.expectation()
        guard value.beforeBytes == expected.before.encoded.count,
              value.editedBytes == expected.edited.encoded.count,
              value.beforeSHA256 == expected.beforeSHA256,
              value.editedSHA256 == expected.editedSHA256 else { throw Failure(stage: "seed-receipt-count-hash-or-order") }
        guard await value.closeAndDrain() else { throw Failure(stage: "seed-pin-drain-incomplete") }
        // The seed witness remains retained for idempotent failure cleanup.
    }
    func expectedRetainedText(caseRoot: URL) async throws -> GateAExpectedText {
        try requireScope(caseRoot)
        // Fixed reviewed generated values: no catalog/body read or new seed.
        return try Self.expectation()
    }
    func installRefusalFixture(layout: ApplicationStorageLayout, caseRoot: URL) async throws {
        try requireScope(caseRoot, layout)
        guard seed == nil, refusal == nil, !observationDrained else { throw Failure(stage: "refusal-reused-or-drained") }
        refusal = try await ConnectionWorkspaceGeneratedRefusal.installRefusalFixture(generatedCase: generated)
    }
    func counters() async throws -> GateABackendCounters { try await observation.snapshot() }
    func requireActualReadPin(_ viewed: SFTPInPlaceViewedVersion, held: Bool, caseRoot: URL) async throws {
        try requireScope(caseRoot)
        // The backend derives the exact body from this already-minted opaque
        // viewed object. Independent-FD EX contention is nonmutating GateA proof;
        // it is not the separate-process GateB proof.
        try await viewed.assertGeneratedReadPin(generatedCase: generated, held: held)
    }
    func requireActiveGraph(layout: ApplicationStorageLayout, caseRoot: URL) async throws {
        try requireScope(caseRoot, layout)
        try await ConnectionWorkspaceGeneratedSeed.assertActiveGraph(generatedCase: generated)
    }
    func requireColdGraph(layout: ApplicationStorageLayout, caseRoot: URL) async throws {
        try requireScope(caseRoot, layout)
        // Opens BOTH actual pinned readers. The harness separately requires a
        // two-entry backend delta; these are not oracle snapshot reads.
        try await ConnectionWorkspaceGeneratedSeed.assertColdGraph(generatedCase: generated)
    }
    func requireRefusalPreserved(layout: ApplicationStorageLayout, caseRoot: URL) async throws {
        try requireScope(caseRoot, layout)
        guard let refusal else { throw Failure(stage: "refusal-witness-missing") }
        try await refusal.assertPreserved()
        // assertPreserved protects the exact unknown leaf only. Add the actual
        // read-only workspace inspection, which requires graph absence before
        // it can return earlierMetadataNeedsReview. Never repair or clean up.
        let workspace = try ConnectionWorkspace(layout: layout)
        do {
            guard try await workspace.inspect().state == .earlierMetadataNeedsReview else {
                throw Failure(stage: "refusal-created-active-graph-or-wrong-state")
            }
        } catch { await workspace.stopAndDrain(); throw error }
        await workspace.stopAndDrain()
    }
    func closeAndDrain() async throws {
        let seedDrained: Bool
        if let seed { seedDrained = await seed.closeAndDrain() }
        else { seedDrained = true }
        if !observationDrained {
            try await observation.closeAndDrain(); observationDrained = true
        }
        // Check actual final observations; no synthesized zero owner count.
        let final = try await observation.snapshot()
        guard seedDrained else { throw Failure(stage: "seed-pin-drain-incomplete") }
        guard final.outstandingOwners == 0 else { throw Failure(stage: "actual-backend-owners-remain") }
    }
}
#endif
