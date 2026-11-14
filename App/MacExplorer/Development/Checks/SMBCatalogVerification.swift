#if DEBUG
import AppKit
import ExplorerCore
@_spi(Qualification) import LocalStorage

/// Generated native result acceptance. This performs no network connection or
/// credential access and does not activate ordinary SMB in the browser.
@MainActor enum SMBCatalogVerification {
    static func run(root: URL, mode: String, settings: BrowserSettings) async throws -> [String: Any] {
        guard ["complete", "stop", "window-close"].contains(mode) else { throw UIVerification.Failure(message: "Unknown catalog review mode") }
        let rows = PagedRows()
        let label = NSTextField(wrappingLabelWithString: "Generated metadata · No network connection")
        let progress = NSTextField(labelWithString: "Preparing temporary result…")
        progress.textColor = .secondaryLabelColor
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.drawsBackground = false; scroll.documentView = rows.table
        let stack = NSStackView(views: [label, progress, scroll]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.edgeInsets = .init(top: 14, left: 14, bottom: 14, right: 14)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28), scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 300)])
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 740, height: 440), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Generated SMB folder paging · 100,000 items"; window.isReleasedWhenClosed = false
        let controller = NSViewController(); controller.view = stack; window.contentViewController = controller
        ToolWindowChrome.install(in: window, settings: settings); window.setContentSize(.init(width: 740, height: 440))
        window.setFrameOrigin(.init(x: -12000, y: -12000)); window.orderFront(nil); window.contentView?.layoutSubtreeIfNeeded()
        defer { window.close() }
        let activity = FileActivityGate(maximumActivities: 1)
        let began = ProcessInfo.processInfo.systemUptime
        var ticks = 0
        let heartbeat = Task { @MainActor in
            while !Task.isCancelled { ticks += 1; try? await Task.sleep(for: .milliseconds(10)) }
        }
        defer { heartbeat.cancel() }
        let session = try await SMBGeneratedCatalogSession.start(bundleURL: Bundle.main.bundleURL, generatedCase: root, activity: activity)
        var closed: SMBCatalogDrainResult?
        do {
            var first: SMBDirectoryPage?
            for _ in 0..<8 {
                do { first = try await session.page(offset: 0); break }
                catch SMBDirectoryFailure.stale { continue }
            }
            guard let first, !first.entries.isEmpty else { throw UIVerification.Failure(message: "Initial committed native page unavailable") }
            try rows.show(first); progress.stringValue = "Observed so far · \(first.request.snapshot.count.formatted()) items · Read only"
            rows.table.layoutSubtreeIfNeeded(); rows.table.displayIfNeeded()
            let firstSeconds = ProcessInfo.processInfo.systemUptime - began
            guard firstSeconds < 1, rows.cache.retainedCount <= 512 else { throw UIVerification.Failure(message: "First native result exceeded its gate") }
            if mode == "window-close" { window.close() }
            var finalCount = first.request.snapshot.count, finalState = first.request.snapshot.state
            var displayed = first.entries.count
            if mode == "complete" {
                if session.snapshot?.state != .complete {
                    for await snapshot in session.snapshots {
                        progress.stringValue = "Observed so far · \(snapshot.count.formatted()) items · Read only"
                        if snapshot.state == .complete { break }
                    }
                }
                guard let final = session.snapshot, final.count == 100000, final.state == .complete else {
                    throw UIVerification.Failure(message: "Native result did not reach its genuine terminal")
                }
                finalCount = final.count; finalState = final.state
                let last = try await session.page(offset: 99744)
                try rows.show(last); rows.table.scrollRowToVisible(99999)
                guard rows.table.numberOfRows == 100000, rows.cache.entry(at: 99999)?.name.displayName == "Item 99999" else {
                    throw UIVerification.Failure(message: "Native paging substituted a late directory item")
                }
                let initial = try await session.page(offset: 0)
                try rows.show(initial); rows.table.scrollRowToVisible(0)
                guard rows.cache.retainedCount == 512, rows.cache.entry(at: 0)?.name.displayName == "Item 0" else {
                    throw UIVerification.Failure(message: "Native cache or natural directory order differs")
                }
                displayed = rows.cache.retainedCount
                progress.stringValue = "100,000 observed items · 512 cached rows · Read only"
                try await UIVerification.snapshot(window, to: root.appendingPathComponent("evidence/native-catalog.png"))
            }
            closed = await session.close()
            guard let closed, closed.actualExit, closed.pipeDrained, closed.catalogClosed, closed.ownerReleased,
                  !closed.forcedContainment, activity.activeCount == 0 else {
                throw UIVerification.Failure(message: "Catalog/query/process ownership did not drain")
            }
            return ["passed": true, "mode": mode, "firstNativePageMilliseconds": firstSeconds * 1000,
                "elapsedSeconds": ProcessInfo.processInfo.systemUptime - began, "finalCount": finalCount,
                "finalState": finalState.rawValue, "cachedRows": displayed, "mainExecutorTicks": ticks,
                "actualExit": closed.actualExit, "pipeDrained": closed.pipeDrained, "catalogClosed": closed.catalogClosed,
                "ownerReleased": closed.ownerReleased, "forcedContainment": closed.forcedContainment,
                "activityAfterDrain": activity.activeCount, "networkConnections": 0, "credentialAccesses": 0,
                "producer": "Generated monotonic names; initial committed-prefix backpressure; native page consumption"]
        } catch {
            if closed == nil { closed = await session.close() }
            try? JSONSerialization.data(withJSONObject: ["passed": false,
                "failure": String(describing: session.failure), "count": session.snapshot?.count ?? -1,
                "state": session.snapshot?.state.rawValue ?? "none", "actualExit": closed?.actualExit ?? false,
                "pipeDrained": closed?.pipeDrained ?? false, "catalogClosed": closed?.catalogClosed ?? false,
                "forcedContainment": closed?.forcedContainment ?? false] as [String: Any])
                .write(to: root.appendingPathComponent("evidence/native.json"), options: .withoutOverwriting)
            throw error
        }
    }
    @MainActor private final class PagedRows: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        let table = NSTableView()
        var cache = SMBDirectoryPageCache()
        override init() {
            super.init()
            for (key, title, width) in [("name", "Name", 420.0), ("kind", "Kind", 100.0), ("size", "Size", 130.0)] {
                let column = NSTableColumn(identifier: .init(key)); column.title = title; column.width = width; table.addTableColumn(column)
            }
            table.dataSource = self; table.delegate = self; table.rowHeight = 24
            table.backgroundColor = .clear; table.usesAlternatingRowBackgroundColors = true
            table.setAccessibilityLabel("Generated paged directory; read only")
        }
        func show(_ page: SMBDirectoryPage) throws {
            cache.observe(page.request.snapshot); try cache.accept(page)
            table.reloadData()
        }
        func numberOfRows(in tableView: NSTableView) -> Int { Int(cache.snapshot?.count ?? 0) }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let item = cache.entry(at: Int64(row)) else { return NSTextField(labelWithString: "") }
            switch tableColumn?.identifier.rawValue {
            case "name": return NSTextField(labelWithString: item.name.displayName)
            case "kind": return NSTextField(labelWithString: item.isDirectory ? "Folder" : "File")
            case "size": return NSTextField(labelWithString: item.isDirectory ? "—" : ByteCountFormatter.string(fromByteCount: Int64(item.logicalBytes), countStyle: .file))
            default: return nil
            }
        }
    }
}
#endif
