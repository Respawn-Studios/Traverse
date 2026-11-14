import AppKit
import FileOperations

@MainActor
extension BrowserViewController {
    private var copyPreviewHost: NSWindow? {
        let windows = [workspace?.settingsWindow, settingsWindow, recoveryWindow?.window, view.window].compactMap { $0 }
        if let key = NSApp.keyWindow, windows.contains(where: { $0 === key }) { return key }
        return windows.first(where: \.isVisible)
    }

    func changeCopyPreview(_ enabled: Bool) {
        guard !isReadOnlyFileSession, let engine = recoverableFileOperations else { return }
        let coordinator = operationCoordinator, settings = settings
        guard coordinator.copyPreviewTask == nil else { return }
        if !enabled {
            // Captured queued requests retain the existing qualified session.
            // Later jobs capture Standard; Undo/recovery do not depend on this flag.
            settings.leaveCopyPreviewOffForSession("Turning preview off for later jobs…")
            coordinator.copyPreviewTask = Task {
                defer { coordinator.copyPreviewTask = nil }
                do {
                    try await settings.commitCopyPreview(nil)
                    settings.copyPreviewStatus = "Preview is off. Captured queued jobs, Undo and recovery keep their existing behavior."
                } catch { settings.leaveCopyPreviewOffForSession("Preview is off for this session. The saved preference could not be confirmed.") }
            }
            return
        }
        guard engine.copyPreviewAvailability == .available, settings.canPersistCopyPreview,
              let host = copyPreviewHost, host.attachedSheet == nil else { return }
        let owner = UUID()
        guard coordinator.beginCopyPreview(owner: owner) else {
            settings.copyPreviewStatus = "Finish or cancel queued jobs, and wait for preparation and history inspection to finish before enabling preview."
            return
        }
        settings.copyPreviewStatus = "Checking preview readiness…"
        coordinator.copyPreviewTask = Task { [weak self] in
            let waiting = coordinator.watchCopyPreviewDelay(owner: owner, settings: settings)
            defer { waiting.cancel(); coordinator.finishCopyPreview(owner: owner); coordinator.copyPreviewTask = nil }
            do { try await settings.prepareCopyPreviewPreferences() }
            catch { settings.leaveCopyPreviewOffForSession("Preview stayed off because its settings folder is unavailable. History was not upgraded."); return }
            let result = await engine.activateCopyPreview(review: { disclosure in
                await Self.reviewCopyPreview(disclosure, settings: settings, host: host, coordinator: coordinator, owner: owner)
            }, persist: { receipt in try await settings.commitCopyPreview(receipt) })
            switch result {
            case .enabled: settings.copyPreviewStatus = "Preview is enabled for eligible later jobs. Other Copy jobs use the standard path."
            case .cancelled: settings.copyPreviewStatus = "Preview was not enabled."
            case .notIdle: settings.leaveCopyPreviewOffForSession("Preview stayed off because file work was still draining. Try again when idle.")
            case .qualificationUnavailable: settings.leaveCopyPreviewOffForSession("This build has no qualified preview volume set. Standard Copy remains available.")
            case .notEnabled(let history, let savedChoiceMayRemain):
                let message: String
                switch history {
                case .upgraded: message = "History upgraded; acceleration is still off. Existing operations and recovery records were preserved."
                case .prepared: message = "History preparation changed the catalog; acceleration is still off. Review its current status before retrying."
                case .uncertain: message = "Acceleration is off. History changed or its final state could not be confirmed; inspect it before retrying."
                case .none: message = "Acceleration is off. History was not upgraded. Prepare older or interrupted history explicitly if review requires it."
                }
                settings.leaveCopyPreviewOffForSession(message + (savedChoiceMayRemain ? " The saved preference could not be confirmed; reopening will only recheck existing history." : ""))
            }
            self?.status.stringValue = settings.copyPreviewStatus
        }
    }

    private static func reviewCopyPreview(_ disclosure: CopyPreviewDisclosure, settings: BrowserSettings, host: NSWindow,
                                         coordinator: ApplicationOperationCoordinator, owner: UUID) async -> Bool {
        if settings.copyPreviewDisclosureAccepted && !disclosure.requiresHistoryUpgrade { return true }
        guard host.isVisible, host.attachedSheet == nil else { return false }
        let alert = makeCopyPreviewDisclosureAlert(disclosure)
        let prompt = OperationWindowPrompt()
        coordinator.setCopyPreviewAwaitingChoice(true, owner: owner)
        defer { coordinator.setCopyPreviewAwaitingChoice(false, owner: owner); withExtendedLifetime(prompt) {} }
        return (try? await prompt.present(alert, in: host)) == .alertFirstButtonReturn
    }

