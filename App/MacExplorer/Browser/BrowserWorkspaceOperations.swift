import AppKit
import FileOperations
import SwiftUI

/// Transient window history is shared independently of the pane that happened
/// to start a job. The operation engine remains the only write/recovery owner.
@MainActor
final class BrowserOperationHistory {
    var lastResult: FileOperationResult? { didSet { recoveryAction = nil; selectionGroup = nil; downloadBatch = nil; diagnosticTrace = nil } }
    var diagnosticTrace: UUID?
    var selectionGroup: SelectionGroupPresentation?
    var downloadBatch: RemoteDownloadBatchPresentation?
    var recoveryAction: CopyRecoveryAction?
    var continuation: TransferContinuation?
    var moveClipboard: MoveClipboardContext?
    var recoveryRecordID: UUID?
    var recoveryRecords: [OperationRecoveryRecord] = []
    var refusedRecoveryEntries: [URL] = []
    var recoveryNextCursor: UUID?
    var recoveryUnfinishedCount = 0
    var recoveryHistoryReadiness: OperationHistoryReadiness = .absent
    var recoveryInspectionTask: Task<Void, Never>?
    private var recoveryInspectionID: UUID?
    private(set) var recoveryInspectionOwner: UUID?

    func beginRecoveryInspection(_ id: UUID, owner: UUID) {
        recoveryInspectionTask?.cancel()
        recoveryInspectionID = id; recoveryInspectionOwner = owner
    }

    @discardableResult
    func finishRecoveryInspection(_ id: UUID) -> Bool {
        guard recoveryInspectionID == id else { return false }
        recoveryInspectionTask = nil
        recoveryInspectionID = nil; recoveryInspectionOwner = nil
        return true
    }

    func cancelRecoveryInspection(owner: UUID) {
        guard recoveryInspectionOwner == owner else { return }
        recoveryInspectionTask?.cancel()
    }
}

