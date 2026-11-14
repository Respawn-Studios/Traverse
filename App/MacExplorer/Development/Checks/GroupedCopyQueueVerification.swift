#if DEBUG
import AppKit
import CryptoKit
import Darwin
import FileOperations
import SwiftUI

@MainActor
extension UIVerification {
    /// The production process fixture generator owns the externally seeded root.
    /// This path exercises actual Paste/Queue routing through the public factory;
    /// no hooks or grouped admission implementation are visible to App.
    static func verifyGroupedCopyQueue(_ browser: BrowserViewController, in testRoot: URL,
                                      output: URL, interactive: Bool) async throws -> [String] {
        try require(browser.isControlledVerification, "Preview queue requires controlled native qualification")
        let queue = browser.operationCoordinator.transfers
        try require(!queue.hasOutstandingWork && browser.operationCoordinator.activeOwner == nil
                    && browser.operationCoordinator.preparationOwner == nil, "Preview queue requires an idle writer")
        let engine = try await RecoverableFileOperations.generatedCopyVerificationSession(in: testRoot)
        try require(engine.copyPreviewAvailability == .available, "Generated session has no bounded preview capability")
        let source = testRoot.appendingPathComponent("source", isDirectory: true)
        let destination = testRoot.appendingPathComponent("destination", isDirectory: true)
        guard let workspace = browser.workspace, let window = browser.view.window else {
            throw Failure(message: "Preview matrix requires its controlled workspace window")
        }
        let matrixRoot = destination.appendingPathComponent("queue-matrix-" + UUID().uuidString, isDirectory: true)
        // Generated setup only: one fresh retained subtree, never root relocation.
        try await Task.detached { guard mkdir(matrixRoot.path, 0o700) == 0 else { throw FileOperationFailure.invalidRequest } }.value
        let oldEngine = browser.recoverableFileOperations
        let originalPaneIDs = Set(workspace.browsers.keys)
        let originalActive = workspace.activePaneID
        let oldEngines = workspace.browsers.mapValues(\.recoverableFileOperations)
        let oldModes = workspace.browsers.mapValues(\.effectiveViewMode)
        let oldLocations = workspace.browsers.mapValues(\.location)
        let oldBackgrounds = workspace.browsers.mapValues(\.permitsBackgroundVerification)
        let oldPresenters = workspace.browsers.mapValues(\.operationResultPresenter)
        let oldErrorPresenters = workspace.browsers.mapValues(\.operationErrorPresenter)
        let oldWriters = workspace.browsers.mapValues(\.clipboardWriter)
        let oldProfile = browser.settings.keyboardProfile
        let oldBoard = browser.transferPasteboard
        let oldWriter = browser.clipboardWriter
        let oldPreview = browser.settings.groupedCopyPreview
        let initiallyPaused = queue.state.isPaused
        let board = NSPasteboard.withUniqueName()
        browser.recoverableFileOperations = engine
        browser.workspace?.browsers.values.forEach { $0.recoverableFileOperations = engine }
        browser.transferPasteboard = board
        browser.clipboardWriter = { text, urls in BrowserClipboard.publish(text, urls: urls, to: board) }
        browser.operationResultPresenter = { _ in }
        browser.operationErrorPresenter = { _ in }
        browser.permitsBackgroundVerification = true
        defer {
            // A failed test never detaches the engine from an undrained writer.
            if !queue.hasOutstandingWork {
                for id in workspace.layout.paneIDs.reversed() where !originalPaneIDs.contains(id) {
                    if let pane = workspace.browsers[id] { workspace.activate(pane); _ = workspace.closeActivePane() }
                }
                browser.recoverableFileOperations = oldEngine
                workspace.browsers.forEach { id, pane in
                    if let previous = oldEngines[id] { pane.recoverableFileOperations = previous }
                    if let mode = oldModes[id] { pane.setPaneViewMode(mode) }
                    if let location = oldLocations[id] { pane.navigate(to: location) }
                    if let background = oldBackgrounds[id] { pane.permitsBackgroundVerification = background }
                    if let presenter = oldPresenters[id] { pane.operationResultPresenter = presenter }
                    if let presenter = oldErrorPresenters[id] { pane.operationErrorPresenter = presenter }
                    if let writer = oldWriters[id] { pane.clipboardWriter = writer }
                }
                browser.transferPasteboard = oldBoard; browser.clipboardWriter = oldWriter
                browser.settings.groupedCopyPreview = oldPreview
                browser.settings.keyboardProfile = oldProfile
                if let active = workspace.browsers[originalActive] { workspace.activate(active) }
                if initiallyPaused { queue.pause() } else { _ = queue.resume() }
                board.releaseGlobally()
            }
        }
        do {
            let legacy = BrowserSettings(persist: false, restoredData: Data(#"{"version":8}"#.utf8))
            try require(!legacy.groupedCopyPreview && legacy.copyExecutionRequest == .standard,
                        "Old preference data enabled Copy preview")
            legacy.groupedCopyPreview = true
            let restored = BrowserSettings(persist: false, restoredData: try legacy.encodedSnapshot())
            try require(restored.groupedCopyPreview && restored.copyExecutionRequest == .previewIfAvailable,
                        "Captured preview preference did not round-trip")
            let future = BrowserSettings(persist: false, restoredData: Data(#"{"version":11,"groupedCopyPreview":true}"#.utf8))
            try require(!future.groupedCopyPreview && !future.preferencesPersistenceStatus.isEmpty,
                        "Unsupported preference data enabled preview")
            let settingsCheck = try await verifyGroupedCopySettingsCapture(browser, engine: engine, in: testRoot)
            browser.navigate(to: .directory(source)); try await settled(browser)
            let inputs = browser.displayedEntries.map(\.url)
            try require([1, 16, 17, 31, 33].contains(inputs.count), "Generated preview source count changed")
            let originalSources = try await Task.detached { try groupedQueueSourceFingerprint(inputs, in: source) }.value
            // Existing layout seams provide a bounded 2x2 workspace. Every pane
            // uses the same fixture session, clipboard and application queue.
            if workspace.browsers.count == 1 {
                workspace.activate(browser)
                try require(workspace.splitActive(at: .trailing), "Preview matrix could not create its second pane")
                try require(workspace.splitActive(at: .bottom), "Preview matrix could not split its right column")
                workspace.activate(browser)
                try require(workspace.splitActive(at: .bottom), "Preview matrix could not split its left column")
            }
            try require(workspace.browsers.count == 4, "Preview matrix requires four bounded fixture panes")
            let panes = workspace.layout.paneIDs.compactMap { workspace.browsers[$0] }
            for pane in panes {
                pane.recoverableFileOperations = engine; pane.permitsBackgroundVerification = true
                pane.operationResultPresenter = { _ in }; pane.operationErrorPresenter = { _ in }
                pane.clipboardWriter = browser.clipboardWriter
            }
            func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
            var checks = ["Preview preference defaults off and round-trips; unsupported preference versions retain the closed default", settingsCheck]
            var variant = 0
            var matrixRecords = Set<UUID>()
            for mode in [BrowserViewMode.details, .list, .icons] {
                for profile in [KeyboardProfile.mac, .explorer] {
                    let label = "\(mode.rawValue)-\(profile.rawValue)"
                    let root = matrixRoot.appendingPathComponent("variant-\(variant)", isDirectory: true)
                    let previewDestination = root.appendingPathComponent("preview", isDirectory: true)
                    let standardDestination = root.appendingPathComponent("standard", isDirectory: true)
                    try await Task.detached {
                        for url in [root, previewDestination, standardDestination] {
                            guard mkdir(url.path, 0o700) == 0 else { throw FileOperationFailure.invalidRequest }
                        }
                    }.value
                    browser.settings.keyboardProfile = profile
                    for pane in panes { pane.setPaneViewMode(mode) }
                    let origin = panes[variant % panes.count]
                    let peer = panes[(variant + 1) % panes.count]
                    let host = panes[(variant + 2) % panes.count]
                    origin.navigate(to: .directory(previewDestination)); peer.navigate(to: .directory(standardDestination))
                    host.navigate(to: .directory(root))
                    for pane in [origin, peer, host] { try await settled(pane) }
                    workspace.activate(origin)
                    try require(window.firstResponder === origin.activeFileView && origin.effectiveViewMode == mode,
                                "Preview matrix origin lost native file focus or requested presentation")
                    queue.pause()
                    browser.settings.groupedCopyPreview = true
                    BrowserClipboard.write(nil, urls: inputs, to: board)
                    let prior = Set(queue.state.waiting.map(\.id))
                    origin.pasteFiles(into: previewDestination)
                    guard let first = queue.state.waiting.first(where: { !prior.contains($0.id) })?.id else {
                        throw Failure(message: "Native Paste did not admit captured preview job: \(label)")
                    }
                    workspace.activate(peer)
                    try require(window.firstResponder === peer.activeFileView && !origin.isActiveCommandPane,
                                "Preview matrix cross-pane activation left authority or focus at the old origin")
                    browser.settings.groupedCopyPreview = false
                    BrowserClipboard.write(nil, urls: [inputs[0]], to: board)
                    peer.pasteFiles(into: standardDestination)
                    guard let second = queue.state.waiting.first(where: { !prior.contains($0.id) && $0.id != first })?.id else {
                        throw Failure(message: "Native Paste did not admit captured standard job: \(label)")
                    }
                    browser.settings.groupedCopyPreview = true
                    BrowserClipboard.write(nil, urls: [], to: board)
                    try await waitUntil("Preview matrix observations") {
                        [first, second].allSatisfy { id in queue.state.waiting.contains { $0.id == id && $0.phase == .ready } }
                    }
                    try require(queue.copyExecutionForVerification(first)?.request == .previewIfAvailable
                                && queue.copyExecutionForVerification(second)?.request == .standard
                                && queue.copyExecutionForVerification(first)?.decision == nil
                                && panes.allSatisfy { $0.recoverableFileOperations === engine },
                                "Matrix queue reread preferences, claimed early admission or lost shared engine identity")
                    workspace.activate(host); host.showTransferQueue(nil)
                    guard let resume = descendants(host.transferQueueDetails).compactMap({ $0 as? NSButton }).first(where: { $0.title == "Resume Queue" }) else {
                        throw Failure(message: "Generated matrix queue has no native Resume action")
                    }
                    let accessibleResume = NSAccessibility.unignoredDescendant(of: resume) as? any NSAccessibilityProtocol
                    let axLabel = accessibleResume?.accessibilityLabel(), axTitle = accessibleResume?.accessibilityTitle()
                    let enabled = resume.isEnabled, roleMatches = accessibleResume?.accessibilityRole() == .button
                    let nameMatches = (axLabel ?? axTitle) == "Resume Queue"
                    let focusMatches = window.firstResponder === resume
                        || (!resume.acceptsFirstResponder && window.firstResponder === host.activeFileView)
                    let liveGeometry = resume.window === window
                        && host.transferQueueDetails.window === window
                        && !resume.isHiddenOrHasHiddenAncestor && !resume.visibleRect.isEmpty
                        && host.operationDetailsContainer.superview === workspace.view
                    try require(enabled && roleMatches && nameMatches && focusMatches && liveGeometry
                                && workspace.activeBrowser === host,
                                "Queue Resume native cell/focus mismatch: role=\(accessibleResume?.accessibilityRole()?.rawValue ?? "nil"), name=\(nameMatches), focus=\(focusMatches), enabled=\(enabled), geometry=\(liveGeometry), activeHost=\(workspace.activeBrowser === host)")
                    // AppKit exposes this NSButton through its unignored cell.
                    // Invoke the native control path in this unshown window;
                    // this does not exercise external AXPress or VoiceOver.
                    resume.performClick(nil)
                    try await waitUntil("Preview matrix queued jobs") { !queue.hasOutstandingWork }
                    host.transferQueueDetails.onClose?()
                    try require(window.firstResponder === host.activeFileView && workspace.activeBrowser === host,
                                "Closing drained Queue stranded focus or activated a completed job's origin")
                    guard let grouped = queue.results.first(where: { $0.id == first }), let standard = queue.results.first(where: { $0.id == second }),
                          let groupedID = grouped.outcome.recordID, let standardID = standard.outcome.recordID else {
                        throw Failure(message: "Native preview matrix lost captured typed results")
                    }
                    try require(grouped.copyExecution == .previewIfAvailable && grouped.executionDecision == .groupedCopy(maximumMembersPerGroup: 16)
                                && standard.copyExecution == .standard && standard.executionDecision == .standard(.previewOff)
                                && grouped.outcome.result.disposition == .succeeded && standard.outcome.result.disposition == .succeeded
                                && grouped.engine === engine && standard.engine === engine,
                                "Matrix actual routing did not honor captured requests/decisions")
                    matrixRecords.insert(groupedID); matrixRecords.insert(standardID)
                    let history = try await engine.recoveryRecords(limit: 64)
                    try require(history.nextCursor == nil && history.refusedEntries.isEmpty && history.records.count <= 64
                                && history.records.first(where: { $0.id == groupedID })?.kind == .groupedCopy
                                && history.records.first(where: { $0.id == standardID })?.kind == .ordinary,
                                "Matrix history exceeded its bound or disagreed with actual typed queue decisions")
                    browser.settings.groupedCopyPreview = false
                    let review = try await engine.prepareGroupedRecovery(recordID: groupedID)
                    try require(review.items.count == inputs.count && review.items.allSatisfy { $0.state == .copied } && review.canUndo,
                                "Matrix preview-off state disabled copied-file evidence or typed Undo")
                    let closed = RecoverableFileOperations(journalDirectory: testRoot.appendingPathComponent("journal", isDirectory: true))
                    let closedPlan = try await closed.prepareTransfer(sources: [inputs[0]], destinationDirectory: standardDestination,
                                                                      move: false, copyExecution: .previewIfAvailable)
                    try require(closed.copyPreviewAvailability == .qualificationPending && closedPlan.executionDecision == .standard(.qualificationPending),
                                "Matrix normal engine inherited owner preview authority")
                    let after = try await engine.prepareGroupedRecovery(recordID: groupedID)
                    try require(after.revision == review.revision && after.state == review.state,
                                "Matrix capability getter or normal prepare mutated grouped history")
                    let reviewChecks = try await verifyGroupedCopyRecovery(host, engine: engine, recordID: groupedID,
                        expectedItems: inputs.count, in: testRoot, output: output, interactive: interactive && variant == 5)
                    try require(!reviewChecks.isEmpty && panes.allSatisfy { $0.recoverableFileOperations === engine },
                                "Matrix copied-file review lost shared session ownership")
                    let preserved = try await Task.detached { try groupedQueueSourceFingerprint(inputs, in: source) }.value
                    try require(preserved == originalSources, "Preview matrix changed its original generated source objects or contents")
                    checks.append("\(label): actual Paste on/off capture, native shared-pane Queue performClick, accessible AXButton cell/name and file focus, typed histories and preview-off copied-file review")
                    variant += 1
                }
            }
            try require(variant == 6 && matrixRecords.count == 12 && workspace.browsers.count == 4,
                        "Preview matrix did not execute all six variants with distinct bounded jobs and four panes")
            checks.append("Six view/preset variants retain distinct outputs and twelve records in one bounded fixture history; four panes share one engine/queue; physical keyboard, external AXPress and VoiceOver remain unverified")
            return checks
        } catch {
            queue.pause(); queue.cancelAllWaiting(); queue.stopActive()
            try? await waitUntil("Failed preview queue writer drain") { !queue.hasOutstandingWork }
            throw error
        }
    }

    /// Construct the actual Operations settings views through both App entry
    /// factories. This verifies captured capability and the live saved binding;
    /// it does not claim an external AXPress or physical toggle interaction.
    private static func verifyGroupedCopySettingsCapture(_ browser: BrowserViewController,
        engine: RecoverableFileOperations, in root: URL) async throws -> String {
        guard let workspace = browser.workspace else { throw Failure(message: "Settings capture needs its native workspace") }
        let active = workspace.activePaneID
        let originalEngine = browser.recoverableFileOperations
        let originalPreview = browser.settings.groupedCopyPreview
        var windows: [NSWindow] = []
        defer {
            windows.forEach { $0.close() }
            browser.recoverableFileOperations = originalEngine
            browser.settings.groupedCopyPreview = originalPreview
            if let previous = workspace.browsers[active] { workspace.activate(previous) }
        }
        workspace.activate(browser)
        browser.recoverableFileOperations = engine
        let fixtureStandalone = browser.makeSettingsView(initialPage: .operations)
        let fixtureWorkspace = workspace.makeWorkspaceSettingsView(initialPage: .operations)
        try require(fixtureStandalone.canSelectCopyPreview && fixtureWorkspace.canSelectCopyPreview
            && fixtureStandalone.settings === browser.settings && fixtureWorkspace.settings === browser.settings,
                    "Actual Settings factories lost generated-session capability or their live preference binding")
        let normal = RecoverableFileOperations(journalDirectory: root.appendingPathComponent("journal", isDirectory: true))
        browser.recoverableFileOperations = normal
        let normalStandalone = browser.makeSettingsView(initialPage: .operations)
        let normalWorkspace = workspace.makeWorkspaceSettingsView(initialPage: .operations)
        browser.recoverableFileOperations = engine
        try require(normal.copyPreviewAvailability == .qualificationPending
            && !normalStandalone.canSelectCopyPreview && !normalWorkspace.canSelectCopyPreview
            && fixtureStandalone.canSelectCopyPreview && fixtureWorkspace.canSelectCopyPreview,
                    "Settings enabled ordinary owner routing or failed to retain its captured session capability")
        for settingsView in [fixtureStandalone, fixtureWorkspace, normalStandalone, normalWorkspace] {
            let window = BrowserSettingsWindow.make(settingsView)
            let host = window.contentViewController!
            window.isReleasedWhenClosed = false
            windows.append(window)
            host.view.layoutSubtreeIfNeeded()
        }
        await Task.yield()
        windows.forEach { $0.contentView?.layoutSubtreeIfNeeded() }
        fixtureWorkspace.settings.groupedCopyPreview = true
        let restored = BrowserSettings(persist: false, restoredData: try browser.settings.encodedSnapshot())
        try require(restored.groupedCopyPreview && restored.copyExecutionRequest == .previewIfAvailable
            && normal.copyPreviewAvailability == .qualificationPending,
                    "Operations preference binding failed to round-trip or opened ordinary engine authority")
        return "Actual standalone/workspace Operations settings capture fixture availability and disable ordinary sessions; saved binding round-trips without activating owner routing; native toggle activation remains unverified"
    }

    nonisolated private static func groupedQueueSourceFingerprint(_ inputs: [URL], in source: URL) throws -> String {
        guard !inputs.isEmpty, inputs.count <= 33 else { throw FileOperationFailure.invalidRequest }
        let parent = open(source.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard parent >= 0 else { throw FileOperationFailure.invalidRequest }; defer { close(parent) }
        var directory = stat()
        guard fstat(parent, &directory) == 0, directory.st_uid == geteuid(), directory.st_mode & 0o077 == 0 else {
            throw FileOperationFailure.invalidRequest
        }
        var total = 0
        var rows: [String] = []
        for url in inputs.sorted(by: { $0.path < $1.path }) {
            guard url.path == url.standardizedFileURL.path, url.deletingLastPathComponent().path == source.path else {
                throw FileOperationFailure.invalidRequest
            }
            let fd = openat(parent, url.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { throw FileOperationFailure.invalidRequest }; defer { close(fd) }
            var before = stat()
            guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG, before.st_uid == geteuid(),
                  before.st_mode & 0o077 == 0, before.st_nlink == 1, before.st_size >= 0,
                  before.st_size <= 16_777_216 else { throw FileOperationFailure.invalidRequest }
            var digest = SHA256(), count = 0, bytes = [UInt8](repeating: 0, count: 65_536)
            while true {
                let read = Darwin.read(fd, &bytes, bytes.count)
                guard read >= 0 else { throw FileOperationFailure.ioFailure }
                if read == 0 { break }
                count += read; total += read
                guard count <= 16_777_216, total <= 67_108_864 else { throw FileOperationFailure.unsupported }
                digest.update(data: Data(bytes.prefix(read)))
            }
            var after = stat(), linked = stat()
            guard fstat(fd, &after) == 0, fstatat(parent, url.lastPathComponent, &linked, AT_SYMLINK_NOFOLLOW) == 0,
                  before.st_dev == after.st_dev, before.st_ino == after.st_ino, before.st_size == after.st_size,
                  before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
                  linked.st_dev == after.st_dev, linked.st_ino == after.st_ino, count == before.st_size else {
                throw FileOperationFailure.sourceChanged
            }
            let hash = digest.finalize().map { String(format: "%02x", $0) }.joined()
            rows.append("\(url.lastPathComponent)|\(after.st_dev)|\(after.st_ino)|\(after.st_mode)|\(after.st_uid)|\(after.st_gid)|\(after.st_flags)|\(after.st_size)|\(after.st_mtimespec.tv_sec)|\(after.st_mtimespec.tv_nsec)|\(hash)")
        }
        return SHA256.hash(data: Data(rows.joined(separator: "\n").utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
#endif
