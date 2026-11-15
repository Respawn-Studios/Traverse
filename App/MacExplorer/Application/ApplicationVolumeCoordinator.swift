import AppKit
import Combine
import ExplorerCore
import LocalStorage

struct DriveJobSummary: Identifiable, Equatable {
    let id: UUID
    let title: String
    let detail: String
}

/// Session-only device intent, queue admission and worker quiescence. Native
/// observations/actions remain in LocalStorage; no UI callback mutates a disk.
@MainActor
final class ApplicationVolumeCoordinator: ObservableObject {
    struct Pending {
        let plan: PreparedVolumeAction
        var intent: DeferredEject
    }
    private unowned let operations: ApplicationOperationCoordinator
    private var backend: (any VolumeLifecycleManaging)?
    private var discovery: Task<Void, Never>?
    private var evaluation: Task<Void, Never>?
    private var running: Task<Void, Never>?
    private var runID: UUID?
    private let protectionStore: DriveProtectionStore
    private let nativeDriveJobStore: NativeDriveJobStore?
    private var protectionSnapshot: DriveProtectionStore.Snapshot?
    private var protectionTask: Task<Void, Never>?
    private var nativeDriveJobTask: Task<Void, Never>?
    private var nativeDriveJobLoaded = false
    @Published private(set) var nativeDriveJobReady = false
    @Published private(set) var nativeDriveJobIssue = ""
    private var sessionProtection: [UUID: VolumeProtectionLevel] = [:]
    @Published private(set) var protectionReady = false
    @Published private(set) var isEditingProtection = false
    @Published private(set) var protectionIssue = ""
    @Published private(set) var protectionRevision = UUID()
    var savedProtections: [DriveProtectionLibrary.Rule] { protectionSnapshot?.library.rules ?? [] }
    @Published private(set) var isStoppingPreparation = false
    private var barrier: (id: UUID, token: FileActivityGate.DrainToken)?
    @Published private(set) var volumes: [ManagedVolume] = []
    @Published private var offlineVolumes: [UUID: ManagedVolume] = [:]
    @Published private(set) var pending: Pending?
    @Published private(set) var jobs: [DriveJobSummary] = []
    @Published private(set) var isPreparing = false
    @Published private(set) var message = ""
    private(set) var lastResult: VolumeActionResult?
    var isBusy: Bool { isPreparing || pending != nil || isEditingProtection }
    var hasDriveRequest: Bool { isPreparing || pending != nil }
    var pendingActionTitle: String {
        switch pending?.plan.action {
        case .mount: "Mount"
        case .unmount: "Unmount"
        case .eject, .forceUnmountAndEject: "Eject"
        case nil: "Drive request"
        }
    }
    var canCancel: Bool { (isPreparing && !isStoppingPreparation) || pending.map { $0.intent.phase != .submitted } == true }

    init(operations: ApplicationOperationCoordinator, backend: (any VolumeLifecycleManaging)? = nil,
         protectionStore: DriveProtectionStore? = nil) {
        self.operations = operations; self.backend = backend
        let directory = AppStorageLocations.stateDirectory?.appendingPathComponent("drive-protection")
        self.protectionStore = protectionStore ?? DriveProtectionStore(directory: directory, memoryOnly: backend != nil)
        self.nativeDriveJobStore = NativeDriveJobStore.applicationStore()
    }
    isolated deinit { discovery?.cancel(); evaluation?.cancel(); nativeDriveJobTask?.cancel() }

    func startDiscovery() {
        guard discovery == nil else { return }
        reloadProtection()
        let backend = backend ?? VolumeLifecycle.shared
        self.backend = backend
        discovery = Task { [weak self] in
            for await values in backend.updates {
                guard let self, !Task.isCancelled else { return }
                var offline = self.offlineVolumes
                for old in self.volumes where old.url != nil {
                    if values.first(where: { $0.id == old.id })?.url != old.url { offline[old.id] = old }
                }
                for current in values where current.url != nil {
                    if offline[current.id]?.url == current.url { offline.removeValue(forKey: current.id) }
                }
                let changed = offline != self.offlineVolumes
                self.volumes = values
                if changed {
                    self.offlineVolumes = offline
                    for browser in self.operations.liveBrowsers where browser.isViewLoaded && !browser.isBrowserSuspended {
                        browser.loadLocation()
                    }
                }
            }
        }
    }

