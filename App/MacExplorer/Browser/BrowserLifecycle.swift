import AppKit

/// Block-based registrations need an explicit lifetime even with weak handlers.
/// NotificationCenter removal is safe when the owning controller is released.
final class BrowserNotificationObservation: @unchecked Sendable {
    private let center: NotificationCenter
    private let token: NSObjectProtocol

    init(center: NotificationCenter = .default, name: Notification.Name, object: Any? = nil,
         handler: @escaping @Sendable (Notification) -> Void) {
        self.center = center
        token = center.addObserver(forName: name, object: object, queue: .main, using: handler)
    }

    deinit { center.removeObserver(token) }
}

@MainActor
extension BrowserViewController {
    var hasPendingFileOperation: Bool {
        hasExclusiveBrowserOperation || operationCoordinator.transfers.hasOutstandingWork || operationCoordinator.drives.hasDriveRequest
    }

    var hasExclusiveBrowserOperation: Bool {
        operationTask != nil || (operationPreparationTask != nil && !inlineRename.isEditing && !selectionGroupDraft.isEditing)
            || operationCoordinator.activeOwner != nil || operationCoordinator.preparationOwner != nil
            || operationCoordinator.copyPreviewOwner != nil
    }

    /// Closing a browser stops its reads and observation, but never interrupts
    /// a write. The window delegate refuses close while an operation is active.
    func suspendBrowser() {
        nameSelection.cancel()
        gitControls.cancel()
        captureArchiveViewState()
        let archives = Array(archiveTabs.values); archiveTabs = [:]
        archives.forEach { ArchiveTabCatalogPool.shared.retire($0) }
        table.marquee?.cancel(restore: false)
        let sessions = smbTabs.values; smbTabs = [:]; sessions.forEach { $0.close() }
        let sftp = sftpTabs.values; sftpTabs = [:]; sftp.forEach { $0.close() }
        sftpClosedUploadNotices = [:]
        smbClosedUploadNotices = [:]
        canvasTransition?.finish(); canvasTransition = nil
        folderSummary.cancel()
        pinDrop.cancel()
        addressCompletion.cancel()
        folderFilter.contextWillChange()
        inlineRename.cancel()
        selectionGroupDraft.cancel()
        operationPreparationTask?.cancel()
        selectionGroupWindow?.close()
        tabStrip.invalidateManagementInteraction()
        quickLook.endSession()
        openAndShare.windowWillClose()
        dragDrop.windowWillClose()
        listedItemPropertiesController?.close()
        saveViewState()
        metadataSearch.locationWillChange()
        isBrowserSuspended = true
        if workspace == nil || workspace?.isClosing == true { clearCutSelection() }
        workspace?.paneWillSuspend(self)
        operationHistory.cancelRecoveryInspection(owner: paneID)
        ownedTrash.close()
        retentionInspectionTask?.cancel()
        sessionID = UUID()
        cancelDirectoryObservation()
        summaryBrowsingAccess = nil
        listingTask?.cancel()
        orderingTask?.cancel()
        folderLoadingFeedbackTask?.cancel(); folderLoadingFeedbackTask = nil
        sidebarTasks.forEach { $0.cancel() }
        sidebarTasks.removeAll()
        Task { [weak self] in await self?.flushBrowserSession() }
    }

    func resumeBrowser() {
        guard isBrowserSuspended else { return }
        isBrowserSuspended = false
        rebuildSidebar()
        loadLocation()
    }

    func explainPendingOperation() {
        if ApplicationDriveBenchmark.shared.hasPendingWork { ApplicationDriveBenchmark.shared.reveal(); return }
        guard let window = view.window, window.attachedSheet == nil else { return }
        let alert = NSAlert()
        let driveOnly = operationCoordinator.drives.hasDriveRequest && !hasExclusiveBrowserOperation && !operationCoordinator.transfers.hasOutstandingWork
        alert.messageText = driveOnly && operationCoordinator.drives.isFormatting
            ? "An APFS Format request is still active"
            : driveOnly ? "A drive request is still pending" : "File work is still pending"
        alert.informativeText = driveOnly && operationCoordinator.drives.isFormatting
            ? "Keep this window open while Traverse checks or formats the selected disk image volume. Open Drives to inspect its status. If macOS has received the erase request, wait for the saved result before quitting."
            : driveOnly
                ? "Keep this window open until macOS finishes. Open Drives to inspect the request or cancel it before submission. A request already submitted to macOS must finish before quitting."
                : "Keep this window open until queued work finishes, or inspect the queue to cancel waiting jobs and Stop running work. Stopping finishes the current safe step; completed changes remain. Queued jobs are not restored after quitting."
        alert.addButton(withTitle: "Keep Working")
        if driveOnly { alert.addButton(withTitle: "Open Drives") }
        else if operationCoordinator.transfers.hasOutstandingWork { alert.addButton(withTitle: "Inspect Queue") }
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertSecondButtonReturn {
                if driveOnly { self?.showDriveControls(nil) } else { self?.showTransferQueue(nil) }
            }
        }
    }
}