@MainActor
extension BrowserWorkspaceController {
    func showWorkspaceSettings() {
        if let settingsWindow { settingsWindow.makeKeyAndOrderFront(nil); return }
        let window = BrowserSettingsWindow.make(makeWorkspaceSettingsView())
        window.title = "Traverse Settings"
        window.isReleasedWhenClosed = false
        settingsWindow = window
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    func makeWorkspaceSettingsView(initialPage: BrowserSettingsView.Page = .general) -> BrowserSettingsView {
        BrowserSettingsView(settings: primaryBrowser.settings, initialPage: initialPage, namesOwner: primaryBrowser.privateNames,
            onReviewRecovery: { [weak self] in self?.activeBrowser.showOperationRecovery(nil) },
            onCompactJournal: { [weak self] in self?.activeBrowser.compactOperationJournal() },
            copyPreviewAvailability: activeBrowser.recoverableFileOperations?.copyPreviewAvailability ?? .qualificationPending,
            onPrepareHistory: { [weak self] in self?.activeBrowser.prepareOperationHistoryForReview() },
            onCopyPreviewChange: { [weak self] in self?.activeBrowser.changeCopyPreview($0) },
            onManageLaunchProfiles: { [weak self] in self?.showLaunchProfiles() },
            onShowSetup: { [weak self] in if let self { TraverseSetupController.shared.show(from: self.activeBrowser) } },
            folderAccess: primaryBrowser.folderAccess,
            accessDrives: primaryBrowser.volumes,
            onShowConnections: { [weak self] in self?.activeBrowser.showSMBConnections(nil) },
            onAccessChanged: { [weak self] in
                guard let self else { return }
                for browser in self.browsers.values { await browser.refreshRememberedFolderReferences() }
            })
    }

    func configureOperationHost(for browser: BrowserViewController) {
        operationButton.motion = browser.settings.motion
        let card = browser.operationDetailsContainer
        card.removeFromSuperview()
        view.addSubview(card)
        let bottom = card.bottomAnchor.constraint(equalTo: paneTreeHost.bottomAnchor, constant: -8)
        operationCardBottomConstraints[browser.paneID] = bottom
        NSLayoutConstraint.activate([
            card.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            bottom
        ])
        operationButton.hoverHost = view
        operationButton.hoverBottomAnchor = paneTreeHost
        updateOperationBottomReservation()
        operationButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        operationButton.onInspect = { [weak self] in
            guard let self else { return }
            (self.operationBrowser ?? self.activeBrowser).showFileOperationDetails(nil)
        }
        operationButton.onQueue = { [weak self] in self?.activeBrowser.showTransferQueue(nil) }
    }

    func updateOperationBottomReservation(bottomAddress: Bool? = nil) {
        // @Published emits before its property changes: the subscription must
        // supply the new value rather than read the previous preference here.
        let inset = (bottomAddress ?? primaryBrowser.settings.showsPathBar) ? InterfaceMetrics.points(BrowserAddressLayout.bottomRowHeight) : 0
        for constraint in operationCardBottomConstraints.values { constraint.constant = -8 - inset }
        operationButton.hoverBottomInset = inset
        viewIfLoaded?.needsLayout = true
    }

    func retireOperationHost(for browser: BrowserViewController) {
        browser.recoveryWindow?.close()
        browser.ownedTrash.close()
        browser.groupedCopyRecoveryWindow?.close()
        browser.groupedCopyRecoveryWindow = nil
        browser.selectionGroupDraft.cancel()
        browser.selectionGroupWindow?.close()
        if let window = browser.selectionGroupWindow {
            Task { @MainActor [browser, window] in
                await window.drain()
                if browser.selectionGroupWindow === window { browser.selectionGroupWindow = nil }
            }
        }
        browser.operationDetailsContainer.removeFromSuperview()
        operationCardBottomConstraints.removeValue(forKey: browser.paneID)?.isActive = false
        if operationBrowser === browser {
            operationBrowser = nil
            operationButton.presentation = nil
            operationButton.isHidden = true
            footerHeight?.constant = InterfaceMetrics.points(28)
        }
        Task { @MainActor [weak self] in
            guard let self, !self.isClosing else { return }
            self.updateOperationProgress(from: self.activeBrowser)
        }
    }

    func renderQueuedPresentation() {
        guard !isClosing else { return }
        let current = layout.paneIDs.compactMap { browsers[$0] }
        for pane in current {
            guard !isClosing else { return }
            guard browsers[pane.paneID] === pane, !pane.isBrowserSuspended else { continue }
            pane.updateOperationProgressControls(updatesWorkspace: false)
            pane.validateNavigationButtons()
            pane.consumePendingDirectoryRefresh()
        }
        guard !isClosing else { return }
        updateOperationProgress(from: operationBrowser ?? activeBrowser)
    }

    func updateOperationProgress(from browser: BrowserViewController) {
        #if DEBUG
        queueSharedRendersForVerification += 1
        #endif
        let transfers = primaryBrowser.operationCoordinator.transfers
        if browser.operationPresentation != nil {
            operationBrowser = browser
        } else if operationBrowser?.operationPresentation == nil {
            if transfers.presentation == nil {
                operationBrowser = nil
            } else if let origin = transfers.activeOrigin, browsers[origin.paneID] === origin, !origin.isBrowserSuspended {
                operationBrowser = origin
            } else if operationBrowser == nil || operationBrowser?.isBrowserSuspended == true {
                operationBrowser = activeBrowser
            }
        }
        let owner = operationBrowser
        operationButton.presentation = owner?.displayedOperationPresentation
        operationButton.inspectionIsPinned = browsers.values.contains { !$0.operationDetailsContainer.isHidden }
        operationButton.onQueue = primaryBrowser.operationCoordinator.transfers.canInspect
            ? { [weak self] in self?.activeBrowser.showTransferQueue(nil) } : nil
        let bottom = primaryBrowser.settings.operationIndicatorPosition == .statusBar
        let visible = operationButton.presentation != nil && bottom
        operationButton.isHidden = !visible
        footerHeight?.constant = InterfaceMetrics.points(visible ? 40 : 28)
        for pane in browsers.values {
            pane.footerOperationButton.isHidden = true
            pane.navigationOperationButton.isHidden = pane !== owner || pane.displayedOperationPresentation == nil || bottom
            pane.operationFooterHeight?.constant = InterfaceMetrics.points(visible ? 40 : 28)
        }
    }

    func suspendWorkspace() {
        isClosing = true
        quickProfileSwitcher?.close()
        startupGeneration = UUID()
        startupTask?.cancel(); startupTask = nil
        preview.endSession()
        operationButton.dismissHoverInspection()
        for browser in browsers.values { browser.suspendBrowser() }
    }

    func resumeWorkspace() {
        isClosing = false
        profileWorkspaceController?.windowReopened()
        for browser in browsers.values { browser.resumeBrowser() }
        queuePresentation?.schedule()
        if !sessionReady { begin() }
        else { refreshRecoveryViews() }
    }

    func refreshRecoveryViews() {
        primaryBrowser.inspectOperationRecovery()
    }

    func refreshRecoveryPresentations() {
        for browser in browsers.values where !browser.isBrowserSuspended {
            browser.refreshRecoveryPresentation()
        }
    }
}