    /// A cold intent may have reached diskutil before the app stopped. This
    /// passive read creates no state; unresolved or unreadable records keep
    /// native Format admission closed, while ordinary drive discovery remains.
    func loadNativeDriveJobIfNeeded() {
        guard !nativeDriveJobLoaded, nativeDriveJobTask == nil else { return }
        nativeDriveJobReady = false
        nativeDriveJobIssue = "Checking saved drive jobs…"
        nativeDriveJobTask = Task { [weak self] in
            guard let self else { return }
            do {
                guard let store = self.nativeDriveJobStore else { throw NativeDriveJobStore.Failure.unavailable }
                let snapshot = try await store.load()
                if snapshot.record?.isUnresolved == true {
                    self.nativeDriveJobIssue = "A prior APFS Format request may have been submitted. Inspect the exact disk image before another native drive change."
                } else {
                    self.nativeDriveJobIssue = ""; self.nativeDriveJobReady = true
                }
            } catch {
                self.nativeDriveJobIssue = "The saved native drive job could not be verified. Native Format remains unavailable."
            }
            self.nativeDriveJobLoaded = true
            self.nativeDriveJobTask = nil
        }
    }

    #if DEBUG
    /// Generated verification waits for the same passive admission read that
    /// ordinary drive presentation starts. A failed or unresolved read never
    /// becomes a clean slot merely because the check has waited for it.
    func waitForNativeDriveJobLoad() async {
        loadNativeDriveJobIfNeeded()
        if let task = nativeDriveJobTask { await task.value }
    }

    /// Passive pre-image admission checks the saved job without constructing
    /// a generated owner, attachment witness or mutation recorder.
    func nativeFormatSavedJobIsClean() -> Bool {
        nativeDriveJobLoaded && nativeDriveJobReady && nativeDriveJobIssue.isEmpty
    }

    /// The cold route checks this saved-job gate without gaining a recorder.
    /// The warm route uses the same predicate before obtaining its recorder.
    func generatedFormatJobIsAdmissible(owner: APFSVolumeFormatGeneratedOwner) -> Bool {
        guard owner.validate() else { return false }
        if !nativeDriveJobLoaded { loadNativeDriveJobIfNeeded() }
        return nativeFormatSavedJobIsClean()
    }

    /// Only the separately gated generated-image verification may obtain a
    /// recorder. It does not submit anything and grants no Format UI action.
    func generatedFormatRecording(owner: APFSVolumeFormatGeneratedOwner,
                                  attachmentCurrent: @escaping @Sendable () -> Bool) -> NativeDriveJobStore.Recording? {
        let args = ProcessInfo.processInfo.arguments
        guard args.contains("--verify-drive-lifecycle"), args.contains("--apfs-format"),
              generatedFormatJobIsAdmissible(owner: owner) else { return nil }
        return nativeDriveJobStore?.recording(owner: owner, attachmentCurrent: attachmentCurrent)
    }
    #endif

