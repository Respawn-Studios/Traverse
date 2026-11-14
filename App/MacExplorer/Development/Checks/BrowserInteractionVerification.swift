import AppKit
import ExplorerCore
import LocalStorage

#if DEBUG
extension UIVerification {
    static func verifyWindowLayout(_ controller: BrowserWindowController) throws -> CGFloat {
        let browser = controller.browser
        let window = controller.window!
        browser.view.layoutSubtreeIfNeeded()
        let top = browser.splitController.view.convert(browser.splitController.view.bounds, to: nil).maxY
        let height = window.frame.height - top
        try require(height <= 130, "Window chrome consumes too much browsing space: \(height)")
        let menus = window.toolbar?.items.compactMap { $0 as? NSMenuToolbarItem } ?? []
        try require(menus.map(\.title) == ["File", "View", "Go", "Settings", "Help"], "Native header menus are missing")
        try require(menus.allSatisfy { !$0.isBordered }, "Header menus should be plain menu titles")
        try require(browser.breadcrumbLocations == [.computer] && browser.pathControl.pathItems.first?.title == "This Mac"
                    && browser.pathControl.placeholderString == nil, "This Mac address must be an actual location, without a fake link")
        try require(browser.tabStrip.activeTabFrame?.minY == 0, "Active tab must connect to the address surface")
        try require(browser.tabStrip.addButton.bounds.height > 20 && (browser.tabStrip.selectionButton(for: browser.activeID)?.bounds.width ?? 0) > 60,
                    "Tab controls have no visible size")
        if let last = browser.tabStrip.lastTabFrame {
            try require(abs(browser.tabStrip.addButton.frame.minX - last.maxX - 4) < 1, "New tab button is detached from tabs")
        }
        return height
    }

    static func verifyRenderedTabs(_ browser: BrowserViewController) throws {
        guard let capture = browser.view.window?.contentView?.superview,
              let bitmap = capture.bitmapImageRepForCachingDisplay(in: capture.bounds) else {
            throw Failure(message: "Unable to inspect tab pixels")
        }
        capture.cacheDisplay(in: capture.bounds, to: bitmap)
        let tab = browser.tabStrip.convert(browser.tabStrip.bounds, to: capture)
        let scale = CGFloat(bitmap.pixelsWide) / capture.bounds.width
        var visiblePixels = 0
        for y in Int((capture.bounds.maxY - tab.maxY + 5) * scale)..<Int((capture.bounds.maxY - tab.minY - 5) * scale) {
            for x in Int(20 * scale)..<Int(190 * scale) {
                if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                   color.redComponent < 0.6 && color.greenComponent < 0.6 && color.blueComponent < 0.6 { visiblePixels += 1 }
            }
        }
        try require(visiblePixels > 30, "Tab title and controls were erased in the full-window render (\(visiblePixels) dark pixels)")
    }

