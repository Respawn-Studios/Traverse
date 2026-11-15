import AppKit
import FileOperations

/// bufferingNewest bounds queued UI work even if the browser is temporarily busy.
final class OperationProgressMailbox: Sendable {
    let stream: AsyncStream<OperationProgress>
    let continuation: AsyncStream<OperationProgress>.Continuation
    init() {
        let pair = AsyncStream<OperationProgress>.makeStream(bufferingPolicy: .bufferingNewest(1))
        stream = pair.stream; continuation = pair.continuation
    }
    func send(_ progress: OperationProgress) { continuation.yield(progress) }
    func finish() { continuation.finish() }
}

@MainActor
extension BrowserViewController {
    @discardableResult
    func startOperationPresentation(_ title: String, preparation: UUID? = nil, diagnosticTrace: UUID? = nil,
                                    reportsAdmissionFailure: Bool = true) -> Bool {
        guard operationPresentationID == nil else { return false }
        let token = UUID()
        guard operationCoordinator.begin(owner: token, preparation: preparation ?? operationPreparationID) else {
            if reportsAdmissionFailure { status.stringValue = "Wait for the current file operation to finish." }
            return false
        }
        operationPresentationID = token
        sftpTabs[activeID]?.clearTransferOutcome()
        smbTabs[activeID]?.clearTransferOutcome()
        let diagnostics = ApplicationDiagnostics.shared
        let trace = diagnosticTrace ?? diagnostics.currentTrace ?? diagnostics.begin(.fileOperation)
        operationDiagnosticTrace = trace; completedOperationDiagnosticTrace = nil
        diagnostics.event(.fileOperation, .admitted, trace: trace)
        let binding = diagnostics.operationBinding(trace: trace)
        operationProgressState = OperationProgressState()
        operationStopRequested = false
        let mailbox = OperationProgressMailbox()
        operationProgressMailbox = mailbox
        operationProgressSink = { binding.receive($0.jobID); mailbox.send($0) }
        operationProgressTask = Task { [weak self] in
            for await update in mailbox.stream {
                guard let self, self.operationPresentationID == token else { break }
                self.receiveOperationProgress(update)
            }
        }
        operationPresentation = OperationProgressPresentation(phaseTitle: "Preparing", summary: title)
        updateOperationProgressControls()
        return true
    }

    func receiveOperationProgress(_ update: OperationProgress) {
        guard operationPresentationID != nil,
              let next = operationProgressState.receive(update, stopping: operationStopRequested) else { return }
        operationPresentation = next
        updateOperationProgressControls()
    }

    func updateOperationProgressControls(updatesWorkspace: Bool = true) {
        #if DEBUG
        operationProgressRendersForVerification += 1
        #endif
        let displayed = displayedOperationPresentation
        let responder = view.window?.firstResponder
        let restoreFocus = displayed == nil && (responder === footerOperationButton || responder === navigationOperationButton
            || responder === workspace?.operationButton || footerOperationButton.ownsHoverResponder(responder)
            || navigationOperationButton.ownsHoverResponder(responder) || workspace?.operationButton.ownsHoverResponder(responder) == true)
        let active = displayed != nil
        footerOperationButton.presentation = displayed
        navigationOperationButton.presentation = displayed
        let queueAction: (() -> Void)? = operationCoordinator.transfers.canInspect ? { [weak self] in self?.showTransferQueue(nil) } : nil
        for button in [footerOperationButton, navigationOperationButton] {
            button.inspectionIsPinned = !operationDetailsContainer.isHidden
            button.onQueue = queueAction
        }
        footerOperationButton.isHidden = !active || settings.operationIndicatorPosition != .statusBar
        navigationOperationButton.isHidden = !active || settings.operationIndicatorPosition != .navigation
        operationFooterHeight?.constant = InterfaceMetrics.points(active && settings.operationIndicatorPosition == .statusBar ? 40 : 28)
        if updatesWorkspace { workspace?.updateOperationProgress(from: self) }
        operationDetails.presentation = displayed
        let displayedQueueID = operationPresentation == nil ? operationCoordinator.transfers.state.active?.id : nil
        let displayedLocalID = operationPresentationID
        operationDetails.onStop = { [weak self] in
            guard let self, !self.isBrowserSuspended else { return }
            if let displayedQueueID { self.operationCoordinator.transfers.stopActive(expectedID: displayedQueueID) }
            else if let displayedLocalID, self.operationPresentationID == displayedLocalID { self.cancelFileOperation(nil) }
        }
        operationDetails.onQueue = queueAction
        if !transferQueueDetails.isHidden { transferQueueDetails.motion = settings.motion; transferQueueDetails.update(operationCoordinator.transfers) }
        if let presentation = operationPresentation, operationPresentationID != nil {
            operationCoordinator.dock.update(presentation, enabled: settings.showsDockProgress && !isVerificationSession)
        }
        if restoreFocus { (workspace?.activeBrowser ?? self).focusBrowserContent() }
    }