    static func makeCopyPreviewDisclosureAlert(_ disclosure: CopyPreviewDisclosure) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "Enable faster Copy preview?"
        alert.informativeText = (disclosure.requiresHistoryUpgrade
            ? "Traverse will prepare and upgrade its operation history. Older builds will refuse to write that upgraded history. Existing operations keep their original Undo rules.\n\n"
            : "This operation history already supports the preview.\n\n")
            + "Faster Copy is an optional development preview for eligible regular-file copies on the two qualified APFS volumes. Other copies continue normally. It can use more memory; file verification, Undo and recovery remain available. You can turn it off at any time in Operations settings."
        alert.addButton(withTitle: "Enable Preview")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = alert.buttons.last
        return alert
    }

    func prepareOperationHistoryForReview(host requestedHost: NSWindow? = nil) {
        guard !isReadOnlyFileSession, let engine = recoverableFileOperations, let host = requestedHost ?? copyPreviewHost,
              host.isVisible,
              host.attachedSheet == nil else { return }
        let coordinator = operationCoordinator, settings = settings, owner = UUID()
        guard coordinator.copyPreviewTask == nil, coordinator.beginCopyPreview(owner: owner) else {
            settings.recoveryMaintenanceStatus = "Finish queued work and history inspection before preparing history."
            return
        }
        let alert = NSAlert()
        alert.messageText = "Prepare operation history for review?"
        alert.informativeText = "This action can initialize history, import older records, update its format or repair an interrupted history transaction. Existing files and recovery backups are preserved. Review will then show any interrupted file operations for your attention."
        alert.addButton(withTitle: "Prepare History"); alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = alert.buttons.last
        coordinator.copyPreviewTask = Task { [weak self] in
            let waiting = coordinator.watchCopyPreviewDelay(owner: owner, settings: settings)
            defer { waiting.cancel() }
            let prompt = OperationWindowPrompt()
            defer { withExtendedLifetime(prompt) {} }
            coordinator.setCopyPreviewAwaitingChoice(true, owner: owner)
            let accepted = (try? await prompt.present(alert, in: host)) == .alertFirstButtonReturn
            coordinator.setCopyPreviewAwaitingChoice(false, owner: owner)
            if accepted {
                do {
                    let inspection = try await engine.recoveryRecords()
                    settings.recoveryMaintenanceStatus = inspection.refusedEntries.isEmpty
                        ? "History is prepared. Open Recovery Review to inspect existing jobs."
                        : "Some history entries remain unavailable. Existing evidence was preserved."
                } catch { settings.recoveryMaintenanceStatus = "History preparation could not finish. Inspect its current status before retrying." }
            }
            coordinator.finishCopyPreview(owner: owner); coordinator.copyPreviewTask = nil
            self?.inspectOperationRecovery()
        }
    }
}

@MainActor
extension ApplicationOperationCoordinator {
    func restoreCopyPreviewIfNeeded(engine: RecoverableFileOperations, settings: BrowserSettings) async {
        guard !attemptedCopyPreviewRestore else { return }
        attemptedCopyPreviewRestore = true
        guard settings.groupedCopyPreview else { return }
        guard let receipt = settings.copyPreviewReceipt, settings.copyPreviewDisclosureAccepted else {
            settings.leaveCopyPreviewOffForSession("Preview needs explicit enabling in Operations settings. History was not changed.")
            return
        }
        let owner = UUID()
        guard beginCopyPreview(owner: owner) else {
            settings.leaveCopyPreviewOffForSession("Preview could not bind while file work was pending. Standard Copy is available; enable preview later when idle.")
            return
        }
        defer { finishCopyPreview(owner: owner) }
        if await engine.rebindCopyPreview(receipt) {
            settings.copyPreviewStatus = "Preview restored after read-only history validation."
        } else {
            settings.leaveCopyPreviewOffForSession("Saved preview could not bind to its original qualified history. Standard Copy is available; no history was created or upgraded.")
        }
    }
}
