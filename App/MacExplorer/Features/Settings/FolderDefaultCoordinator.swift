import Combine
import ExplorerCore
import Foundation

/// One application-owned instance, shared by every Settings presentation.
/// Views own only presentation tokens and never own/cancel a native request.
@MainActor final class FolderDefaultCoordinator: ObservableObject {
    enum Phase: Equatable { case idle, checking, preparing, requesting, recording }
    enum Notice {
        case none, observationUnavailable, recoveryUnavailable, changed, notSubmitted
        case selected, selectedWithError, cancelled, failed, unconfirmed, closing
    // BEGIN quota3 admission
        case storageCapacity, recordingCapacity
    // END quota3 admission
    }
    struct Consent: Equatable {
        fileprivate let owner: UUID, nonce: UUID, generation: UUID, presentation: UUID
        fileprivate let direction: FolderDefaultRecoveryRecord.Direction
        fileprivate let current: FolderDefaultApplication, traverse: FolderDefaultApplication
        fileprivate let recovery: FolderDefaultRecoveryRecord?
        var destination: FolderDefaultApplication { direction == .makeTraverse ? traverse : recovery!.previous }
        private var targetName: String { traverse.bundleIdentifier == FolderDefaultIdentityPolicy.previewIdentifier ? "Traverse Preview" : "Traverse" }
        var title: String { direction == .makeTraverse ? "Make \(targetName) the default folder app?" : "Restore the previous folder app?" }
        var button: String { direction == .makeTraverse ? "Make \(targetName) Default" : "Restore Previous" }
        var explanation: String {
            var text = "This asks macOS to open folders with \(destination.name) instead of \(current.name). macOS may ask for confirmation."
            if direction == .makeTraverse {
                text += " Restore Previous will ask macOS to use \(current.name) again."
                if let recovery, !recovery.previous.identifies(current) {
                    text += " This replaces the earlier saved restore choice, \(recovery.previous.name)."
                }
            }
            if recovery?.stage == .pending || recovery?.stage == .unreadable {
                text += " The earlier request was not confirmed. This is a new request using the current observation."
            }
            return text + " Finder remains available. Open and Save dialogs keep their usual behavior."
        }
    }
    @Published private(set) var phase = Phase.idle
    @Published private(set) var notice = Notice.none
    @Published private(set) var current: FolderDefaultApplication?
    @Published private(set) var traverse: FolderDefaultApplication?
    @Published private(set) var recovery: FolderDefaultRecoveryRecord?
    private let system: any FolderDefaultSystem
    private let store: any FolderDefaultRecoveryStore
    let permitsChanges: Bool
    private let activity: FileActivityGate
    private let owner = UUID()
    private var generation = UUID()
    private var presentations = Set<UUID>()
    private var issuedConsent: Consent?
    private var work: Task<Void, Never>?
    private var permit: FolderDefaultRequestPermit?
    private var pendingRefresh = false, accepting = true
    private var observationIsFresh = false, recoveryIsLoaded = false

    init(system: any FolderDefaultSystem, store: any FolderDefaultRecoveryStore, activity: FileActivityGate,
         permitsChanges: Bool = FolderDefaultFeature.permitsSystemChanges) {
        self.system = system; self.store = store; self.activity = activity; self.permitsChanges = permitsChanges
    }
    var isBusy: Bool { work != nil }
    var isCurrent: Bool { current.flatMap { app in traverse.map(app.identifies) } == true }
    var isAnotherTraverseCopy: Bool {
        guard let current, let traverse else { return false }
        return current.bundleIdentifier == traverse.bundleIdentifier && !current.identifies(traverse)
    }
    var hasForeignRestoreChoice: Bool {
        guard let recovery, let traverse else { return false }
        return !recovery.traverse.identifies(traverse)
    }
    var canMakeDefault: Bool {
        ready && current != nil && traverse != nil && !isCurrent && !isAnotherTraverseCopy && !hasForeignRestoreChoice
    }
    var canRestorePrevious: Bool { ready && isCurrent && recovery != nil && !hasForeignRestoreChoice }
    private var ready: Bool {
        permitsChanges && accepting && !presentations.isEmpty && work == nil
            && observationIsFresh && recoveryIsLoaded
    }
    var detail: String {
        if isBusy {
            if phase == .checking { return "Checking the current folder app…" }
            if phase == .recording { return "Checking the result…" }
            return permit?.isSubmitted == true
                ? "Waiting for macOS to finish. Closing Settings does not cancel a submitted request."
                : "Preparing the folder app request…"
        }
        switch notice {
        case .observationUnavailable: return "The current folder app could not be checked. Try Refresh."
        case .recoveryUnavailable: return "The previous-app setting is unavailable or could not be confirmed. Try Refresh before making changes."
        case .changed: return "The folder app or restore choice changed. Refresh before trying again."
        case .notSubmitted: return "No change was submitted to macOS. The current observation is shown above."
        case .selected: return current.map { "Folders now open in \($0.name)." } ?? "The folder app was changed."
        case .selectedWithError: return "The requested app was observed, but macOS also reported a problem."
        case .cancelled: return "macOS cancelled the request. The current observation is shown above."
        case .failed: return "macOS reported a problem. Review the current observation before trying again."
        case .unconfirmed: return "The requested choice could not be confirmed. The previous app is still saved for review."
        case .closing: return "Waiting for the existing request to finish before quitting."
    // BEGIN quota3 admission
        case .storageCapacity:
            return "Traverse couldn’t save the previous app because its settings storage is full. Your folder app wasn’t changed."
        case .recordingCapacity:
            return "macOS finished, but Traverse couldn’t save the result. The previous app is kept for review. Refresh to check the current folder app."
    // END quota3 admission
        case .none: break
        }
        if !permitsChanges { return "Open selected folders in Traverse using Finder’s Services menu." }
        if isAnotherTraverseCopy { return "Another copy of Traverse is selected. Open that copy to manage its folder setting." }
        if hasForeignRestoreChoice { return "The saved restore choice belongs to another copy of Traverse. It has been preserved." }
        if recovery?.stage == .pending || recovery?.stage == .unreadable {
            return "An earlier request has an unconfirmed outcome. Refresh checks the current choice; it does not confirm that earlier request."
        }
        return "This affects apps that use the folder default. Some apps open Finder directly. Open and Save dialogs keep their usual behavior."
    }