    /// All clickable destinations are owned fixture folders. Actual mounted
    /// volumes are only observed, never opened by this verification.
    static func verifyDriveInteractions(_ browser: BrowserViewController, fixture: URL, output: URL) async throws {
        let drives = VolumeBrowserView()
        let second = fixture.appendingPathComponent("Empty Folder", isDirectory: true)
        drives.update(volumes: [
            VolumeInfo(url: fixture, name: "Fixture drive", kind: .internalDisk, totalBytes: 1000, availableBytes: 600),
            VolumeInfo(url: second, name: "External fixture", kind: .externalDisk, totalBytes: 2000, availableBytes: 1500, isReadOnly: true),
            VolumeInfo(url: fixture.appendingPathComponent("Folder A", isDirectory: true), name: "Unavailable capacity", kind: .unknown)
        ])
        var opened: URL?
        var copied: URL?
        var copiedPaths: [URL] = []
        drives.onOpen = { opened = $0 }
        drives.onCopy = { copied = drives.selectedURLs.first }
        drives.onCopyPath = { copiedPaths = $0 }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 240),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Generated drive interaction fixture"
        window.contentView = drives
        window.center()
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        try await waitUntil("Drive fixture focus") { NSApplication.shared.keyWindow === window }
        try await waitUntil("Drive fixture layout") { drives.visibleTiles.count == 3 && drives.bounds.width > 600 }
        try require(drives.visibleTiles.allSatisfy { $0.view.bounds.height <= 80 }, "Drive tiles are too tall")
        try await snapshot(window, to: output.appendingPathComponent("09-drive-capacities.png"))
        let first = IndexPath(item: 0, section: 0)
        try await clickDrive(first, in: drives, window: window, count: 1)
        try require(drives.selectedURLs == [fixture] && opened == nil, "A single drive click must select without opening")
        drives.focus()
        drives.collectionView.keyDown(with: key(String(UnicodeScalar(0xF703)!), code: 124, flags: [], window: window))
        try require(drives.selectedURLs == [second], "Arrow keys did not move the drive selection")
        drives.setSelection([fixture])
        drives.collectionView.copy(nil)
        try require(copied == fixture, "Native Copy did not route from drives")
        drives.collectionView.selectAll(nil)
        try require(drives.selectedCount == 3, "Native Select All did not select drives")
        let point = drives.visibleTiles.first(where: { $0.volume?.url == fixture })!.view.convert(NSPoint(x: 20, y: 20), to: nil)
        let contextEvent = NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [],
                                             timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                             context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        drives.collectionView.menu(for: contextEvent)?.performActionForItem(at: 1)
        try require(copiedPaths.count == 3, "Drive context Copy Path must include all selected drives")
        drives.setSelection([fixture])
        try await clickDrive(first, in: drives, window: window, count: 2)
        try require(opened == fixture, "Double-click did not open a drive")
        opened = nil
        drives.collectionView.keyDown(with: key("\r", code: 36, flags: [], window: window))
        try require(opened == fixture, "Explorer Return did not open a drive")
        opened = nil
        drives.explorerKeysEnabled = false
        drives.collectionView.keyDown(with: key("\r", code: 36, flags: [], window: window))
        try require(opened == nil, "Mac profile should not intercept Return")
        drives.explorerKeysEnabled = true
        drives.update(volumes: [VolumeInfo(url: second, name: "External fixture", kind: .externalDisk),
                               VolumeInfo(url: fixture, name: "Fixture drive", kind: .internalDisk)])
        try require(drives.selectedURLs == [fixture], "Volume refresh lost selection when rows moved")
        drives.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(80))
        guard let tile = drives.visibleTiles.first(where: { $0.volume?.url == second }),
              let action = tile.view.accessibilityCustomActions()?.first,
              let target = action.target as? VolumeTileItem,
              action.selector == #selector(VolumeTileItem.performAccessibleOpen(_:)) else {
            throw Failure(message: "Drive has no accessible Open action")
        }
        try require(target.performAccessibleOpen(action), "Accessible drive Open failed")
        try require(opened == second, "Accessible Open used a stale volume")
        try await snapshot(window, to: output.appendingPathComponent("07-drive-interactions.png"))
        window.orderOut(nil)
        browser.view.window?.makeKeyAndOrderFront(nil)

        // Check composition, clipboard routing and independent This Mac state.
        guard let mounted = browser.volumes.first else { throw Failure(message: "No mounted drive observation") }
        browser.volumeBrowser.setSelection([mounted.url])
        browser.copyPath(nil)
        let originalID = browser.activeID
        browser.newTab(nil)
        try await settled(browser)
        try require(browser.selectedURLs.isEmpty, "A new This Mac tab inherited selection")
        browser.selectTab(originalID)
        try await settled(browser)
        try require(browser.selectedURLs == [mounted.url], "This Mac tab lost its selection")
        let extraID = browser.tabs.first { $0.id != originalID }!.id
        browser.closeTab(id: extraID)
        browser.volumeBrowser.onOpen?(fixture)
        try await settled(browser)
        try require(browser.location == .directory(fixture), "Drive Open callback did not navigate")
        try require(browser.view.window?.firstResponder === browser.table, "Drive Open did not focus the folder list")
        browser.goBack(nil)
        try await settled(browser)
        try require(browser.selectedURLs == [mounted.url], "Back lost This Mac selection")
    }

    static func clickDrive(_ index: IndexPath, in drives: VolumeBrowserView, window: NSWindow, count: Int) async throws {
        drives.layoutSubtreeIfNeeded()
        guard let item = drives.collectionView.item(at: index) else { throw Failure(message: "Drive fixture tile is missing") }
        let point = item.view.convert(NSPoint(x: item.view.bounds.midX, y: item.view.bounds.midY), to: nil)
        let now = ProcessInfo.processInfo.systemUptime
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: now,
                                          windowNumber: window.windowNumber, context: nil,
                                          eventNumber: 1, clickCount: count, pressure: type == .leftMouseDown ? 1 : 0)!
            NSApplication.shared.postEvent(event, atStart: false)
        }
        try await Task.sleep(for: .milliseconds(120))
    }

    static func verifyExplorerFlows(_ browser: BrowserViewController, fixture: URL, output: URL) async throws {
        let window = browser.view.window!
        window.setContentSize(NSSize(width: 1140, height: 760))
        browser.goComputer(nil)
        try await settled(browser)
        let unusedAddress = browser.pathControl.convert(NSPoint(x: browser.pathControl.bounds.maxX - 4,
                                                               y: browser.pathControl.bounds.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: type, location: unusedAddress, modifierFlags: [],
                                          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                          context: nil, eventNumber: 1, clickCount: 1, pressure: 0)!
            NSApplication.shared.postEvent(event, atStart: false)
        }
        // A folder/search editor can already be first responder before the
        // posted click is delivered. Wait for this address editor specifically.
        try await waitUntil("Click address to edit") {
            !browser.pathField.isHidden && browser.pathField.currentEditor() === window.firstResponder
        }
        try require(!browser.pathField.isHidden, "Unused address space did not start path editing")
        _ = browser.control(browser.pathField, textView: window.firstResponder as! NSTextView,
                            doCommandBy: #selector(NSResponder.cancelOperation(_:)))
        browser.navigate(to: .directory(fixture))
        try await settled(browser)
        browser.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        let rowPoint = browser.table.convert(NSPoint(x: 80, y: browser.table.rect(ofRow: 1).midY), to: nil)
        let rowEvent = NSEvent.mouseEvent(with: .rightMouseDown, location: rowPoint, modifierFlags: [],
                                         timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                         context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        _ = browser.table.menu(for: rowEvent)
        try require(browser.table.selectedRowIndexes == IndexSet(integer: 1), "Right-click acted on the previously selected file")
        let child = fixture.appendingPathComponent("Folder A/Child", isDirectory: true)
        browser.navigate(to: .directory(child))
        try await settled(browser)
        browser.focusBrowserContent()
        browser.table.keyDown(with: key("\u{7F}", code: 51, flags: [], window: window))
        try await settled(browser)
        try require(browser.location == .directory(fixture), "Backspace must use history, not the parent")
        browser.navigate(to: .directory(child))
        try await settled(browser)
        _ = browser.handleExplorerShortcut(key(String(UnicodeScalar(0xF700)!), code: 126, flags: .option, window: window))
        try await settled(browser)
        try require(browser.location == .directory(fixture.appendingPathComponent("Folder A", isDirectory: true)), "Option-Up must use the parent")
        browser.navigate(to: .directory(child))
        try await settled(browser)
        if let cell = browser.pathControl.cell as? NSPathCell, cell.pathComponentCells.count > 1 {
            let component = cell.pathComponentCells[cell.pathComponentCells.count - 2]
            let rect = cell.rect(of: component, withFrame: browser.pathControl.bounds, in: browser.pathControl)
            try require(!rect.isEmpty, "Owned parent breadcrumb was not visible")
            let point = browser.pathControl.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                NSApplication.shared.postEvent(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 1, clickCount: 1, pressure: 0)!, atStart: false)
            }
            try await waitUntil("Parent breadcrumb click") { browser.location == .directory(fixture.appendingPathComponent("Folder A", isDirectory: true)) }
            try await settled(browser)
        } else { throw Failure(message: "Native breadcrumb cells were not created") }
        browser.focusBrowserContent()
        _ = browser.handleExplorerShortcut(key(String(UnicodeScalar(0xF709)!), code: 97, flags: [], window: window))
        try require(window.firstResponder === browser.outline, "F6 did not cycle to the sidebar")
        browser.focusFilter(nil)
        _ = browser.handleExplorerShortcut(key(String(UnicodeScalar(0xF709)!), code: 97, flags: [], window: window))
        try require(window.firstResponder === browser.table, "F6 did not cycle out of the filename field")
        browser.navigate(to: .directory(fixture))
        try await settled(browser)
        let previousIDs = browser.tabs.map(\.id)
        let original = browser.activeID
        window.setContentSize(NSSize(width: 1140, height: 760))
        for _ in 0..<4 { browser.newTab(nil) }
        try await settled(browser)
        browser.view.layoutSubtreeIfNeeded()
        window.setContentSize(NSSize(width: 820, height: 520))
        browser.view.layoutSubtreeIfNeeded()
        try require(browser.tabStrip.activeTabIsVisible, "Resizing hid the active tab")
        for _ in 0..<3 { browser.newTab(nil) }
        try await settled(browser)
        browser.view.layoutSubtreeIfNeeded()
        try require(browser.tabStrip.isOverflowing && browser.tabStrip.activeTabIsVisible, "Overflow must keep the active tab visible")
        try require(browser.tabStrip.addButton.frame.maxX <= browser.tabStrip.bounds.width, "New tab button disappeared during overflow")
        try await snapshot(window, to: output.appendingPathComponent("08-tab-overflow.png"))
        browser.tabStrip.selectionButton(for: previousIDs[0])?.performClick(nil)
        try await settled(browser)
        try require(browser.activeID == previousIDs[0] && browser.tabStrip.activeTabIsVisible, "Clicking an overflowed tab did not reveal it")
        browser.focusBrowserContent()
        _ = browser.handleExplorerShortcut(key("9", code: 25, flags: .control, window: window))
        try await settled(browser)
        try require(browser.activeID == browser.tabs.last?.id, "Control-9 did not select the last tab")
        let closing = browser.activeID
        browser.tabStrip.closeButton(for: closing)?.performClick(nil)
        try require(!browser.tabs.contains { $0.id == closing }, "Tab close button failed")
        for id in browser.tabs.map(\.id) where !previousIDs.contains(id) { browser.closeTab(id: id) }
        browser.selectTab(original)
        try await settled(browser)
    }
}
#endif
