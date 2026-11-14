#if DEBUG && TRAVERSE_GATEB_NATIVE_QUALIFICATION
import CryptoKit
import Darwin
import Dispatch
import ExplorerCore
import FileOperations
import Foundation

/// A closed, qualification-only stage. Only LocalStorage can construct one;
/// the App may report its fixed code after the backend has drained its owners.
@_spi(Qualification) public struct GateBGeneratedFailure: Error, Sendable {
    public let stage: String
}

/// A second, case-bound observer counts real document Save/Stop entries and
/// checked recovery reader entries. Initial MEXSFTPM baseline chunks are
/// transport writes into the local body, not checked reader invocations.
final class GateBReadObservation: @unchecked Sendable {
    static let shared = GateBReadObservation()
    private let lock = NSLock()
    private var directory: URL?, entries = 0, saveEntries = 0, stopEntries = 0
    private var invalid = false
    func arm(directory: URL) throws {
        try lock.withLock {
            guard self.directory == nil, !invalid else { throw GateBGeneratedFailure(stage: "body-read-observer-reused") }
            self.directory = directory
        }
    }
    func enter(directory: URL) throws {
        try lock.withLock {
            guard let expected = self.directory, expected == directory, !invalid,
                  entries < Int.max else {
                invalid = true; throw GateBGeneratedFailure(stage: "foreign-or-unarmed-body-read")
            }
            entries += 1
        }
    }
    func saveEntered() {
        lock.withLock {
            if directory == nil || invalid || saveEntries == Int.max { invalid = true }
            else { saveEntries += 1 }
        }
    }
    func stopEntered() {
        lock.withLock {
            if directory == nil || invalid || stopEntries == Int.max { invalid = true }
            else { stopEntries += 1 }
        }
    }
    func snapshot() throws -> (reads: Int, saves: Int, stops: Int) {
        try lock.withLock {
            guard directory != nil, !invalid else { throw GateBGeneratedFailure(stage: "body-read-observer-invalid") }
            return (entries, saveEntries, stopEntries)
        }
    }
}

/// One exact generated editor and one exact removeUnusedAfterDrain commit. A
/// pending.json from the injected beforeRename is retained for review; no
/// general SQLite/catalog retry or discard-stage path is installed.
private final class GateBRemovalHold: @unchecked Sendable {
    private let condition = NSCondition()
    private let waitQueue = DispatchQueue(label: "traverse.gateb.removal-wait", qos: .utility)
    private var expectedEditor: UUID?, expectedBody: SFTPOriginalSpoolReference?
    private var nativeCount: (@Sendable () -> Int)?
    private var armed = false, released = false, aborted = false, returned = false
    private var timedOut = false, invalid = false, scoped = false
    private var nativeEntries = 0, pinDrains = 0, scopedEntries = 0
    private var beforeRenameEntries = 0, injected = 0

