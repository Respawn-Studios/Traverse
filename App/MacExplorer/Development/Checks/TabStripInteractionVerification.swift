import AppKit
import ExplorerCore

#if DEBUG
@MainActor
private final class TabFixtureDrag: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    let draggingSource: Any?
    let draggingSequenceNumber: Int
    let draggingSourceOperationMask: NSDragOperation
    var draggingLocation = NSPoint.zero
    var draggingDestinationWindow: NSWindow?
    var draggedImageLocation: NSPoint { .zero }
    nonisolated var draggedImage: NSImage? { nil }
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 0
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    init(board: NSPasteboard, source: Any?, sequence: Int, allowed: NSDragOperation = .move) {
        draggingPasteboard = board; draggingSource = source; draggingSequenceNumber = sequence
        draggingSourceOperationMask = allowed
        super.init()
    }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    nonisolated override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func resetSpringLoading() {}
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions, for view: NSView?,
                                classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any],
                                using block: @escaping (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
}

@MainActor
extension UIVerification {
    static func verifyTabStripInteractions(_ browser: BrowserViewController, fixture: URL,
                                           output: URL) async throws -> [String] {
        // Positive native accessibility actions require a visible live window.
        // The controlled runner otherwise deliberately keeps its browser hidden.
        let window = browser.view.window, wasVisible = browser.view.window?.isVisible == true
        let originalFrame = window?.frame
        if !wasVisible { window?.setFrameOrigin(.init(x:-12000,y:-12000));window?.orderFront(nil) }
        defer {
            if !wasVisible {
                window?.orderOut(nil)
                if let originalFrame {window?.setFrame(originalFrame,display:false)}
            }
        }
        let preallocationCheck = try verifyTabStripPreallocation(output: output)
        let originalTabs = browser.tabs, originalID = browser.activeID, originalClosed = browser.closedTabs
        let originalBackground = browser.permitsBackgroundVerification
        let first = BrowserTab(location: .computer)
        let second = BrowserTab(location: .directory(fixture))
        let third = BrowserTab(location: .directory(fixture.appendingPathComponent("Folder A", isDirectory: true)))
        browser.permitsBackgroundVerification = true
        browser.tabs = [first, second, third]; browser.activeID = second.id; browser.loadLocation()
        defer {
            browser.tabStrip.invalidateManagementInteraction()
            browser.tabs = originalTabs; browser.activeID = originalID; browser.closedTabs = originalClosed
            browser.permitsBackgroundVerification = originalBackground; browser.loadLocation()
        }
        try await settled(browser)
        let strip = browser.tabStrip
        strip.layoutSubtreeIfNeeded()
        let active = browser.activeID, visit = browser.sessionID
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        guard let type = strip.registerTabDragForVerification(id: first.id, sequence: 5101),
              let lastFrame = strip.lastTabFrame else { throw Failure(message: "Controlled tab source could not be registered") }
        board.setString(first.id.uuidString, forType: type)
        let source = TabFixtureDrag(board: board, source: strip, sequence: 5101)
        source.draggingDestinationWindow = browser.view.window
        source.draggingLocation = strip.convert(NSPoint(x: lastFrame.maxX - 4, y: lastFrame.midY), to: nil)
        try require(strip.draggingUpdated(source) == .move && strip.prepareForDragOperation(source),
                    "Authenticated tab drag did not negotiate a same-strip reorder")
        try require(browser.tabs.map(\.id) == [first.id, second.id, third.id]
                    && (strip.selectionButton(for: first.id)?.superview?.frame.minX ?? -1)
                        > (strip.selectionButton(for: third.id)?.superview?.frame.minX ?? .greatestFiniteMagnitude),
                    "Insertion did not rearrange native tab views independently of the uncommitted tab model")
        try require(strip.performDragOperation(source), "Authenticated native tab drop did not invoke reordering")
        try require(browser.tabs.map(\.id) == [second.id, third.id, first.id]
                    && browser.activeID == active && browser.sessionID == visit,
                    "Tab reorder changed active identity/visit or lost tab state")
        strip.invalidateManagementInteraction()
        try require(strip.draggingUpdated(source).isEmpty && !strip.performDragOperation(source),
                    "Ended tab session retained reorder authority")

        guard strip.registerTabDragForVerification(id: first.id, sequence: 5102) != nil else {
            throw Failure(message: "Second controlled tab source could not be registered")
        }
        let mismatch = TabFixtureDrag(board: board, source: strip, sequence: 5199)
        mismatch.draggingLocation = source.draggingLocation
        let foreign = TabFixtureDrag(board: board, source: NSObject(), sequence: 5102)
        foreign.draggingLocation = source.draggingLocation
        try require(strip.draggingUpdated(mismatch).isEmpty && !strip.performDragOperation(mismatch)
                    && strip.draggingUpdated(foreign).isEmpty && !strip.performDragOperation(foreign),
                    "Tab drop trusted an unauthenticated source or native sequence")
        board.clearContents(); board.setString(third.id.uuidString, forType: type)
        let wrongToken = TabFixtureDrag(board: board, source: strip, sequence: 5102)
        wrongToken.draggingLocation = source.draggingLocation
        try require(strip.draggingUpdated(wrongToken).isEmpty, "Tab drag accepted another tab's pasteboard identity")
        board.clearContents(); board.setString(first.id.uuidString, forType: type)
        browser.closeTab(id: first.id)
        try await settled(browser)
        let removed = TabFixtureDrag(board: board, source: strip, sequence: 5102)
        removed.draggingLocation = source.draggingLocation
        try require(strip.draggingUpdated(removed).isEmpty && !strip.performDragOperation(removed),
                    "Removed tab retained a source session")

        strip.layoutSubtreeIfNeeded()
        guard let frame = strip.lastTabFrame,
              strip.registerTabDragForVerification(id: second.id, sequence: 5103,
                  previewRelativeToPointer: NSRect(x: -180, y: -14, width: 196, height: 28)) != nil else {
            throw Failure(message: "Preview-overlap source could not register")
        }
        board.clearContents(); board.setString(second.id.uuidString, forType: type)
        let overlapping = TabFixtureDrag(board: board, source: strip, sequence: 5103)
        overlapping.draggingDestinationWindow = browser.view.window
        // Pointer is beyond the tab viewport; the long preview extends left
        // into it, as when a tab is picked up near its right edge.
        overlapping.draggingLocation = strip.convert(NSPoint(x: frame.maxX + 24, y: frame.midY), to: nil)
        try require(strip.draggingUpdated(overlapping) == .move && strip.prepareForDragOperation(overlapping),
                    "Authenticated tab preview overlaps the tab strip but pointer-only acceptance rejects it")
        let inside = NSPoint(x: frame.midX, y: frame.midY)
        overlapping.draggingLocation = strip.convert(inside, to: nil)
        try require(TabStripView.dragPoint(overlapping, in: strip, region: frame) == inside,
                    "Preview overlap overrode the pointer inside its destination")
        let corner = TabStripView.overlapPoint(pointer: NSPoint(x: 110, y: 110),
            footprint: NSRect(x: 90, y: 90, width: 30, height: 30), region: NSRect(x: 0, y: 0, width: 100, height: 100))
        try require(corner == NSPoint(x: 99.5, y: 99.5)
                    && TabStripView.overlapPoint(pointer: .zero, footprint: NSRect(x: 100, y: 0, width: 20, height: 20),
                        region: NSRect(x: 0, y: 0, width: 100, height: 100)) == nil,
                    "Preview corner resolution or zero-area contact was ambiguous")
        overlapping.draggingLocation = strip.convert(NSPoint(x: frame.maxX + 24, y: frame.midY), to: nil)
        overlapping.draggingLocation.x += 400
        try require(strip.draggingUpdated(overlapping).isEmpty,
                    "Nonoverlapping preview retained an insertion destination")
        strip.invalidateManagementInteraction()

        let beforeAX = browser.tabs.map(\.id)
        guard let button = strip.selectionButton(for: beforeAX[0]) as? TabSelectionButton,
              let move = button.accessibilityCustomActions()?.first(where: { $0.name == "Move Tab Right" }),
              move.target as? TabSelectionButton === button,
              move.selector == #selector(TabSelectionButton.accessibleMoveRight(_:)) else {
            throw Failure(message: "Tab is missing its accessible reorder action")
        }
        try require(button.accessibleMoveRight(move), "Accessible tab Move Right did not invoke shared management")
        try require(browser.tabs.map(\.id) == [beforeAX[1], beforeAX[0]], "Accessible reorder changed the wrong tab")
        guard let keyboardButton = strip.selectionButton(for: beforeAX[0]) as? TabSelectionButton,
              let window = browser.view.window else { throw Failure(message: "Tab keyboard responder is missing") }
        keyboardButton.keyDown(with: key("\u{f702}", code: 123, flags: [.command, .shift], window: window))
        try require(browser.tabs.map(\.id) == beforeAX, "Focused-tab keyboard reorder did not share the identity command")

