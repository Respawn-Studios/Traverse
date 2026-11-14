#if DEBUG
import AppKit
import ExplorerCore
@_spi(Qualification) @testable import LocalStorage

/// Generated metadata only. This exercises the concrete SFTP browser owner and
/// native controls; its actor double proves neither SSH nor SMB transport.
@MainActor enum ConnectionNavigationVerification {
    private typealias Failure = ConnectionQualificationFailure
    private final class BoundaryProbe {
        var admissions = 0
        var observations: [String: Int] = [:]
        var marqueeGeometry: [[String: Any]] = []
    }
    private final class SMBViewportProbe {
        var demand = SMBDirectoryPageDemand()
        var takenOffsets: [Int64] = []
        func take() -> SMBDirectoryPageDemand.Key? {
            guard let key = demand.take() else { return nil }
            takenOffsets.append(key.offset); return key
        }
    }
    private static func require(_ value: Bool, _ stage: String) throws {
        if !value { throw Failure.stage(stage) }
    }
    private static func wait(_ stage: String, _ value: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 8
        while !value() {
            try require(ProcessInfo.processInfo.systemUptime < deadline, stage)
            try await Task.sleep(for: .milliseconds(5))
        }
    }
    private static func argument(_ name: String) -> String? {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
        return args[index + 1]
    }
    private static func key(_ text: String, code: UInt16, window: NSWindow) throws -> NSEvent {
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code) else {
            throw Failure.stage("native-key-event-unavailable")
        }
        return event
    }
    private static func click(_ row: Int, table: NSTableView, window: NSWindow,
                              modifiers: NSEvent.ModifierFlags = []) throws {
        let rect = table.rect(ofRow: row)
        let point = table.convert(NSPoint(x: 100, y: rect.midY), to: nil)
        func event(_ type: NSEvent.EventType) throws -> NSEvent {
            guard let value = NSEvent.mouseEvent(with: type, location: point, modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else {
                throw Failure.stage("native-selection-event-unavailable")
            }
            return value
        }
        NSApp.postEvent(try event(.leftMouseUp), atStart: true)
        table.mouseDown(with: try event(.leftMouseDown))
    }

    static func run() async {
        var root: URL?, browser: BrowserViewController?, window: NSWindow?, owner: SFTPTabController?
        var composition: BrowserWorkspaceController?, maximumBrowserOwners = 1
        var transport: Transport?, checks: [String] = [], failure: String?, phase = "unadmitted"
        var actualSessionExit = false, actualSessionEOF = false
        let boundary = BoundaryProbe()
        do {
            let args = ProcessInfo.processInfo.arguments
            guard args.filter({ $0 == "--verify-ui" }).count == 1,
                  args.filter({ $0 == "--check-connection-navigation" }).count == 1,
                  let chosen = argument("--connection-phase"), ["address", "find", "selection", "persistence", "completion", "escape", "viewport", "pin-readiness"].contains(chosen),
                  let raw = ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"] else {
                throw Failure.stage("scope-arguments")
            }
            phase = chosen
            let admitted = URL(fileURLWithPath: raw)
            let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let marker = try JSONSerialization.jsonObject(with: Data(contentsOf: admitted.appendingPathComponent("reservation.json"))) as? [String: Any]
            let admission = try JSONSerialization.jsonObject(with: Data(contentsOf: admitted.appendingPathComponent("packet-admission.json"))) as? [String: Any]
            try require(admitted.resolvingSymlinksInPath() == admitted
                && admitted.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-development")
                && UUID(uuidString: admitted.lastPathComponent)?.uuidString == admitted.lastPathComponent
                && marker?["packet"] as? String == "traverse-development-v1"
                && marker?["action"] as? String == "connection-navigation-v1"
                && admission?["master"] as? String == "46F68181-FA2B-4308-8713-7D518F2FF08C"
                && admission?["phase"] as? String == phase
                && Bundle.main.bundleIdentifier == "local.macexplorer.development", "scope-marker")
            root = admitted
            let settings = BrowserSettings(persist: false)
            settings.autoRefreshFolders = false; settings.folderSummariesEnabled = false
            settings.reviewsRecoveryAtStartup = false; settings.showsDockProgress = false
            settings.motion.mode = .off; InterfacePresentation.shared.bind(settings)
            let controller = BrowserViewController(settings: settings); browser = controller
            controller.permitsBackgroundVerification = true
            let host = NSWindow(contentRect: .init(x: 160, y: 140, width: 1100, height: 700),
                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window = host; host.isReleasedWhenClosed = false
            if phase == "selection" {
                let workspace = BrowserWorkspaceController(primaryBrowser: controller); composition = workspace
                host.contentViewController = workspace
            } else { host.contentViewController = controller }
            host.title = "Connection navigation · generated metadata"
            host.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            if let composition {
                try require(composition.splitActive(at: .trailing), "selection-second-pane-not-created")
                maximumBrowserOwners = composition.browsers.count
                try require(maximumBrowserOwners == 2, "selection-browser-owner-bound")
                for value in composition.browsers.values { value.permitsBackgroundVerification = true }
                composition.activate(controller, focus: false)
            }
            let localSpy = LocalPropertiesSpy()
            controller.propertiesController = FilePropertiesWindowController(reader: localSpy, settings: settings, copyPaths: { _ in })
            controller.navigate(to: .directory(admitted.appendingPathComponent("source")))
            try await wait("generated-local-row-before-remote") { controller.displayedEntries.contains { $0.name == "GeneratedMetadataOnly.txt" } }
            controller.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            let actor = Transport(); transport = actor
            let session = SFTPBrowserSession(id: UUID(), transport: actor)
            let address = try SFTPConnectionAddress((phase == "persistence" || phase == "pin-readiness") ? "sftp://generated.invalid" : "sftp://generated.invalid/")
            let draft = try SFTPServerDraft(name: "Generated connection", address: address, account: "generated")
            let startingDirectory = phase == "persistence" ? try SFTPDefaultDirectory(field: "/InitialDefault", root: .server) : nil
            let connection = SFTPTabController(session: session, address: address, title: "Generated connection",
                defaultDirectory: startingDirectory, presentation: draft)
            owner = connection; controller.installSFTPTab(connection)
            try await wait("initial-metadata-page") { connection.rows.cache.retainedCount == 3 && connection.navigationAdmittedForVerification }
            if phase == "persistence" {
                guard case .sftp(let location) = controller.location else { throw Failure.stage("initial-remote-location") }
                try require(controller.remoteAddressText == "/InitialDefault"
                    && connection.navigationDirectory(location)?.root == .server,
                    "saved-default-initial-root-ignored")
                checks.append("Initial saved server-root default opens independently of the original Home sign-in address")
            }
            host.contentView?.layoutSubtreeIfNeeded()
            try require(host.makeFirstResponder(connection.rows.table)
                && host.firstResponder === connection.rows.table, "remote-table-not-focused")
            checks.append("Concrete SFTP owner loaded three generated metadata observations")
            let originalTab = controller.activeID, count = controller.tabs.count, sessionID = connection.session.id
            switch phase {
            case "address":
                connection.rows.table.keyDown(with: try key("l", code: 37, window: host))
                try require(!controller.pathField.isHidden && controller.pathField.currentEditor() != nil
                    && host.firstResponder === controller.pathField.currentEditor(), "remote-address-editor-not-focused")
                checks.append("Actual remote-table Cmd-L focuses the native address field")
                try await qualifyAddress(controller, owner: connection, window: host, transport: actor)
                checks.append("Same-owner address/Back/Forward/Up/native ancestor menu preserve exact Home/server/literal paths; foreign endpoints and unsafe paths refuse before transport")
            case "find":
                connection.rows.table.keyDown(with: try key("f", code: 3, window: host))
                let field = controller.folderFilter.displayedField
                try require(field.isEnabled && field.currentEditor() != nil
                    && host.firstResponder === field.currentEditor(), "remote-find-editor-not-focused")
                checks.append("Actual remote-table Cmd-F focuses the native current-folder Find field")
                try await qualifyFind(controller, owner: connection, window: host, transport: actor, probe: boundary)
                checks.append("Current-folder Find reaches beyond512 cached names, preserves original observations and literal Unicode behavior, coalesces held queries without reconnecting, clears with Escape, and rejects delayed navigation; SMB query/cache projection also qualified")
            case "completion":
                try await qualifyCompletion(controller, owner: connection, window: host, probe: boundary)
                checks.append("Native remote editor reactivation and published address preferences admit zero local completion requests; refusal interceptor prevents all local metadata work")
            case "escape":
                try await qualifyEscape(controller, owner: connection, window: host, probe: boundary)
                checks.append("Actual remote Find field-editor Escape clears the remote query/text and restores observed rows without local filter mutation or ordering")
            case "viewport":
                try await qualifyViewport(controller, owner: connection, window: host, transport: actor, probe: boundary)
                checks.append("Actual SFTP and SMB viewport boundary/LRU refill and repeated demand stay within two cached pages; full-folder Find is exercised separately in the Find phase")
            case "selection":
                try click(0, table: connection.rows.table, window: host)
                try click(2, table: connection.rows.table, window: host, modifiers: .shift)
                try require(connection.rows.table.selectedRowIndexes == IndexSet(integersIn: 0...2),
                    "remote-multiple-selection-disabled")
                checks.append("Native remote-table Shift-click selects the three observed rows")
                if let composition, let other = composition.browsers.values.first(where: { $0 !== controller }) { composition.activate(other, focus: false) }
                try await qualifyMarquee(connection, window: host, probe: boundary)
                try require(controller.workspace?.activeBrowser === controller, "remote-marquee-did-not-activate-owning-pane")
                try require(connection.rows.selectedDownload == nil && connection.rows.selectedFolderDownload == nil
                    && controller.observedRemoteItem == nil, "multiple-selection-gained-single-transfer-authority")
                checks.append("Actual gutter/drag/up responder draws a band and selects loaded rows; multiple selection grants no one-item transfer or local-file authority")
            case "persistence":
                checks += try await ConnectionPersistenceVerification.run(root: admitted, browser: controller, owner: connection)
            case "pin-readiness":
                checks += try await ConnectionPersistenceVerification.runPinReadiness(root: admitted, browser: controller, owner: connection)
            default: throw Failure.stage("scope-phase")
            }
            try require(controller.activeID == originalTab && controller.tabs.count == count
                && connection.session.id == sessionID && controller.sftpTabs[originalTab] === connection,
                "same-connection-owner-changed")
            try require(controller.orderedSelectedURLs.isEmpty, "remote-selection-gained-local-url-authority")
            for action in [#selector(BrowserViewController.trashSelection(_:)), #selector(BrowserViewController.renameSelection(_:)),
                #selector(BrowserViewController.duplicateSelection(_:)), #selector(BrowserViewController.showQuickLook(_:)),
                #selector(BrowserViewController.copyFileURLs(_:)), #selector(BrowserViewController.pasteFileURLs(_:))] {
                try require(!controller.commandEnabled(action, synchronizingClipboard: false), "remote-enabled-hidden-local-row-command")
            }
            controller.showProperties(nil)
            try require(await localSpy.count() == 0, "remote-properties-read-hidden-local-row")
            checks.append("Actual generated local rows preceded the remote tab; local operation eligibility stays denied and the local Properties reader observes zero calls")
        } catch Failure.stage(let stage) { failure = stage }
        catch { failure = "unexpected-" + String(describing: type(of: error)) }

        var presentation: [String: Any] = [:]
        if let owner {
            let visible = owner.rows.table.rows(in: owner.rows.table.visibleRect)
            presentation = ["loadedRows": owner.rows.cache.retainedCount, "tableRows": owner.rows.table.numberOfRows,
                "visibleRowStart": visible.location == NSNotFound ? -1 : visible.location,
                "visibleRowLength": visible.length, "pendingPages": owner.hasPendingPages,
                "cacheMatchesCurrentGeneration": owner.rows.cache.generation == owner.session.latest.generation]
        }
        // A failed assertion still joins the actual concrete owner's close task.
        if let owner {
            let result = await owner.close().value
            actualSessionExit = result.actualExit; actualSessionEOF = result.ipcEOF
        }
        composition?.isClosing = true
        maximumBrowserOwners = max(maximumBrowserOwners, composition?.browsers.count ?? 0)
        if let composition { for value in composition.browsers.values { value.suspendBrowser() } }
        else { browser?.suspendBrowser() }
        window?.contentViewController = nil; window?.close()
        browser = nil; owner = nil; window = nil; composition = nil
        let activityDeadline = ProcessInfo.processInfo.systemUptime + 3
        while ApplicationFileActivity.gate.activeCount != 0 && ProcessInfo.processInfo.systemUptime < activityDeadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        let counts = await transport?.counts() ?? [0, 0, 0]
        let drained = actualSessionExit && actualSessionEOF && counts[2] == 1
            && ApplicationFileActivity.gate.activeCount == 0 && ConnectionPersistenceVerification.pinReadinessLoadDrained
        if !drained && failure == nil { failure = "actual-session-activity-drain" }
        if let root {
            let report: [String: Any] = ["passed": failure == nil, "failureStage": failure as Any? ?? NSNull(),
                "phase": phase, "checks": checks, "boundaryObservations": boundary.observations, "marqueeGeometry": boundary.marqueeGeometry,
                "pinAdmissionObservations": ConnectionPersistenceVerification.pinAdmissionObservations,
                "pinReadinessLoadDrained": ConnectionPersistenceVerification.pinReadinessLoadDrained, "actualSessionExit": actualSessionExit,
                "actualSessionEOF": actualSessionEOF, "transportCounts": counts, "actualSessionDrain": drained,
                "activityAfter": ApplicationFileActivity.gate.activeCount, "maximumBrowserOwners": maximumBrowserOwners,
                "networkRequests": 0, "keychainCalls": 0, "bodyReads": 0, "personalFiles": 0,
                "sftpProof": "Concrete session/controller with generated actor transport; no SSH security proof",
                "smbLiveOwnerExercised": false, "physicalKeyboardExercised": false]
            var final = report; final["presentationBeforeCleanup"] = presentation
            try? JSONSerialization.data(withJSONObject: final, options: [.prettyPrinted, .sortedKeys])
                .write(to: root.appendingPathComponent("evidence/native-connection-navigation.json"), options: .withoutOverwriting)
        }
        NSApp.terminate(nil)
    }

    private static func enter(_ text: String, browser: BrowserViewController, owner: SFTPTabController, window: NSWindow) throws {
        browser.cancelLocationEditing(); try require(window.makeFirstResponder(owner.rows.table), "navigation-table-focus")
        owner.rows.table.keyDown(with: try key("l", code: 37, window: window))
        try require(browser.pathField.currentEditor() != nil, "remote-address-editor-not-focused")
        browser.pathField.stringValue = text
        try require(browser.pathField.sendAction(browser.pathField.action, to: browser.pathField.target), "native-address-action-not-dispatched")
    }
    private static func qualifyCompletion(_ browser: BrowserViewController, owner: SFTPTabController,
                                          window: NSWindow, probe: BoundaryProbe) async throws {
        let completion = browser.addressCompletion
        // This probe refuses before request parsing, Home resolution, access
        // acquisition, remembered-name lookup, Spotlight or directory I/O.
        completion.localAdmissionForVerification = { [probe] in probe.admissions += 1; return false }
        defer { completion.cancel(); completion.localAdmissionForVerification = nil; browser.cancelLocationEditing() }
        owner.rows.table.keyDown(with: try key("l", code: 37, window: window))
        guard let editor = browser.pathField.currentEditor() as? NSTextView else {
            throw Failure.stage("completion-remote-editor-not-focused")
        }
        editor.string = "GeneratedRemoteFolder"
        browser.pathField.stringValue = editor.string
        editor.setSelectedRange(.init(location: editor.string.utf16.count, length: 0))
        completion.cancel()
        let auxiliary = NSWindow(contentRect: .init(x: 210, y: 180, width: 240, height: 100),
            styleMask: [.titled], backing: .buffered, defer: false)
        auxiliary.isReleasedWhenClosed = false; auxiliary.title = "Generated activation control"
        defer { auxiliary.close() }
        auxiliary.makeKeyAndOrderFront(nil)
        let previous = completion.resumeInvocationsForVerification
        probe.admissions = 0
        window.makeKeyAndOrderFront(nil)
        try await wait("completion-reactivation-callback-not-delivered") {
            completion.resumeInvocationsForVerification > previous
        }
        try require(browser.pathField.currentEditor() === editor && window.firstResponder === editor,
                    "completion-reactivation-replaced-editor")
        probe.observations["reactivationLocalAdmissions"] = probe.admissions
        probe.observations["reactivationLocalWorkRetained"] = completion.hasLocalWorkForVerification ? 1 : 0
        completion.cancel(); probe.admissions = 0
        let beforeSettings = completion.changedInvocationsForVerification
        browser.settings.addressSuggestionLimit = browser.settings.addressSuggestionLimit == 8 ? 9 : 8
        try await wait("completion-settings-callback-not-delivered") {
            completion.changedInvocationsForVerification > beforeSettings
        }
        probe.observations["settingsLocalAdmissions"] = probe.admissions
        probe.observations["settingsLocalWorkRetained"] = completion.hasLocalWorkForVerification ? 1 : 0
        probe.observations["localMetadataRequestsExecuted"] = 0
        try require(probe.observations["reactivationLocalAdmissions"] == 0
                    && probe.observations["settingsLocalAdmissions"] == 0,
                    "remote-address-completion-local-admission")
        try require(!completion.hasLocalWorkForVerification && completion.suggestions.isEmpty && completion.result == nil,
                    "remote-address-completion-retained-local-work")
    }

    private static func qualifyEscape(_ browser: BrowserViewController, owner: SFTPTabController,
                                      window: NSWindow, probe: BoundaryProbe, query: String = "Report", expectedRows: Int = 3, expectedMatches: Int = 1) async throws {
        try require(window.makeFirstResponder(owner.rows.table), "escape-table-focus")
        owner.rows.table.keyDown(with: try key("f", code: 3, window: window))
        let field = browser.folderFilter.displayedField
        guard field === browser.filterField, let editor = field.currentEditor() as? NSTextView else {
            throw Failure.stage("escape-remote-find-editor-not-focused")
        }
        editor.selectAll(nil)
        editor.insertText(query, replacementRange: .init(location: 0, length: editor.string.utf16.count))
        try await wait("escape-generated-query-not-established") {
            owner.rows.findQuery == query && field.stringValue == query && owner.rows.table.numberOfRows == expectedMatches && !owner.hasPendingPages
        }
        let previousFilter = browser.tabs[browser.activeIndex].filter, previousOrder = browser.orderRevision
        // AppKit's actual field-editor delegate command, without copied clear logic.
        let handled = browser.control(field, textView: editor,
                                      doCommandBy: #selector(NSResponder.cancelOperation(_:)))
        probe.observations["escapeHandled"] = handled ? 1 : 0
        probe.observations["remoteQueryRemainingBytes"] = owner.rows.findQuery.utf8.count
        probe.observations["fieldRemainingBytes"] = field.stringValue.utf8.count
        probe.observations["rowsAfterEscape"] = owner.rows.table.numberOfRows
        probe.observations["localOrderingRequests"] = browser.orderRevision - previousOrder
        probe.observations["localFilterChanged"] = browser.tabs[browser.activeIndex].filter == previousFilter ? 0 : 1
        try require(handled && owner.rows.findQuery.isEmpty && field.stringValue.isEmpty
                    && owner.rows.table.numberOfRows == expectedRows, "remote-find-escape-retained-query")
        try require(browser.tabs[browser.activeIndex].filter == previousFilter && browser.orderRevision == previousOrder,
                    "remote-find-escape-invoked-local-ordering")
    }

    private static func qualifyAddress(_ browser: BrowserViewController, owner: SFTPTabController, window: NSWindow, transport: Transport) async throws {
        let root = browser.location
        try enter("/Folder", browser: browser, owner: owner, window: window)
        try await wait("address-folder-read") { owner.navigationAdmittedForVerification && browser.remoteAddressText == "/Folder" && owner.rows.cache.retainedCount == 3 }
        let folder = browser.location
        browser.goBack(nil)
        try await wait("address-back") { browser.location == root && owner.navigationAdmittedForVerification && owner.rows.cache.retainedCount == 3 }
        try require(!browser.tabs[browser.activeIndex].canGoBack, "address-added-double-history")
        browser.goForward(nil)
        try await wait("address-forward") { browser.location == folder && owner.navigationAdmittedForVerification && owner.rows.cache.retainedCount == 3 }
        browser.goUp(nil)
        try await wait("address-up") { browser.location == root && owner.navigationAdmittedForVerification && owner.rows.cache.retainedCount == 3 }
        try enter("sftp://generated.invalid/Literal%25%3F%23", browser: browser, owner: owner, window: window)
        try await wait("address-literal-read") { browser.remoteAddressText == "/Literal%?#" && owner.navigationAdmittedForVerification && owner.rows.cache.retainedCount == 3 }
        try require(await transport.lastPath() == "/Literal%?#", "address-double-decoded-literal")
        try enter("~/Home/Deeper", browser: browser, owner: owner, window: window)
        try await wait("home-relative-read") { browser.remoteAddressText == "~/Home/Deeper" && owner.navigationAdmittedForVerification && owner.rows.cache.retainedCount == 3 }
        try require(await transport.lastPath() == "./Home/Deeper", "home-path-became-absolute")
        let before = browser.location, calls = await transport.counts()
        for input in ["sftp://different.generated.invalid/Folder", "/Folder/../Other", "/Bad\nFolder", "/" + String(repeating: "x", count: 8193)] {
            try enter(input, browser: browser, owner: owner, window: window)
            try require(browser.location == before, "invalid-address-navigated")
        }
        try require(await transport.counts() == calls, "invalid-address-reached-transport")
        browser.cancelLocationEditing()
        let deep = "~/" + (0..<12).map { "GeneratedLongFolder" + String($0) }.joined(separator: "/")
        try enter(deep, browser: browser, owner: owner, window: window)
        try await wait("deep-native-breadcrumb") { owner.navigationAdmittedForVerification && owner.rows.cache.retainedCount == 3 && !browser.pathControl.hiddenAncestors.isEmpty }
        guard let index = browser.pathControl.hiddenAncestors.first, let menu = browser.pathControl.ancestorMenu() else {
            throw Failure.stage("native-ancestor-menu-missing")
        }
        let target = browser.pathControl.locations[index]
        menu.performActionForItem(at: 0)
        try await wait("native-ancestor-action") { browser.location == target && owner.navigationAdmittedForVerification && owner.rows.cache.retainedCount == 3 }
    }
    private static func qualifyFind(_ browser: BrowserViewController, owner: SFTPTabController, window: NSWindow, transport: Transport, probe: BoundaryProbe) async throws {
        browser.folderFilter.contextWillChange()
        try enter("/Large", browser: browser, owner: owner, window: window)
        try await wait("find-first-page") { owner.rows.cache.retainedCount == 256 && owner.navigationAdmittedForVerification }
        owner.rows.table.scrollRowToVisible(270); owner.rows.requestVisiblePage()
        try await wait("find-second-page") { owner.rows.cache.retainedCount == 512 && owner.navigationAdmittedForVerification }
        try require(window.makeFirstResponder(owner.rows.table), "find-table-focus")
        owner.rows.table.keyDown(with: try key("f", code: 3, window: window))
        let field = browser.folderFilter.displayedField
        guard let editor = field.currentEditor() as? NSTextView else { throw Failure.stage("remote-find-editor-not-focused") }
        let before = await transport.counts()
        editor.selectAll(nil)
        editor.insertText("Needle", replacementRange: .init(location: 0, length: editor.string.utf16.count))
        try await wait("find-full-catalog-count") { owner.rows.table.numberOfRows == 2 && owner.rows.cache.entry(at: 0) != nil && !owner.hasPendingPages }
        browser.folderFilter.synchronize()
        try require(browser.folderFilter.button.accessibilityValue() as? String == "Needle"
            && browser.folderFilter.button.accessibilityHelp()?.contains("this folder only") == true,
            "remote-find-compact-button-retained-local-scope-or-value")
        owner.rows.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        try require(owner.rows.selectedObservation?.observation == 258, "find-offset-became-observation")
        editor.selectAll(nil)
        editor.insertText("UnloadedNeedle", replacementRange: .init(location: 0, length: editor.string.utf16.count))
        try await wait("find-beyond-cache") { owner.rows.table.numberOfRows == 1 && owner.rows.cache.entry(at: 0)?.observation == 701 && !owner.hasPendingPages }
        owner.rows.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        try require(owner.rows.selectedObservation?.observation == 701 && owner.rows.cache.snapshot?.count == 768
            && owner.rows.cache.displayCount == 1 && owner.rows.cache.retainedCount <= 512, "find-replaced-source-snapshot-or-identity")
        owner.setLoadedNameQuery("%_[]*")
        try await wait("find-literal-metacharacters") { owner.rows.cache.find?.count == 1 && owner.rows.cache.entry(at: 0)?.observation == 702 && !owner.hasPendingPages }
        owner.setLoadedNameQuery("CAFÉ")
        try await wait("find-unicode-lowercase") { owner.rows.cache.find?.count == 1 && owner.rows.cache.entry(at: 0)?.observation == 703 && !owner.hasPendingPages }
        let composedID = owner.rows.findRequest?.id
        owner.setLoadedNameQuery("Cafe\u{301}")
        try await wait("find-unicode-form-distinction") { owner.rows.findRequest?.id != composedID && owner.rows.cache.find?.count == 1 && owner.rows.cache.entry(at: 0)?.observation == 704 && !owner.hasPendingPages }
        owner.setLoadedNameQuery("")
        try await wait("find-clear") { owner.rows.findQuery.isEmpty && owner.rows.table.numberOfRows == 768 && owner.navigationAdmittedForVerification }
        browser.folderFilter.synchronize()
        try require(browser.folderFilter.button.accessibilityValue() as? String == "No name filter",
            "remote-find-compact-button-retained-cleared-query")
        try await qualifyEscape(browser, owner: owner, window: window, probe: probe, query: "Needle", expectedRows: 768, expectedMatches: 2)
        try await wait("find-escape-drain") { owner.navigationAdmittedForVerification }

        await transport.holdNextFind(); owner.setLoadedNameQuery("Needle")
        var deadline = ProcessInfo.processInfo.systemUptime + 5
        while !(await transport.findHeld()) { try require(ProcessInfo.processInfo.systemUptime < deadline, "find-rpc-not-held"); try await Task.sleep(for: .milliseconds(5)) }
        let retiredID = owner.rows.findRequest?.id
        owner.setLoadedNameQuery("UnloadedNeedle"); owner.setLoadedNameQuery("Needle")
        let latestID = owner.rows.findRequest?.id
        try require(latestID != retiredID && owner.rows.table.numberOfRows == 0 && owner.rows.selectedObservation == nil && owner.hasPendingPages,
            "find-aba-retained-retired-results")
        await transport.releaseFind()
        try await wait("find-latest-query-drain") { owner.rows.cache.find?.query.id == latestID && owner.rows.table.numberOfRows == 2 && owner.rows.cache.entry(at: 0) != nil && owner.navigationAdmittedForVerification }
        owner.rows.table.sortDescriptors = [NSSortDescriptor(key: "size", ascending: false)]
        try await wait("find-sort-preserved") { owner.rows.lastPageSort == .size && owner.rows.lastPageDescending == true && owner.rows.cache.entry(at: 0)?.observation == 701 && owner.navigationAdmittedForVerification }
        owner.rows.table.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]
        try await wait("find-name-sort-restored") { owner.rows.lastPageSort == .name && owner.rows.lastPageDescending == false && owner.navigationAdmittedForVerification }
        owner.setLoadedNameQuery(""); try await wait("find-normal-before-held-clear") { owner.navigationAdmittedForVerification }
        await transport.holdNextFind(); owner.setLoadedNameQuery("Needle")
        deadline = ProcessInfo.processInfo.systemUptime + 5
        while !(await transport.findHeld()) { try require(ProcessInfo.processInfo.systemUptime < deadline, "clear-find-rpc-not-held"); try await Task.sleep(for: .milliseconds(5)) }
        owner.setLoadedNameQuery("")
        try require(owner.rows.table.numberOfRows == 768 && owner.rows.cache.find == nil && owner.hasPendingPages, "clear-cancelled-or-retained-find")
        await transport.releaseFind()
        try await wait("clear-old-find-drain") { owner.rows.findQuery.isEmpty && owner.rows.cache.find == nil && owner.navigationAdmittedForVerification }
        let after = await transport.counts()
        let findCalls = await transport.findCalls()
        try require(after[0] == before[0] && after[2] == before[2] && findCalls > 0,
            "find-navigated-or-closed-connection")
        probe.observations["fullFolderFindReachedObservation701"] = 1
        probe.observations["findOriginalSnapshotCount"] = Int(owner.rows.cache.snapshot?.count ?? 0)
        probe.observations["findConnectionCloses"] = after[2] - before[2]
        probe.observations["findMaximumRetainedRows"] = owner.rows.cache.retainedCount

        let smb = SMBRemoteRowsView(frame: .init(x: 0, y: 0, width: 700, height: 300))
        let snapshot = SMBDirectorySnapshot(readID: UUID(), revision: 1, count: 768, folders: 0, state: .complete)
        smb.observe(snapshot); smb.setFindQuery("Needle")
        guard let query = smb.findRequest else { throw Failure.stage("smb-find-query-missing") }
        let result = try SMBDirectoryFindResult(query: query, snapshot: snapshot, count: 2, folders: 0)
        try smb.acceptFind(result)
        let entries = try [SMBDirectoryObservation(id: 258, name: .init("Needle"), attributes: 0, logicalBytes: 257, modifiedFileTime: 0),
            SMBDirectoryObservation(id: 701, name: .init("UnloadedNeedle"), attributes: 0, logicalBytes: 700, modifiedFileTime: 0)]
        try smb.accept(.init(request: .init(snapshot: snapshot, offset: 0, find: result), entries: entries))
        smb.table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        try require(smb.table.numberOfRows == 2 && smb.selectedObservation?.id == 701 && smb.cache.snapshot?.count == 768, "smb-filtered-observation-identity")
        let partial = SMBDirectorySnapshot(readID: UUID(), revision: 1, count: 1, folders: 0, state: .partial)
        smb.observe(partial)
        try require(smb.selectedObservation == nil && smb.table.numberOfRows == 0, "smb-find-retained-stale-row")
        do { try smb.acceptFind(result); throw Failure.stage("smb-old-find-result-accepted") }
        catch RemoteDirectoryFindFailure.stale { }
        guard let partialQuery = smb.findRequest else { throw Failure.stage("smb-partial-find-query-missing") }
        try smb.acceptFind(.init(query: partialQuery, snapshot: partial, count: 0, folders: 0))
        try require(smb.message.stringValue.contains("incomplete") && smb.findStatusText?.contains("observed") == true, "smb-partial-zero-claimed-complete")

        try enter("/Large", browser: browser, owner: owner, window: window)
        try await wait("held-page-first-load") { owner.rows.cache.retainedCount >= 256 && owner.navigationAdmittedForVerification }
        await transport.holdNextPage(); owner.rows.invalidatePages(); owner.rows.requestVisiblePage()
        deadline = ProcessInfo.processInfo.systemUptime + 5
        while !(await transport.pageHeld()) { try require(ProcessInfo.processInfo.systemUptime < deadline, "delayed-page-not-held"); try await Task.sleep(for: .milliseconds(5)) }
        try enter("/AfterDelayedPage", browser: browser, owner: owner, window: window)
        await transport.releasePage()
        try await wait("delayed-page-navigation-drain") {
            owner.navigationAdmittedForVerification && browser.remoteAddressText == "/AfterDelayedPage" && owner.rows.cache.retainedCount == 3
                && owner.rows.cache.generation == owner.session.latest.generation
        }
        try require(owner.rows.table.numberOfSelectedRows == 0 && owner.rows.findQuery.isEmpty, "navigation-retained-filter-or-selection")
    }
    private static func qualifyViewport(_ browser: BrowserViewController, owner: SFTPTabController,
                                        window: NSWindow, transport: Transport, probe: BoundaryProbe) async throws {
        try enter("/Large", browser: browser, owner: owner, window: window)
        try await wait("viewport-initial-page") { owner.navigationAdmittedForVerification && owner.rows.cache.retainedCount == 256 }
        owner.rows.table.scrollRowToVisible(270); owner.rows.requestVisiblePage()
        let crossing = owner.rows.table.rows(in: owner.rows.table.visibleRect)
        try require(crossing.location != NSNotFound && crossing.location < 256
                    && crossing.length > 256 - crossing.location, "viewport-did-not-cross-cached-boundary")
        try await wait("viewport-crossing-page") {
            owner.navigationAdmittedForVerification && owner.rows.cache.retainedCount == 512
                && owner.rows.cache.entry(at: 0) != nil && owner.rows.cache.entry(at: 256) != nil
        }
        let firstPages = await transport.pageOffsets()
        try require(firstPages == [0, 0, 256], "viewport-crossing-duplicate-or-wrong-page")
        await transport.holdNextPage()
        owner.rows.table.scrollRowToVisible(600); owner.rows.requestVisiblePage()
        let heldDeadline = ProcessInfo.processInfo.systemUptime + 5
        while !(await transport.pageHeld()) {
            try require(ProcessInfo.processInfo.systemUptime < heldDeadline, "viewport-page-not-held")
            try await Task.sleep(for: .milliseconds(5))
        }
        for _ in 0..<16 { owner.rows.requestVisiblePage() }
        try require(await transport.pageOffsets() == [0, 0, 256, 512], "viewport-active-demand-not-coalesced")
        await transport.releasePage()
        try await wait("viewport-later-page") {
            owner.navigationAdmittedForVerification && owner.rows.cache.entry(at: 512) != nil
                && owner.rows.cache.entry(at: 0) == nil && owner.rows.cache.retainedCount == 512
        }
        try require(await transport.pageOffsets() == [0, 0, 256, 512], "viewport-later-page-flood")
        owner.rows.table.scrollRowToVisible(244); owner.rows.requestVisiblePage()
        try await wait("viewport-return-refill") {
            owner.navigationAdmittedForVerification && owner.rows.cache.entry(at: 0) != nil
                && owner.rows.cache.entry(at: 256) != nil && owner.rows.cache.entry(at: 512) == nil
                && owner.rows.cache.retainedCount == 512
        }
        let afterReturn = await transport.counts()
        for _ in 0..<16 { owner.rows.requestVisiblePage() }
        try await wait("viewport-repeat-demand-drain") { owner.navigationAdmittedForVerification }
        try require(await transport.counts() == afterReturn, "viewport-cached-demand-read-again")
        try require(await transport.pageOffsets() == [0, 0, 256, 512, 0, 256], "viewport-return-not-bounded-two-pages")
        probe.observations["sftpMaximumRetainedRows"] = owner.rows.cache.retainedCount
        probe.observations["sftpActualPageCalls"] = afterReturn[1]
        try qualifySMBViewport(probe: probe)
        window.makeKeyAndOrderFront(nil)
    }

    private static func qualifySMBViewport(probe: BoundaryProbe) throws {
        let rows = SMBRemoteRowsView(frame: .init(x: 0, y: 0, width: 800, height: 360))
        let host = NSWindow(contentRect: .init(x: 190, y: 170, width: 800, height: 360),
            styleMask: [.titled], backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false; host.title = "Generated SMB metadata viewport"
        host.contentView = rows; host.orderFront(nil)
        let queue = SMBViewportProbe()
        rows.onPage = { [weak rows, queue] offset in
            guard let rows, let snapshot = rows.cache.snapshot,
                  let key = try? SMBDirectoryPageDemand.Key(snapshot: snapshot, offset: offset, sort: .name, descending: false) else { return }
            queue.demand.request(key, alreadyCached: rows.cache.entry(at: offset) != nil)
        }
        defer { rows.onPage = nil; queue.demand.clear(); host.contentView = nil; host.close() }
        let snapshot = SMBDirectorySnapshot(readID: UUID(), revision: 1, count: 768, folders: 0, state: .complete)
        var generatedRows: [SMBDirectoryObservation] = []
        generatedRows.reserveCapacity(768)
        for index in 0..<768 {
            let label: String
            if index == 257 { label = "Needle" }
            else if index == 700 { label = "UnloadedNeedle" }
            else { label = String(format: "Row%04d", index) }
            let name = try SMBRemoteName(label)
            let identifier: Int64 = Int64(index) + 1
            let attributes: UInt32 = 0
            let logicalBytes: UInt64 = 0
            let modifiedFileTime: UInt64 = 0
            generatedRows.append(SMBDirectoryObservation(id: identifier, name: name,
                attributes: attributes, logicalBytes: logicalBytes, modifiedFileTime: modifiedFileTime))
        }
        generatedRows.sort { left, right in left.name.displayName < right.name.displayName }
        let allRows: [SMBDirectoryObservation] = generatedRows
        func take(_ expected: Int64) throws -> SMBDirectoryPageDemand.Key {
            guard let key = queue.take(), key.offset == expected else { throw Failure.stage("smb-viewport-wrong-demand") }
            for _ in 0..<16 { rows.requestVisiblePage() }
            try require(!queue.demand.hasQueued, "smb-viewport-duplicate-active-demand")
            return key
        }
        func accept(_ key: SMBDirectoryPageDemand.Key) throws {
            let start = Int(key.offset), end = min(768, start + 256)
            try rows.accept(.init(request: try .init(snapshot: key.snapshot, offset: key.offset,
                sort: key.sort, descending: key.descending), entries: Array(allRows[start..<end])))
            queue.demand.finish(key)
            try require(rows.cache.retainedCount <= 512, "smb-viewport-cache-quota")
        }
        rows.observe(snapshot); host.contentView?.layoutSubtreeIfNeeded()
        try accept(take(0))
        rows.table.scrollRowToVisible(260); rows.requestVisiblePage()
        let crossing = rows.table.rows(in: rows.table.visibleRect)
        try require(crossing.location != NSNotFound && crossing.location < 256
                    && crossing.length > 256 - crossing.location, "smb-viewport-not-crossing-boundary")
        try accept(take(256))
        try require(rows.cache.retainedCount == 512 && !queue.demand.hasQueued, "smb-viewport-crossing-not-loaded")
        rows.table.scrollRowToVisible(600); rows.requestVisiblePage()
        try accept(take(512))
        rows.table.scrollRowToVisible(244); rows.requestVisiblePage()
        try accept(take(0)); try accept(take(256))
        for _ in 0..<16 { rows.requestVisiblePage() }
        try require(!queue.demand.hasQueued && rows.cache.entry(at: 0) != nil
                    && rows.cache.entry(at: 256) != nil && rows.cache.entry(at: 512) == nil
                    && queue.takenOffsets == [0, 256, 512, 0, 256], "smb-viewport-return-not-bounded")
        probe.observations["smbMaximumRetainedRows"] = rows.cache.retainedCount
        probe.observations["smbTakenPageDemands"] = queue.takenOffsets.count
    }

    private static func qualifyMarquee(_ owner: SFTPTabController, window: NSWindow, probe: BoundaryProbe) async throws {
        guard let marquee = owner.rows.table.marquee else { throw Failure.stage("remote-marquee-owner-missing") }
        owner.rows.table.deselectAll(nil); window.contentView?.layoutSubtreeIfNeeded()
        let margin = marquee.verificationState.margin
        try require(margin.bounds.width >= 12 && !margin.isHiddenOrHasHiddenAncestor, "remote-marquee-gutter-unusable")
        let startRow = owner.rows.table.rect(ofRow: 0), endRow = owner.rows.table.rect(ofRow: 2)
        let x = margin.convert(.init(x: margin.bounds.midX, y: margin.bounds.midY), to: nil).x
        let first = owner.rows.table.convert(.init(x: 0, y: startRow.minY + 2), to: nil)
        let last = owner.rows.table.convert(.init(x: 0, y: endRow.midY), to: nil)
        func event(_ type: NSEvent.EventType, _ point: NSPoint) throws -> NSEvent {
            guard let value = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { throw Failure.stage("marquee-event-missing") }
            return value
        }
        let initialDraws = marquee.verificationState.draws
        margin.mouseDown(with: try event(.leftMouseDown, .init(x: x, y: first.y)))
        margin.mouseDragged(with: try event(.leftMouseDragged, .init(x: x + 50, y: last.y)))
        var before = marquee.verificationGeometry; before["stage"] = "after-drag-before-paint-turn"
        probe.marqueeGeometry.append(before)
        defer {
            var after = marquee.verificationGeometry; after["stage"] = "after-bounded-paint-observation"
            probe.marqueeGeometry.append(after)
        }
        try require(marquee.verificationState.active && marquee.verificationState.rectangle != nil, "remote-marquee-band-missing")
        let paintDeadline = ProcessInfo.processInfo.systemUptime + 0.5
        while marquee.verificationState.draws <= initialDraws {
            try require(marquee.verificationState.active && marquee.verificationState.rectangle != nil,
                        "remote-marquee-band-retired-before-paint")
            try require(ProcessInfo.processInfo.systemUptime < paintDeadline, "remote-marquee-band-not-drawn")
            // Let the real AppKit display transaction paint the active overlay.
            // Never call draw/display/raster methods or alter its counter.
            try await Task.sleep(for: .milliseconds(5))
        }
        try require(marquee.verificationState.draws > initialDraws, "remote-marquee-band-not-drawn")
        margin.mouseUp(with: try event(.leftMouseUp, .init(x: x + 50, y: last.y)))
        try require(owner.rows.table.selectedRowIndexes == IndexSet(integersIn: 0...2)
            && !marquee.verificationState.active && !marquee.verificationState.timer, "remote-marquee-selection-or-drain")
    }

    private actor Transport: SFTPDirectoryTransport {
        private var generation = UUID()
        private var opens = 0, pages = 0, closes = 0, finds = 0
        private var paths: [String] = [], pageHistory: [UInt64] = [], holding = false, closed = false
        private var held: CheckedContinuation<Void, Never>?
        private var holdingFind = false, heldFind: CheckedContinuation<Void, Never>?
        private var selectedFind: SFTPDirectoryFindResult?
        func lastPath() -> String { paths.last ?? "" }
        func pageOffsets() -> [UInt64] { pageHistory }
        func holdNextPage() { if !closed { holding = true } }
        func pageHeld() -> Bool { held != nil }
        func releasePage() { let value = held; held = nil; value?.resume() }
        func counts() -> [Int] { [opens, pages, closes] }
        func findCalls() -> Int { finds }
        func holdNextFind() { if !closed { holdingFind = true } }
        func findHeld() -> Bool { heldFind != nil }
        func releaseFind() { let value = heldFind; heldFind = nil; value?.resume() }
        func openStoredDirectory(_ path: String) async throws -> (UUID, SFTPStoredSnapshot) {
            guard !closed, path.hasPrefix("/") || path == "." || path.hasPrefix("./"), path.utf8.count <= 8192 else { throw Failure.stage("unexpected-generated-path") }
            paths.append(path); generation = UUID(); opens += 1
            return (generation, .init(read: UInt64(opens), revision: 1, count: path == "/Large" ? 768 : 3, folders: 1, state: .complete))
        }
        func ingestNext(_ generation: UUID) async throws -> SFTPStoredSnapshot { throw Failure.stage("unexpected-ingest") }
        private func metadataRows(_ snapshot: SFTPStoredSnapshot) throws -> [SFTPStoredRow] {
            guard [3, 768].contains(snapshot.count) else { throw Failure.stage("unexpected-generated-count") }
            return try (0..<Int(snapshot.count)).map { index in
                let name: String
                if snapshot.count == 3 { name = ["Folder", "Report.txt", "Third.txt"][index] }
                else {
                    switch index {
                    case 0: name = "Folder"
                    case 257: name = "Needle"
                    case 700: name = "UnloadedNeedle"
                    case 701: name = "Literal%_[]*.txt"
                    case 702: name = "Café.txt"
                    case 703: name = "Cafe\u{301}.txt"
                    case 704: name = "ÄPFEL.txt"
                    default: name = String(format: "Row%04d", index)
                    }
                }
                return .init(observation: UInt64(index + 1), entry: .init(name: try .init(Data(name.utf8)),
                    logicalBytes: UInt64(index), modifiedSeconds: UInt32(index), permissions: index == 0 ? 0o040755 : 0o100644))
            }
        }
        private func matching(_ rows: [SFTPStoredRow], query: RemoteDirectoryFindQuery) -> [SFTPStoredRow] {
            let needle = Data(query.text.lowercased().utf8)
            return rows.filter { Data(String(decoding: $0.entry.name.wireUTF8, as: UTF8.self).lowercased().utf8).range(of: needle) != nil }
        }
        func find(_ generation: UUID, snapshot: SFTPStoredSnapshot, query: RemoteDirectoryFindQuery) async throws -> SFTPDirectoryFindResult {
            guard !closed, generation == self.generation else { throw RemoteDirectoryFindFailure.stale }
            finds += 1
            if holdingFind { holdingFind = false; await withCheckedContinuation { heldFind = $0 } }
            guard !closed, generation == self.generation else { throw RemoteDirectoryFindFailure.stale }
            let rows = matching(try metadataRows(snapshot), query: query)
            let result = try SFTPDirectoryFindResult(query: query, generation: generation, snapshot: snapshot,
                count: UInt64(rows.count), folders: UInt64(rows.filter { $0.entry.isDirectory == true }.count))
            selectedFind = result; return result
        }
        func page(_ generation: UUID, snapshot: SFTPStoredSnapshot, offset: UInt64,
                  sort: SFTPStoredSort, descending: Bool) async throws -> SFTPStoredPage? {
            try await page(generation, snapshot: snapshot, offset: offset, sort: sort, descending: descending, find: nil)
        }
        func page(_ generation: UUID, snapshot: SFTPStoredSnapshot, offset: UInt64,
                  sort: SFTPStoredSort, descending: Bool, find: SFTPDirectoryFindResult?) async throws -> SFTPStoredPage? {
            guard !closed, generation == self.generation, offset <= (find?.count ?? snapshot.count) else {
                throw Failure.stage("unexpected-generated-page")
            }
            if let find, find != selectedFind { throw RemoteDirectoryFindFailure.stale }
            pages += 1; pageHistory.append(offset)
            if holding { holding = false; await withCheckedContinuation { held = $0 } }
            var rows = try metadataRows(snapshot)
            if let find { rows = matching(rows, query: find.query) }
            switch sort {
            case .name: rows.sort { $0.entry.name.wireUTF8.lexicographicallyPrecedes($1.entry.name.wireUTF8) }
            case .size: rows.sort { ($0.entry.logicalBytes ?? 0) < ($1.entry.logicalBytes ?? 0) }
            case .modified: rows.sort { ($0.entry.modifiedSeconds ?? 0) < ($1.entry.modifiedSeconds ?? 0) }
            }
            if descending { rows.reverse() }
            let lower = Int(offset), upper = min(rows.count, Int(offset) + 256)
            return .init(request: UUID(), generation: generation, snapshot: snapshot, offset: offset, rows: Array(rows[lower..<upper]), find: find)
        }
        func close() async -> SFTPWorkerClose {
            closes += 1
            closed = true; holding = false
            releasePage(); releaseFind()
            return .init(actualExit: true, exitStatus: 0, ipcEOF: true, contained: false,
                protocolValid: true, terminal: nil, temporaryStoreRemoved: nil)
        }
    }
    private actor LocalPropertiesSpy: FilePropertiesReading {
        private var reads = 0
        func count() -> Int { reads }
        func read(_ urls: [URL]) async throws -> FilePropertiesReport {
            reads += 1; throw Failure.stage("local-properties-read-forbidden")
        }
    }
}
#endif