    func install(editor: UUID, body: SFTPOriginalSpoolReference) throws {
        try condition.withLock {
            guard expectedEditor == nil, expectedBody == nil else { throw GateBGeneratedFailure(stage: "observer-reused") }
            expectedEditor = editor; expectedBody = body
        }
    }
    func arm(nativeCloseCount: @escaping @Sendable () -> Int) throws {
        try condition.withLock {
            guard expectedEditor != nil, expectedBody != nil, !armed, !invalid else { throw GateBGeneratedFailure(stage: "failure-hold-not-ready") }
            nativeCount = nativeCloseCount; armed = true
        }
    }
    func nativeCloseEntered() {
        condition.withLock {
            nativeEntries += 1
            if !armed || nativeEntries > 2 || (nativeEntries != 1 && injected == 0) { invalid = true }
            condition.broadcast()
        }
    }
    func actualPinDrained() {
        condition.withLock {
            pinDrains += 1
            if !armed || pinDrains != 1 || nativeEntries != 1 { invalid = true }
            condition.broadcast()
        }
    }
    func scopedRemovalCommit(editor: UUID, body: SFTPOriginalSpoolReference) throws {
        try condition.withLock {
            scopedEntries += 1
            guard armed, !invalid, scopedEntries == 1, !scoped,
                  expectedEditor == editor, expectedBody == body,
                  nativeEntries == 1, pinDrains == 1, nativeCount?() == 1 else {
                invalid = true; condition.broadcast()
                throw GateBGeneratedFailure(stage: "wrong-remove-after-actual-drain")
            }
            scoped = true; condition.broadcast()
        }
    }
    func catalogProbe(_ stage: RemoteSettingsFile<SFTPOriginalEditorCatalogDocument>.Stage) throws {
        guard stage == .beforeRename else { return }
        condition.lock(); defer { condition.unlock() }
        // releasePending is an earlier real catalog commit. Only the scoped
        // removeUnusedAfterDrain method sets scoped=true immediately before
        // its own commit, so its beforeRename alone is held and failed.
        guard scoped else { return }
        beforeRenameEntries += 1; condition.broadcast()
        guard armed, !invalid, beforeRenameEntries == 1,
              nativeEntries == 1, pinDrains == 1, nativeCount?() == 1 else {
            invalid = true; returned = true; condition.broadcast()
            throw GateBGeneratedFailure(stage: "wrong-catalog-beforeRename")
        }
        let deadline = Date(timeIntervalSinceNow: 5)
        while !released && !aborted {
            if !condition.wait(until: deadline) {
                timedOut = true; returned = true; condition.broadcast()
                throw GateBGeneratedFailure(stage: "failure-hold-expired")
            }
        }
        if released && !aborted { injected += 1 }
        returned = true; condition.broadcast()
        throw RemoteSettingsFailure.unavailable
    }
    // NSCondition waits run on this hold's serial utility queue, outside the
    // Swift cooperative executor and any App/MainActor task. The continuation has
    // exactly one terminal resume; the condition's five-second waits remain
    // responsible for the actual failure latch.
    private func waitOnUtility(_ work: @escaping @Sendable () throws -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            waitQueue.async {
                do { try work(); continuation.resume(returning: ()) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
    func waitForHeldCommit() async throws {
        try await waitOnUtility { [self] in try waitForHeldCommitBlocking() }
    }
    private func waitForHeldCommitBlocking() throws {
        condition.lock(); defer { condition.unlock() }
        let deadline = Date(timeIntervalSinceNow: 5)
        while pinDrains != 1 || scopedEntries != 1 || beforeRenameEntries != 1 {
            if invalid || timedOut || !condition.wait(until: deadline) {
                throw GateBGeneratedFailure(stage: "actual-pin-or-scoped-commit-not-observed")
            }
        }
        guard !invalid, !timedOut, !returned else { throw GateBGeneratedFailure(stage: "failure-hold-not-owned") }
    }
    func releaseOne() throws {
        try condition.withLock {
            guard armed, scoped, beforeRenameEntries == 1, !released, !aborted, !returned,
                  !invalid, !timedOut else { throw GateBGeneratedFailure(stage: "failure-hold-release-invalid") }
            released = true; condition.broadcast()
        }
    }
    func abort() { condition.withLock { aborted = true; condition.broadcast() } }
    func waitForDrain() async throws {
        try await waitOnUtility { [self] in try waitForDrainBlocking() }
    }
    private func waitForDrainBlocking() throws {
        condition.lock(); defer { condition.unlock() }
        if beforeRenameEntries == 0 { return }
        let deadline = Date(timeIntervalSinceNow: 5)
        while !returned {
            if !condition.wait(until: deadline) { throw GateBGeneratedFailure(stage: "failure-hold-not-drained") }
        }
        guard !timedOut else { throw GateBGeneratedFailure(stage: "failure-hold-expired") }
    }
    func snapshot() throws -> (armed: Bool, native: Int, pins: Int, commits: Int, injected: Int, pendingHold: Bool) {
        try condition.withLock {
            guard !invalid, !timedOut, nativeEntries <= 2, pinDrains <= 1,
                  scopedEntries <= 1, beforeRenameEntries <= 1, injected <= 1 else {
                throw GateBGeneratedFailure(stage: "backend-observation-invalid")
            }
            return (armed, nativeEntries, pinDrains, scopedEntries, injected,
                beforeRenameEntries > 0 && !returned)
        }
    }
}

@_spi(Qualification) public struct GateBGeneratedBackendSnapshot: Sendable {
    public let instrumentationArmed: Bool
    public let nativeBufferCloseEntries: Int, actualPinDrains: Int
    public let scopedRemovalCommitEntries: Int, injectedBeforeRenameFailures: Int
    public let checkedBodyReadEntries: Int, remoteSaveEntries: Int, remoteStopEntries: Int
    public let workerLaunchAttempts: Int, workerIPC: Int, remoteWrites: Int, saveAcknowledgements: Int
    public let outstandingOwners: Int
}

/// Concrete DEBUG-only offline backend. It opens an actual generated worker
/// pipe, authenticates the closed fixture, adopts the real browser, and asks
/// that browser to open its real SFTPInPlaceDocumentSession. The App receives
/// no fabricated baseline, transport, catalog record or body path.
@_spi(Qualification) public final class GateBGeneratedBackend: @unchecked Sendable {
    public let initialContents: TextDocumentValue, connectionID: UUID
    private let root: URL, layout: ApplicationStorageLayout
    private let workspace: ConnectionWorkspace, worker: SFTPWorkerSession
    private let browser: SFTPBrowserSession, storage: SFTPInPlaceWorkingCopyStorage
    private let document: SFTPInPlaceDocumentSession, hold: GateBRemovalHold
    private let editorID: UUID, reference: SFTPOriginalSpoolReference
    private let state = NSLock()
    private var handedOut = false, closed = false
    private var retainedGraph: GateBGeneratedGraphSnapshot?

    private init(root: URL, layout: ApplicationStorageLayout, workspace: ConnectionWorkspace,
        worker: SFTPWorkerSession, browser: SFTPBrowserSession, storage: SFTPInPlaceWorkingCopyStorage,
        document: SFTPInPlaceDocumentSession, hold: GateBRemovalHold,
        editorID: UUID, reference: SFTPOriginalSpoolReference, initialContents: TextDocumentValue) {
        self.root = root; self.layout = layout; self.workspace = workspace
        self.worker = worker; self.browser = browser; self.storage = storage
        self.document = document; self.hold = hold; self.editorID = editorID
        self.reference = reference; self.initialContents = initialContents
        connectionID = browser.id
    }
    public static func make(generatedCase root: URL) async throws -> GateBGeneratedBackend {
        guard let owner = LocalStorageGeneratedCheckoutOrigin.developmentCases,
              root.isFileURL, root == root.standardizedFileURL,
              root.resolvingSymlinksInPath() == root,
              root.deletingLastPathComponent() == owner,
              UUID(uuidString: root.lastPathComponent)?.uuidString == root.lastPathComponent,
              Bundle.main.bundleIdentifier == "local.macexplorer.development",
              Bundle.main.executableURL?.path.contains("/.build/traverse-development/") == true else {
            throw GateBGeneratedFailure(stage: "backend-generated-scope")
        }
        // Fail before constructing any backend owner unless Main's private
        // reviewed image and case admission are still exact.
        _ = try GateBGeneratedChildAdmission.parentEnvironment(root: root,
            maximumSeconds: 60)
        let layout: ApplicationStorageLayout
        do {
            layout = try ApplicationStorageLayout(applicationSupport: root.appendingPathComponent("state/ApplicationSupport", isDirectory: true),
                caches: root.appendingPathComponent("state/Caches", isDirectory: true),
                bundleIdentifier: "local.macexplorer.development.gateb")
        } catch { throw GateBGeneratedFailure(stage: "backend-layout-refused") }
        let workspace: ConnectionWorkspace
        do { workspace = try ConnectionWorkspace(layout: layout) }
        catch { throw GateBGeneratedFailure(stage: "backend-workspace-init-refused") }
        var worker: SFTPWorkerSession?, browser: SFTPBrowserSession?
        var openedDocument: SFTPInPlaceDocumentSession?
        var openedCatalog: SFTPOriginalEditorCatalog?
        let hold = GateBRemovalHold()
        var setupStage = "backend-workspace-inspect-refused"
        do {
            guard try await workspace.inspect().state == .unprepared else { throw GateBGeneratedFailure(stage: "backend-case-not-fresh") }
            setupStage = "backend-workspace-prepare-refused"
            let admission = try await workspace.prepareForConnect()
            let config = admission.metadataStorage
            setupStage = "backend-storage-init-refused"
            let storage = try SFTPInPlaceWorkingCopyStorage(metadataStorage: config,
                catalogProbe: { [hold] stage in try hold.catalogProbe(stage) }, journalProbe: nil)
            openedCatalog = storage.catalog
            setupStage = "backend-read-observer-arm-refused"
            try GateBReadObservation.shared.arm(directory: storage.layout.bodies)
            setupStage = "backend-worker-start-refused"
            let launched = try await SFTPWorkerSession.generatedInPlacePipeForQualification(
                pool: .init(storage: config), activity: FileActivityGate(), scenario: .success,
                gateBCaseRoot: root)
            worker = launched
            setupStage = "backend-worker-approve-refused"
            try await launched.approve(.connectOnce)
            setupStage = "backend-worker-auth-refused"
            try await launched.authenticateGenerated()
            setupStage = "backend-browser-adopt-refused"
            let adopted = try await SFTPBrowserSession.adoptAuthenticated(launched)
            browser = adopted
            setupStage = "backend-browser-navigate-refused"
            let generation = try await adopted.navigate(pathUTF8: Data("/generated".utf8))
            let deadline = ContinuousClock.now + .seconds(8)
            while adopted.latest.snapshot?.state != .complete {
                guard .now < deadline else { throw GateBGeneratedFailure(stage: "generated-directory-not-complete") }
                try await Task.sleep(for: .milliseconds(10))
            }
            setupStage = "backend-browser-page-refused"
            let page = try await adopted.page(offset: 0)
            guard page.generation == generation, page.snapshot.state == .complete,
                  page.snapshot.count == 1, page.rows.count == 1,
                  page.rows[0].observation == 1,
                  page.rows[0].entry.name.wireUTF8 == Data("file.txt".utf8),
                  page.rows[0].entry.logicalBytes == 7,
                  page.rows[0].entry.modifiedSeconds == 77,
                  page.rows[0].entry.permissions == 0o100600 else {
                throw GateBGeneratedFailure(stage: "real-generated-listing-row")
            }
            setupStage = "backend-selection-refused"
            let selection = try SFTPDownloadSelection(generation: generation, row: page.rows[0])
            setupStage = "backend-document-open-refused"
            let doc = try await adopted.openInPlaceText(selection, storage: storage)
            openedDocument = doc
            let text = doc.initialContents
            guard text.encoded == Data("before\n".utf8) else { throw GateBGeneratedFailure(stage: "real-session-initial-body") }
            setupStage = "backend-catalog-inspect-refused"
            let catalog = try await storage.catalog.inspect()
            let active = catalog.records.filter { $0.phase == .admitted && $0.body != nil }
            guard active.count == 1, let reference = active[0].body,
                  reference.logicalBytes == 7 else { throw GateBGeneratedFailure(stage: "one-actual-admitted-body") }
            let editorID = active[0].id
            setupStage = "backend-hold-install-refused"
            try hold.install(editor: editorID, body: reference)
            return .init(root: root, layout: layout, workspace: workspace, worker: launched,
                browser: adopted, storage: storage, document: doc, hold: hold,
                editorID: editorID, reference: reference, initialContents: text)
        } catch {
            // The original exception remains private. A fixed source stage,
            // or an already closed GateB stage, is reported only after cleanup.
            let existingStage = (error as? GateBGeneratedFailure)?.stage
            let failedStage = existingStage.flatMap { value in
                value.count <= 70 && value.first.map({ "abcdefghijklmnopqrstuvwxyz".contains($0) }) == true
                    && value.allSatisfy({ "abcdefghijklmnopqrstuvwxyz0123456789-".contains($0) }) ? value : nil
            } ?? setupStage
            // Before the App installs a native buffer, the real session owns
            // the cleanup decision and can drain its pin through its normal
            // uninstalled-buffer close path. Never drop that owner silently.
            var cleanupComplete = true
            if let openedDocument {
                let result = await openedDocument.closeAfterExplicitBufferDecision()
                if case .closedUnusedCopyRemoved = result {} else { cleanupComplete = false }
            }
            if let browser {
                let result = await browser.close()
                if !result.localResourcesEnded { cleanupComplete = false }
            }
            if let worker {
                let result = await worker.close()
                if !result.localResourcesEnded { cleanupComplete = false }
            }
            await openedCatalog?.close()
            await workspace.stopAndDrain()
            if let worker, !worker.inPlaceOwnershipForQualification.processDrainRecorded {
                cleanupComplete = false
            }
            guard cleanupComplete else {
                throw GateBGeneratedFailure(stage: failedStage + "-backend-drain-incomplete")
            }
            throw GateBGeneratedFailure(stage: failedStage)
        }
    }
    public func makeDocumentSession() throws -> SFTPInPlaceDocumentSession {
        try state.withLock {
            guard !closed, !handedOut else { throw GateBGeneratedFailure(stage: "session-reused-or-closed") }
            handedOut = true; return document
        }
    }
    public func requireCrossProcessOwnerPin(held: Bool) async throws {
        guard storage.layout.bodies == layout.persistentConnectionWorkspaceDirectory.appendingPathExtension("original-bodies") else {
            throw GateBGeneratedFailure(stage: "pin-body-layout-mismatch")
        }
        try await GateBGeneratedPinProbe.check(root: root, bodies: storage.layout.bodies,
            reference: reference, held: held)
    }
    public func armUnusedRemovalFailure(nativeCloseCount: @escaping @Sendable () -> Int) async throws {
        try await document.installGateBEventObservers(
            nativeClose: { [hold] in hold.nativeCloseEntered() },
            pinDrain: { [hold] in hold.actualPinDrained() })
        try storage.catalog.installGateBScopedCommit { [hold] id, body in
            try hold.scopedRemovalCommit(editor: id, body: body)
        }
        try hold.arm(nativeCloseCount: nativeCloseCount)
    }
    public func waitForActualPinDrainBeforeCatalogCommit() async throws { try await hold.waitForHeldCommit() }
    public func releaseOneCatalogFailure() throws { try hold.releaseOne() }
    public func abortOwnedFailureHold() { hold.abort() }
    public func waitForFailureHoldDrain() async throws { try await hold.waitForDrain() }
    public func observations() throws -> GateBGeneratedBackendSnapshot {
        let counts = try hold.snapshot()
        let parent = worker.inPlaceOwnershipForQualification
        let sent = parent.sent
        let ipc = sent.values.reduce(0, +) + parent.receivedPositive
        let remoteWrites = [UInt8(9), 23, 42, 52].reduce(0) { $0 + (sent[$1] ?? 0) }
        let entries = try GateBReadObservation.shared.snapshot()
        guard ipc >= 0, entries.saves == 0, remoteWrites == 0 else {
            throw GateBGeneratedFailure(stage: "unexpected-remote-write-or-save")
        }
        // All counters above come from the actual parent process owner or
        // the checked reader entry hook; no App/UI flag supplies a zero.
        let owners = (parent.processDrainRecorded ? 0 : 1) + max(0, 1 - counts.pins) + (counts.pendingHold ? 1 : 0)
        return .init(instrumentationArmed: counts.armed,
            nativeBufferCloseEntries: counts.native, actualPinDrains: counts.pins,
            scopedRemovalCommitEntries: counts.commits, injectedBeforeRenameFailures: counts.injected,
            checkedBodyReadEntries: entries.reads,
            remoteSaveEntries: entries.saves, remoteStopEntries: entries.stops,
            workerLaunchAttempts: parent.generatedLaunchAttempts,
            workerIPC: ipc, remoteWrites: remoteWrites,
            saveAcknowledgements: parent.inPlaceSaveAcknowledgements, outstandingOwners: owners)
    }
    public func requireExactRetainedGraph() async throws {
        let observed = try await GateBGeneratedGraphOracle.capture(layout: layout, storage: storage,
            editorID: editorID, reference: reference)
        try state.withLock {
            if let prior = retainedGraph {
                guard prior == observed else { throw GateBGeneratedFailure(stage: "retained-graph-drift") }
            } else { retainedGraph = observed }
        }
    }
    /// Returns only a real fresh-process outcome. R is accepted after an
    /// exact no-follow identity+digest comparison; P requires body removal.
    public func inspectFreshRemovalAfterDetachment() async throws -> String {
        try await requireExactRetainedGraph()
        let before = try state.withLock { () throws -> GateBGeneratedGraphSnapshot in
            guard let retainedGraph else { throw GateBGeneratedFailure(stage: "retained-graph-not-established") }
            return retainedGraph
        }
        let outcome = try await GateBGeneratedRemovalProbe.attempt(root: root)
        switch outcome {
        case 82:
            let after = try await GateBGeneratedGraphOracle.capture(layout: layout, storage: storage,
                editorID: editorID, reference: reference)
            guard before == after else { throw GateBGeneratedFailure(stage: "fresh-remove-refusal-mutated-graph") }
            return "reviewRequiredWithoutMutation"
        case 80:
            try await GateBGeneratedGraphOracle.requireProgress(layout: layout, storage: storage,
                editorID: editorID, reference: reference, before: before)
            return "validGraphProgress"
        default: throw GateBGeneratedFailure(stage: "fresh-remove-unrecognized-result")
        }
    }
    public func closeAndDrain() async throws {
        if state.withLock({ closed }) { return }
        hold.abort()
        var complete = true
        do { try await hold.waitForDrain() } catch { complete = false }
        if state.withLock({ !handedOut }) {
            // The App never received this session. Only this factory may take
            // its ordinary uninstalled-buffer decision; a handed-out native
            // buffer must remain owned by the App's explicit close path.
            let result = await document.closeAfterExplicitBufferDecision()
            if case .closedUnusedCopyRemoved = result {} else { complete = false }
        }
        let ended = await browser.close()
        let workerEnd = await worker.close()
        await storage.catalog.close()
        await workspace.stopAndDrain()
        guard complete, ended.localResourcesEnded && workerEnd.localResourcesEnded,
              worker.inPlaceOwnershipForQualification.processDrainRecorded else {
            throw GateBGeneratedFailure(stage: "actual-worker-or-workspace-not-drained")
        }
        state.withLock { closed = true }
    }
}
#endif