    func reloadProtection() {
        guard !isBusy, protectionTask == nil else { return }
        isEditingProtection = true
        protectionTask = Task { [weak self] in
            guard let self else { return }
            do {
                let loaded = try await self.protectionStore.load()
                guard self.protectionSnapshot?.bytes == nil || loaded.bytes != nil else { throw DriveProtectionLibrary.Failure.unavailable }
                self.protectionSnapshot = loaded; self.protectionReady = true; self.protectionIssue = ""; self.message = ""
            }
            catch { self.protectionReady = false; self.protectionIssue = "Saved drive protection could not be verified. Removal stays blocked. Restore the original file if needed, then Reload Protection." }
            self.isEditingProtection = false; self.protectionTask = nil; self.protectionRevision = UUID()
        }
    }
    private var removalProtection: VolumeRemovalProtection {
        get throws { try VolumeRemovalProtection(saved: protectionSnapshot?.library.saved ?? [:], session: sessionProtection) }
    }
    func protectionLevel(for volume: ManagedVolume) -> VolumeProtectionLevel { (try? removalProtection.level(for: volume)) ?? .keepMounted }
    func savesProtection(for volume: ManagedVolume) -> Bool {
        guard let uuid = volume.volumeUUID else { return false }
        return volumes.filter { $0.volumeUUID == uuid }.count == 1
    }
    func permitsRemoval(_ volume: ManagedVolume, action: VolumeAction) -> Bool {
        if action == .mount { return true }
        guard protectionReady else { return false }
        let members = action == .unmount ? [volume] : volumes.filter { $0.group == volume.group }
        return (try? removalProtection.validate(target: volume, action: action, members: members)) != nil
    }
    func setProtection(_ level: VolumeProtectionLevel, for volume: ManagedVolume) {
        guard protectionReady, !isBusy, let snapshot = protectionSnapshot,
              volumes.contains(volume), [.externalDisk, .diskImage].contains(volume.deviceKind) else { return }
        let persistent = savesProtection(for: volume)
        if !persistent {
            if level == .none { sessionProtection.removeValue(forKey: volume.id) }
            else if sessionProtection[volume.id] != nil || sessionProtection.count < 256 { sessionProtection[volume.id] = level }
            else { protectionIssue = "The session protection limit is reached. Remove an unused rule before adding another."; return }
            protectionIssue = ""; message = ""; protectionRevision = UUID(); return
        }
        guard let uuid = volume.volumeUUID else { return }
        isEditingProtection = true
        protectionTask = Task { [weak self] in
            guard let self else { return }
            do {
                let title = String(volume.name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(64))
                self.protectionSnapshot = try await self.protectionStore.set(uuid,
                    name: title.isEmpty ? "Unnamed volume" : title, level: level, expected: snapshot)
                self.sessionProtection.removeValue(forKey: volume.id); self.protectionIssue = ""; self.message = ""
            } catch BrowserSnapshotFile.Failure.writerBusy {
                self.protectionIssue = "Another Explorer instance is saving drive protection. Try again shortly or Reload Protection."
            } catch {
                self.protectionReady = false
                self.protectionIssue = "Drive protection was not acknowledged. Removal stays blocked until Reload Protection verifies the saved state."
            }
            self.isEditingProtection = false; self.protectionTask = nil; self.protectionRevision = UUID()
        }
    }
    func forgetSavedProtection(_ id: UUID) {
        guard !isBusy, protectionReady, let snapshot = protectionSnapshot,
              snapshot.library.rules.contains(where: { $0.id == id }) else { return }
        isEditingProtection = true
        protectionTask = Task { [weak self] in
            guard let self else { return }
            do { self.protectionSnapshot = try await self.protectionStore.set(id, name: "Removed drive", level: .none, expected: snapshot); self.protectionIssue = "" }
            catch { self.protectionReady = false; self.protectionIssue = "The protection edit was not acknowledged. Reload Protection before removing a drive." }
            self.isEditingProtection = false; self.protectionTask = nil; self.protectionRevision = UUID()
        }
    }
    func drainProtection() async { await protectionTask?.value; await protectionStore.drain() }
    func offlineVolume(containing url: URL) -> ManagedVolume? {
        offlineVolumes.values.filter { volume in
            guard let root = volume.url else { return false }
            return url.path == root.path || url.path.hasPrefix(root.path + "/")
        }.max { ($0.url?.path.count ?? 0) < ($1.url?.path.count ?? 0) }
    }
    /// Presentation acknowledgement only. A deliberate navigation can adopt a
    /// currently observed mounted device at that path; writes still need fresh
    /// operation observations. Back/tab restoration does not call this method.
    func acknowledgeNavigation(to url: URL) {
        let matching = offlineVolumes.filter { _, old in
            guard let root = old.url, url.path == root.path || url.path.hasPrefix(root.path + "/") else { return false }
            return volumes.contains { $0.url?.path == root.path && $0.fileSystemID != nil && $0.mediaID != nil }
        }.map(\.key)
        for id in matching { offlineVolumes.removeValue(forKey: id) }
    }

    func request(_ target: ManagedVolume, action: VolumeAction, policy: EjectNewWorkPolicy) {
        guard action == .mount || !ApplicationDriveDetails.shared.hasUncertainHealthState else {
            message = "A hardware health check could not finish cleanly. Drive removal in Traverse is unavailable for this session."
            return
        }
        // Advanced force is deliberately unavailable until its separate native
        // qualification. Normal requests never silently escalate to force.
        guard action != .forceUnmountAndEject else {
            message = "Force Unmount and Eject is awaiting separate qualification. Use Disk Utility for advanced device recovery."
            return
        }
        guard operations.copyPreviewOwner == nil else {
            message = "Finish or cancel Copy preview setup before starting a drive request."
            return
        }
        guard action == .mount || protectionReady else { message = "Saved drive protection needs verification. Open Drives and choose Reload Protection."; return }
        guard permitsRemoval(target, action: action) else { message = "Drive protection prevents this action or its device scope is uncertain. Review the protection in Drives."; return }
        guard !isBusy, let backend else { return }
        isPreparing = true; isStoppingPreparation = false; lastResult = nil; message = "Checking drive and affected tasks…"
        let protected = operations.protectedStorageLocations
        running = Task { [weak self] in
            guard let self else { return }
            do {
                if action != .mount {
                    do {
                        let loaded = try await self.protectionStore.load()
                        guard self.protectionSnapshot?.bytes == nil || loaded.bytes != nil else { throw DriveProtectionLibrary.Failure.unavailable }
                        self.protectionSnapshot = loaded
                    }
                    catch { self.protectionReady = false; throw VolumeLifecycleFailure.protectionUncertain }
                }
                try Task.checkCancellation()
                let rules = try self.removalProtection
                let plan = try await backend.prepare(target, action: action, protecting: protected, removalProtection: rules)
                try Task.checkCancellation()
                let devices = Set(plan.affected.compactMap(\.fileSystemID))
                let jobs = self.operations.transfers.volumeJobs(affecting: devices)
                self.pending = Pending(plan: plan, intent: DeferredEject(cohort: Set(jobs.map(\.id)), policy: policy))
                self.jobs = jobs
                self.message = ""
            } catch {
                self.message = Task.isCancelled ? "Drive check cancelled." :
                    (error as? VolumeLifecycleFailure)?.userMessage ?? "The drive could not be checked. Try again after refreshing it."
            }
            self.isPreparing = false; self.isStoppingPreparation = false; self.running = nil
            self.workDidChange()
        }
    }