    @objc func showFileOperationDetails(_ sender: Any?) {
        if let owner = workspace?.operationBrowser, owner !== self { owner.showFileOperationDetails(sender); return }
        guard displayedOperationPresentation != nil else { return }
        footerOperationButton.dismissHoverInspection(); navigationOperationButton.dismissHoverInspection(); workspace?.operationButton.dismissHoverInspection()
        if !operationDetailsContainer.isHidden, !operationDetails.isHidden { operationDetails.onClose?(); return }
        workspace?.browsers.values.filter { $0 !== self }.forEach { $0.operationDetailsContainer.isHidden = true }
        operationDetails.isHidden = false
        transferQueueDetails.isHidden = true
        operationDetailsContainer.isHidden = false
        // A workspace owns/reparents this overlay. Reflow its actual host,
        // including any newly shown bottom address, before presenting it.
        let layoutHost: NSView = workspace?.view ?? view
        layoutHost.needsUpdateConstraints = true; layoutHost.needsLayout = true
        layoutHost.layoutSubtreeIfNeeded()
        footerOperationButton.inspectionIsPinned = true
        navigationOperationButton.inspectionIsPinned = true
        workspace?.operationButton.inspectionIsPinned = true
        operationDetailsContainer.alphaValue = 1
        if settings.motion.allows(.pages), !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            operationDetailsContainer.alphaValue = settings.motion.mode.initialOpacity(0)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16 * settings.motion.mode.durationScale
                operationDetailsContainer.animator().alphaValue = 1
            }
        }
        view.layoutSubtreeIfNeeded()
        operationDetails.focusPrimaryAction()
    }

    @objc func showTransferQueue(_ sender: Any?) {
        guard operationCoordinator.transfers.canInspect else { return }
        if let workspace, workspace.activeBrowser !== self { workspace.activeBrowser.showTransferQueue(sender); return }
        footerOperationButton.dismissHoverInspection(); navigationOperationButton.dismissHoverInspection(); workspace?.operationButton.dismissHoverInspection()
        workspace?.browsers.values.filter { $0 !== self }.forEach { $0.operationDetailsContainer.isHidden = true }
        operationDetails.isHidden = true
        transferQueueDetails.isHidden = false
        transferQueueDetails.motion = settings.motion
        transferQueueDetails.update(operationCoordinator.transfers)
        operationDetailsContainer.isHidden = false
        operationDetailsContainer.alphaValue = 1
        footerOperationButton.inspectionIsPinned = true
        navigationOperationButton.inspectionIsPinned = true
        workspace?.operationButton.inspectionIsPinned = true
        view.layoutSubtreeIfNeeded()
        transferQueueDetails.focusPrimaryAction()
    }

    func endOperationProgressPresentation() {
        let currentResponder = view.window?.firstResponder
        let responder = currentResponder as? NSView
        let field = (responder as? NSTextView)?.delegate as? NSView
        // AppKit can drop focus to the window when the focused Stop button becomes
        // disabled. Restore that case too, without stealing focus from text editing.
        let restoreFocus = responder == nil || responder === footerOperationButton || responder === navigationOperationButton
            || responder === workspace?.operationButton
            || responder?.isDescendant(of: operationDetails) == true || field?.isDescendant(of: operationDetails) == true
            || footerOperationButton.ownsHoverResponder(currentResponder) || navigationOperationButton.ownsHoverResponder(currentResponder)
            || workspace?.operationButton.ownsHoverResponder(currentResponder) == true
        operationProgressMailbox?.finish()
        operationProgressTask?.cancel()
        operationProgressMailbox = nil; operationProgressTask = nil; operationProgressSink = nil
        if let token = operationPresentationID { operationCoordinator.finish(owner: token) }
        operationPresentationID = nil
        operationPresentation = nil
        operationDetailsContainer.isHidden = true
        operationDetailsContainer.alphaValue = 1
        updateOperationProgressControls()
        if restoreFocus { (workspace?.activeBrowser ?? self).focusBrowserContent() }
        workspace?.refreshRecoveryViews()
    }

    func buildOperationDetails() {
        operationDetailsContainer.isHidden = true
        operationDetailsContainer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(operationDetailsContainer)
        NSLayoutConstraint.activate([
            operationDetailsContainer.widthAnchor.constraint(equalToConstant: OperationProgressDetailsView.cardSize.width),
            operationDetailsContainer.heightAnchor.constraint(equalToConstant: OperationProgressDetailsView.cardSize.height),
            operationDetailsContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            operationDetailsContainer.bottomAnchor.constraint(equalTo: splitController.view.bottomAnchor, constant: -8)
        ])
        pin(operationDetails, inside: operationDetailsContainer)
        pin(transferQueueDetails, inside: operationDetailsContainer)
        transferQueueDetails.isHidden = true
        for button in [footerOperationButton, navigationOperationButton] {
            button.hoverHost = view
            button.hoverBottomAnchor = splitController.view
            button.onInspect = { [weak self] in self?.showFileOperationDetails(nil) }
            button.isHidden = true
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        operationDetails.onClose = { [weak self] in
            guard let self else { return }
            self.operationDetailsContainer.isHidden = true
            self.footerOperationButton.inspectionIsPinned = false
            self.navigationOperationButton.inspectionIsPinned = false
            self.workspace?.operationButton.inspectionIsPinned = false
            let button = self.settings.operationIndicatorPosition == .statusBar ? (self.workspace?.operationButton ?? self.footerOperationButton) : self.navigationOperationButton
            if self.displayedOperationPresentation != nil { self.view.window?.makeFirstResponder(button) }
            else { self.focusBrowserContent() }
        }
        transferQueueDetails.onClose = { [weak self] in self?.operationDetails.onClose?() }
        transferQueueDetails.onProgress = { [weak self] in self?.showFileOperationDetails(nil) }
        transferQueueDetails.onCancel = { [weak self] id in
            guard let self, !self.isBrowserSuspended else { return }; _ = self.operationCoordinator.transfers.cancelWaiting(id)
        }
        transferQueueDetails.onStop = { [weak self] id in
            guard let self, !self.isBrowserSuspended else { return }; self.operationCoordinator.transfers.stopActive(expectedID: id)
        }
        transferQueueDetails.onMoveWaiting = { [weak self] id, offset, order in
            guard let self, !self.isBrowserSuspended else { return false }
            return self.operationCoordinator.transfers.moveWaiting(id, offset: offset, expectedOrder: order)
        }
        transferQueueDetails.onPauseOrResume = { [weak self] resume, reviewResultID in
            guard let self, !self.isBrowserSuspended else { return }
            let queue = self.operationCoordinator.transfers
            if resume {
                guard queue.state.isPaused, queue.reviewResultID == reviewResultID else { return }
                _ = queue.resume()
            } else { queue.pause() }
        }
        transferQueueDetails.onResult = { [weak self] id in
            guard let self else { return }
            self.operationCoordinator.transfers.showResult(id, in: self)
        }
    }
}
