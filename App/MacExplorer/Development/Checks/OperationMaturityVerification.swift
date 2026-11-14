#if DEBUG
import AppKit
import FileOperations
import SwiftUI

private final class NativeProgressReceipt: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [OperationProgress] = []
    func append(_ value: OperationProgress) {
        lock.withLock {
            if values.count < 512 { values.append(value) }
        }
    }
    var snapshots: [OperationProgress] { lock.withLock { values } }
}

@MainActor
extension UIVerification {
    static func verifyOperationMaturity(_ browser: BrowserViewController, in testRoot: URL, output: URL,
                                        interactive: Bool) async throws -> [String] {
        let position = browser.settings.operationIndicatorPosition
        let originalDock = browser.settings.showsDockProgress
        let originalPathBar = browser.settings.showsPathBar
        let originalEngine = browser.recoverableFileOperations
        let originalPresenter = browser.operationResultPresenter
        let originalError = browser.operationErrorPresenter
        defer {
            browser.finishOperationPresentation()
            browser.settings.operationIndicatorPosition = position
            browser.settings.showsDockProgress = originalDock
            browser.settings.showsPathBar = originalPathBar
            browser.recoverableFileOperations = originalEngine
            browser.operationResultPresenter = originalPresenter
            browser.operationErrorPresenter = originalError
            browser.retentionInspectionTask?.cancel()
            browser.recoveryWindow?.close()
        }
        try require(browser.startOperationPresentation("Controlled progress presentation"), "Could not reserve progress presentation")
        let inspectionWorker = Task<Void, Never> {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(20)) } catch { return }
            }
        }
        browser.operationTask = inspectionWorker
        var inspectionWorkerActive = true
        defer {
            inspectionWorker.cancel()
            if inspectionWorkerActive { browser.operationTask = nil }
        }
        let model = OperationProgressPresentation(phaseTitle: "Copy", percentage: 0.37,
            summary: "Controlled presentation fixture · phase percentage",
            sourcePath: "/Generated fixture/Source", destinationPath: "/Generated fixture/Destination",
            currentItem: "Generated sample.bin", completedText: "37 MB of 100 MB in this phase",
            remainingText: "63 MB remaining in this phase", speedText: "12 MB/s · logical copy bytes",
            samples: [4, 8, 11, 7, 10, 12, 9, 12].map { $0 * 1_000_000 })
        browser.operationPresentation = model
        browser.settings.operationIndicatorPosition = .statusBar
        browser.updateOperationProgressControls()
        browser.view.layoutSubtreeIfNeeded()
        try require(!browser.footerOperationButton.isHidden && browser.navigationOperationButton.isHidden
            && browser.operationFooterHeight?.constant == 40, "Footer progress did not reserve readable space")
        let contentBeforeInspection = browser.splitController.view.frame
        var hoverQualified = false
        if interactive, let window = browser.view.window {
            let responder = window.firstResponder
            let hover = NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)!
            browser.footerOperationButton.mouseEntered(with: hover)
            try await waitUntil("Compact native hover card") { browser.footerOperationButton.isHoverInspectionVisible }
            try require(browser.footerOperationButton.hoverInspectionSize == OperationProgressDetailsView.cardSize,
                        "Hover inspection did not use the compact card size")
            try require(window.firstResponder === responder, "Informational hover stole browser keyboard focus")
            if let hoverWindow = browser.footerOperationButton.hoverInspectionWindow {
                try await snapshot(hoverWindow, to: output.appendingPathComponent("operation-progress-hover.png"))
            }
            browser.footerOperationButton.dismissHoverInspection()
            try require(!browser.footerOperationButton.isHoverInspectionVisible, "Hover inspection did not dismiss")
            hoverQualified = true
        }
        try require(browser.footerOperationButton.accessibilityPerformPress(), "Progress accessibility press was unavailable")
        try require(!browser.operationDetailsContainer.isHidden, "Progress activation did not pin details inside the browser")
        browser.view.layoutSubtreeIfNeeded()
        try require(browser.operationDetailsContainer.frame.size == OperationProgressDetailsView.cardSize
            && browser.splitController.view.frame == contentBeforeInspection,
                    "Pinned inspection consumed browser content or lost its compact size")
        browser.operationDetails.cancelOperation(nil)
        try require(browser.operationDetailsContainer.isHidden && browser.view.window?.firstResponder === browser.footerOperationButton,
                    "Closing details did not restore indicator keyboard focus")
        _ = browser.footerOperationButton.accessibilityPerformPress()
        browser.view.layoutSubtreeIfNeeded()
        let visibleText = maturityVisibleText(in: browser.operationDetails)
        try require(visibleText.contains("Controlled presentation fixture") && visibleText.contains("Copy"),
                    "Pinned details opened with its heading or summary outside the viewport")
        try await snapshot(browser.view.window!, to: output.appendingPathComponent("operation-progress-footer.png"))
        var cardCompositorCaptured = false
        if let window = browser.view.window {
            let previousFrame = window.frame
            window.setFrame(NSRect(origin: previousFrame.origin, size: window.minSize), display: true)
            for showsPathBar in [false, true] {
                browser.settings.showsPathBar = showsPathBar
                try await waitUntil("Bottom address layout applied before measuring") {
                    browser.addressLayout?.bottomSurface.isHidden == !showsPathBar
                }
                window.contentView?.layoutSubtreeIfNeeded()
                guard let host = browser.operationDetailsContainer.superview else {
                    throw Failure(message: "Compact inspection has no workspace host")
                }
                let card = browser.operationDetailsContainer.convert(browser.operationDetailsContainer.bounds, to: host)
                let contentView = browser.workspace?.paneTreeHost ?? browser.splitController.view
                let content = contentView.convert(contentView.bounds, to: host)
                try require(content.contains(card), "Compact inspection escaped content at minimum window size")
                let footerView: NSView = browser.workspace?.footerHost ?? browser.statusSurface!
                let footer = footerView.convert(footerView.bounds, to: host)
                try require(card.minY > footer.maxY, "Compact inspection covered the bottom status row")
                if showsPathBar, let pathRow = browser.addressLayout?.bottomSurface {
                    try require(card.minY > pathRow.convert(pathRow.bounds, to: host).maxY,
                                "Compact inspection covered the optional bottom path row")
                }
            }
            try await snapshot(window, to: output.appendingPathComponent("operation-progress-compact-minimum.png"))
            if interactive {
                // cacheDisplay and the compositor differ for layered surfaces; keep
                // an exact owned-window capture for the compact overlay as well.
                do {
                    try await GlassVerification.captureOwnedWindow(window,
                        to: output.appendingPathComponent("operation-progress-compact-compositor.png"))
                    cardCompositorCaptured = true
                } catch {
                    // A refused capture remains unexercised; do not broaden its scope.
                }
            }
            window.setFrame(previousFrame, display: true)
            browser.settings.showsPathBar = originalPathBar
        }
        browser.operationDetailsContainer.isHidden = true
        browser.settings.operationIndicatorPosition = .navigation
        browser.updateOperationProgressControls()
        browser.view.layoutSubtreeIfNeeded()
        try require(browser.footerOperationButton.isHidden && !browser.navigationOperationButton.isHidden
            && browser.operationFooterHeight?.constant == 28, "Navigation progress did not restore footer geometry")
        try await snapshot(browser.view.window!, to: output.appendingPathComponent("operation-progress-navigation.png"))
        let encoded = try browser.settings.encodedSnapshot()
        let restored = BrowserSettings(persist: false, restoredData: encoded)
        try require(restored.operationIndicatorPosition == .navigation && restored.showsDockProgress == originalDock
            && restored.reviewsRecoveryAtStartup, "Operation preferences did not survive a versioned snapshot")
        let legacySettings = BrowserSettings(persist: false, restoredData: Data("{\"version\":5}".utf8))
        try require(legacySettings.operationIndicatorPosition == .statusBar && legacySettings.showsDockProgress
            && legacySettings.reviewsRecoveryAtStartup, "Older preferences did not receive development-safe operation defaults")
        let previousTile = NSApplication.shared.dockTile.contentView
        browser.operationCoordinator.dock.update(model, enabled: true)
        try require(browser.operationCoordinator.dock.isVisible && NSApplication.shared.dockTile.contentView !== previousTile,
                    "Public Dock tile did not install a progress drawing")
        browser.operationCoordinator.dock.restore()
        try require(!browser.operationCoordinator.dock.isVisible && NSApplication.shared.dockTile.contentView === previousTile,
                    "Dock progress did not restore the prior tile")
        let competitor = UUID()
        try require(!browser.operationCoordinator.begin(owner: competitor), "Another window could claim an active mutation")
        if interactive, let window = browser.view.window {
            let hover = NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)!
            browser.navigationOperationButton.mouseEntered(with: hover)
            try await waitUntil("Navigation hover card") { browser.navigationOperationButton.isHoverInspectionVisible }
            guard let card = browser.navigationOperationButton.hoverInspectionFrameInHost else {
                throw Failure(message: "Navigation hover frame missing")
            }
            let content = browser.splitController.view.convert(browser.splitController.view.bounds, to: browser.view)
            try require(abs(card.maxY - content.maxY) <= 10,
                        "Navigation hover was placed too far from its indicator")
            if let details = browser.navigationOperationButton.hoverInspectionView {
                browser.navigationOperationButton.mouseExited(with: hover)
                details.mouseEntered(with: hover)
                try await Task.sleep(for: .milliseconds(350))
                try require(browser.navigationOperationButton.isHoverInspectionVisible,
                            "Entering hover inspection did not cancel its pointer-travel dismissal")
                if let path = maturityField("Source", in: details) {
                    path.selectText(nil)
                    try require(browser.navigationOperationButton.ownsHoverResponder(window.firstResponder),
                                "Selectable hover path did not own its native field editor")
                } else { throw Failure(message: "Hover source path was unavailable") }
            }
        }
        browser.cancelFileOperation(nil)
        try require(browser.operationPresentation?.stopping == true && inspectionWorker.isCancelled,
                    "Stop did not update the inspection state and cancel its controlled worker")
        await inspectionWorker.value
        browser.operationTask = nil
        inspectionWorkerActive = false
        browser.finishOperationPresentation()
        try require(browser.operationCoordinator.activeOwner == nil && browser.operationPresentation == nil,
                    "Progress completion leaked application ownership")
        try require(browser.view.window?.firstResponder === browser.table,
                    "Completing progress inspection left keyboard focus in a hidden control")
        let settingsWindow = BrowserSettingsWindow.make(
            BrowserSettingsView(settings: browser.settings, initialPage: .operations))
        settingsWindow.isReleasedWhenClosed = false
        settingsWindow.title = "Operation Preferences · Verification"
        if interactive { settingsWindow.makeKeyAndOrderFront(nil) }
        else { settingsWindow.contentView?.layoutSubtreeIfNeeded() }
        try await snapshot(settingsWindow, to: output.appendingPathComponent("operation-settings.png"))
        var settingsCompositorCaptured = false
        if interactive {
            do {
                try await GlassVerification.captureOwnedWindow(settingsWindow,
                    to: output.appendingPathComponent("operation-settings-compositor.png"))
                settingsCompositorCaptured = true
            } catch {
                // The native view render remains authentic. Capture refusal does not
                // request a permission reset or broaden to another window/desktop.
            }
        }
        settingsWindow.close()
        if interactive { browser.view.window?.makeKeyAndOrderFront(nil) }

        let owned = testRoot.appendingPathComponent("maturity-ui-" + UUID().uuidString, isDirectory: true)
        let source = owned.appendingPathComponent("Source", isDirectory: true)
        let destination = owned.appendingPathComponent("Destination", isDirectory: true)
        let payload = source.appendingPathComponent("Generated large file.bin")
        try await Task.detached {
            let fm = FileManager()
            try fm.createDirectory(at: source, withIntermediateDirectories: true)
            try fm.createDirectory(at: destination, withIntermediateDirectories: false)
            try Data("MacExplorer operation maturity disposable fixture v1".utf8)
                .write(to: owned.appendingPathComponent(".fixture-owner"), options: .withoutOverwriting)
            guard fm.createFile(atPath: payload.path, contents: nil) else { throw Failure(message: "Could not create generated large file") }
            let file = try FileHandle(forWritingTo: payload)
            defer { try? file.close() }
            let chunk = Data(repeating: 0x6b, count: 1_048_576)
            for _ in 0..<128 { try file.write(contentsOf: chunk) }
            try file.synchronize()
        }.value
        let engine = RecoverableFileOperations(journalDirectory: owned.appendingPathComponent("journal", isDirectory: true))
        browser.recoverableFileOperations = engine
        browser.operationResultPresenter = { _ in }
        var errors: [String] = []
        browser.operationErrorPresenter = { errors.append($0) }
        browser.navigate(to: .directory(source)); try await settled(browser)
        browser.focusBrowserContent()
        let receipt = NativeProgressReceipt()
        let queue = browser.operationCoordinator.transfers
        queue.progressForVerification = { value in
            receipt.append(value)
            if value.phase == .copying {
                Task { @MainActor in queue.stopActive() }
            }
        }
        defer { queue.progressForVerification = nil; _ = queue.resume() }
        browser.beginRecoverableOperation(.copy(sources: [payload], destinationDirectory: destination),
            title: "Copying generated large file…", roots: [payload, destination], observing: nil, engine: engine)
        try await waitUntil("Native progress operation completion") { !browser.hasPendingFileOperation }
        await browser.recoveryInspectionTask?.value
        try require(errors.isEmpty && browser.lastOperationResult != nil, "Native large-copy progress failed to return a result")
        try require(receipt.snapshots.contains { $0.phase == .copying && $0.bytesTotal == 134_217_728 },
                    "Native copy did not report its known logical phase size")
        try require(receipt.snapshots.contains { $0.isTerminal }, "Native progress did not deliver a terminal snapshot")
        try require(browser.lastOperationResult?.cancellationRequested == true,
                    "Native Stop was not exercised before this generated operation finished")
        try require(FileManager().fileExists(atPath: payload.path), "Stopped Copy removed its generated source")
        try require(browser.operationCoordinator.activeOwner == nil && browser.operationPresentation == nil,
                    "Native operation did not clear progress ownership")
        var checks = [
            "Controlled phase ring renders in footer and navigation; compact pinned inspection preserves content geometry, bottom path/status rows and minimum-size layout",
            "Versioned operation settings, single application mutation ownership and public Dock tile install/restore",
            "Actual generated 128 MiB Copy feeds bounded progress into native presentation; Stop preserves source and terminal result clears ownership"
        ]
        var report: [String: Any] = ["passed": true, "presentationCaptureMode": "controlled-presentation-fixture",
            "actualPayloadBytes": 134_217_728, "actualProgressSnapshotCount": receipt.snapshots.count,
            "actualPhases": Array(Set(receipt.snapshots.map { $0.phase.rawValue })).sorted(),
            "stopRequested": browser.lastOperationResult?.cancellationRequested ?? false,
            "disposition": browser.lastOperationResult?.disposition.rawValue ?? "missing",
            "foreground": interactive, "dockScope": "public contentView/display install and restoration; visual compositor not captured"]
        report["settingsCompositorCaptured"] = settingsCompositorCaptured
        report["compactHoverQualified"] = hoverQualified
        report["compactCardCompositorCaptured"] = cardCompositorCaptured
        report["cardSize"] = ["width": 380, "height": 250]
        if hoverQualified { checks.append("Native animated hover uses compact details without stealing keyboard focus; explicit dismissal closes it") }

        if ProcessInfo.processInfo.arguments.contains("--qualify-trash-fixture") {
            let incoming = source.appendingPathComponent("Cleanup.txt")
            let target = destination.appendingPathComponent("Cleanup.txt")
            try await Task.detached {
                try Data("generated incoming".utf8).write(to: incoming, options: .withoutOverwriting)
                try Data("generated displaced backup".utf8).write(to: target, options: .withoutOverwriting)
            }.value
            let plan = try await engine.prepareTransfer(sources: [incoming], destinationDirectory: destination, move: false)
            guard let conflict = plan.conflicts.first else { throw Failure(message: "Generated cleanup Replace had no conflict") }
            let replaced = await engine.perform(plan, resolutions: [conflict.id: .replace])
            guard replaced.result.disposition == .succeeded, let id = replaced.recordID else { throw Failure(message: "Generated cleanup preparation failed") }
            let backups = try await engine.retentionRecord(recordID: id)
            try require(backups.canCleanup, "Generated displaced original did not qualify for explicit cleanup")
            browser.showOperationRecovery(nil)
            await browser.recoveryInspectionTask?.value
            browser.confirmRecoveryCleanup(backups)
            try await waitUntil("Generated recovery cleanup confirmation") { browser.recoveryWindow?.window?.attachedSheet != nil }
            guard let sheet = browser.recoveryWindow?.window?.attachedSheet,
                  let confirm = maturityButton("Move Copies to Trash", in: sheet.contentView) else { throw Failure(message: "Cleanup confirmation was unavailable") }
            confirm.performClick(nil)
            try await waitUntil("Generated recovery cleanup completion") { browser.recoveryWindow?.window?.attachedSheet == nil && !browser.hasPendingFileOperation }
            await browser.recoveryInspectionTask?.value
            let retained = try await engine.retentionRecord(recordID: id)
            try require(retained.state == "cleaned" && !retained.canCleanup
                && browser.lastOperationResult?.disposition == .succeeded,
                        "Native cleanup did not preserve an honest terminal recovery state")
            try require(try String(contentsOf: target, encoding: .utf8) == "generated incoming"
                && String(contentsOf: incoming, encoding: .utf8) == "generated incoming", "Backup cleanup changed a public source or destination")
            try require(await engine.undo(recordID: id).result.disposition == .failed, "Cleanup left file Undo enabled")
            await browser.retentionInspectionTask?.value
            if let window = browser.recoveryWindow?.window {
                try await snapshot(window, to: output.appendingPathComponent("operation-retention-review.png"))
            }
            report["nativeCleanupRecordID"] = id.uuidString
            report["nativeCleanupKnownTrashTargets"] = browser.lastOperationResult?.items.compactMap { $0.destination?.path } ?? []
            checks.append("Explicit native confirmation moves only generated verified recovery backups to real system Trash, preserves public files and disables Mac Explorer Undo")
        }
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("operation-maturity.json"), options: .withoutOverwriting)
        return checks
    }

    private static func maturityButton(_ title: String, in view: NSView?) -> NSButton? {
        guard let view else { return nil }
        if let button = view as? NSButton, button.title == title { return button }
        return view.subviews.lazy.compactMap { maturityButton(title, in: $0) }.first
    }
    private static func maturityField(_ title: String, in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.accessibilityLabel() == title { return field }
        return view.subviews.lazy.compactMap { maturityField(title, in: $0) }.first
    }
    private static func maturityVisibleText(in view: NSView) -> String {
        var result: [String] = []
        if let field = view as? NSTextField, !field.visibleRect.isEmpty { result.append(field.stringValue) }
        result += view.subviews.map(maturityVisibleText)
        return result.joined(separator: "\n")
    }
}
#endif