        // The explicit context UUID must identify the clicked background tab.
        let backgroundID = browser.tabs.first(where: { $0.id != browser.activeID })!.id
        let backgroundLocation = browser.tabs.first(where: { $0.id == backgroundID })!.location
        let context = strip.contextMenu(for: backgroundID)
        guard let duplicate = context.items.first(where: { $0.title == "Duplicate Tab" }),
              duplicate.isEnabled, let action = duplicate.action else { throw Failure(message: "Tab duplicate context command unavailable") }
        let priorCount = browser.tabs.count
        try require(NSApplication.shared.sendAction(action, to: duplicate.target, from: duplicate),
                    "Context duplicate action was not dispatched")
        try await settled(browser)
        try require(browser.tabs.count == priorCount + 1 && browser.activeID != backgroundID
                    && browser.location == backgroundLocation,
                    "Background-tab context command duplicated the active tab instead of its explicit identity")
        try await snapshot(window, to: output.appendingPathComponent("tab-interactions.png"))
        let checks = [
            preallocationCheck,
            "Authenticated same-strip native tab drop preserves active identity/visit and independent tabs; source, sequence and token mismatches refuse",
            "Ended and removed tab sessions lose reorder authority; no native dragging session or physical mouse delivery is claimed",
            "Accessible custom reorder action and focused-tab keyboard command invoke shared identity management; VoiceOver reading remains unexercised",
            "Background-tab context duplicate dispatch carries its explicit UUID; actual native menu tracking/focus transfer remains a foreground gate"
        ]
        try JSONSerialization.data(withJSONObject: ["checks": checks, "physicalDragExercised": false,
            "voiceOverExercised": false, "nativeMenuTrackingExercised": false], options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("tab-strip-interactions.json"), options: .withoutOverwriting)
        return checks
    }

    private static func verifyTabStripPreallocation(output: URL) throws -> String {
        // Exercise allocation before a window or ancestor can satisfy the
        // strip's height constraint. Settled-browser tests omit this phase.
        let strip = TabStripView(frame: NSRect(x: 0, y: 0, width: 300, height: 0))
        let tab = BrowserTab(location: .computer)
        strip.update(tabs: [tab], activeID: tab.id)
        guard let choose = strip.selectionButton(for: tab.id),
              let close = strip.closeButton(for: tab.id), let item = choose.superview else {
            throw Failure(message: "Preallocation tab controls are missing")
        }
        func numbers(_ rect: NSRect) -> [Double] {
            [Double(rect.minX), Double(rect.minY), Double(rect.width), Double(rect.height)]
        }
        func validSize(_ rect: NSRect) -> Bool {
            numbers(rect).allSatisfy(\.isFinite) && rect.width >= 0 && rect.height >= 0
        }
        var rows: [[String: Any]] = []
        var passed = true
        for height: CGFloat in [0, 1, 2, 36] {
            strip.setFrameSize(NSSize(width: 300, height: height))
            let before = strip.bounds
            strip.layout()
            item.layout()
            let after = strip.bounds
            let expectedHeight = max(0, height - 2)
            let exercised = before.height == height && after.height == height
            let rowPassed = exercised && validSize(item.frame) && validSize(choose.frame)
                && validSize(close.frame) && abs(item.frame.height - expectedHeight) < 0.001
            passed = passed && rowPassed
            rows.append(["requestedHeight": Double(height), "boundsBefore": numbers(before),
                "boundsAfter": numbers(after), "allocationExercised": exercised,
                "tabFrame": numbers(item.frame), "chooseFrame": numbers(choose.frame),
                "closeFrame": numbers(close.frame), "expectedTabHeight": Double(expectedHeight),
                "passed": rowPassed])
        }
        let restored = strip.activeTabIsVisible && choose.isEnabled && close.isEnabled
        try JSONSerialization.data(withJSONObject: ["cases": rows,
            "positiveAllocationRestored": restored, "passed": passed && restored,
            "scope": "Unparented actual native tab strip; runtime diagnostics remain a separate gate"],
            options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("tab-strip-preallocation.json"), options: .withoutOverwriting)
        try require(passed && restored, "Tab strip preallocation has invalid dimensions or loses normal allocation")
        return "Actual native tab layout keeps finite nonnegative dimensions at heights 0/1/2 and restores normal 36-point allocation"
    }
}
#endif
