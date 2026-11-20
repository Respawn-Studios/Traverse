import AppKit

#if DEBUG
@MainActor
private final class SidebarFeedbackDrag: NSObject, NSDraggingInfo {
    let draggingPasteboard = NSPasteboard.withUniqueName()
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    var draggingSourceOperationMask: NSDragOperation { [] }
    var draggingDestinationWindow: NSWindow?
    var draggingLocation = NSPoint.zero
    var draggedImageLocation: NSPoint { .zero }
    nonisolated var draggedImage: NSImage? { nil }
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 0
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    nonisolated override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func resetSpringLoading() {}
    func enumerateDraggingItems(options: NSDraggingItemEnumerationOptions, for view: NSView?, classes: [AnyClass],
        searchOptions: [NSPasteboard.ReadingOptionKey: Any],
        using block: @escaping (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
}

private final class SidebarHoverAccessProbe: FolderAccessBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return calls }
    private func record() { lock.lock(); calls += 1; lock.unlock() }
    func startAccess(to url: URL) -> Bool { record(); return false }
    func stopAccess(to url: URL) { record() }
    func bookmark(for url: URL) throws -> Data { record(); throw CocoaError(.fileReadNoPermission) }
    func resolve(_ bookmark: Data) throws -> FolderBookmarkResolution { record(); throw CocoaError(.fileReadNoPermission) }
}

@MainActor
private final class SidebarMenuTrackingReceipt {
    private var menu: NSMenu?
    let outline: BrowserSidebarOutlineView
    let row: BrowserSidebarRowView
    let event: NSEvent
    private var timerObserved = false
    init(outline: BrowserSidebarOutlineView, row: BrowserSidebarRowView, event: NSEvent) {
        self.outline = outline; self.row = row; self.event = event
    }
    func track() -> Bool {
        let original = outline.onLocationMenu
        outline.onLocationMenu = { [self] location in
            menu = original?(location)
            return menu
        }
        defer { outline.onLocationMenu = original }
        let cancel = Timer(timeInterval: 0.1, repeats: false) { [self] _ in
            MainActor.assumeIsolated {
                timerObserved = row.showsContextHighlight && outline.isTrackingContextMenuForVerification
                menu?.cancelTracking()
            }
        }
        RunLoop.main.add(cancel, forMode: .eventTracking)
        outline.rightMouseDown(with: event)
        cancel.invalidate()
        return timerObserved && menu != nil
    }
}

