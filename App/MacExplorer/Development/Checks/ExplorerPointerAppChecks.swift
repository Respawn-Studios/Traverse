#if DEBUG
import AppKit
import ExplorerCore
import LocalStorage

/// Root composes this into its admitted actual App build. These are constructed
/// events dispatched through NSApplication into visible generated native views,
/// not modifier-only assertions or physical/OS-posted pointer acceptance.
@MainActor
enum ExplorerPointerAppChecks {
    private enum Failure: Error { case stage(String) }
    private static func require(_ condition: Bool, _ stage: String) throws {
        guard condition else { throw Failure.stage(stage) }
    }
    private final class Rows: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var writerRequests: [Int] = []
        func numberOfRows(in tableView: NSTableView) -> Int { 6 }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let cell = NSTableCellView()
            let field = NSTextField(labelWithString: "Generated item \(row)")
            field.frame = .init(x: 8, y: 0, width: 250, height: 24)
            cell.addSubview(field); cell.textField = field
            return cell
        }
        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
            writerRequests.append(row)
            return nil // Admit the native writer callback, refuse session creation.
        }
    }
    private final class ProbeTable: FileTableView {
        var contexts = 0
        var dragGroups: [IndexSet] = []
        override func menu(for event: NSEvent) -> NSMenu? { contexts += 1; _ = super.menu(for: event); return nil }
        override func canDragRows(with rowIndexes: IndexSet, at mouseDownPoint: NSPoint) -> Bool {
            dragGroups.append(rowIndexes)
            return super.canDragRows(with: rowIndexes, at: mouseDownPoint)
        }
    }
    private static func wait(_ label: String, _ condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while !condition() {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw Failure.stage(label) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    private static func event(_ type: NSEvent.EventType, window: NSWindow, point: NSPoint,
                              flags: NSEvent.ModifierFlags, stamp: TimeInterval, number: Int) throws -> NSEvent {
        guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: flags,
            timestamp: stamp, windowNumber: window.windowNumber, context: nil,
            eventNumber: number, clickCount: 1, pressure: type == .leftMouseUp || type == .rightMouseUp ? 0 : 1) else {
            throw Failure.stage("constructed-native-event-unavailable")
        }
        return event
    }
    /// Never drain an arbitrary app event. Only this exact generated release
    /// may remain when a control returns without entering native tracking.
    private static func releaseOwn(_ release: NSEvent) {
        let mask: NSEvent.EventTypeMask = release.type == .rightMouseUp ? .rightMouseUp : .leftMouseUp
        guard let pending = NSApp.nextEvent(matching: mask, until: .distantPast, inMode: .default, dequeue: false),
              pending.windowNumber == release.windowNumber && pending.timestamp == release.timestamp
                && pending.eventNumber == release.eventNumber && pending.locationInWindow == release.locationInWindow else { return }
        if let own = NSApp.nextEvent(matching: mask, until: .distantPast, inMode: .default, dequeue: true) { NSApp.sendEvent(own) }
    }
    private static func click(window: NSWindow, point: NSPoint, flags: NSEvent.ModifierFlags = [], secondary: Bool = false) async throws {
        try require(window.isKeyWindow && window.isVisible && NSApp.isActive, "generated-window-foreground-required")
        let stamp = ProcessInfo.processInfo.systemUptime
        let down = try event(secondary ? .rightMouseDown : .leftMouseDown, window: window, point: point, flags: flags, stamp: stamp, number: 721)
        let up = try event(secondary ? .rightMouseUp : .leftMouseUp, window: window, point: point, flags: flags, stamp: stamp + 0.01, number: 722)
        NSApp.postEvent(up, atStart: true)
        NSApp.sendEvent(down)
        releaseOwn(up)
        try await Task.sleep(for: .milliseconds(25))
    }
    private static func drag(window: NSWindow, from start: NSPoint, to end: NSPoint, flags: NSEvent.ModifierFlags = []) async throws {
        try require(window.isKeyWindow && window.isVisible && NSApp.isActive, "generated-drag-window-foreground-required")
        let stamp = ProcessInfo.processInfo.systemUptime
        let down = try event(.leftMouseDown, window: window, point: start, flags: flags, stamp: stamp, number: 731)
        let moved = try event(.leftMouseDragged, window: window, point: end, flags: flags, stamp: stamp + 0.02, number: 732)
        let up = try event(.leftMouseUp, window: window, point: end, flags: flags, stamp: stamp + 0.04, number: 733)
        NSApp.postEvent(up, atStart: true); NSApp.postEvent(moved, atStart: true)
        NSApp.sendEvent(down)
        // Native trackers usually consume both. If not, send only our exact
        // remaining drag/release to the same generated window.
        if let pending = NSApp.nextEvent(matching: .leftMouseDragged, until: .distantPast, inMode: .default, dequeue: false),
           pending.windowNumber == moved.windowNumber && pending.timestamp == moved.timestamp && pending.eventNumber == moved.eventNumber,
           let own = NSApp.nextEvent(matching: .leftMouseDragged, until: .distantPast, inMode: .default, dequeue: true) { NSApp.sendEvent(own) }
        releaseOwn(up)
        try await Task.sleep(for: .milliseconds(25))
    }
    private static func show(_ view: NSView, title: String) async throws -> NSWindow {
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 1000, height: 520), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.title = title; window.contentView = view
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        try await wait("generated-native-window-ready") { window.isKeyWindow && view.bounds.width > 900 }
        view.layoutSubtreeIfNeeded()
        return window
    }
    private static func tablePoint(_ row: Int, table: NSTableView) -> NSPoint {
        let rect = table.rect(ofRow: row)
        return table.convert(.init(x: 110, y: rect.midY), to: nil)
    }
    private static func tableSequence(_ table: NSTableView, window: NSWindow, alias: NSEvent.ModifierFlags) async throws -> [IndexSet] {
        table.deselectAll(nil)
        var states: [IndexSet] = []
        for (row, flags) in [(0, NSEvent.ModifierFlags()), (2, alias), (0, alias), (4, alias.union(.shift))] {
            try await click(window: window, point: tablePoint(row, table: table), flags: flags)
            states.append(table.selectedRowIndexes)
        }
        return states
    }
    private static func table(_ table: NSTableView, name: String, setBehavior: (BrowserBehaviorPreferences) -> Void,
                              details: Bool) async throws -> [String] {
        let rows = Rows(), scroll = NSScrollView()
        table.headerView = details ? NSTableHeaderView() : nil
        table.rowHeight = 26; table.allowsMultipleSelection = true; table.allowsEmptySelection = true
        let column = NSTableColumn(identifier: .init("generated-name")); column.title = "Name"; column.width = 800
        table.addTableColumn(column); table.dataSource = rows; table.delegate = rows
        table.menu = nil; scroll.documentView = table; scroll.hasVerticalScroller = true
        table.setDraggingSourceOperationMask(.copy, forLocal: true)
        let host = NSView(frame: .init(x: 0, y: 0, width: 1000, height: 520))
        scroll.frame = .init(x: 12, y: 0, width: 988, height: 520)
        scroll.autoresizingMask = [.width, .height]; host.addSubview(scroll)
        if let files = table as? FileTableView {
            files.marquee = TableMarqueeSelection(table: files, scroll: scroll, parent: host)
        } else if let remote = table as? RemoteFileTableView {
            #if DEBUG
            remote.marquee = TableMarqueeSelection(table: remote, scroll: scroll, parent: host,
                revision: { [weak remote] in remote?.marqueeRevision ?? 0 },
                pointerBehavior: { [weak remote] in remote?.behavior ?? .mac })
            #else
            remote.marquee = TableMarqueeSelection(table: remote, scroll: scroll, parent: host,
                revision: { [weak remote] in remote?.marqueeRevision ?? 0 })
            #endif
        }
        let window = try await show(host, title: "Generated " + name + " pointer controls")
        defer { window.close() }
        table.reloadData(); table.layoutSubtreeIfNeeded()
        setBehavior(.explorer)
        let command = try await tableSequence(table, window: window, alias: .command)
        try require(command[1] == [0, 2] && command[2] == [2], name + "-native-command-baseline")
        let control = try await tableSequence(table, window: window, alias: .control)
        try require(control == command, name + "-actual-control-add-toggle-off-and-shift-match-native-command")
        try require(window.firstResponder === table, name + "-toggle-keeps-native-focus")
        let empty = table.convert(.init(x: 100, y: table.rect(ofRow: 5).maxY + 40), to: nil)
        table.selectRowIndexes([0, 2], byExtendingSelection: false)
        try await click(window: window, point: empty, flags: .command)
        let emptyCommand = table.selectedRowIndexes
        table.selectRowIndexes([0, 2], byExtendingSelection: false)
        try await click(window: window, point: empty, flags: .control)
        try require(table.selectedRowIndexes == emptyCommand, name + "-empty-primary-control-matches-native-command")
        let firstInHost = table.convert(.init(x: 0, y: table.rect(ofRow: 0).midY), to: host)
        let fourthInHost = table.convert(.init(x: 0, y: table.rect(ofRow: 3).midY), to: host)
        let gutterStart = host.convert(.init(x: 5, y: firstInHost.y), to: nil)
        let gutterEnd = host.convert(.init(x: 70, y: fourthInHost.y), to: nil)
        table.selectRowIndexes([0, 2], byExtendingSelection: false)
        try await drag(window: window, from: gutterStart, to: gutterEnd, flags: .command)
        let gutterCommand = table.selectedRowIndexes
        table.selectRowIndexes([0, 2], byExtendingSelection: false)
        try await drag(window: window, from: gutterStart, to: gutterEnd, flags: .control)
        try require(table.selectedRowIndexes == gutterCommand, name + "-existing-gutter-owner-control-matches-command")
        table.deselectAll(nil)
        try await click(window: window, point: tablePoint(0, table: table))
        try await click(window: window, point: tablePoint(2, table: table), flags: .control)
        if let probe = table as? ProbeTable {
            probe.dragGroups = []; rows.writerRequests = []
            let start = tablePoint(2, table: table)
            try await drag(window: window, from: start, to: start.applying(.init(translationX: 30, y: 12)))
            try require(!probe.dragGroups.isEmpty && probe.dragGroups.contains([0, 2]) && !rows.writerRequests.isEmpty,
                        name + "-actual-native-group-drag-admission-preserved")
        }
        setBehavior(.mac)
        let macCommand = try await tableSequence(table, window: window, alias: .command)
        try require(macCommand == command, name + "-mac-command-selection-retained")
        table.selectRowIndexes([0], byExtendingSelection: false)
        try await click(window: window, point: tablePoint(2, table: table), flags: .control)
        try require(table.selectedRowIndexes != [0, 2], name + "-mac-control-not-converted-to-toggle")
        if let probe = table as? ProbeTable { try require(probe.contexts > 0, name + "-mac-control-reaches-native-context") }
        table.selectRowIndexes([0, 2], byExtendingSelection: false)
        try await click(window: window, point: tablePoint(2, table: table), secondary: true)
        try require(table.selectedRowIndexes == [0, 2], name + "-secondary-click-retains-selected-group")
        return [name + ": actual native Command/Control/Control-Shift selection, toggle-off/focus, Mac semantics and secondary click"]
    }
    private static func collectionPoint(_ item: Int, collection: NSCollectionView) throws -> NSPoint {
        guard let attributes = collection.collectionViewLayout?.layoutAttributesForItem(at: .init(item: item, section: 0)) else {
            throw Failure.stage("real-collection-layout-missing")
        }
        return collection.convert(.init(x: attributes.frame.midX, y: attributes.frame.midY), to: nil)
    }
    private static func collectionSequence(_ collection: NSCollectionView, window: NSWindow, alias: NSEvent.ModifierFlags) async throws -> [Set<IndexPath>] {
        collection.selectionIndexPaths = []
        var states: [Set<IndexPath>] = []
        for (item, flags) in [(0, NSEvent.ModifierFlags()), (2, alias), (0, alias), (4, alias.union(.shift))] {
            try await click(window: window, point: collectionPoint(item, collection: collection), flags: flags)
            states.append(collection.selectionIndexPaths)
        }
        return states
    }
    private static func collection(_ collection: NSCollectionView, in view: NSView, name: String,
                                   setBehavior: (BrowserBehaviorPreferences) -> Void) async throws -> [String] {
        let window = try await show(view, title: "Generated " + name + " pointer controls")
        defer { window.close() }
        try await wait(name + "-real-items-mounted") { collection.visibleItems().count >= 5 }
        setBehavior(.explorer)
        let command = try await collectionSequence(collection, window: window, alias: .command)
        let pair: Set<IndexPath> = [.init(item: 0, section: 0), .init(item: 2, section: 0)]
        try require(command[1] == pair && command[2] == [.init(item: 2, section: 0)], name + "-native-command-baseline")
        let control = try await collectionSequence(collection, window: window, alias: .control)
        try require(control == command, name + "-actual-control-add-toggle-off-and-shift-match-native-command")
        setBehavior(.mac)
        let macCommand = try await collectionSequence(collection, window: window, alias: .command)
        try require(macCommand == command, name + "-mac-command-retained")
        collection.selectionIndexPaths = [.init(item: 0, section: 0)]
        try await click(window: window, point: collectionPoint(2, collection: collection), flags: .control)
        try require(collection.selectionIndexPaths != pair, name + "-mac-control-stays-context")
        collection.selectionIndexPaths = pair
        try await click(window: window, point: collectionPoint(2, collection: collection), secondary: true)
        try require(collection.selectionIndexPaths == pair, name + "-secondary-click-retains-group")
        return [name + ": actual production collection items/gesture routing with Command/Control/Control-Shift and Mac/secondary clicks"]
    }
    static func check(fixtureRoot: URL) async throws -> [String: Any] {
        try require(fixtureRoot.isFileURL && fixtureRoot.path.contains("/.build/traverse-development/"), "owned-generated-fixture-url-required")
        var checks: [String] = []
        for details in [true, false] {
            let table = ProbeTable()
            checks += try await self.table(table, name: details ? "Details" : "List", setBehavior: { table.behavior = $0 }, details: details)
        }
        let archive = ArchiveMetadataTable()
        checks += try await table(archive, name: "Archive", setBehavior: { archive.behavior = $0 }, details: true)
        let remote = RemoteFileTableView()
        #if DEBUG
        checks += try await table(remote, name: "Shared SMB/SFTP", setBehavior: { remote.behavior = $0 }, details: true)
        #else
        // Original remote table has no profile binding. This compatibility seam
        // lets the same actual input control compile for its retained RED run.
        checks += try await table(remote, name: "Shared SMB/SFTP", setBehavior: { _ in }, details: true)
        #endif
        let files = FileIconBrowserView(frame: .zero)
        files.showsFolderSummaries = false
        let entries = (0..<6).map { FileEntry(url: fixtureRoot.appendingPathComponent("Generated-\($0).txt"), name: "Generated-\($0).txt", kind: .file) }
        files.update(.init(entries: entries, rowsByURL: Dictionary(uniqueKeysWithValues: entries.enumerated().map { ($0.element.url, $0.offset) })),
                     selected: [], cut: [], showsExtensions: true)
        files.collectionView.onContextMenu = { _ in nil }
        checks += try await collection(files.collectionView, in: files, name: "Icons", setBehavior: { files.collectionView.behavior = $0 })
        let drives = VolumeBrowserView(frame: .zero)
        drives.update(volumes: (0..<6).map { VolumeInfo(url: fixtureRoot.appendingPathComponent("Generated Drive \($0)", isDirectory: true),
                    name: "Generated Drive \($0)", kind: .unknown) })
        drives.collectionView.onContextMenu = { _ in nil } // Never activate a drive command or menu action.
        checks += try await collection(drives.collectionView, in: drives, name: "This Mac", setBehavior: { drives.behavior = $0 })
        return ["passed": true, "checks": checks, "input": "Constructed in-process NSApplication events into actual native controls",
                "physicalInput": "NOT EXERCISED", "actualDragSession": "NOT EXERCISED; native writer refuses before session",
                "engineCalls": 0, "OSPostedEvents": 0, "networkCalls": 0]
    }
}
#endif