    func attach() -> UUID {
        let token = UUID()
        guard accepting else { return token }
        presentations.insert(token)
        refresh()
        return token
    }
    func detach(_ token: UUID) {
        presentations.remove(token)
        if issuedConsent?.presentation == token { issuedConsent = nil }
        if activePresentation == token { permit?.cancelBeforeSubmission() }
        if presentations.isEmpty {
            generation = UUID(); pendingRefresh = false; issuedConsent = nil
        }
    }
    private var activePresentation: UUID?
    func refresh() {
        guard accepting, !presentations.isEmpty else { return }
        guard work == nil else { pendingRefresh = true; return }
        generation = UUID(); issuedConsent = nil
        let ticket = generation
        phase = .checking; observationIsFresh = false; recoveryIsLoaded = false
        work = Task { [self] in
            defer { finished() }
            var target: FolderDefaultApplication?, observed: FolderDefaultApplication?
            var record: FolderDefaultRecoveryRecord?
            var observedSuccessfully = false, loadedSuccessfully = false
            do { target = try await system.runningApplication() } catch { }
            do { observed = try await system.currentApplication(); observedSuccessfully = true } catch { }
            if permitsChanges {
                do { record = try await store.load(); try record?.validate(); loadedSuccessfully = true } catch { }
            } else { loadedSuccessfully = true }
            guard accepting, !presentations.isEmpty, generation == ticket else { return }
            traverse = target; recovery = record; current = observed
            observationIsFresh = observedSuccessfully && target != nil
            recoveryIsLoaded = loadedSuccessfully
            notice = !loadedSuccessfully ? .recoveryUnavailable
                : !observationIsFresh ? .observationUnavailable : .none
        }
    }
    func consent(for direction: FolderDefaultRecoveryRecord.Direction, in presentation: UUID) -> Consent? {
        guard presentations.contains(presentation), let current, let traverse,
              direction == .makeTraverse ? canMakeDefault : canRestorePrevious else { return nil }
        let consent = Consent(owner: owner, nonce: UUID(), generation: generation, presentation: presentation,
            direction: direction, current: current, traverse: traverse, recovery: recovery)
        issuedConsent = consent
        return consent
    }
    func discard(_ consent: Consent) { if issuedConsent == consent { issuedConsent = nil } }
    @discardableResult func confirm(_ consent: Consent) -> Bool {
        guard issuedConsent == consent, consent.owner == owner, consent.generation == generation,
              presentations.contains(consent.presentation), ready,
              consent.current == current, consent.traverse == traverse, consent.recovery == recovery,
              consent.direction == .makeTraverse ? canMakeDefault : canRestorePrevious else {
            if work == nil { notice = .changed; observationIsFresh = false }
            return false
        }
        issuedConsent = nil; generation = UUID(); observationIsFresh = false
        let permit = FolderDefaultRequestPermit()
        self.permit = permit; activePresentation = consent.presentation; phase = .preparing
        work = Task { [self] in
            defer { finished() }
            await perform(consent, permit: permit)
        }
        return true
    }
    private func perform(_ consent: Consent, permit: FolderDefaultRequestPermit) async {
        let lease: FileActivityGate.Lease
        do { lease = try activity.begin() }
        catch { notice = .notSubmitted; return }
        defer { withExtendedLifetime(lease) {} }
        let pending: FolderDefaultRecoveryRecord
        do {
            guard try await store.load() == consent.recovery,
                  try await system.runningApplication().identifies(consent.traverse),
                  try await system.currentApplication()?.identifies(consent.current) == true,
                  accepting, presentations.contains(consent.presentation) else { notice = .changed; return }
            pending = FolderDefaultRecoveryRecord(
                recordID: consent.direction == .makeTraverse ? UUID() : consent.recovery!.recordID,
                traverse: consent.traverse,
                previous: consent.direction == .makeTraverse ? consent.current : consent.recovery!.previous,
                attemptID: UUID(), direction: consent.direction, stage: .pending)
            try await store.replace(expected: consent.recovery, with: pending)
            recovery = pending; recoveryIsLoaded = true
    // BEGIN quota3 admission
        } catch let error as FolderDefaultWriteAdmissionFailure {
            recoveryIsLoaded = false
            switch error {
            case .retainedTemporaryCapacity, .inventoryCapacity: notice = .storageCapacity
            case .unsafeTemporaryMetadata, .temporaryInventoryUnavailable: notice = .recoveryUnavailable
            }
            return
    // END quota3 admission
        } catch { recoveryIsLoaded = false; notice = .recoveryUnavailable; return }
        if !accepting || !presentations.contains(consent.presentation) { permit.cancelBeforeSubmission() }
        phase = .requesting
        let diagnostics = ApplicationDiagnostics.shared.workflow(.settings, trace: pending.attemptID, context: .init(.nativeStatus))
        let reply = await system.request(pending.destination, expecting: consent.current, permit: permit)
        switch reply {
        case .notSubmitted: diagnostics.event(.blocked, context: .init(.nativeStatus))
        case .completed(_, let failure):
            // Retain the callback's codes before readback/storage, including in
            // App Logs' warnings filter. A later matching readback can still
            // truthfully record completion independently of this warning.
            diagnostics.event(failure == nil ? .verifying : .partial, context: .init(.nativeStatus),
                error: failure?.error, causes: failure?.causes)
        }
        var settled = pending
        var readFailed = false
        do { settled.observed = try await system.currentApplication() }
        catch { readFailed = true }
        switch reply {
        case .notSubmitted:
            // A conforming adapter never returns this after beginSubmission.
            guard !permit.isSubmitted else { notice = .unconfirmed; return }
            settled.stage = .notSubmitted
        case .completed(let callback, _):
            settled.callback = callback
            settled.stage = readFailed ? .unreadable
                : settled.observed?.identifies(settled.destination) == true ? .matched : .different
        }
        phase = .recording
        do {
            try await store.replace(expected: pending, with: settled)
            recovery = settled; recoveryIsLoaded = true
    // BEGIN quota3 admission
        } catch let error as FolderDefaultWriteAdmissionFailure {
            recoveryIsLoaded = false; current = nil
            switch error {
            case .retainedTemporaryCapacity, .inventoryCapacity: notice = .recordingCapacity
            case .unsafeTemporaryMetadata, .temporaryInventoryUnavailable: notice = .recoveryUnavailable
            }
            return
    // END quota3 admission
        } catch {
            // Native entry may already have happened. Keep the durable pending
            // record and do not turn a memory-only observation into completion.
            recoveryIsLoaded = false; current = nil; notice = .recoveryUnavailable
            return
        }
        current = readFailed ? nil : settled.observed
        observationIsFresh = !readFailed
        switch reply {
        case .notSubmitted: notice = .notSubmitted
        case .completed(let callback, _):
            if settled.stage == .matched { notice = callback == .returned ? .selected : .selectedWithError }
            else if readFailed { notice = .unconfirmed }
            else if callback == .cancelled { notice = .cancelled }
            else { notice = callback == .failed ? .failed : .unconfirmed }
        }
        diagnostics.event(settled.stage == .matched ? .completed : settled.callback == .cancelled ? .cancelled : .partial,
            context: .init(.nativeStatus))
        // Keep one bounded previous-app record even after a verified restore.
        // Only another explicit Make Default consent may replace it.
    }
    private func finished() {
        work = nil; permit = nil; activePresentation = nil; phase = .idle
        if pendingRefresh, accepting, !presentations.isEmpty { pendingRefresh = false; refresh() }
    }
    func stopAndDrain() async {
        accepting = false; issuedConsent = nil; generation = UUID(); pendingRefresh = false
        permit?.cancelBeforeSubmission(); notice = .closing
        // No task cancellation: callback, readback, storage and worker ownership
        // drain together. The app must defer termination rather than fake drain.
        while let work { await work.value }
    }
    func resumeAfterCancelledTermination() {
        accepting = true
        if !presentations.isEmpty { refresh() }
    }
}
