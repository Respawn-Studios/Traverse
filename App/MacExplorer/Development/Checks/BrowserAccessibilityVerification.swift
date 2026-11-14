#if DEBUG
import AppKit
import ExplorerCore

/// Generated native protocol/input checks. Spoken VoiceOver is not inferred.
@MainActor enum BrowserAccessibilityVerification {
    static func run() async {
        guard let path = ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"] else { exit(2) }
        let root = URL(fileURLWithPath: path)
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard root.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-release"),
              UUID(uuidString: root.lastPathComponent)?.uuidString == root.lastPathComponent,
              root.resolvingSymlinksInPath() == root,
              let bytes = try? Data(contentsOf: root.appendingPathComponent("reservation.json")),
              let value = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              value["action"] as? String == "traverse-browser-accessibility" else { exit(2) }
        var owner: BrowserWindowController?
        var checks: [String] = [], failures: [String] = [], observations: [[String: Any]] = []
        do {
            let settings = BrowserSettings(persist: false)
            settings.autoRefreshFolders = false; settings.reviewsRecoveryAtStartup = false
            settings.appearance = .dark; settings.navigationStyle = .glass; settings.glassFileContent = true
            let controller = BrowserWindowController(settings: settings)
            owner = controller
            let browser = controller.browser
            browser.permitsBackgroundVerification = true
            guard let window = controller.window else { throw UIVerification.Failure(message: "Missing generated browser window") }
            window.title = "Browser accessibility · generated review"
            window.setContentSize(.init(width: 960, height: 640))
            window.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            browser.navigate(to: .directory(root.appendingPathComponent("source/Files")))
            try await settle(browser)
            try UIVerification.require(browser.displayedEntries.count == 3, "Generated rows did not load exactly")
            try UIVerification.require(browser.table.accessibilityLabel() == "Files in the current folder"
                && browser.outline.accessibilityLabel() == "Locations and folders", "Native browsing regions lack stable labels")
            checks.append("Native file and location regions have stable accessible labels")
            for field in [BrowserColumn.name, .modified, .kind, .size] {
                for ascending in [true, false] {
                    browser.table.sortDescriptors = [NSSortDescriptor(key: field.rawValue, ascending: ascending)]
                    try await settle(browser)
                    browser.table.headerView?.layoutSubtreeIfNeeded()
                    for column in browser.table.tableColumns where !column.isHidden && column.sortDescriptorPrototype != nil {
                        let active = column.identifier.rawValue == field.rawValue
                        let expected: NSAccessibilitySortDirection = active ? (ascending ? .ascending : .descending) : .unknown
                        let actual = column.headerCell.accessibilitySortDirection()
                        observations.append(["sortedField": field.rawValue, "ascending": ascending,
                            "column": column.identifier.rawValue, "expectedSort": expected.rawValue, "actualSort": actual.rawValue])
                        if actual != expected { failures.append("Accessible sort state differs for \(column.title) while sorting \(field.title)") }
                    }
                }
            }
            if failures.isEmpty { checks.append("Every primary sort direction is exposed natively; previous columns clear their sort state") }
            let first = browser.activeID
            browser.newTab(nil); try await settle(browser)
            let second = browser.activeID
            guard let old = browser.tabStrip.selectionButton(for: first), let active = browser.tabStrip.selectionButton(for: second) else {
                throw UIVerification.Failure(message: "Accessible tab controls absent")
            }
            try UIVerification.require(active.accessibilityRole() == .radioButton
                && (active.accessibilityValue() as? NSNumber)?.intValue == 1
                && (old.accessibilityValue() as? NSNumber)?.intValue == 0,
                "Accessible tabs lose selection or role")
            try UIVerification.require(old.accessibilityPerformPress(), "Native accessible tab press refused")
            try await settle(browser)
            try UIVerification.require(browser.activeID == first, "Accessible press selected a different tab")
            old.isEnabled = false
            try UIVerification.require(!old.accessibilityPerformPress(), "Disabled tab accepted accessible selection")
            old.isEnabled = true; old.isHidden = true
            try UIVerification.require(!old.accessibilityPerformPress(), "Hidden tab accepted accessible selection")
            old.isHidden = false
            browser.closeTab(id: second); try await settle(browser)
            try UIVerification.require(!active.accessibilityPerformPress(), "Removed tab retained an accessible press")
            checks.append("Tab role/selection and accessible press work; disabled, hidden and removed controls refuse")
            for mode in BrowserViewMode.allCases {
                browser.viewModeControl.selectedSegment = BrowserViewMode.allCases.firstIndex(of: mode)!
                browser.changeViewFromControl(browser.viewModeControl)
                try await settle(browser)
                browser.focusBrowserContent()
                try UIVerification.require(browser.effectiveViewMode == mode && window.firstResponder != nil,
                    "View switch lost its content focus")
                browser.focusLocation(nil)
                try UIVerification.require(browser.pathField.currentEditor() === window.firstResponder,
                    "Address action did not focus the editable path")
                browser.focusBrowserContent()
            }
            checks.append("Details/List/Icons preserve content focus and explicit editable-address focus")
            browser.viewModeControl.selectedSegment = BrowserViewMode.allCases.firstIndex(of: .details)!
            browser.changeViewFromControl(browser.viewModeControl)
            for profile in [KeyboardProfile.explorer, .mac] {
                settings.keyboardProfile = profile
                try await settle(browser)
                guard let row = browser.displayedEntries.firstIndex(where: { $0.name == "Folder" }) else {
                    throw UIVerification.Failure(message: "Generated folder is absent")
                }
                browser.table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                window.makeFirstResponder(browser.table)
                let event = profile == .explorer
                    ? UIVerification.key("\r", code: 36, flags: [], window: window)
                    : UIVerification.key(String(UnicodeScalar(0xF701)!), code: 125, flags: [.command], window: window)
                browser.table.keyDown(with: event)
                try await settle(browser)
                try UIVerification.require(browser.location == .directory(root.appendingPathComponent("source/Files/Folder")),
                    "Profile-specific native key event did not enter the selected folder")
                browser.table.keyDown(with: UIVerification.key(String(UnicodeScalar(0xF702)!), code: 123, flags: [.option], window: window))
                try await settle(browser)
                try UIVerification.require(browser.location == .directory(root.appendingPathComponent("source/Files")),
                    "Native Back key did not restore the parent")
            }
            checks.append("Real in-window Return/Command-Down and Option-Left events navigate correctly in Explorer/Mac profiles")
            browser.suspendBrowser(); window.close()
        } catch { failures.append(String(describing: error)) }
        owner?.suspendBrowsing(); owner?.window?.close()
        let report: [String: Any] = ["passed": failures.isEmpty, "checks": checks, "failures": failures,
            "sortObservations": observations, "spokenVoiceOver": false, "systemAccessibilityChanges": 0,
            "fileMutations": 0, "personalCatalogs": 0, "networkRequests": 0]
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("result.json"), options: .withoutOverwriting)
        NSApplication.shared.terminate(nil)
    }
    private static func settle(_ browser: BrowserViewController) async throws {
        let until = ProcessInfo.processInfo.systemUptime + 8
        while browser.isLoading || browser.orderingTask != nil || browser.canvasTransition != nil {
            try UIVerification.require(ProcessInfo.processInfo.systemUptime < until, "Generated native browser did not settle")
            try await Task.sleep(for: .milliseconds(10))
        }
        browser.view.window?.contentView?.layoutSubtreeIfNeeded()
    }
}
#endif
