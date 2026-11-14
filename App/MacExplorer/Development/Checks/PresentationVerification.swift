import AppKit
import LocalStorage
import ExplorerCore

#if DEBUG
@MainActor
extension UIVerification {
    static func verifyPresentation(_ browser: BrowserViewController, fixture: URL, output: URL? = nil) async throws {
        browser.navigate(to: .directory(fixture))
        try await settled(browser)
        var failures: [String] = []
        guard let row = browser.displayedEntries.firstIndex(where: { $0.byteCount == 0 }),
              let column = browser.table.tableColumns.first(where: { $0.identifier.rawValue == "size" }),
              let cell = browser.tableView(browser.table, viewFor: column, row: row) as? NSTableCellView else {
            throw Failure(message: "No zero-byte fixture cell was rendered")
        }
        let text = cell.textField?.stringValue ?? ""
        if !text.contains(where: \.isNumber) { failures.append("Zero-byte file size is spelled out instead of numeric: \(text)") }
        let actualVolumes = browser.volumes
        browser.volumes = [VolumeInfo(url: fixture, name: "Generated internal volume", kind: .internalDisk)]
        browser.updateNavigation()
        defer { browser.volumes = actualVolumes; browser.updateNavigation() }
        guard let image = browser.pathControl.pathItems.first?.image else {
            throw Failure(message: "Volume breadcrumb icon is missing")
        }
        if !(image.size.width > 0 && abs(image.size.width - image.size.height) < 0.5 && image.size.height <= 18) {
            failures.append("Volume breadcrumb icon has an elongated image canvas: \(NSStringFromSize(image.size))")
        }
        browser.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        let selected = browser.orderedSelectedURLs
        browser.copyPath(nil)
        if browser.orderedSelectedURLs != selected { failures.append("Copy Path cleared the file selection before the next command") }
        browser.copyFileURLs(nil)
        let copied = (browser.transferPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [NSURL])?.map { $0 as URL }
        if copied != selected { failures.append("Copy after Copy Path did not retain the selected file") }
        try require(failures.isEmpty, failures.joined(separator: "; "))
        try await verifyViewChoices(browser, output: output)
        try verifyColumnPreferences()
        try verifyCollectionWidthAdmission(browser, output: output)
    }

