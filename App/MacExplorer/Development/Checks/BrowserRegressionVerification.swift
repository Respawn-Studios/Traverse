#if DEBUG
import AppKit
import ExplorerCore
import LocalStorage
import Search

/// Actual editor/window lifecycle; only an independently admitted generated
/// fixture, in-memory settings and no clipboard or file-operation mutation.
@MainActor
enum BrowserRegressionVerification {
    private static func wait(_ name: String, _ condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while !condition() && ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try UIVerification.require(condition(), "Browser regression timed out: " + name)
    }
    static func run(source: URL) async throws -> [String: Any] {
        let settings = BrowserSettings(persist: false)
        settings.autoRefreshFolders = false
        let browser = BrowserViewController(settings: settings)
        browser.pinsController = BrowserPinsController(stateDirectory: nil)
        browser.folderAccess = FolderAccessController(stateDirectory: nil)
        browser.permitsBackgroundVerification = true
        let workspace = BrowserWorkspaceController(primaryBrowser: browser)
        let window = NSWindow(contentRect: .init(x: 150, y: 180, width: 2000, height: 700),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = workspace
        defer { workspace.suspendWorkspace(); window.close() }
        browser.navigate(to: .directory(source))
        try await wait("generated listing") { !browser.isLoading && browser.orderingTask == nil }
        window.contentView?.layoutSubtreeIfNeeded()
        browser.focusLocation(nil)
        guard let editor = browser.pathField.currentEditor() as? NSTextView else {
            throw UIVerification.Failure(message: "Native address editor unavailable")
        }
        browser.addressCompletion.nameLocationsForVerification = [.init(name: "steamapps", url: source.appendingPathComponent("steamapps"), source: .familiar)]
        let input = "ste"
        editor.insertText(input, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        editor.setSelectedRange(NSRange(location: input.utf16.count, length: 0))
        try await wait("initial completion") { browser.addressCompletion.suggestions.first?.name == "steamapps" }
        for mode in [AddressSuggestionPresentation.dropdown, .inline, .off, .both] {
            // Replay the native notifications against the actual field editor.
            // Foreground pointer delivery is a separate live acceptance check.
            NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
            settings.addressPresentation = mode
            NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
            // Return to the same field editor, rather than starting a new one.
            editor.insertText(input, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
            editor.setSelectedRange(NSRange(location: input.utf16.count, length: 0))
            if mode == .off {
                try await Task.sleep(for: .milliseconds(180))
                try UIVerification.require(browser.addressCompletion.suggestions.isEmpty, "Off retained completion")
            } else {
                let deadline = ProcessInfo.processInfo.systemUptime + 1.5
                while browser.addressCompletion.suggestions.isEmpty && ProcessInfo.processInfo.systemUptime < deadline {
                    try await Task.sleep(for: .milliseconds(10))
                }
                try UIVerification.require(browser.addressCompletion.suggestions.first?.name == "steamapps",
                    "Completion lost its live editor after Settings focus return")
                try UIVerification.require((browser.addressCompletion.ghostTextForVerification != nil) == mode.showsInline,
                    "Settings focus return did not apply " + mode.rawValue + " completion: " + browser.addressCompletion.geometryForVerification)
            }
        }
        browser.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: browser.pathField))
        editor.insertText(input, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        editor.setSelectedRange(NSRange(location: input.utf16.count, length: 0))
        try await wait("Reused editor after late end notification") { browser.addressCompletion.suggestions.first?.name == "steamapps" }
        browser.cancelLocationEditing()
        settings.symbolTolerantNames = false
        browser.focusLocation(nil)
        guard let symbolEditor = browser.pathField.currentEditor() as? NSTextView else { throw UIVerification.Failure(message: "Symbol policy editor missing") }
        symbolEditor.insertText(input, replacementRange: NSRange(location: 0, length: symbolEditor.string.utf16.count))
        symbolEditor.setSelectedRange(NSRange(location: input.utf16.count, length: 0))
        try await wait("Literal symbol policy reaches indexed request") { browser.addressCompletion.nameRequestForVerification?.symbolTolerant == false }
        guard let volumeTicket = workspace.beginVolumeRefresh(from: browser) else { throw UIVerification.Failure(message: "Volume display refresh was not admitted") }
        let volume = VolumeInfo(url: source.deletingLastPathComponent(), name: "Fixture volume", kind: .externalDisk)
        try UIVerification.require(workspace.completeVolumeRefresh(.success([volume]), from: browser, ticket: volumeTicket)
            && browser.pathControl.logicalItems.first?.title == "Fixture volume"
            && !browser.pathField.isHidden && symbolEditor.string == input,
            "Late volume discovery either kept a root fallback or discarded the edited address")
        browser.cancelLocationEditing()
        browser.operationPresentation = .init(phaseTitle: "Copy", summary: "Generated presentation only")
        workspace.updateOperationProgress(from: browser)
        workspace.view.layoutSubtreeIfNeeded()
        func surface(_ view: NSView) -> NavigationGlassSurface? {
            if let value = view as? NavigationGlassSurface { return value }
            return view.superview.flatMap(surface)
        }
        try UIVerification.require(surface(workspace.operationButton) != nil
            && surface(workspace.operationButton) === surface(browser.viewModeControl),
            "Bottom progress is outside the status material beside the view controls")
        try UIVerification.require(browser.folderFilter.scopeButton.superview == nil
            && browser.folderFilter.displayedField.searchMenuTemplate?.items.contains(where: { $0.title.hasPrefix("Filter this folder") }) == true
            && browser.folderFilter.displayedField.searchMenuTemplate?.items.contains(where: { $0.title == "Type, date and size filters…" }) == true,
            "The unified search field has duplicate visible scope controls or lost its filter options")
        settings.showsPathBar = true
        try await wait("Finder bottom address") { browser.pathContainer.isHidden && browser.addressLayout?.bottomSurface.isHidden == false }
        workspace.view.layoutSubtreeIfNeeded()
        try UIVerification.require(browser.pathControl.isDescendant(of: browser.addressLayout!.bottomSurface)
            && browser.tabStrip.isDescendant(of: browser.addressLayout!.tabRow)
            && browser.folderFilter.isCompact && workspace.pathHost.isHidden,
            "Finder layout duplicated its address or retained a separate top navigation row")
        browser.focusLocation(nil)
        try UIVerification.require(browser.pathField.currentEditor() != nil
            && browser.pathField.isDescendant(of: browser.addressLayout!.bottomSurface), "Bottom address cannot edit paths")
        browser.toggleLocationEditing(nil)
        try UIVerification.require(browser.pathField.isHidden && !browser.pathControl.isHidden, "Bottom pencil does not restore breadcrumbs")
        settings.showsPathBar = false
        try await wait("Top address restored") { !browser.pathContainer.isHidden && browser.addressLayout?.bottomSurface.isHidden == true }
        let originalWriter = browser.clipboardWriter
        defer { browser.clipboardWriter = originalWriter }
        var copiedPath: String?
        browser.clipboardWriter = { text, _ in copiedPath = text; return .text }
        for bottom in [false, true] {
            settings.showsPathBar = bottom
            try await wait("Address layout settles") { browser.pathContainer.isHidden == bottom }
            await Task.yield()
            window.contentView?.layoutSubtreeIfNeeded()
            let path = browser.pathControl
            guard let cell = path.cell as? NSPathCell, let component = cell.pathComponentCells.last else {
                throw UIVerification.Failure(message: "Current breadcrumb missing")
            }
            let rect = cell.rect(of: component, withFrame: path.bounds, in: path).intersection(path.bounds)
            let point = path.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
            let event = NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            guard let menu = path.menu(for: event), let index = menu.items.firstIndex(where: { $0.title == "Copy Path" }) else {
                throw UIVerification.Failure(message: "Actual breadcrumb lost its location actions")
            }
            copiedPath = nil; menu.performActionForItem(at: index)
            try UIVerification.require(copiedPath == source.path, "Breadcrumb Copy Path lost the exact current location")
            browser.updateOperationProgressControls()
            browser.showFileOperationDetails(nil)
            window.contentView?.layoutSubtreeIfNeeded()
            let card = browser.operationDetailsContainer.convert(browser.operationDetailsContainer.bounds, to: browser.view)
            let bottomFrame = browser.addressLayout!.bottomSurface.convert(browser.addressLayout!.bottomSurface.bounds, to: browser.view)
            try UIVerification.require(!browser.operationDetailsContainer.isHidden
                && browser.view.bounds.contains(card) && (!bottom || !card.intersects(bottomFrame)),
                "Pinned progress details overlap the relocated address or escape the pane: bottom=\(bottom), card=\(card), address=\(bottomFrame)")
            browser.operationDetails.onClose?()
        }
        try await UIVerification.verifySharedClipboardFocus(fixture: source)
        let native = BrowserWindowController(settings: BrowserSettings(persist: false))
        defer { native.suspendBrowsing(); native.close() }
        native.window?.contentView?.layoutSubtreeIfNeeded()
        if let nativeWindow = native.window as? BrowserWindow, let root = nativeWindow.contentView,
           let header = nativeWindow.titlebarMaterial {
            let surface = native.browser.navigationSurface!
            let frame = surface.convert(surface.bounds, to: root)
            try UIVerification.require(header.bounds.height > 0 && header.hitTest(.zero) == nil
                && frame.maxY <= root.bounds.maxY - root.safeAreaInsets.top + 1,
                "Native titlebar glass overlaps controls or intercepts their input")
        } else { throw UIVerification.Failure(message: "Native titlebar material missing") }
        await browser.pinsController.restoreIfNeeded()
        let pinned = source.appendingPathComponent("steamapps")
        try UIVerification.require(browser.pinDrop.prepare([pinned]), "Generated folder pin admission failed")
        await browser.pinDrop.task?.value
        try UIVerification.require(browser.isPinned(pinned), "Folder drop did not add its lexical pin")
        let pinMenu = browser.locationMenu(for: .directory(pinned))
        guard let unpin = pinMenu.items.first(where: { $0.title == "Unpin Folder" }), let action = unpin.action else {
            throw UIVerification.Failure(message: "Context menu did not synchronize its Pin/Unpin state")
        }
        NSApplication.shared.sendAction(action, to: unpin.target, from: unpin)
        try UIVerification.require(!browser.isPinned(pinned), "Origin-bound Unpin affected the wrong location")
        try UIVerification.require(browser.pinDrop.prepare([pinned, pinned.appendingPathComponent("workshop/item.bin")]), "Mixed pin check not admitted")
        await browser.pinDrop.task?.value
        try UIVerification.require(browser.pinsController.collection.pins.isEmpty, "Invalid multi-item drop left partial pins")
        let capacity = try requireCapacity()
        try UIVerification.require(capacity.used == nil && capacity.free == 30 * 1024
            && capacity.available == 20 * 1024 && capacity.freeUnavailableToApps == 10 * 1024
            && capacity.capacityMinusFree == 70 * 1024,
            "Capacity minus free must not be reported as native APFS volume-used space")
        try UIVerification.require(PropertyVolumeCapacity.observed(blocks: .max, available: 1, blockSize: 4096) == nil
            && PropertyVolumeCapacity.observed(blocks: 1, available: 2, blockSize: 4096) == nil
            && PropertyVolumeCapacity.observed(blocks: 100, available: 20, blockSize: 1024, freeBlocks: 200)?.free == nil,
            "Filesystem accounting fabricated free bytes after overflow or inconsistent input")
        let independent = PropertyVolumeCapacity.observed(blocks: 100, available: 20, blockSize: 1024,
            freeBlocks: 30, reportedUsed: .init(bytes: 9 * 1024))
        try UIVerification.require(independent?.used == 9 * 1024 && independent?.capacityMinusFree == 70 * 1024,
            "Independent APFS volume-used report was forced into the capacity partition")
        return ["passed": true, "checks": ["Both/Dropdown/Inline/Off survive Settings focus-notification replay on the actual editor", "Progress and view controls share the bottom status material", "One search scope menu retains all scopes and advanced filters", "Finder layout reuses the path editor at the bottom and reclaims the top row", "Actual breadcrumb location Copy Path in both layouts; pinned progress avoids the address", "Existing two-pane clipboard focus/dismiss/dimming checks in both keyboard presets and address layouts", "Pin drop and origin-bound Unpin; mixed file/folder drop is all-or-none", "Filesystem accounting separates free, ordinary availability, capacity complement and independently reported volume-used"],
                "fixture_only": true]
    }
    private static func requireCapacity() throws -> PropertyVolumeCapacity {
        guard let value = PropertyVolumeCapacity.observed(blocks: 100, available: 20, blockSize: 1024, freeBlocks: 30) else {
            throw UIVerification.Failure(message: "Generated capacity vector was refused")
        }
        return value
    }
}
#endif
