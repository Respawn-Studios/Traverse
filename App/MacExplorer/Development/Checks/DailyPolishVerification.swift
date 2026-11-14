import AppKit
import ExplorerCore
import LocalStorage
import FileOperations

#if DEBUG
@MainActor
extension UIVerification {
    static func verifyDailyPolish(_ browser: BrowserViewController, fixture: URL, output: URL) async throws -> [String] {
        try verifyOwnedCopyPublicationState(fixture: fixture)
        try await verifyClipboardDismissControl(fixture: fixture)
        let interactive = !ProcessInfo.processInfo.arguments.contains("--offscreen")
        if interactive { try await verifyClipboardPopoverDismissClick(fixture: fixture, output: output) }
        let attentionStep = interactive ? 1 : 0
        let drives = VolumeBrowserView()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 360),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = drives
        defer { window.orderOut(nil) }
        var measurements: [[String: Any]] = []
        var maximumGap: CGFloat = 0
        for width in [1100, 760, 340] {
            window.setContentSize(NSSize(width: width, height: 360))
            for count in [2, 3, 5] {
                drives.update(volumes: (0..<count).map { index in
                    VolumeInfo(url: fixture.appendingPathComponent("Polish drive \(index)", isDirectory: true),
                               name: "Fixture drive \(index + 1)", kind: .externalDisk,
                               totalBytes: 1000, availableBytes: 600)
                })
                drives.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(50))
                drives.collectionView.layoutSubtreeIfNeeded()
                let frames = (0..<count).compactMap {
                    drives.collectionView.collectionViewLayout?.layoutAttributesForItem(at: IndexPath(item: $0, section: 0))?.frame
                }
                try require(frames.count == count, "Drive geometry did not materialize all fixture items")
                try require(frames.allSatisfy { $0.minX >= 0 && $0.maxX <= drives.collectionView.bounds.width + 1 && $0.height == 76 },
                            "Compact drive tile extends beyond available width or changes its height")
                for index in 0..<count {
                    let point = NSPoint(x: frames[index].midX, y: frames[index].midY)
                    guard drives.collectionView.visibleRect.contains(point) else { continue }
                    try require(drives.collectionView.indexPathForItem(at: point)?.item == index,
                                "Native drive hit testing disagrees with compact frame at width \(width), count \(count), index \(index)")
                }
                let ordered = frames.sorted { abs($0.minY - $1.minY) < 1 ? $0.minX < $1.minX : $0.minY < $1.minY }
                let gaps = zip(ordered, ordered.dropFirst()).compactMap { left, right in
                    abs(left.minY - right.minY) < 1 ? right.minX - left.maxX : nil
                }
                maximumGap = max(maximumGap, gaps.max() ?? 0)
                measurements.append(["width": width, "count": count,
                    "frames": frames.map { ["x": $0.minX, "y": $0.minY, "width": $0.width, "height": $0.height] },
                    "horizontalGaps": gaps])
                if count == 5 { try await snapshot(window, to: output.appendingPathComponent("daily-drives-\(width).png")) }
            }
        }
        try JSONSerialization.data(withJSONObject: ["measurements": measurements, "maximumGap": maximumGap],
                                   options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("daily-polish-drive-layout.json"), options: .withoutOverwriting)
        try require(maximumGap <= 13, "Drive tiles spread apart at wide widths: largest adjacent gap \(maximumGap) pt; expected 12 pt")
        window.setContentSize(NSSize(width: 760, height: 360))
        drives.layoutSubtreeIfNeeded()
        let selected = fixture.appendingPathComponent("Polish drive 0", isDirectory: true)
        drives.setSelection([selected])
        guard let tile = drives.visibleTiles.first(where: { $0.volume?.url == selected }) else {
            throw Failure(message: "Drive hover fixture did not materialize")
        }
        tile.setHoveredForVerification(true)
        tile.isDropTarget = true
        try require(tile.isHovered && tile.isSelected && drives.selectedURLs == [selected] && tile.isDropTarget,
                    "Drive hover replaced selection or drop-target state")
        tile.setHoveredForVerification(false)
        try require(!tile.isHovered && tile.isSelected && tile.isDropTarget,
                    "Drive hover exit erased selection or the drop target")
        tile.isDropTarget = false
        drives.selectAll()
        try require(drives.selectedCount == 5, "Compact drive layout lost multiple selection")
        var opened: URL?
        drives.onOpen = { opened = $0 }
        drives.setSelection([selected])
        drives.focus()
        drives.collectionView.keyDown(with: key("\u{f703}", code: 124, flags: [], window: window))
        try require(drives.selectedURLs == [fixture.appendingPathComponent("Polish drive 1", isDirectory: true)],
                    "Compact drive layout lost native right-arrow selection")
        drives.setSelection([selected])
        drives.collectionView.keyDown(with: key("\r", code: 36, flags: [], window: window))
        try require(opened == selected, "Compact drive layout lost keyboard Open")
        tile.setHoveredForVerification(true)
        try await snapshot(window, to: output.appendingPathComponent("daily-drive-selection-hover.png"))
        tile.setHoveredForVerification(false)

        let originalBackground = browser.permitsBackgroundVerification
        browser.permitsBackgroundVerification = true
        defer { browser.permitsBackgroundVerification = originalBackground; browser.clearCutSelection() }
        browser.navigate(to: .directory(fixture))
        try await settled(browser)
        try require(browser.displayedEntries.count >= 2, "Clipboard fixture needs two entries")
        browser.table.selectRowIndexes(IndexSet([0, 1]), byExtendingSelection: false)
        let copied = browser.orderedSelectedURLs
        try verifyControllerCopyPublication(browser, fixture: fixture)
        try await verifyControllerCutPublication(browser)
        let beforeAttention = browser.clipboardStatus.attentionCount
        browser.copyFileURLs(nil)
        try require(browser.clipboardStatus.refreshDetails() && browser.transferFeedback?.urls == copied,
                    "Copy inspector did not use exact clipboard file references")
        try require(browser.clipboardStatus.attentionCount == beforeAttention + attentionStep
                    && browser.transferFeedback?.attention.presented == interactive,
                    "Copy attention must present once in a visible window and remain unconsumed while hidden")
        guard let browserWindow = browser.view.window else { throw Failure(message: "Clipboard has no browser window") }
        let priorResponder = browserWindow.firstResponder
        try require(browserWindow.makeFirstResponder(browser.clipboardStatus)
                    && browserWindow.firstResponder === browser.clipboardStatus
                    && browser.clipboardStatus.accessibilityRole() == .button,
                    "Clipboard inspection cannot receive native keyboard focus or lacks its accessible button role")
        if interactive {
            browser.clipboardStatus.keyDown(with: key(" ", code: 49, flags: [], window: browserWindow))
            try require(browser.clipboardStatus.detailsAreShownForVerification,
                        "Space did not open the live clipboard inspector")
            browser.clipboardStatus.keyDown(with: key("\u{1b}", code: 53, flags: [], window: browserWindow))
            try require(!browser.clipboardStatus.detailsAreShownForVerification && browser.transferFeedback?.urls == copied,
                        "Escape dismissed clipboard intent instead of closing only inspection")
        }
        browserWindow.makeFirstResponder(priorResponder)
        try verifyClipboardF6(browser, in: browserWindow)
        let originalLines = browser.clipboardStatus.detailLines
        try require(copied.allSatisfy { url in
            originalLines.contains("\(url.lastPathComponent)\nSource: \(url.deletingLastPathComponent().path)")
        }, "Clipboard inspector omitted exact item names or source locations")
        browser.goComputer(nil)
        try await settled(browser)
        browser.renderTransferFeedback(); browser.refreshStatus()
        try require(browser.clipboardStatus.refreshDetails() && browser.clipboardStatus.detailLines == originalLines
                    && browser.clipboardStatus.attentionCount == beforeAttention + attentionStep,
                    "Navigation lost Copy source details or repeated its attention cue")
        let other = ClipboardFeedbackView(frame: NSRect(x: 0, y: 0, width: 380, height: 28))
        let otherWindow = NSWindow(contentRect: other.frame, styleMask: [], backing: .buffered, defer: false)
        other.liveFeedback = { browser.transferFeedback }
        other.update(browser.transferFeedback)
        otherWindow.contentView = other
        try require(other.attentionCount == 0, "A second pane repeated shared clipboard attention")
        try require(browser.transferFeedback?.attention.presented == interactive,
                    "A hidden second-pane footer consumed pending clipboard attention")
        otherWindow.contentView = nil
        if let details = browser.clipboardStatus.detailsControllerForVerification() {
            let inspectionWindow = NSWindow(contentRect: NSRect(origin: .zero, size: details.preferredContentSize),
                                            styleMask: [], backing: .buffered, defer: false)
            inspectionWindow.contentViewController = details
            try await snapshot(inspectionWindow, to: output.appendingPathComponent("daily-clipboard-details.png"))
            inspectionWindow.orderOut(nil)
        } else { throw Failure(message: "Live clipboard inspector did not build its native content") }
        browser.navigate(to: .directory(fixture))
        try await settled(browser)
        browser.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        browser.cutFileURLs(nil)
        try await waitUntil("Polish Cut observation") { browser.cutPreparationTask == nil }
        try require(browser.clipboardStatus.refreshDetails() && browser.clipboardStatus.stringValue.contains("Cut 1 item")
                    && browser.clipboardStatus.attentionCount == beforeAttention + 2 * attentionStep,
                    "Cut did not update inspector or obey visible-only finite attention")
        browser.transferFeedback?.moveAttemptIncomplete = true
        browser.renderTransferFeedback()
        try require(browser.clipboardStatus.detailLines.last?.contains("Move unfinished") == true
                    && browser.clipboardStatus.attentionCount == beforeAttention + 2 * attentionStep,
                    "Incomplete Move feedback repeated attention or retained ready-to-move guidance")
        BrowserClipboard.write("Newer fixture clipboard", urls: [], to: browser.transferPasteboard)
        try require(!browser.clipboardStatus.refreshDetails() && browser.clipboardStatus.detailLines.isEmpty
                    && browser.clipboardStatus.isHidden && browser.pendingCut == nil,
                    "Inspection exposed stale references after a newer clipboard revision")
        browser.focusBrowserContent()
        try require(browserWindow.performKeyEquivalent(with: key("\u{f709}", code: 97, flags: [], window: browserWindow))
                    && browserWindow.firstResponder === browser.outline,
                    "F6 retained an expired clipboard inspector in its focus cycle")
        let many = (0..<12).map { fixture.appendingPathComponent("Source \($0)/Same name.txt") }
        BrowserClipboard.write(nil, urls: many, to: browser.transferPasteboard)
        browser.showTransferFeedback(.copy, urls: many)
        try require(browser.clipboardStatus.detailLines.count == 8
                    && browser.clipboardStatus.detailLines[6] == "6 more items on the clipboard"
                    && browser.clipboardStatus.detailLines[0] != browser.clipboardStatus.detailLines[1],
                    "Clipboard details are unbounded or confuse equal names from distinct sources")
        try await verifySharedClipboardFocus(fixture: fixture)
        let deferred = ClipboardFeedbackView(frame: NSRect(x: 0, y: 0, width: 380, height: 28))
        let deferredFeedback = TransferClipboardFeedback(intent: .copy, urls: [fixture], changeCount: 0)
        let deferredWindow = NSWindow(contentRect: deferred.frame, styleMask: [.titled], backing: .buffered, defer: false)
        deferredWindow.isReleasedWhenClosed = false
        deferredWindow.contentView = deferred
        deferred.liveFeedback = { deferredFeedback }
        deferred.update(deferredFeedback)
        try require(deferred.attentionCount == 0 && !deferredFeedback.attention.presented,
                    "Attaching a hidden footer consumed its deferred attention")
        if interactive {
            deferredWindow.orderFront(nil)
            deferred.update(deferredFeedback)
            try require(!deferredWindow.isKeyWindow && deferred.attentionCount == 0 && !deferredFeedback.attention.presented,
                        "An ordered non-key window consumed attention before the user returned to it")
            deferredWindow.makeKeyAndOrderFront(nil)
            try await waitUntil("Deferred visible clipboard attention") { deferred.attentionCount == 1 }
            deferredWindow.orderOut(nil)
            deferredWindow.makeKeyAndOrderFront(nil)
            deferred.update(deferredFeedback)
            try require(deferred.attentionCount == 1 && deferredFeedback.attention.presented,
                        "Reopening a window repeated consumed clipboard attention")
            deferredWindow.orderOut(nil)
            browserWindow.makeKeyAndOrderFront(nil)
        }
        deferredWindow.close()
        try requireControlledWindowsHidden("daily polish")
        return [
            "Native drive frames retain 12 pt compact spacing and hit testing across wide/mid/narrow widths with 2/3/5 supplied volumes",
            "Drive hover supplements selection/drop targets; multiple selection and Explorer keyboard Open survive compact layout",
            "Native Copy/Cut inspector retains exact file names/source directories across navigation; repeated render and a second pane do not repeat attention",
            "Incomplete Move guidance stays honest; newer clipboard clears inspector immediately; large selections are bounded to six explicit items",
            "Native BrowserWindow F6/Shift-F6 events reach the live inspector, skip expired feedback and follow the active pane's shared footer; text editing aliases remain native",
            interactive ? "Positive native window visibility presents deferred attention exactly once across hide/show" : "Hidden windows and detached/inactive pane footers leave attention unconsumed; positive visible pulse remains a foreground gate",
            "Native details content rendered in a hidden window; physical hover, popover focus delivery and VoiceOver remain owner walkthrough gates",
            "Dismiss and Cut cancellation clear only the captured app intent; native private-pasteboard generations, types and bytes remain exact across newer intents, text and file references",
            "Shared-pane Cut markings clear together; Explorer/Mac presets and optional bottom path rows retain keyboard focus and bounded dismiss-button geometry",
            interactive ? "One native footer click dismisses hover/keyboard-opened Copy and Cut cards, preserves the native clipboard and does not consume a neighboring control's click" : "First-click popover routing is explicitly unexercised offscreen; run foreground --check-polish"
        ]
    }

    private static func verifyClipboardF6(_ browser: BrowserViewController, in window: NSWindow) throws {
        browser.focusBrowserContent()
        let content: NSView = browser.showsComputerVolumes ? browser.volumeBrowser.collectionView : browser.activeFileView
        try require(window.performKeyEquivalent(with: key("\u{f709}", code: 97, flags: [], window: window))
                    && window.firstResponder === browser.clipboardStatus,
                    "Native F6 shortcut dispatch cannot reach the visible clipboard inspector")
        try require(window.performKeyEquivalent(with: key("\u{f709}", code: 97, flags: [], window: window))
                    && window.firstResponder === browser.outline,
                    "Native F6 cannot leave the clipboard inspector")
        try require(window.performKeyEquivalent(with: key("\u{f709}", code: 97, flags: [.shift], window: window))
                    && window.firstResponder === browser.clipboardStatus,
                    "Native Shift-F6 cannot reach the clipboard inspector in reverse")
        try require(window.performKeyEquivalent(with: key("\u{f709}", code: 97, flags: [.shift], window: window))
                    && window.firstResponder === content,
                    "Native Shift-F6 cannot return from the clipboard inspector to file content")
        if !browser.showsComputerVolumes {
            // A compact search uses a transient popover, which an offscreen
            // window cannot display. Its address is the native text editor
            // available in both layouts for this shortcut-isolation control.
            if browser.folderFilter.isCompact { browser.focusLocation(nil) }
            else { browser.focusFilter(nil) }
            let editor = window.firstResponder
            try require(editor is NSTextView, "Clipboard focus regression did not enter its native text editor")
            let revision = browser.clipboardRevision
            _ = window.performKeyEquivalent(with: key("c", code: 8, flags: [.control], window: window))
            try require(window.firstResponder === editor && browser.clipboardRevision == revision,
                        "File Copy alias intercepted native text-field editing")
            if !browser.pathField.isHidden { browser.cancelLocationEditing() }
            browser.focusBrowserContent()
        }
    }

    /// Real shared-state receipt lifecycle; unique native boards only.
    private static func verifyOwnedCopyPublicationState(fixture: URL) throws {
        let board = NSPasteboard.withUniqueName(), other = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally(); other.releaseGlobally() }
        let state = BrowserClipboardState()
        state.pasteboard = board
        let urls = [fixture]
        let revision = state.revision
        let publication = BrowserClipboard.publish(nil, urls: urls, to: board)
        try require(state.acceptCopy(publication, urls: urls, revision: revision), "Owned Copy lacked successful native publication")
        let firstID = state.feedback!.id
        let nativeGeneration = board.changeCount
        try require(state.readFiles(allowOwnedCopy: true)?.urls == urls && board.changeCount == nativeGeneration,
                    "Owned Copy capture changed its references or native generation")
        try require(!state.acceptCopy(.failed, urls: urls, revision: revision), "Failed writer borrowed equal prior references")
        state.clear()
        let newerRevision = state.revision
        let newer = BrowserClipboard.publish(nil, urls: urls, to: board)
        try require(state.acceptCopy(newer, urls: urls, revision: newerRevision), "New Copy receipt was not accepted")
        let newerID = state.feedback!.id
        try require(!state.acceptCopy(publication, urls: urls, revision: revision)
                    && !state.dismiss(feedbackID: firstID) && state.feedback?.id == newerID,
                    "Old publication or dismissal replaced newer shared Copy intent")
        let beforeDismiss = board.changeCount
        try require(state.dismiss(feedbackID: newerID) && state.feedback == nil && board.changeCount == beforeDismiss,
                    "Dismissal changed native ownership or retained app intent")
        try require(state.readFiles(allowOwnedCopy: true)?.urls == urls, "Dismissal lost native ordinary Paste references")
        let current = BrowserClipboard.publish(nil, urls: urls, to: board)
        try require(state.acceptCopy(current, urls: urls, revision: state.revision), "Current Copy receipt missing")
        _ = BrowserClipboard.write(nil, urls: urls, to: board)
        state.synchronize()
        try require(state.feedback == nil && state.readFiles(allowOwnedCopy: true)?.urls == urls,
                    "New identical native publication retained old app ownership or lost fallback")
        _ = BrowserClipboard.write(nil, urls: urls, to: other)
        let otherGeneration = other.changeCount
        state.pasteboard = other
        try require(state.feedback == nil && state.pendingCut == nil && other.changeCount == otherGeneration,
                    "Board substitution retained old intent or mutated native references")
        try require(state.readFiles(allowOwnedCopy: true)?.urls == urls, "Foreign board native fallback failed")
    }

    /// Actual controller Copy dispatch through a reentrant custom writer.
    private static func verifyControllerCopyPublication(_ browser: BrowserViewController, fixture: URL) throws {
        let oldState = browser.clipboardState, oldWriter = browser.clipboardWriter
        let oldStatus = browser.status.stringValue
        let board = NSPasteboard.withUniqueName()
        let state = BrowserClipboardState()
        state.pasteboard = board
        browser.clipboardState = state
        defer {
            state.clear()
            browser.clipboardStatus.closeDetails()
            browser.clipboardState = oldState
            browser.clipboardWriter = oldWriter
            browser.status.stringValue = oldStatus
            browser.renderTransferFeedback()
            board.releaseGlobally()
        }
        let inputs = browser.orderedSelectedURLs
        try require(inputs.count >= 2, "Reentrant Copy fixture lacks actual selected references")
        for returnOldReceipt in [true, false] {
            state.clear()
            var newerID: UUID?, newerRevision: UUID?, newerGeneration: Int?
            var calls = 0
            browser.clipboardWriter = { [weak browser] _, urls in
                guard let browser else { return .failed }
                calls += 1
                let oldReceipt = BrowserClipboard.publish(nil, urls: urls, to: board)
                state.clear()
                let revision = state.revision
                let newerURLs = Array(urls.reversed())
                let newer = BrowserClipboard.publish(nil, urls: newerURLs, to: board)
                browser.showTransferFeedback(.copy, urls: newerURLs, publication: newer, revision: revision)
                newerID = state.feedback?.id; newerRevision = state.revision; newerGeneration = board.changeCount
                return returnOldReceipt ? oldReceipt : .failed
            }
            browser.copyFileURLs(nil)
            try require(calls == 1 && newerID != nil && state.feedback?.id == newerID
                        && state.revision == newerRevision && state.feedback?.urls == Array(inputs.reversed())
                        && state.hasOwnedCopyForVerification && board.changeCount == newerGeneration,
                        "Older Copy writer completion cleared or replaced a valid newer Copy revision")
        }
        // A large publication is accepted by the real controller/state path,
        // while its 1,025 reference URLs are deliberately never cached as owned.
        state.clear()
        let large = (0..<1025).map { fixture.appendingPathComponent("clipboard-reference-\($0)") }
        let revision = state.revision
        let publication = BrowserClipboard.publish(nil, urls: large, to: board)
        guard case .unownedFiles = publication else { throw Failure(message: "Large native Copy unexpectedly failed or received an owned receipt") }
        browser.showTransferFeedback(.copy, urls: large, publication: publication, revision: revision)
        let generation = board.changeCount
        try require(state.feedback?.urls == large && !state.hasOwnedCopyForVerification,
                    "Large controller Copy failed native validation or retained an oversized owned shortcut")
        let native = state.readFiles(allowOwnedCopy: true)
        try require(native?.urls == large && native?.urls.count == 1025 && board.changeCount == generation,
                    "Large shared-state Paste fallback lost exact native reference order/count")

        // Simulate reentry immediately after native validation, with no claim
        // that an actual AppKit IPC nested the run loop in this test.
        state.clear()
        let firstRevision = state.revision
        let firstPublication = BrowserClipboard.publish(nil, urls: inputs, to: board)
        let unchangedGeneration = board.changeCount
        var finalID: UUID?
        let accepted = state.acceptCopyForVerification(firstPublication, urls: inputs, revision: firstRevision) {
            state.clear()
            // Rebind the still-valid native proof to a fresh local intent, so
            // this regression isolates revision protection from generation.
            _ = state.acceptCopy(firstPublication, urls: inputs, revision: state.revision)
            finalID = state.feedback?.id
        }
        try require(!accepted && finalID != nil && state.feedback?.id == finalID && state.hasOwnedCopyForVerification
                    && board.changeCount == unchangedGeneration,
                    "Copy acceptance ignored a newer local revision after native validation")
        let staleRead = state.readFilesForVerification(allowOwnedCopy: true) {
            state.clear()
            _ = state.acceptCopy(firstPublication, urls: inputs, revision: state.revision)
            finalID = state.feedback?.id
        }
        try require(staleRead == nil && finalID != nil && state.feedback?.id == finalID && state.hasOwnedCopyForVerification
                    && board.changeCount == unchangedGeneration,
                    "Owned Copy read returned old references after a newer revision replaced its intent")

        // A watcher observation belongs to the captured local intent, even if
        // a newer Copy is installed after the native generation was observed.
        // This seam simulates that boundary; it does not assert real IPC reentry.
        for replaceRevision in [false, true] {
            state.clear()
            let oldPublication = BrowserClipboard.publish(nil, urls: inputs, to: board)
            try require(state.acceptCopy(oldPublication, urls: inputs, revision: state.revision),
                        "Clipboard watcher control could not establish an old Copy intent")
            let newerURLs = Array(inputs.reversed())
            let newerPublication = BrowserClipboard.publish(nil, urls: newerURLs, to: board)
            let observedGeneration = board.changeCount
            var newerID: UUID?, newerRevision: UUID?
            var replacementAccepted = false
            state.synchronizeForVerification {
                if replaceRevision { state.clear() }
                replacementAccepted = state.acceptCopy(newerPublication, urls: newerURLs, revision: state.revision)
                newerID = state.feedback?.id; newerRevision = state.revision
            }
            try require(replacementAccepted && newerID != nil && state.feedback?.id == newerID
                        && state.revision == newerRevision && state.feedback?.urls == newerURLs
                        && state.hasOwnedCopyForVerification && board.changeCount == observedGeneration,
                        "Stale clipboard observation cleared a newer Copy intent")
        }
        let invalidatedID = state.feedback?.id
        let foreignPublication = BrowserClipboard.publish("Generated clipboard watcher control", urls: [], to: board)
        guard case .text = foreignPublication else { throw Failure(message: "Clipboard watcher native mismatch control failed") }
        let foreignGeneration = board.changeCount
        state.synchronize()
        try require(invalidatedID != nil && state.feedback == nil && !state.hasOwnedCopyForVerification
                    && state.pendingCut == nil && board.changeCount == foreignGeneration,
                    "Clipboard watcher failed to clear a genuinely superseded intent or mutated the native clipboard")
    }

    /// Actual asynchronous Cut must establish native publication, not borrow
    /// already-equal references. This uses only generated selection/private board.
    private static func verifyControllerCutPublication(_ browser: BrowserViewController) async throws {
        let oldState = browser.clipboardState, oldWriter = browser.clipboardWriter
        let oldStatus = browser.status.stringValue, oldErrorPresenter = browser.operationErrorPresenter
        let board = NSPasteboard.withUniqueName()
        let state = BrowserClipboardState()
        state.pasteboard = board
        browser.clipboardState = state
        var errors = 0
        browser.operationErrorPresenter = { _ in errors += 1 }
        defer {
            state.clear()
            browser.clipboardStatus.closeDetails()
            browser.clipboardState = oldState
            browser.clipboardWriter = oldWriter
            browser.operationErrorPresenter = oldErrorPresenter
            browser.status.stringValue = oldStatus
            browser.renderTransferFeedback()
            board.releaseGlobally()
        }
        let inputs = browser.orderedSelectedURLs
        try require(inputs.count >= 2, "Cut publication fixture lacks an actual generated selection")
        for nativeFailure in [false, true] {
            state.clear()
            try require(BrowserClipboard.write(nil, urls: inputs, to: board), "Cut old-equal native fixture publication failed")
            var calls = 0
            var writerGeneration: Int?
            browser.clipboardWriter = { _, urls in
                calls += 1
                let result: BrowserClipboard.Publication = nativeFailure
                    ? BrowserClipboard.publishForVerification(nil, urls: urls, to: board, failWrite: true) : .failed
                writerGeneration = board.changeCount
                return result
            }
            browser.cutFileURLs(nil)
            guard let task = state.cutPreparation else { throw Failure(message: "Cut publication regression did not enter actual preparation") }
            await task.value
            try require(calls == 1 && errors == 0 && state.pendingCut == nil && state.pendingCutChangeCount == nil
                        && state.cutURLs.isEmpty && state.feedback == nil && !state.hasOwnedCopyForVerification
                        && browser.status.stringValue.contains("could not be placed") && board.changeCount == writerGeneration,
                        "Failed Cut publication borrowed old equal native references and claimed Ready to move")
            let native = BrowserClipboard.readFiles(from: board, isCurrent: { true })
            try require(native?.urls == (nativeFailure ? [] : inputs), "Failed Cut altered the writer's native clipboard result")
        }
        for returnOldReceipt in [true, false] {
            state.clear()
            var calls = 0
            var newerID: UUID?, newerRevision: UUID?, newerGeneration: Int?
            browser.clipboardWriter = { [weak browser] _, urls in
                guard let browser else { return .failed }
                calls += 1
                let oldReceipt = BrowserClipboard.publish(nil, urls: urls, to: board)
                state.clear()
                let revision = state.revision
                let newerURLs = Array(urls.reversed())
                let newer = BrowserClipboard.publish(nil, urls: newerURLs, to: board)
                browser.showTransferFeedback(.copy, urls: newerURLs, publication: newer, revision: revision)
                newerID = state.feedback?.id; newerRevision = state.revision; newerGeneration = board.changeCount
                return returnOldReceipt ? oldReceipt : .failed
            }
            browser.cutFileURLs(nil)
            guard let task = state.cutPreparation else { throw Failure(message: "Reentrant Cut regression did not enter actual preparation") }
            await task.value
            try require(calls == 1 && errors == 0 && newerID != nil && state.feedback?.id == newerID
                        && state.revision == newerRevision && state.feedback?.intent == .copy
                        && state.feedback?.urls == Array(inputs.reversed()) && state.hasOwnedCopyForVerification
                        && state.pendingCut == nil && state.cutURLs.isEmpty && board.changeCount == newerGeneration,
                        "Older Cut completion cleared or replaced a valid newer Copy intent")
        }
        state.clear()
        var successfulGeneration: Int?
        browser.clipboardWriter = { text, urls in
            let result = BrowserClipboard.publish(text, urls: urls, to: board)
            successfulGeneration = board.changeCount
            return result
        }
        browser.cutFileURLs(nil)
        guard let task = state.cutPreparation else { throw Failure(message: "Successful Cut control did not enter actual preparation") }
        await task.value
        try require(errors == 0 && state.pendingCut?.urls == inputs && state.pendingCutChangeCount == successfulGeneration
                    && state.cutURLs == Set(inputs) && state.feedback?.intent == .move && state.feedback?.urls == inputs
                    && !state.hasOwnedCopyForVerification && board.changeCount == successfulGeneration,
                    "Successful native Cut lost its exact observed selection or established a Copy shortcut")
        let native = BrowserClipboard.readFiles(from: board, isCurrent: { true })
        try require(native?.urls == inputs, "Successful Cut changed native reference order")
    }

    /// Unlike performClick, queued window events include AppKit's popover
    /// dismissal routing. This catches a click being consumed to close the card.
    private static func verifyClipboardPopoverDismissClick(fixture: URL, output: URL) async throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let state = BrowserClipboardState()
        state.pasteboard = board
        BrowserClipboard.write(nil, urls: [fixture], to: board)
        let originalClipboard = ClipboardSnapshot(board)
        let footer = ClipboardFeedbackView(frame: NSRect(x: 20, y: 20, width: 400, height: 28))
        footer.liveFeedback = { state.synchronize(); return state.feedback }
        var dismissCalls = 0
        footer.onDismiss = { id in dismissCalls += 1; return state.dismiss(feedbackID: id) }
        let previousKeyWindow = NSApplication.shared.keyWindow
        let window = NSWindow(contentRect: NSRect(x: 240, y: 240, width: 460, height: 420),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.title = "Disposable clipboard click verification"
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 420))
        content.addSubview(footer)
        var outsideCalls = 0
        let outside = ActionButton(title: "Disposable neighboring control", action: { outsideCalls += 1 })
        outside.frame = NSRect(x: 20, y: 360, width: 240, height: 28)
        content.addSubview(outside)
        window.contentView = content
        defer {
            footer.closeDetails()
            window.close()
            previousKeyWindow?.makeKeyAndOrderFront(nil)
        }
        window.makeKeyAndOrderFront(nil)
        NSRunningApplication.current.activate(options: [.activateAllWindows])
        try await waitUntil("Clipboard click verification foreground") { window.isKeyWindow }
        guard let dismiss = footer.subviews.compactMap({ $0 as? NSButton }).first,
              let entered = NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [],
                  timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                  context: nil, eventNumber: 1, trackingNumber: 0, userData: nil),
              let exited = NSEvent.enterExitEvent(with: .mouseExited, location: .zero, modifierFlags: [],
                  timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                  context: nil, eventNumber: 1, trackingNumber: 0, userData: nil) else {
            throw Failure(message: "Clipboard click fixture has no native dismiss target or hover event")
        }
        func click(_ control: NSView) async throws {
            let point = control.convert(NSPoint(x: control.bounds.midX, y: control.bounds.midY), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!
                NSApplication.shared.postEvent(event, atStart: false)
            }
            try await Task.sleep(for: .milliseconds(400))
        }
        var cases: [[String: Any]] = []
        let observed = try await LocalFileOperations().observeSelection([fixture])
        for intent in [TransferClipboardFeedback.Intent.copy, .move] {
            for hover in [true, false] {
                window.makeKeyAndOrderFront(nil)
                state.feedback = TransferClipboardFeedback(intent: intent, urls: [fixture], changeCount: board.changeCount)
                if intent == .move {
                    state.pendingCut = observed
                    state.pendingCutChangeCount = board.changeCount
                    state.cutURLs = [fixture]
                }
                footer.update(state.feedback)
                footer.layoutSubtreeIfNeeded()
                if hover { footer.mouseEntered(with: entered) }
                else {
                    footer.mouseExited(with: exited)
                    try require(window.makeFirstResponder(footer), "Keyboard card cannot focus its footer")
                    footer.keyDown(with: key(" ", code: 49, flags: [], window: window))
                }
                try await waitUntil("Open clipboard card") { footer.detailsAreShownForVerification }
                try require(!dismiss.isHidden, "Opening the card hid its footer dismiss target")
                let beforeCalls = dismissCalls
                try await click(dismiss)
                let passed = dismissCalls == beforeCalls + 1 && state.feedback == nil && footer.isHidden
                    && !footer.detailsAreShownForVerification && state.pendingCut == nil && state.cutURLs.isEmpty
                    && ClipboardSnapshot(board) == originalClipboard
                cases.append(["intent": intent == .copy ? "copy" : "cut", "opening": hover ? "hover" : "keyboard",
                    "passed": passed, "nativeDismissCalls": dismissCalls - beforeCalls,
                    "feedbackCleared": state.feedback == nil, "detailsClosed": !footer.detailsAreShownForVerification,
                    "nativeClipboardUnchanged": ClipboardSnapshot(board) == originalClipboard])
            }
        }
        window.makeKeyAndOrderFront(nil)
        state.feedback = TransferClipboardFeedback(intent: .copy, urls: [fixture], changeCount: board.changeCount)
        let retainedID = state.feedback?.id
        footer.update(state.feedback)
        footer.mouseEntered(with: entered)
        try await waitUntil("Clipboard card for neighboring click") { footer.detailsAreShownForVerification }
        try await click(outside)
        let neighborPassed = outsideCalls == 1 && !footer.detailsAreShownForVerification
            && state.feedback?.id == retainedID && ClipboardSnapshot(board) == originalClipboard
        cases.append(["opening": "hover", "target": "neighbor", "passed": neighborPassed,
            "nativeActionCalls": outsideCalls, "feedbackRetained": state.feedback?.id == retainedID])
        let passed = cases.allSatisfy { $0["passed"] as? Bool == true }
        try JSONSerialization.data(withJSONObject: ["passed": passed, "cases": cases,
            "delivery": "One queued native down/up pair in the owning window per case; private pasteboard"],
            options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("clipboard-first-click.json"), options: .withoutOverwriting)
        try require(passed, "Clipboard card consumed a first click or changed clipboard intent incorrectly; see clipboard-first-click.json")
    }

    /// Exercise the actual native action against an isolated pasteboard. Dismissal
    /// removes app feedback, while every stored representation remains intact.
    private static func verifyClipboardDismissControl(fixture: URL) async throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let state = BrowserClipboardState()
        state.pasteboard = board
        BrowserClipboard.write(nil, urls: [fixture], to: board)
        state.feedback = TransferClipboardFeedback(intent: .copy, urls: [fixture], changeCount: board.changeCount)
        let view = ClipboardFeedbackView(frame: NSRect(x: 0, y: 0, width: 380, height: 28))
        view.liveFeedback = { state.synchronize(); return state.feedback }
        view.onDismiss = { state.dismiss(feedbackID: $0) }
        view.update(state.feedback)
        guard let controller = view.detailsControllerForVerification() else {
            throw Failure(message: "Dismiss fixture could not build clipboard inspection")
        }
        func findDismiss(in root: NSView) -> NSButton? {
            if let button = root as? NSButton, button.title == "Dismiss Clipboard Feedback" { return button }
            return root.subviews.lazy.compactMap { findDismiss(in: $0) }.first
        }
        let before = ClipboardSnapshot(board)
        guard let dismiss = findDismiss(in: controller.view) else {
            throw Failure(message: "Clipboard inspection lacks its accessible Dismiss Clipboard Feedback action")
        }
        dismiss.performClick(nil)
        try require(state.feedback == nil, "Dismiss action left application clipboard feedback visible")
        try require(ClipboardSnapshot(board) == before,
                    "Dismissing application feedback changed native pasteboard generation, types or bytes")

        // A focused status control must remain usable without enabling the
        // system-wide preference that makes Tab visit native buttons.
        state.feedback = TransferClipboardFeedback(intent: .copy, urls: [fixture], changeCount: board.changeCount)
        view.update(state.feedback)
        let removeFeedback = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
            characters: "\u{7f}", charactersIgnoringModifiers: "\u{7f}", isARepeat: false, keyCode: 51)!
        view.keyDown(with: removeFeedback)
        try require(state.feedback == nil && ClipboardSnapshot(board) == before,
                    "Focused clipboard Delete failed to dismiss only app feedback")

        // A retained old popover must not dismiss a newer Copy, even when the
        // URLs and native generation happen to be identical.
        let newer = TransferClipboardFeedback(intent: .copy, urls: [fixture], changeCount: board.changeCount)
        state.feedback = newer
        view.update(newer)
        dismiss.performClick(nil)
        try require(state.feedback?.id == newer.id && ClipboardSnapshot(board) == before,
                    "An old inspection callback dismissed a newer app intent or changed its clipboard")

        // Cut observations and their preparation belong to app intent. A
        // dismissal invalidates eventual completion guards without consuming
        // the native file references or touching any operation task.
        let observed = try await LocalFileOperations().observeSelection([fixture])
        state.pendingCut = observed
        state.pendingCutChangeCount = board.changeCount
        state.cutURLs = [fixture]
        let move = TransferClipboardFeedback(intent: .move, urls: [fixture], changeCount: board.changeCount)
        state.feedback = move
        let oldRevision = state.revision
        let gate = AsyncStream<Void>.makeStream()
        let preparation = Task { for await _ in gate.stream {} }
        state.cutPreparation = preparation
        try require(state.dismiss(feedbackID: move.id), "Current Cut dismissal was rejected")
        try require(preparation.isCancelled && state.cutPreparation == nil && state.pendingCut == nil
                    && state.pendingCutChangeCount == nil && state.cutURLs.isEmpty && state.feedback == nil
                    && state.revision != oldRevision,
                    "Cut dismissal retained markings/preparation or did not invalidate captured completion intent")
        gate.continuation.finish()
        await preparation.value
        try require(ClipboardSnapshot(board) == before
                    && (board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [NSURL])?.map({ $0 as URL }) == [fixture],
                    "Dismissed Cut no longer leaves exact native references available for ordinary Copy/Paste")

        // Synchronization must reject the stale captured action while preserving
        // both text and file revisions written by another clipboard owner.
        for files in [false, true] {
            state.feedback = TransferClipboardFeedback(intent: .copy, urls: [fixture], changeCount: board.changeCount)
            let oldID = state.feedback!.id
            if files { BrowserClipboard.write(nil, urls: [fixture.appendingPathComponent("New native reference")], to: board) }
            else {
                let item = NSPasteboardItem()
                item.setString("Newer isolated text", forType: .string)
                item.setData(Data([0, 1, 2, 255]), forType: .init("com.mac-explorer.fixture-representation"))
                board.clearContents(); board.writeObjects([item])
            }
            let newerNative = ClipboardSnapshot(board)
            try require(!state.dismiss(feedbackID: oldID) && state.feedback == nil && ClipboardSnapshot(board) == newerNative,
                        "Stale dismissal altered newer native text/file representations")
        }
    }

    private struct ClipboardSnapshot: Equatable {
        let generation: Int
        let types: [[NSPasteboard.PasteboardType]]
        let data: [[Data?]]
        init(_ board: NSPasteboard) {
            generation = board.changeCount
            let items = board.pasteboardItems ?? []
            types = items.map(\.types)
            data = items.map { item in item.types.map { item.data(forType: $0) } }
        }
    }

    static func verifySharedClipboardFocus(fixture: URL) async throws {
        let settings = BrowserSettings(persist: false)
        settings.autoRefreshFolders = false
        settings.reviewsRecoveryAtStartup = false
        let primary = BrowserViewController(settings: settings)
        var clipboardErrors: [String] = []
        primary.operationErrorPresenter = { clipboardErrors.append($0) }
        primary.permitsBackgroundVerification = true
        primary.pinsController = BrowserPinsController(stateDirectory: nil)
        primary.folderAccess = FolderAccessController(stateDirectory: nil)
        let tab = BrowserTab(location: .directory(fixture))
        primary.tabs = [tab]; primary.activeID = tab.id
        let board = NSPasteboard.withUniqueName()
        primary.transferPasteboard = board
        primary.clipboardWriter = { text, urls in BrowserClipboard.publish(text, urls: urls, to: board) }
        let workspace = BrowserWorkspaceController(primaryBrowser: primary)
        let window = BrowserWindow(contentRect: NSRect(x: 0, y: 0, width: 1300, height: 780),
                                   styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.browser = primary; window.workspace = workspace
        workspace.onActiveBrowserChanged = { [weak window] pane in window?.browser = pane }
        window.contentViewController = workspace
        // AppKit may adopt the controller's fitting size on installation;
        // establish this fixture's deliberate two-pane geometry afterward.
        window.setContentSize(NSSize(width: 1300, height: 780))
        window.contentView?.layoutSubtreeIfNeeded()
        defer {
            primary.clipboardState.clear()
            workspace.isClosing = true
            workspace.browsers.values.forEach { $0.suspendBrowser() }
            window.close()
            board.releaseGlobally()
        }
        workspace.startBrowser(primary)
        try await settled(primary)
        BrowserClipboard.write(nil, urls: [fixture], to: board)
        primary.showTransferFeedback(.copy, urls: [fixture])
        try verifyClipboardF6(primary, in: window)
        let geometry = "content=\(window.contentView?.bounds.size ?? .zero), tree=\(workspace.paneTreeHost.bounds.size), canChange=\(workspace.canChangePaneLayout), busy=\(primary.hasPendingFileOperation), cutPreparing=\(primary.cutPreparationTask != nil)"
        try require(workspace.splitActive(at: .trailing), "Shared clipboard focus fixture could not split: " + geometry)
        let peer = workspace.activeBrowser
        peer.operationErrorPresenter = { clipboardErrors.append($0) }
        peer.permitsBackgroundVerification = true
        try await settled(peer)
        peer.renderTransferFeedback()
        try require(peer.clipboardState === primary.clipboardState
                    && peer.statusSurface?.superview === workspace.activeFooterHost
                    && primary.statusSurface?.superview == nil,
                    "Clipboard focus fixture did not install exactly the active pane's shared footer")
        try verifyClipboardF6(peer, in: window)
        workspace.activate(primary)
        primary.renderTransferFeedback()
        try verifyClipboardF6(primary, in: window)
        try require(primary.clipboardStatus.attentionCount == 0 && peer.clipboardStatus.attentionCount == 0
                    && primary.transferFeedback?.attention.presented == false,
                    "Hidden pane switching consumed or repeated deferred clipboard attention")

        for preset in [KeyboardProfile.explorer, .mac] {
            settings.keyboardProfile = preset
            for pathVisible in [false, true] {
                settings.showsPathBar = pathVisible
                await Task.yield()
                window.contentView?.layoutSubtreeIfNeeded()
                if preset == .explorer { try verifyClipboardF6(primary, in: window) }
                else {
                    primary.focusBrowserContent()
                    let responder = window.firstResponder
                    try require(!primary.handleExplorerShortcut(key("\u{f709}", code: 97, flags: [], window: window))
                                && window.firstResponder === responder,
                                "Mac preset unexpectedly enabled Explorer F6 focus remapping")
                }
                window.makeFirstResponder(primary.clipboardStatus)
                primary.clipboardStatus.layoutSubtreeIfNeeded()
                guard let dismiss = primary.clipboardStatus.subviews.compactMap({ $0 as? NSButton }).first else {
                    throw Failure(message: "Clipboard footer has no native dismiss button")
                }
                let rect = dismiss.convert(dismiss.bounds, to: primary.clipboardStatus)
                let footerRect = primary.clipboardStatus.convert(primary.clipboardStatus.bounds, to: workspace.activeFooterHost)
                let measured = "preset=\(preset.rawValue), path=\(pathVisible), pathHidden=\(workspace.pathHost.isHidden), "
                    + "dismissHidden=\(dismiss.isHidden), dismiss=\(rect), inspector=\(primary.clipboardStatus.bounds), "
                    + "inspectorInFooter=\(footerRect), footer=\(workspace.activeFooterHost.bounds), "
                    + "footerSurface=\(primary.statusSurface?.bounds ?? .zero), responder=\(String(describing: window.firstResponder))"
                try require(!dismiss.isHidden && rect.width >= 20 && rect.height >= 20
                            && primary.clipboardStatus.bounds.insetBy(dx: -1, dy: -1).contains(rect)
                            && workspace.activeFooterHost.bounds.insetBy(dx: -1, dy: -1).contains(footerRect)
                            && workspace.pathHost.isHidden
                            && primary.addressLayout?.bottomSurface.isHidden == !pathVisible,
                            "Clipboard dismiss geometry depends on keyboard preset/path row or clips outside its host: " + measured)
                let point = dismiss.convert(NSPoint(x: dismiss.bounds.midX, y: dismiss.bounds.midY), to: primary.clipboardStatus.superview)
                try require(primary.clipboardStatus.hitTest(point) === dismiss,
                            "Native clipboard dismiss hit testing disagrees with its visible bounds")
                primary.clipboardStatus.keyDown(with: key("\u{1b}", code: 53, flags: [], window: window))
                try require(primary.transferFeedback != nil && window.firstResponder === primary.clipboardStatus,
                            "Escape removed clipboard intent or lost footer focus")
            }
        }
        // Use the browser's file-selection seam after preference/layout work;
        // selecting a hidden or stale native table row is not a Cut gesture.
        workspace.activate(primary)
        try await settled(primary)
        guard let selected = primary.displayedEntries.first else { throw Failure(message: "Shared Cut fixture has no file entry") }
        primary.setFileSelection([selected.url])
        primary.fileSelectionDidChange()
        primary.focusBrowserContent()
        func cutDiagnostic() -> String {
            "canPrepare=\(primary.canPrepareTransferClipboard), focus=\(primary.hasFileCommandFocus), activePane=\(primary.isActiveCommandPane), "
                + "task=\(primary.operationTask != nil), preparation=\(primary.operationPreparationTask != nil), preparationID=\(String(describing: primary.operationPreparationID)), "
                + "owner=\(String(describing: primary.operationCoordinator.activeOwner)), preparationOwner=\(String(describing: primary.operationCoordinator.preparationOwner)), "
                + "cutPrep=\(primary.cutPreparationTask != nil), loading=\(primary.isLoading), metadata=\(primary.metadataSearch.isShowingResults), "
                + "selected=\(primary.orderedSelectedURLs.count), displayed=\(primary.displayedEntries.count), suspended=\(primary.isBrowserSuspended), "
                + "directory=\(primary.location.directoryURL != nil), sheet=\(window.attachedSheet != nil), errors=\(clipboardErrors)"
        }
        try require(primary.canPrepareTransferClipboard && primary.orderedSelectedURLs == [selected.url],
                    "Shared clipboard Cut fixture cannot issue its command: " + cutDiagnostic())
        primary.cutFileURLs(nil)
        do {
            try await waitUntil("Shared clipboard Cut") { primary.cutPreparationTask == nil && primary.pendingCut != nil && peer.transferFeedback != nil }
        } catch { throw Failure(message: "Shared clipboard Cut did not finish: " + cutDiagnostic()) }
        await Task.yield()
        try require(!primary.cutURLs.isEmpty && primary.cutURLs == peer.cutURLs,
                    "Shared-pane fixture did not establish one Cut selection")
        let cut = primary.cutURLs
        for pane in [primary, peer] {
            guard let row = pane.displayedEntries.firstIndex(where: { cut.contains($0.url) }), let column = pane.table.tableColumns.first else {
                throw Failure(message: "Shared-pane Cut fixture row is missing")
            }
            try require(pane.tableView(pane.table, viewFor: column, row: row)?.alphaValue == 0.5,
                        "Cut selection did not dim in both panes")
        }
        let beforeDismiss = ClipboardSnapshot(board)
        workspace.activate(peer)
        peer.renderTransferFeedback()
        window.makeFirstResponder(peer.clipboardStatus)
        guard let dismiss = peer.clipboardStatus.subviews.compactMap({ $0 as? NSButton }).first else {
            throw Failure(message: "Shared-pane clipboard dismiss button is missing")
        }
        dismiss.performClick(nil)
        try await waitUntil("Shared clipboard dismissal") {
            primary.clipboardStatus.isHidden && peer.clipboardStatus.isHidden && primary.cutURLs.isEmpty && peer.cutURLs.isEmpty
        }
        try require(ClipboardSnapshot(board) == beforeDismiss && primary.pendingCut == nil && peer.pendingCut == nil
                    && window.firstResponder === peer.activeFileView,
                    "Peer dismissal changed clipboard bytes, retained Cut intent or stranded focus")
        for pane in [primary, peer] {
            guard let row = pane.displayedEntries.firstIndex(where: { cut.contains($0.url) }), let column = pane.table.tableColumns.first else {
                throw Failure(message: "Dismissed Cut fixture row is missing")
            }
            try require(pane.tableView(pane.table, viewFor: column, row: row)?.alphaValue == 1,
                        "Peer dismissal retained dimming in another pane")
        }
    }
}
#endif