    /// Called on the main actor with queue admission. Unknown membership is
    /// conservatively affected until original source/destination facts exist.
    func admitNewWork(fileSystemIDs: Set<Int64>?) -> Bool {
        guard operations.volumeBarrierOwner == nil else { return false }
        guard var pending else { return !isPreparing }
        let affected = fileSystemIDs.map { !$0.isDisjoint(with: Set(pending.plan.affected.compactMap(\.fileSystemID))) } ?? true
        guard pending.intent.admitNewWork(affected: affected) else { return false }
        if pending.intent.phase == .cancelled { let title = pendingActionTitle; cancel(); message = title + " cancelled by new work." }
        return true
    }

    func cancel() {
        if isPreparing {
            guard !isStoppingPreparation else { return }
            isStoppingPreparation = true; message = "Stopping the drive check…"
            // Metadata work may not honour Task cancellation. Keep ownership
            // until its actual return, then reject the cancelled result.
            running?.cancel()
            return
        }
        guard var pending, pending.intent.cancel() else { return }
        let id = pending.intent.id
        let title = pendingActionTitle
        self.pending = nil; jobs = []; message = title + " cancelled."
        running?.cancel(); running = nil; runID = nil
        releaseBarrier(id)
        operations.transfers.startIfPossible()
    }

    func resumeAfterReview() {
        guard var pending, operations.transfers.reviewResult == nil,
              pending.intent.resumeAfterReview() else { return }
        self.pending = pending; workDidChange()
    }

    func workDidChange() {
        guard pending != nil, evaluation == nil else { return }
        evaluation = Task { [weak self] in
            guard let self else { return }
            self.evaluation = nil; self.advance()
        }
    }

