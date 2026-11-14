#if DEBUG
import AppKit
import Darwin
import ExplorerCore
import LocalStorage

/// Generated UI and private-preference checks. No source listing, transfer,
/// connection, file-operation mutation or system preference change is admitted.
@MainActor enum SidebarLayoutVerification {
    private struct Failure: Error { let stage: String }
    private final class ReviewCompletion: NSObject {
        var continuation: CheckedContinuation<Void, Never>?
        var watchdog: Task<Void, Never>?
        private(set) var timedOut = false
        @objc func finish() {
            guard let continuation else { return }
            self.continuation = nil
            watchdog?.cancel()
            continuation.resume()
        }
        func expire() { timedOut = true; finish() }
    }
    private static func review(_ controller: BrowserWindowController, root: URL) async throws -> [String: Any] {
        guard let window = controller.window, let content = window.contentView else { throw Failure(stage: "review-window") }
        controller.browser.settings.interfaceSize = .init(100)
        controller.browser.settings.appearance = .dark
        try await Task.sleep(for: .milliseconds(450))
        let probe = try SidebarLayoutGestureProbe(controller.browser, root: root)
        let completion = ReviewCompletion()
        let button = NSButton(title: "Finish generated check", target: completion,
                              action: #selector(ReviewCompletion.finish))
        button.bezelStyle = .rounded
        button.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(button)
        NSLayoutConstraint.activate([
            button.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            button.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12)
        ])
        window.title = "Generated sidebar name review · " + root.lastPathComponent.prefix(8)
        let marker = Data("generated sidebar ready\n".utf8)
        _ = try? await Task.detached {
            try marker.write(to: root.appendingPathComponent("evidence/interactive-ready.txt"), options: .withoutOverwriting)
        }.value
        await withCheckedContinuation { continuation in
            completion.continuation = continuation
            completion.watchdog = Task { @MainActor in
                do { try await Task.sleep(for: .seconds(180)) } catch { return }
                completion.expire()
            }
        }
        button.removeFromSuperview()
        var result = await probe.finish()
        result["timedOut"] = completion.timedOut
        if completion.timedOut { result["passed"] = false }
        return result
    }
    private static func need(_ value: Bool, _ stage: String) throws {
        if !value { throw Failure(stage: stage) }
    }
    private static func wait(_ stage: String, _ ready: () -> Bool) async throws {
        let until = ContinuousClock.now + .seconds(8)
        while !ready() {
            try need(.now < until, stage)
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    @MainActor private final class Info: NSObject, NSDraggingInfo {
        let draggingPasteboard: NSPasteboard
        var draggingSource: Any? { nil }
        var draggingSequenceNumber: Int { 1 }
        var draggingSourceOperationMask: NSDragOperation { .move }
        var draggingDestinationWindow: NSWindow?
        var draggingLocation: NSPoint = .zero
        var draggedImageLocation: NSPoint { .zero }
        nonisolated var draggedImage: NSImage? { nil }
        var draggingFormation: NSDraggingFormation = .none
        var animatesToDestination = false
        var numberOfValidItemsForDrop = 0
        var springLoadingHighlight: NSSpringLoadingHighlight { .none }
        init(_ board: NSPasteboard) { draggingPasteboard = board }
        func slideDraggedImage(to screenPoint: NSPoint) {}
        nonisolated override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
        func resetSpringLoading() {}
        func enumerateDraggingItems(options: NSDraggingItemEnumerationOptions, for view: NSView?, classes: [AnyClass],
            searchOptions: [NSPasteboard.ReadingOptionKey: Any], using block: @escaping (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    }
    private static func preferenceChecks(_ scope: URL) async throws -> [String] {
        let directory = scope.appendingPathComponent("state/sidebar")
        let store = BrowserSidebarLayoutFile(directory: directory)
        try need(try await store.load() == nil, "preference-start-absent")
        var value = SidebarLayoutPreferences()
        try value.moveSection(.places, before: .computer, expectedRevision: 0)
        let bytes = try value.encoded()
        try await store.save(bytes, replacing: nil)
        try need(try await store.load() == bytes, "exact-preference-save")
        do {
            try await store.save(try SidebarLayoutPreferences().encoded(), replacing: nil)
            throw Failure(stage: "stale-preference-write-accepted")
        } catch is Failure { throw Failure(stage: "stale-preference-write-accepted") }
        catch {}
        try need(try await store.load() == bytes, "stale-write-preserves-record")
        let restored = BrowserSidebarLayoutController(persistence: BrowserSidebarLayoutFile(directory: directory))
        restored.restoreIfNeeded()
        _ = await restored.flush()
        try need(restored.canEdit && restored.preferences == value, "new-controller-restores-record")
        try need(restored.reset(expectedRevision: value.revision), "explicit-layout-reset")
        _ = await restored.flush()
        let reloaded = try await BrowserSidebarLayoutFile(directory: directory).load()
        try need(try reloaded.map(SidebarLayoutPreferences.decode)?.sectionOrder == SidebarLayoutSection.allCases,
                 "reset-persists-default-positions")
        guard let legacyBytes = reloaded,
              var legacyObject = try JSONSerialization.jsonObject(with: legacyBytes) as? [String: Any],
              legacyObject["version"] as? Int == 1 else { throw Failure(stage: "legacy-layout-version") }
        try need(try SidebarLayoutPreferences.decode(legacyBytes).encoded() == legacyBytes,
            "old-layout-canonical-bytes")
        let serverID = UUID()
        let smb = try WorkspaceConnectionBookmark(kind: .smbServer, serverID: serverID,
            binding: Data(repeating: 1, count: 32), title: "Generated SMB")
        let sftp = try WorkspaceConnectionBookmark(kind: .sftpServer, serverID: serverID,
            binding: Data(repeating: 2, count: 32), title: "Generated SFTP")
        let route = try WorkspaceConnectionBookmark(kind: .sftpRoute, serverID: serverID,
            binding: Data(repeating: 3, count: 32), title: "Generated Route")
        let keys = [smb, sftp, route].map { SidebarLayoutItemKey.server($0.kind, id: $0.serverID) }
        try need(Set(keys).count == 3, "server-kind-order-identities")
        var serverLayout = try SidebarLayoutPreferences.decode(legacyBytes)
        try serverLayout.moveItem(keys[2], before: keys[0], in: .servers, observed: keys,
            expectedRevision: serverLayout.revision)
        let serverBytes = try serverLayout.encoded()
        try await store.save(serverBytes, replacing: legacyBytes)
        let serverOwner = BrowserSidebarLayoutController(persistence: BrowserSidebarLayoutFile(directory: directory))
        serverOwner.restoreIfNeeded(); _ = await serverOwner.flush()
        try need(serverOwner.canEdit && serverOwner.preferences == serverLayout
            && (try serverOwner.preferences.orderedItems(keys, in: .servers)) == [keys[2], keys[0], keys[1]],
            "saved-server-cold-order")
        let encodedText = String(decoding: serverBytes, as: UTF8.self)
        try need(encodedText.contains("\"version\":2") && !encodedText.contains("Generated")
            && !encodedText.contains("binding") && !encodedText.contains("components"), "opaque-server-order-only")
        legacyObject = try JSONSerialization.jsonObject(with: serverBytes) as? [String: Any] ?? [:]
        legacyObject["version"] = 1
        do {
            _ = try SidebarLayoutPreferences.decode(JSONSerialization.data(withJSONObject: legacyObject, options: [.sortedKeys]))
            throw Failure(stage: "new-server-keys-in-v1-accepted")
        } catch is SidebarLayoutFailure { /* New keys cannot masquerade as the old format. */ }
        let id = BrowserConnectionIdentity(pane: UUID(), tab: UUID(), connection: UUID(), kind: .sftp)
        let live = BrowserConnectedLocation(id: id, name: "Generated SFTP", status: "Connected",
            location: .sftp(.init(connectionID: id.connection, directoryID: UUID(), displayHint: "Generated SFTP")), savedTarget: sftp)
        let mapped = BrowserSidebarLayoutAdapter.serverRowIDs(live: [live], saved: [smb, route])
        try need(mapped == [.stored(keys[1]), .stored(keys[0]), .stored(keys[2])], "saved-live-row-stable-key")
        var changed = live
        changed.savedTarget = try WorkspaceConnectionBookmark(kind: sftp.kind, serverID: sftp.serverID,
            binding: Data(repeating: 4, count: 32), title: "Changed Generated Name", components: [Data("Other".utf8)])
        try need(BrowserSidebarLayoutAdapter.serverRowIDs(live: [changed], saved: []) == [.stored(keys[1])],
            "server-properties-preserve-order-identity")
        let duplicateID = BrowserConnectionIdentity(pane: id.pane, tab: UUID(), connection: UUID(), kind: .sftp)
        let duplicate = BrowserConnectedLocation(id: duplicateID, name: live.name, status: live.status,
            location: live.location, savedTarget: sftp)
        try need(BrowserSidebarLayoutAdapter.serverRowIDs(live: [live, duplicate], saved: []) == [.server(id), .server(duplicateID)],
            "duplicate-live-profiles-stay-distinct")
        return ["Private preferences save and cold owner restore", "Stale expected bytes refuse overwrite", "Explicit layout reset persists",
            "Saved SMB/SFTP/route order survives a cold owner with opaque IDs only; existing v1 bytes stay compatible",
            "Edited saved profiles retain position; duplicate live sessions remain distinct and session-local"]
    }
    static func run() async {
        var scope: URL?, controller: BrowserWindowController?, checks: [String] = [], failure: String?
        var capturedFrames: [Int] = []
        var clips: [[String: Any]] = []
        var rowPresentation: [String: Any]?
        var gestureObservation: [String: Any]?
        var checkpoint = "scope"
        do {
            guard let raw = ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"] else { throw Failure(stage: "scope") }
            let root = URL(fileURLWithPath: raw)
            let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let admitted = try await Task.detached {
                guard root.resolvingSymlinksInPath() == root, root.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-development"),
                      UUID(uuidString: root.lastPathComponent)?.uuidString == root.lastPathComponent else { return false }
                let data = try Data(contentsOf: root.appendingPathComponent("reservation.json"))
                guard data.count <= 4096, let marker = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
                return marker["packet"] as? String == "traverse-development-v1" && marker["action"] as? String == "native-sidebar-layout"
            }.value
            try need(admitted && Bundle.main.bundleIdentifier == "local.macexplorer.development", "scope-and-app")
            scope = root
            checkpoint = "private-preferences"
            checks += try await preferenceChecks(root)
            checkpoint = "generated-home-directories"
            let home = root.appendingPathComponent("source/Sidebar Home", isDirectory: true)
            try await Task.detached {
                for name in ["", "Desktop", "Documents", "Downloads"] {
                    let folder = name.isEmpty ? home : home.appendingPathComponent(name)
                    try FileManager().createDirectory(at: folder, withIntermediateDirectories: false,
                                                     attributes: [.posixPermissions: 0o700])
                }
            }.value
            checkpoint = "generated-home-admission"
            try await BrowsingHome.withGeneratedSidebarHome(home, root: root) {
                checkpoint = "native-window-composition"
                let settings = BrowserSettings(persist: false)
                settings.autoRefreshFolders = false; settings.folderSummariesEnabled = false; settings.reviewsRecoveryAtStartup = false
                settings.navigationStyle = .glass; settings.glassFileContent = true; settings.appearance = .dark
                settings.motion = .init(mode: .full)
                InterfacePresentation.shared.bind(settings)
                let owner = BrowserWindowController(settings: settings); controller = owner
                let browser = owner.browser
                browser.readVolumesForVerification = { [] }
                browser.volumes = []
                owner.showWindow(nil)
                guard let window = owner.window else { throw Failure(stage: "window") }
                window.title = "Sidebar · generated review · ordering"
                window.setFrame(.init(x: 80, y: 100, width: 980, height: 680), display: true)
                window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
                browser.rebuildSidebar()
                try await wait("foreground") { browser.sidebarLayout.isActive && browser.pinsController.canEdit }
                try await Task.sleep(for: .milliseconds(300))
                let layout = browser.sidebarLayout, origin = browser.location
                try need(layout.owner === browser.sidebarLayoutOwner && browser.isVerificationSession, "actual-shared-owner")
                guard let places = layout.root(for: .places), let home = places.children?.first,
                      let homeSubject = layout.subject(for: home), let fence = layout.fence() else { throw Failure(stage: "initial-places") }
                let beforeIDs = (places.children ?? []).map(ObjectIdentifier.init)
                let selected = browser.outline.row(forItem: home)
                browser.updatingSidebarSelection = true
                browser.outline.selectRowIndexes(IndexSet(integer: selected), byExtendingSelection: false)
                browser.updatingSidebarSelection = false
                var moved = false
                let move = {
                    guard let current = layout.fence() else { return }
                    moved = layout.move(homeSubject, to: .row(.places, .stored(.place(.downloads))), captured: current)
                }
                if ProcessInfo.processInfo.arguments.contains("--check-development-motion") {
                    let report = try await NativeMotionRecorder.record(window: window, root: root, label: "sidebar-row-move", sampling: .diagnostic(for: window)) {
                        move()
                    }
                    capturedFrames.append(report.frames.count)
                    clips.append(["label": "sidebar-row-move"])
                } else {
                    move()
                }
                try need(moved, "actual-native-row-move")
                try await Task.sleep(for: .milliseconds(220))
                try need(Set(beforeIDs) == Set((places.children ?? []).map(ObjectIdentifier.init)) && layout.root(for: .places) === places,
                         "row-move-retains-all-native-identities")
                try need((browser.outline.item(atRow: browser.outline.selectedRow) as? SidebarNode) === home && browser.location == origin,
                         "selection-preserved-without-navigation")
                try need(!layout.move(homeSubject, to: .row(.places, nil), captured: fence), "stale-fence-refused")
                checks.append("Native row movement preserves nodes, selection and navigation")
                let beforePreference = layout.root(for: .places)
                settings.showsHiddenFiles.toggle()
                try await wait("display-preference-rebuild-not-suppressed") {
                    layout.root(for: .places) !== beforePreference
                }
                checks.append("Display preference changes refresh after a local reorder")
                guard let categoryFence = layout.fence() else { throw Failure(stage: "category-fence") }
                try need(layout.move(.category(.locations), to: .category(.computer), captured: categoryFence), "category-move")
                try await Task.sleep(for: .milliseconds(220))
                try need(layout.visibleSections.first == .locations, "category-native-position")
                checks.append("Category move and stale projection refusal")
                let board = NSPasteboard.withUniqueName(); defer { board.clearContents() }
                board.declareTypes([BrowserSidebarLayoutDragCoordinator.pasteboardType, .fileURL], owner: nil)
                board.setString("invalid", forType: BrowserSidebarLayoutDragCoordinator.pasteboardType)
                board.setString(root.appendingPathComponent("Never materialize").absoluteString, forType: .fileURL)
                let fake = Info(board)
                try need(browser.sidebarLayoutValidateDrop(fake, outline: browser.outline, item: nil, childIndex: 0) == [], "mixed-internal-token-consumed")
                try need(browser.sidebarLayoutAcceptDrop(fake, outline: browser.outline, item: nil, childIndex: 0) == false, "unauthenticated-internal-drop-refused")
                board.clearContents()
                try need(browser.sidebarLayoutValidateDrop(fake, outline: browser.outline, item: nil, childIndex: 0) == nil,
                         "noninternal-routing-preserved")
                checks.append("Internal refusal stays separate from ordinary file drops")
                guard let category = layout.root(for: .places), let menu = layout.drag.appendAlternatives(to: nil, for: category),
                      let collapse = menu.items.first(where: { $0.title == "Collapse Category" }), let action = collapse.action else {
                    throw Failure(stage: "category-accessible-menu")
                }
                try need(collapse.isEnabled && NSApp.sendAction(action, to: collapse.target, from: collapse), "category-menu-action")
                try await Task.sleep(for: .milliseconds(120))
                try need(browser.sidebarLayoutOwner.preferences.collapsed.contains(.places), "category-menu-collapse")
                guard let resetFence = layout.fence() else { throw Failure(stage: "reset-fence") }
                try need(layout.reset(captured: resetFence), "actual-layout-reset")
                try await Task.sleep(for: .milliseconds(160))
                try need(layout.visibleSections.first == .computer && browser.sidebarLayoutOwner.preferences.collapsed.isEmpty,
                         "reset-restores-order-and-expansion")
                rowPresentation = await SidebarLayoutPresentationRegression.run(browser)
                try need(rowPresentation?["passed"] as? Bool == true, "sidebar-item-rendered-agreement")
                checks.append("Actual adapter category, child and menu moves preserve rendered item labels")
                settings.interfaceSize = .init(150); settings.appearance = .light
                try await Task.sleep(for: .milliseconds(220))
                window.contentView?.layoutSubtreeIfNeeded()
                let expectedRowHeight = ceil(CGFloat(27) * 1.5)
                @MainActor func reorderNames(in view: NSView) -> [BrowserSidebarNameView] {
                    if let handle = view as? BrowserSidebarNameView { return [handle] }
                    return view.subviews.flatMap { reorderNames(in: $0) }
                }
                let names = reorderNames(in: browser.outline)
                try need(abs(browser.outline.rowHeight - expectedRowHeight) < 0.01 && !browser.hasPendingFileOperation,
                         "large-interface-and-no-file-work")
                try need(!names.isEmpty && names.allSatisfy { $0.frame.width >= 30 }, "scaled-sidebar-name-targets")
                if let places = layout.root(for: .places) {
                    let expanded = browser.outline.isItemExpanded(places)
                    browser.outline.performNameClick(places, clickCount: 1)
                    try need(browser.outline.isItemExpanded(places) != expanded, "category-name-click")
                    browser.outline.performNameClick(places, clickCount: 1)
                    try need(browser.outline.isItemExpanded(places) == expanded, "category-name-restores")
                } else { throw Failure(stage: "category-missing") }

                checks.append("Accessible category menu, reset and enlarged layout")
                checkpoint = "native-saved-server-order"
                // Display changes refresh the browser's ordinary window title.
                // Restore the generated-capture title after that refresh.
                window.title = "Sidebar · generated review · ordering"
                let serverID = UUID()
                let savedA = try WorkspaceConnectionBookmark(kind: .sftpServer, serverID: serverID,
                    binding: Data(repeating: 1, count: 32), title: "Generated SFTP")
                let savedB = try WorkspaceConnectionBookmark(kind: .smbServer, serverID: serverID,
                    binding: Data(repeating: 2, count: 32), title: "Generated SMB")
                let savedNodes = [savedA, savedB].map {
                    SidebarNode($0.title, icon: "server.rack", children: [], serverBookmark: $0)
                }
                browser.disconnectedServerSnapshot = [savedA, savedB]
                let serverChildren = browser.sidebarLayoutServers(savedNodes, values: [], saved: [savedA, savedB])
                let servers = layout.bindRoot(SidebarNode("Servers", group: true, children: serverChildren), to: .servers)
                browser.sidebarRoots.append(servers); browser.sidebarLayoutOrderRoots()
                browser.outline.reloadData(); layout.restoreExpansion()
                try await wait("server-order-focus") { layout.isActive && layout.owner.canEdit }
                guard let serverSubject = layout.subject(for: savedNodes[0]) else { throw Failure(stage: "saved-server-subject") }
                var serverMoved = false
                let moveServer = {
                    guard let current = layout.fence() else { return }
                    serverMoved = layout.move(serverSubject, to: .row(.servers, nil), captured: current)
                }
                if ProcessInfo.processInfo.arguments.contains("--check-development-motion") {
                    let report = try await NativeMotionRecorder.record(window: window, root: root,
                        label: "sidebar-saved-server-move", sampling: .diagnostic(for: window)) { moveServer() }
                    capturedFrames.append(report.frames.count); clips.append(["label": "sidebar-saved-server-move"])
                } else { moveServer() }
                try need(serverMoved, "native-saved-server-move")
                try await wait("server-native-move-finished") {
                    layout.pendingNativeMoveGenerationForQualification == nil
                        && servers.children?.map(\.title) == [savedB.title, savedA.title]
                }
                try need(await layout.owner.flush() == nil, "server-order-owner-drained")
                try need(browser.location == origin && browser.connectedLocationSnapshot.isEmpty && !browser.hasPendingFileOperation,
                    "server-reorder-started-no-connection-or-operation")
                let keys = [savedA, savedB].map { SidebarLayoutItemKey.server($0.kind, id: $0.serverID) }
                let persistedOrder = try SidebarLayoutPreferences.decode(layout.owner.preferences.encoded())
                try need(try persistedOrder.orderedItems(keys, in: .servers) == [keys[1], keys[0]], "native-server-order-encoded")
                let rebuiltNodes = [savedA, savedB].map {
                    SidebarNode($0.title, icon: "server.rack", children: [], serverBookmark: $0)
                }
                servers.children = browser.sidebarLayoutServers(rebuiltNodes, values: [], saved: [savedA, savedB])
                browser.outline.reloadItem(servers, reloadChildren: true); layout.restoreExpansion()
                try need(servers.children?.map(\.title) == [savedB.title, savedA.title], "server-order-after-row-rebuild")
                browser.disconnectedServerSnapshot = []
                browser.sidebarRoots.removeAll { $0 === servers }; layout.removeRoot(.servers)
                try need(layout.owner.reset(expectedRevision: layout.owner.preferences.revision), "server-order-reset")
                browser.rebuildSidebar()
                checks.append("Native saved-server row move and rebuilt rows keep the encoded order without Connect or file operations")
                if ProcessInfo.processInfo.arguments.contains("--interactive-sidebar-review") {
                    checkpoint = "interactive-sidebar-review"
                    gestureObservation = try await review(owner, root: root)
                    try need(gestureObservation?["passed"] as? Bool == true, "interactive-name-agreement")
                    checks.append("Real native name/drop lifecycle preserves settled row labels")
                }
            }
        } catch { failure = (error as? Failure)?.stage ?? checkpoint }
        if let controller {
            _ = await controller.browser.sidebarLayoutOwner.flush()
            controller.suspendBrowsing(); controller.window?.performClose(nil)
        }
        let drained = ApplicationFileActivity.gate.activeCount == 0
        let windowsClosed = NSApp.windows.allSatisfy { !$0.isVisible }
        if !windowsClosed && failure == nil { failure = "native-window-close" }
        if let scope {
            let value: [String: Any] = ["passed": failure == nil && drained, "checks": checks, "failure": failure ?? "none",
                "activityDrained": drained, "capturedFrames": capturedFrames, "clips": clips, "sourceFileBodiesRead": 0, "fileOperations": 0,
                "privatePreferenceChecks": true,
                "realDragGesture": (gestureObservation?["realStarts"] as? Int ?? 0) > 0 ? "EXERCISED" : "NOT EXERCISED",
                "nativeWindowsClosed": windowsClosed,
                "rowPresentation": rowPresentation ?? ["status": "NOT EXERCISED"], "externalAccessibility": "NOT EXERCISED",
                "gestureObservation": gestureObservation ?? ["status": "NOT EXERCISED"]]
            if let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) {
                try? await Task.detached { try data.write(to: scope.appendingPathComponent("evidence/sidebar-layout-result.json"), options: .withoutOverwriting) }.value
            }
        }
        exit(failure == nil && drained ? 0 : 1)
    }
}
#endif