@MainActor
extension UIVerification {
    /// Measures the actual outline group rows, including the native disclosure
    /// control and rendered label. App-owned rendering excludes compositor Glass.
    static func verifySidebarLayout(_ browser: BrowserViewController, output: URL,
                                    checkFolderPointerFeedback: Bool = true) async throws {
        guard browser.isVerificationSession, let window = browser.view.window else {
            throw Failure(message: "Sidebar verification requires an owned native session")
        }
        try await settled(browser)
        window.contentView?.layoutSubtreeIfNeeded()
        // Native disclosure images refresh with the window's appearance pass.
        // Flush that pass before measuring a cropped child render.
        try await snapshot(window, to: output.appendingPathComponent("sidebar-layout.png"))
        var rows: [[String: Any]] = []
        var failures: [String] = []
        for group in browser.sidebarRoots where group.group {
            let row = browser.outline.row(forItem: group)
            guard row >= 0, let view = browser.outline.view(atColumn: 0, row: row, makeIfNecessary: true),
                  let content = Optional((view as? BrowserSidebarNameView)?.content ?? view),
                  let field = (content as? NSTextField) ?? (content as? NSTableCellView)?.textField,
                  let bitmap = field.bitmapImageRepForCachingDisplay(in: field.bounds) else {
                throw Failure(message: "Visible sidebar group has no measurable label")
            }
            field.cacheDisplay(in: field.bounds, to: bitmap)
            var low = bitmap.pixelsHigh, high = -1
            for y in 0..<bitmap.pixelsHigh {
                guard let background = bitmap.colorAt(x: bitmap.pixelsWide - 1, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                for x in 0..<bitmap.pixelsWide - 1 {
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                    let distance = abs(color.redComponent - background.redComponent)
                        + abs(color.greenComponent - background.greenComponent) + abs(color.blueComponent - background.blueComponent)
                        + abs(color.alphaComponent - background.alphaComponent)
                    if distance > 0.15 { low = min(low, y); high = max(high, y) }
                }
            }
            let scale = CGFloat(bitmap.pixelsHigh) / max(1, field.bounds.height)
            let inkCenter = high >= low ? CGFloat(low + high + 1) / (2 * scale) : -1
            let inkOffset = abs(inkCenter - field.bounds.midY)
            let labelRect = field.convert(field.bounds, to: browser.outline)
            let disclosure = browser.outline.frameOfOutlineCell(atRow: row)
            let controlOffset = abs(labelRect.midY - disclosure.midY)
            guard let rowView = browser.outline.rowView(atRow: row, makeIfNecessary: true) else {
                throw Failure(message: "Native group row is unavailable")
            }
            func disclosureButton(in view: NSView) -> NSButton? {
                if let button = view as? NSButton { return button }
                return view.subviews.lazy.compactMap { disclosureButton(in: $0) }.first
            }
            guard let button = disclosureButton(in: rowView),
                  let disclosureBitmap = button.bitmapImageRepForCachingDisplay(in: button.bounds) else {
                throw Failure(message: "Native disclosure button cannot be rendered")
            }
            button.cacheDisplay(in: button.bounds, to: disclosureBitmap)
            var arrowLow = disclosureBitmap.pixelsHigh, arrowHigh = -1
            for y in 0..<disclosureBitmap.pixelsHigh {
                guard let background = disclosureBitmap.colorAt(x: 0, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                for x in 1..<disclosureBitmap.pixelsWide {
                    guard let color = disclosureBitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                    let distance = abs(color.redComponent - background.redComponent)
                        + abs(color.greenComponent - background.greenComponent) + abs(color.blueComponent - background.blueComponent)
                        + abs(color.alphaComponent - background.alphaComponent)
                    if distance > 0.15 { arrowLow = min(arrowLow, y); arrowHigh = max(arrowHigh, y) }
                }
            }
            let arrowScale = CGFloat(disclosureBitmap.pixelsHigh) / max(1, button.bounds.height)
            let arrowCenter = arrowHigh >= arrowLow ? CGFloat(arrowLow + arrowHigh + 1) / (2 * arrowScale) : -1
            let arrowPoint = button.convert(NSPoint(x: button.bounds.midX,
                y: button.isFlipped ? arrowCenter : button.bounds.height - arrowCenter), to: browser.outline)
            let labelPoint = field.convert(NSPoint(x: field.bounds.midX,
                y: field.isFlipped ? inkCenter : field.bounds.height - inkCenter), to: browser.outline)
            let arrowOffset = abs(arrowPoint.y - labelPoint.y)
            rows.append(["group": group.title, "row": row, "cell": NSStringFromRect(view.frame),
                "label": NSStringFromRect(labelRect), "disclosure": NSStringFromRect(disclosure),
                "labelInkCenterOffset": inkOffset, "labelControlCenterOffset": controlOffset,
                "labelInkBoundsY": [low, high], "disclosureInkBoundsY": [arrowLow, arrowHigh],
                "disclosureInkCenterOffset": arrowOffset,
                "disclosureButton": NSStringFromRect(button.convert(button.bounds, to: browser.outline)),
                "glyphCentersInOutline": [Double(labelPoint.y), Double(arrowPoint.y)],
                "expanded": browser.outline.isItemExpanded(group)])
            if high < low || arrowHigh < arrowLow || inkOffset > 2 || controlOffset > 2 || arrowOffset > 2 {
                failures.append("\(group.title) disclosure/label alignment exceeds 2 points")
            }
        }
        let pointer = if checkFolderPointerFeedback {
            try await verifySidebarPointerFeedback(browser, output: output)
        } else { ["observed": false, "reason": "Folder groups collapsed"] as [String: Any] }
        let rememberedHover = try verifyRememberedSidebarHover()
        let report: [String: Any] = ["passed": failures.isEmpty, "rows": rows, "failures": failures,
            "pointerFeedback": pointer,
            "rememberedReferenceHover": rememberedHover,
            "captureMethod": "App-owned native outline and label cacheDisplay",
            "notExercised": ["Physical disclosure hit testing", "VoiceOver", "WindowServer compositing"]]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("sidebar-layout.json"), options: .atomic)
        try require(!rows.isEmpty && failures.isEmpty, failures.joined(separator: "; "))
    }

    private static func verifyRememberedSidebarHover() throws -> [String: Any] {
        guard let declared = ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"] else {
            throw Failure(message: "Remembered hover requires the generated fixture declaration")
        }
        let target = URL(fileURLWithPath: declared, isDirectory: true).appendingPathComponent("Unopened hover reference")
        let references = [
            FolderAccessRestoreResult(id: UUID(), url: target, state: .resolvedUnverified),
            FolderAccessRestoreResult(id: UUID(), url: target, state: .needsRenewal),
            FolderAccessRestoreResult(id: UUID(), url: nil, state: .unavailable(.missing))
        ]
        // Only the actual outline is installed. The browser view/startup and
        // folder navigation are never loaded, so no target probe is necessary.
        let fixture = BrowserViewController(settings: BrowserSettings(persist: false))
        let access = SidebarHoverAccessProbe()
        fixture.folderAccess = FolderAccessController(stateDirectory: nil, backend: access)
        let group = fixture.rememberedFolderSidebar.group(for: references)
        try require(group.children?.count == references.count, "Remembered hover control lost a reference state")
        fixture.sidebarRoots = [group]
        let outline = fixture.outline
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("reference-hover"))
        column.width = 230
        outline.addTableColumn(column); outline.outlineTableColumn = column
        outline.headerView = nil; outline.rowHeight = 27; outline.style = .plain
        outline.delegate = fixture; outline.dataSource = fixture
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 250, height: 150))
        outline.frame = scroll.bounds; outline.autoresizingMask = [.width]
        scroll.documentView = outline
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = scroll
        defer { window.close() }
        outline.reloadData(); outline.expandItem(group)
        window.contentView?.layoutSubtreeIfNeeded()
        let visit = fixture.sessionID, selected = outline.selectedRowIndexes
        for (node, reference) in zip(group.children ?? [], references) {
            let index = outline.row(forItem: node)
            guard index >= 0,
                  let row = outline.rowView(atRow: index, makeIfNecessary: true) as? BrowserSidebarRowView else {
                throw Failure(message: "Native remembered-reference row was not materialized")
            }
            try require(node.location == nil && fixture.rememberedFolderSidebar.referenceID(for: node) == reference.id
                && fixture.outlineView(outline, shouldSelectItem: node) && row.acceptsPointerFeedback,
                "Remembered hover control lost its nil-location reference ID or cached selectability")
            let rect = outline.rect(ofRow: index)
            let point = outline.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
            guard let move = NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 0, pressure: 0) else {
                throw Failure(message: "Native remembered-reference hover event was unavailable")
            }
            outline.mouseMoved(with: move)
            try require(row.showsHoverOutline && !row.showsContextHighlight,
                "Selectable nil-location remembered reference still has no hover outline")
            outline.mouseExited(with: move)
            try require(!row.showsHoverOutline, "Remembered reference retained hover after pointer exit")
        }
        let groupRow = outline.rowView(atRow: outline.row(forItem: group), makeIfNecessary: true) as? BrowserSidebarRowView
        try require(groupRow?.acceptsPointerFeedback == false,
            "Nonselectable remembered group acquired actionable hover feedback")
        try require(access.count == 0 && !fixture.isViewLoaded && fixture.sessionID == visit
            && outline.selectedRowIndexes == selected && fixture.listingTask == nil && fixture.sidebarTasks.isEmpty,
            "Remembered hover probed access, loaded navigation or changed selection/visit")
        return ["nilLocationReferenceRows": references.count, "allReferenceStatesHover": true,
            "accessBackendCalls": access.count, "browserViewLoaded": fixture.isViewLoaded,
            "selectionAndVisitPreserved": true, "groupHoverExcluded": true]
    }

    private static func verifySidebarPointerFeedback(_ browser: BrowserViewController, output: URL) async throws -> [String: Any] {
        let outline = browser.outline
        guard let window = outline.window,
              let index = (0..<outline.numberOfRows).first(where: {
                  ($0 != outline.selectedRow) && (outline.item(atRow: $0) as? SidebarNode)?.location?.directoryURL != nil
              }), let node = outline.item(atRow: index) as? SidebarNode,
              let row = outline.rowView(atRow: index, makeIfNecessary: true) as? BrowserSidebarRowView else {
            throw Failure(message: "Sidebar pointer feedback requires an actual unselected native location row")
        }
        let selected = outline.selectedRowIndexes, visit = browser.sessionID, location = browser.location
        let expanded = browser.sidebarRoots.filter { outline.isItemExpanded($0) }.map(ObjectIdentifier.init)
        let geometry = outline.rect(ofRow: index), disclosure = outline.frameOfOutlineCell(atRow: index)
        let point = outline.convert(NSPoint(x: geometry.midX, y: geometry.midY), to: nil)
        func event(_ type: NSEvent.EventType) throws -> NSEvent {
            guard let value = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 0) else {
                throw Failure(message: "Could not construct native sidebar pointer event")
            }
            return value
        }
        func render(_ name: String) throws -> Data {
            row.displayIfNeeded()
            guard let bitmap = row.bitmapImageRepForCachingDisplay(in: row.bounds) else {
                throw Failure(message: "Native sidebar row cannot be rendered")
            }
            row.cacheDisplay(in: row.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else {
                throw Failure(message: "Native sidebar row render has no PNG representation")
            }
            try png.write(to: output.appendingPathComponent(name), options: .atomic)
            return png
        }
        let initial = try render("sidebar-row-idle.png")
        let move = try event(.mouseMoved)
        outline.mouseMoved(with: move)
        try require(row.showsHoverOutline && !row.showsContextHighlight,
            "Native sidebar pointer did not outline its actual unselected row")
        let hovered = try render("sidebar-row-hover.png")
        guard let menu = outline.menu(for: try event(.rightMouseDown)) else {
            throw Failure(message: "Native sidebar location did not return its existing contextual menu")
        }
        try require(!row.showsContextHighlight && !row.showsHoverOutline,
            "Requesting an untracked menu left a sticky sidebar contextual highlight")
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: NSMenu())
        try require(!row.showsContextHighlight, "An unrelated menu filled the pending sidebar contextual target")
        NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: menu)
        try require(row.showsContextHighlight && !row.showsHoverOutline,
            "Contextual sidebar target did not replace hover with a stronger row cue")
        let contextual = try render("sidebar-row-context.png")
        try require(initial != hovered && hovered != contextual,
            "Native row rendering did not distinguish idle, hover and contextual highlight")
        // Public notifications qualify state lifetime without opening a menu
        // against a hidden anchor. Visible qualification additionally tracks it.
        outline.mouseExited(with: move)
        try require(row.showsContextHighlight && !row.showsHoverOutline,
            "Leaving the outline prematurely cleared the tracking menu's contextual target")
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: NSMenu())
        try require(row.showsContextHighlight, "An unrelated menu cleared the sidebar contextual target")
        NotificationCenter.default.post(name: NSMenu.didEndTrackingNotification, object: menu)
        try require(!row.showsContextHighlight && !row.showsHoverOutline,
            "Ending the location menu left a stale sidebar contextual highlight")

        var trackedVisibleMenu = false
        if window.isVisible {
            NSRunningApplication.current.activate(options: [.activateAllWindows])
            window.makeKeyAndOrderFront(nil)
            try await waitUntil("Sidebar contextual dispatch activation") {
                NSApplication.shared.isActive && window.isKeyWindow
            }
            // Enter AppKit's nested menu loop from a native timer callback,
            // after this Swift Task has suspended, rather than pumping a Task.
            let receipt = SidebarMenuTrackingReceipt(outline: outline, row: row, event: try event(.rightMouseDown))
            trackedVisibleMenu = await withCheckedContinuation { continuation in
                let opener = Timer(timeInterval: 0, repeats: false) { _ in
                    MainActor.assumeIsolated {
                        continuation.resume(returning: receipt.track())
                    }
                }
                RunLoop.main.add(opener, forMode: .default)
            }
            try require(trackedVisibleMenu && !row.showsContextHighlight,
                "Actual native menu tracking did not retain then clear the contextual row")
        }
        outline.mouseMoved(with: move)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        try require(!row.showsHoverOutline, "Window focus loss left a stale sidebar hover outline")
        outline.mouseMoved(with: move)
        outline.mouseExited(with: move)
        try require(!row.showsHoverOutline, "Sidebar pointer exit left a stale hover outline")
        outline.mouseMoved(with: move)
        let drag = SidebarFeedbackDrag()
        defer { drag.draggingPasteboard.releaseGlobally() }
        drag.draggingDestinationWindow = window; drag.draggingLocation = point
        _ = outline.draggingEntered(drag)
        outline.setDropItem(node, dropChildIndex: NSOutlineViewDropOnItemIndex)
        outline.mouseMoved(with: move)
        try require(outline.isFileDragActive && !row.showsHoverOutline && !row.showsContextHighlight,
            "Sidebar pointer decoration competed with native file-drop targeting")
        outline.setDropItem(nil, dropChildIndex: -1)
        outline.draggingExited(drag)
        try require(!outline.isFileDragActive, "Sidebar drag exit did not restore ordinary pointer admission")
        _ = outline.menu(for: try event(.rightMouseDown))
        outline.reloadItem(node)
        guard let reloaded = outline.rowView(atRow: outline.row(forItem: node), makeIfNecessary: true) as? BrowserSidebarRowView else {
            throw Failure(message: "Sidebar reload lost its native decorated row")
        }
        try require(!reloaded.showsContextHighlight && !reloaded.showsHoverOutline,
            "Reload reused a stale hover or contextual highlight")
        try require(outline.selectedRowIndexes == selected && browser.sessionID == visit && browser.location == location
            && expanded == browser.sidebarRoots.filter { outline.isItemExpanded($0) }.map(ObjectIdentifier.init)
            && outline.rect(ofRow: index) == geometry && outline.frameOfOutlineCell(atRow: index) == disclosure,
            "Pointer/menu feedback navigated, selected, expanded or moved a native sidebar row")
        return ["nativeRowEvents": true, "threeDistinctRowRenders": true,
            "preservedSelectionVisitAndDisclosure": true, "scopedMenuLifetime": true,
            "nativeDragCallbackDecorationExclusion": true, "animationInstalled": false,
            "actualVisibleMenuTracking": trackedVisibleMenu,
            "nativeControlRightMouseDown": trackedVisibleMenu,
            "notExercised": window.isVisible ? ["Physical pointer delivery", "VoiceOver"]
                : ["Actual visible menu tracking", "Physical pointer delivery", "VoiceOver"]]
    }
}
#endif