    private func advance() {
        guard var pending, running == nil, let backend else { return }
        let devices = Set(pending.plan.affected.compactMap(\.fileSystemID))
        let jobs = operations.transfers.volumeJobs(affecting: devices)
        if self.jobs != jobs { self.jobs = jobs }
        let review = operations.transfers.reviewResult.map { pending.intent.cohort.contains($0.id) } ?? false
        pending.intent.update(outstanding: Set(jobs.map(\.id)), needsAttention: review)
        self.pending = pending
        if pending.intent.phase == .needsAttention {
            message = "Resolve the transfer result, then resume the drive request."
            return
        }
        guard pending.intent.phase == .draining else { message = pendingActionTitle + " will wait for the captured tasks."; return }
        guard operations.beginVolumeBarrier(pending.intent.id) else {
            message = "Waiting for other active work to finish before closing background readers."
            return
        }
        do { try ApplicationCompressedArchives.shared.prepareForQuiescence() }
        catch {
            operations.finishVolumeBarrier(pending.intent.id)
            message = "A compressed archive is still closing. Close its review and try the drive request again."
            return
        }
        guard let token = ApplicationFileActivity.gate.closeAdmission() else {
            ApplicationCompressedArchives.shared.resumeAfterQuiescence()
            operations.finishVolumeBarrier(pending.intent.id)
            message = "Background readers are already being stopped. Try again when that request finishes."
            return
        }
        let id = pending.intent.id
        barrier = (id, token); runID = id
        message = "Finishing background reads and closing Explorer previews…"
        ApplicationStorageAnalysis.shared.prepareForVolumeQuiescence()
        ApplicationDriveDetails.shared.prepareForVolumeQuiescence()
        ApplicationZIPBrowser.shared.prepareForVolumeQuiescence()
        ApplicationTARBrowser.shared.suspend()
        ApplicationArchiveExtraction.shared.closeIdleWindow()
        ApplicationArchiveCreation.shared.closeIdleWindow()
        ApplicationBatchRename.shared.closeIdleWindow()
        // Close/cancel every reader before awaiting the actual worker leases.
        // Native preview/service helpers may still cause a normal OS Busy result.
        for browser in operations.liveBrowsers where browser.isViewLoaded { browser.prepareForVolumeQuiescence() }
        running = Task { [weak self] in
            guard let self else { return }
            defer {
                self.releaseBarrier(id)
                if self.runID == id { self.running = nil; self.runID = nil }
            }
            await ApplicationBatchRename.shared.closeAndDrain()
            await ApplicationArchiveExtraction.shared.closeAndDrain()
            await ApplicationArchiveCreation.shared.closeAndDrain()
            await ApplicationDriveDetails.shared.drainHealth()
            guard !ApplicationDriveDetails.shared.hasUncertainHealthState else {
                self.message = "A hardware health check could not finish cleanly. The drive request was deferred."
                return
            }
            await SelectionGroupResultsWindow.closeAllAndDrain()
            _ = await ApplicationNativeSharing.cancelPreparationsAndDrain()
            for browser in self.operations.liveBrowsers {
                await browser.operationPreparationTask?.value
                for owner in browser.archiveTabs.values { await owner.drain() }
            }
            await ApplicationZIPBrowser.shared.drain()
            await ApplicationTARBrowser.shared.drain()
            guard await ApplicationCompressedArchives.shared.drain() else {
                self.message = "A temporary archive copy could not be closed. The drive request was deferred."
                return
            }
            let drained = await ApplicationFileActivity.gate.waitUntilDrained(token)
            guard !Task.isCancelled, drained, ApplicationFileActivity.gate.ownsDrainedAdmission(token),
                  var current = self.pending, current.intent.id == id,
                  current.intent.submit(afterVerifiedDrain: true) else { return }
            self.pending = current
            self.message = "Waiting for macOS to finish the drive request…"
            let result = await backend.perform(current.plan)
            self.lastResult = result
            guard var finished = self.pending, finished.intent.complete(request: id) else { return }
            self.pending = nil; self.jobs = []
            if result.unmounted {
                for volume in current.plan.affected where volume.url != nil { self.offlineVolumes[volume.id] = volume }
            }
            if let failure = result.failure {
                self.message = (result.unmounted ? "Unmounted; eject did not finish. " : "") + failure.userMessage
            } else {
                switch current.plan.action {
                case .mount: self.message = "\(current.plan.target.name) mounted."
                case .unmount: self.message = "\(current.plan.target.name) unmounted."
                default:
                    self.message = result.ejected ? "\(current.plan.target.name) ejected." :
                        "Ejection could not be confirmed. Review this device in Drives."
                }
            }
        }
    }

    private func releaseBarrier(_ id: UUID) {
        guard let barrier, barrier.id == id else { return }
        self.barrier = nil
        ApplicationFileActivity.gate.reopen(barrier.token)
        ApplicationDriveDetails.shared.resumeHealthMonitoring()
        ApplicationCompressedArchives.shared.resumeAfterQuiescence()
        ApplicationZIPBrowser.shared.resumeAfterVolumeQuiescence()
        ApplicationTARBrowser.shared.resume()
        for browser in operations.liveBrowsers { browser.archiveTabs.values.forEach { $0.resume() } }
        operations.finishVolumeBarrier(id)
    }
}

@MainActor
extension BrowserViewController {
    var isOfflineCurrentFolder: Bool {
        let source: URL?
        if case .archive(let value) = location { source = value.source } else { source = location.directoryURL }
        return source.flatMap { operationCoordinator.drives.offlineVolume(containing: $0) } != nil
    }
    func prepareForVolumeQuiescence() {
        captureArchiveViewState()
        archiveTabs.values.forEach { $0.suspend() }
        addressCompletion.cancel()
        folderFilter.contextWillChange(); inlineRename.cancel()
        selectionGroupDraft.cancel(); operationPreparationTask?.cancel()
        selectionGroupWindow?.close()
        quickLook.endSession(); openAndShare.windowWillClose(); dragDrop.windowWillClose()
        workspace?.preview.endSession()
        metadataSearch.cancel(restoreFolder: false)
        sessionID = UUID()
        cancelDirectoryObservation()
        listingTask?.cancel(); orderingTask?.cancel()
        sidebarTasks.forEach { $0.cancel() }; sidebarTasks.removeAll()
        recoveryInspectionTask?.cancel(); retentionInspectionTask?.cancel()
    }
}