    private static func verifyViewChoices(_ browser: BrowserViewController, output: URL?) async throws {
        let settings = browser.settings
        let originalMode = settings.viewMode
        let originalColumns = BrowserColumn.allCases.map(browser.isColumnVisible)
        defer {
            for (column, visible) in zip(BrowserColumn.allCases, originalColumns) where browser.isColumnVisible(column) != visible {
                let item = NSMenuItem(); item.tag = column.toggleTag
                browser.toggleColumn(item)
            }
            settings.viewMode = originalMode
            browser.applyDisplayPreferences()
        }
        settings.viewMode = .details
        browser.applyDisplayPreferences()
        guard let header = browser.table.headerView as? FileTableHeaderView,
              let window = browser.view.window else { throw Failure(message: "Details did not install the column context header") }
        let selected = browser.selectedURLs
        let headerEvent = NSEvent.mouseEvent(with: .rightMouseDown,
            location: header.convert(NSPoint(x: 16, y: 10), to: nil), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        guard let menu = header.menu(for: headerEvent) else { throw Failure(message: "Right-clicking Name did not offer columns") }
        menu.update()
        try require(menu.items.map(\.title) == BrowserColumn.allCases.map(\.title), "Header choices are incomplete")
        try require(menu.items.first?.state == .on && menu.items.first?.isEnabled == false,
                    "Name must remain checked and cannot be hidden")
        for column in BrowserColumn.allCases where column != .name {
            guard let index = menu.items.firstIndex(where: { $0.tag == column.toggleTag }),
                  let native = browser.table.tableColumns.first(where: { $0.identifier.rawValue == column.rawValue }) else {
                throw Failure(message: "Missing column control: \(column.title)")
            }
            let wasVisible = browser.isColumnVisible(column)
            menu.performActionForItem(at: index)
            try await waitUntil("Header column toggle") { native.isHidden == wasVisible }
            menu.update()
            try require(menu.items[index].state == (wasVisible ? .off : .on), "Header checkmark did not follow its column")
            menu.performActionForItem(at: index)
            try await waitUntil("Header column restore") { native.isHidden != wasVisible }
        }
        try require(browser.selectedURLs == selected, "Changing header columns erased the file selection")

        let row = browser.table.selectedRow
        let entry = browser.displayedEntries[row]
        for (key, expected) in [
            ("created", entry.createdAt.map { BrowserViewController.dateFormatter.string(from: $0) } ?? "—"),
            ("accessed", entry.accessedAt.map { BrowserViewController.dateFormatter.string(from: $0) } ?? "—"),
            ("extension", entry.filenameExtension ?? "—"),
        ] {
            let column = browser.table.tableColumns.first { $0.identifier.rawValue == key }!
            let cell = browser.tableView(browser.table, viewFor: column, row: row) as? NSTableCellView
            try require(cell?.textField?.stringValue == expected, "Column did not display observed metadata: \(key)")
        }
        let point = browser.table.convert(NSPoint(x: 50, y: browser.table.rect(ofRow: row).midY), to: nil)
        let rowEvent = NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        guard let context = browser.table.menu(for: rowEvent) else { throw Failure(message: "File context menu is missing") }
        try require(!context.items.contains(where: { $0.title == "View" || $0.title == "Columns" }),
                    "Item context menu retained unrelated View or Columns controls")
        let topView = BrowserMenus.menu(.view, target: browser)
        let topModes = topView.items.filter { $0.action == #selector(BrowserViewController.changeViewMode(_:)) }
        try require(topModes.count == BrowserViewMode.allCases.count, "Top View choices are incomplete")
        for index in BrowserViewMode.allCases.indices {
            try require(topModes[index].image != nil
                        && browser.viewModeControl.image(forSegment: index) != nil,
                        "A view choice is missing its icon")
        }
        browser.viewModeControl.selectedSegment = 1
        try require(browser.viewModeControl.sendAction(browser.viewModeControl.action, to: browser.viewModeControl.target),
                    "List view control is disconnected")
        try await waitUntil("List icon action") { browser.table.headerView == nil }
        try require(settings.viewMode == .list && browser.table.tableColumns.filter { !$0.isHidden }.count == 1
                    && browser.selectedURLs == selected, "List icon did not retain selection and show only names")
        topView.update()
        try require(topModes[1].state == .on, "View menu checkmark did not follow the icon control")
        topView.performActionForItem(at: topView.index(of: topModes[0]))
        try await waitUntil("Details View action") { browser.table.headerView === header }
        try require(settings.viewMode == .details && browser.viewModeControl.selectedSegment == 0
                    && browser.selectedURLs == selected, "Details View action did not synchronize the control")
        settings.showsModifiedColumn = true
        settings.showsKindColumn = true
        settings.showsSizeColumn = true
        settings.showsCreatedColumn = false
        settings.showsAccessedColumn = false
        settings.showsExtensionColumn = false
        browser.applyDisplayPreferences()
        window.contentView?.layoutSubtreeIfNeeded()
        browser.table.tile()
        let last = browser.table.tableColumns.lastIndex { !$0.isHidden }!
        try require(browser.table.rect(ofColumn: last).maxX <= browser.folderScroll.contentView.bounds.width + 1,
                    "Default Details columns overflow after List/header changes: last edge \(browser.table.rect(ofColumn: last).maxX), viewport \(browser.folderScroll.contentView.bounds.width)")
        if let output {
            settings.showsCreatedColumn = true
            settings.showsAccessedColumn = false
            settings.showsExtensionColumn = false
            browser.applyDisplayPreferences()
            try await snapshot(window, to: output.appendingPathComponent("14-details-created.png"))
        }
    }

    /// A native allocated child reproduces transient zero/narrow widths without
    /// resizing a real owner window, reading files or entering the full suite.
    private static func verifyCollectionWidthAdmission(_ browser: BrowserViewController, output: URL?) throws {
        let entries = Array(browser.displayedEntries.prefix(8))
        try require(!entries.isEmpty, "Collection allocation check has no generated observations")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        window.contentView = host
        let icons = FileIconBrowserView(frame: host.bounds)
        host.addSubview(icons)
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        icons.update(OrderedRows(entries: entries, rowsByURL: Dictionary(uniqueKeysWithValues:
            entries.enumerated().map { ($0.element.url, $0.offset) })), selected: [entries[0].url], cut: [], showsExtensions: true)
        var observations: [[String: Any]] = []
        var invalid: [Int] = []
        for width in [0, 1, 8, 19, 20, 21, 32, 36, 52, 53, 54, 64, 156, 320, 64, 320] {
            icons.setFrameSize(NSSize(width: width, height: 240))
            icons.needsLayout = true
            icons.layoutSubtreeIfNeeded()
            icons.collectionView.layoutSubtreeIfNeeded()
            guard let flow = icons.collectionView.collectionViewLayout as? NSCollectionViewFlowLayout else {
                throw Failure(message: "File Icons lost its native flow layout")
            }
            let first = flow.layoutAttributesForItem(at: IndexPath(item: 0, section: 0))
            let deferred = first == nil && flow.layoutAttributesForElements(in: icons.collectionView.bounds).isEmpty
            let actual = icons.collectionView.bounds.width
            let available = actual - flow.sectionInset.left - flow.sectionInset.right
            let valid = actual.isFinite && flow.itemSize.width.isFinite && (deferred
                || (flow.itemSize.width > 0 && flow.itemSize.width <= available))
            if !valid { invalid.append(width) }
            observations.append(["requestedWidth": width, "clipWidth": icons.scrollView.contentView.bounds.width,
                "collectionWidth": actual, "itemWidth": flow.itemSize.width,
                "leftInset": flow.sectionInset.left, "rightInset": flow.sectionInset.right, "deferred": deferred, "valid": valid])
        }
        if let output {
            try JSONSerialization.data(withJSONObject: ["observations": observations, "passed": invalid.isEmpty],
                options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("collection-width-admission.json"), options: .withoutOverwriting)
        }
        try require(invalid.isEmpty, "File Icons item width exceeds its native allocated width after section insets at requested widths: \(invalid)")
        try require(icons.itemCount == entries.count && icons.selectedURLs == [entries[0].url],
            "Narrow collection allocation discarded supplied rows or selection")
        try require(!icons.visibleItems.isEmpty
            && (icons.collectionView.collectionViewLayout as? NSCollectionViewFlowLayout)?.itemSize.width == 136,
            "Normal allocation did not restore the existing Icons tile size and visible rows")
    }

    private static func verifyColumnPreferences() throws {
        let legacy = BrowserSettings(persist: false, restoredData: Data(#"{"version":2,"showsModifiedColumn":false,"showsKindColumn":true,"showsSizeColumn":false}"#.utf8))
        try require(!legacy.showsModifiedColumn && legacy.showsKindColumn && !legacy.showsSizeColumn
                    && !legacy.showsCreatedColumn && !legacy.showsAccessedColumn && !legacy.showsExtensionColumn,
                    "Version 2 column preferences did not preserve choices and additive defaults")
        legacy.showsCreatedColumn = true
        legacy.showsAccessedColumn = true
        legacy.showsExtensionColumn = true
        let encoded = try legacy.encodedSnapshot()
        let decoded = BrowserSettings(persist: false, restoredData: encoded)
        try require(decoded.showsCreatedColumn && decoded.showsAccessedColumn && decoded.showsExtensionColumn
                    && !decoded.showsModifiedColumn && !decoded.showsSizeColumn,
                    "New column preferences did not round-trip")
        let object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        try require(object?["version"] as? Int == BrowserSettings.preferencesVersion,
                    "Current preference snapshot has an unexpected schema")
    }
}
#endif
