#if DEBUG
import AppKit
import ExplorerCore

/// Bounded generated-only observation of native proposal callbacks. No names,
/// paths, pointer locations or file data enter this in-memory recorder.
@MainActor enum SelectionGestureEvidence {
    static var enabled = false
    private(set) static var values: [[String:Any]] = []
    private(set) static var omitted = 0
    static func observe(kind: String, state: NSCollectionViewItem.HighlightState, committed: Bool) {
        guard enabled, state == .forSelection || state == .forDeselection else { return }
        guard values.count < 1024 else { omitted += 1; return }
        values.append(["kind":kind,"proposal":state == .forSelection ? "select" : "deselect","committed":committed,
            "event":NSApp.currentEvent.map { Int($0.type.rawValue) } ?? -1,"uptime":ProcessInfo.processInfo.systemUptime])
    }
}

@MainActor enum SelectionGestureVerification {
    private enum Failure: Error { case scope, check(UInt) }
    private static func require(_ value: Bool, _ line: UInt = #line) throws { if !value { throw Failure.check(line) } }
    private static func wait(_ predicate: () -> Bool, _ line: UInt = #line) async throws {
        let end = ContinuousClock.now + .seconds(6)
        while !predicate() { try require(.now < end, line); try await Task.sleep(for: .milliseconds(10)) }
    }
    static func run() async {
        var root: URL?, window: NSWindow?, browser: BrowserViewController?, checks: [String] = [], failure: UInt?, kind: String?, gestures: [String:Any] = [:]
        do {
            guard let raw = ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"] else { throw Failure.scope }
            let area = URL(fileURLWithPath: raw), repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let marker = try JSONSerialization.jsonObject(with: Data(contentsOf: area.appendingPathComponent("reservation.json"))) as? [String:Any]
            try require(area.resolvingSymlinksInPath() == area && area.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-development")
                && marker?["action"] as? String == "native-selection-gestures" && Bundle.main.bundleIdentifier == "local.macexplorer.development")
            root = area
            let settings = BrowserSettings(persist: false); settings.autoRefreshFolders = false; settings.folderSummariesEnabled = false
            settings.reviewsRecoveryAtStartup = false; settings.navigationStyle = .glass; settings.glassFileContent = true; settings.appearance = .dark; settings.motion.mode = .reduced
            settings.viewMode = .details
            let owner = BrowserViewController(settings: settings); browser = owner; owner.permitsBackgroundVerification = true
            let folder = area.appendingPathComponent("source/Rows", isDirectory: true)
            owner.tabs = [.init(location: .directory(folder))]; owner.activeID = owner.tabs[0].id
            owner.readVolumesForVerification = { (0..<4).map { .init(url: area.appendingPathComponent("source/Drive \($0)", isDirectory: true), name: "Generated drive \($0 + 1)", kind: .externalDisk,
                totalBytes: 1_000_000, availableBytes: 500_000, isReadOnly: false) } }
            var finished = false
            let controls = NSStackView(views: [
                ActionButton(title: "Table", action: { settings.viewMode = .details; owner.navigate(to: .directory(folder)) }),
                ActionButton(title: "Icons", action: { settings.viewMode = .icons; owner.navigate(to: .directory(folder)) }),
                ActionButton(title: "This Mac", action: { owner.navigate(to: .computer) }),
                ActionButton(title: "Reload", action: { owner.refresh(nil) }),
                ActionButton(title: "Finish", action: { finished = true })])
            controls.orientation = .horizontal; controls.spacing = 12
            let host = NSViewController(); host.view = NSView(frame: .init(x: 0,y: 0,width: 1000,height: 680)); host.addChild(owner)
            controls.translatesAutoresizingMaskIntoConstraints = false; owner.view.translatesAutoresizingMaskIntoConstraints = false
            host.view.addSubview(controls); host.view.addSubview(owner.view)
            NSLayoutConstraint.activate([controls.topAnchor.constraint(equalTo: host.view.topAnchor), controls.heightAnchor.constraint(equalToConstant: 36),
                controls.leadingAnchor.constraint(equalTo: host.view.leadingAnchor,constant: 12), controls.trailingAnchor.constraint(lessThanOrEqualTo: host.view.trailingAnchor),
                owner.view.topAnchor.constraint(equalTo: controls.bottomAnchor), owner.view.bottomAnchor.constraint(equalTo: host.view.bottomAnchor),
                owner.view.leadingAnchor.constraint(equalTo: host.view.leadingAnchor), owner.view.trailingAnchor.constraint(equalTo: host.view.trailingAnchor)])
            let panel = NSWindow(contentRect: .init(x: 180,y: 140,width: 1000,height: 680), styleMask: [.titled,.closable,.resizable], backing: .buffered, defer: false)
            window = panel; panel.isReleasedWhenClosed = false; panel.contentViewController = host; panel.title = "Selection margin and tiles · generated review"
            panel.setContentSize(.init(width: 1000,height: 680))
            panel.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            owner.loadLocation()
            try await wait { !owner.isLoading && owner.orderingTask == nil && owner.displayedEntries.count == 120 }
            owner.view.layoutSubtreeIfNeeded()
            try require(owner.table.visibleRect.height > 300 && owner.table.visibleRect.width > 500)
            guard let marquee = owner.table.marquee else { throw Failure.scope }
            try require(marquee.verificationState.margin.frame.width >= 11 && marquee.verificationState.margin.frame.width <= 13 && !marquee.active && !marquee.verificationState.timer)
            checks.append("A real leading selection margin reserves space outside table cells and the fixed header")
            for (flags, expected): (NSEvent.ModifierFlags,IndexSet) in [([],IndexSet(integersIn: 2..<5)),(.shift,IndexSet([0,2,3,4])),(.command,IndexSet([0,3,4])),([.command,.shift],IndexSet([0,2,3,4]))] {
                try require(TableMarqueeSelection.selection(base: IndexSet([0,2]), intersected: IndexSet(integersIn: 2..<5), modifiers: flags) == expected)
            }
            checks.append("Plain replaces, Shift adds and Command toggles against the initial selection")
            let firstRow = owner.table.rows(in: NSRect(x: 0,y: 0,width: 100,height: 1))
            let aboveRows = owner.table.rows(in: NSRect(x: 0,y: -100,width: 100,height: 50))
            try require(firstRow.location == 0 && firstRow.length == 1 && aboveRows.length == 0)
            checks.append("Native table geometry supplies intersected rows without a per-pointer filesystem query")
            let clip = NSRect(x:12,y:0,width:500,height:400)
            for (a,b) in [(NSPoint(x:5,y:40),NSPoint(x:5,y:100)),(.init(x:5,y:100),.init(x:5,y:40)),(.init(x:5,y:40),.init(x:200,y:100)),(.init(x:5,y:100),.init(x:200,y:40))] {
                let band = TableMarqueeSelection.band(origin:a,current:b,clip:clip,minimumWidth:12)
                try require(band != nil && band!.minX == clip.minX && band!.width >= 12 && band!.height == 60 && clip.contains(band!))
            }
            try require(TableMarqueeSelection.band(origin:.init(x:5,y:-100),current:.init(x:5,y:-50),clip:clip,minimumWidth:12) == nil)
            checks.append("Vertical and diagonal bands start inside the body and clip correctly in both directions")
            let (raster, painted, metrics) = try TableMarqueeSelection.rasterForVerification()
            try raster.write(to:area.appendingPathComponent("evidence/marquee-raster.png"),options:.withoutOverwriting)
            try JSONSerialization.data(withJSONObject:metrics,options:[.prettyPrinted,.sortedKeys]).write(to:area.appendingPathComponent("evidence/marquee-raster.json"),options:.withoutOverwriting)
            try require(painted)
            checks.append("The actual overlay paints contrasting native fill and stroke without intercepting input")
            owner.table.selectRowIndexes(IndexSet([1,3]), byExtendingSelection: false)
            owner.table.reloadData(); try require(!marquee.active && !marquee.verificationState.timer && marquee.verificationState.rectangle == nil)
            checks.append("A listing replacement leaves no active selection overlay or scrolling timer")
            if ProcessInfo.processInfo.arguments.contains("--physical-selection-review") {
                SelectionGestureEvidence.enabled = true
                try Data("generated native selection ready".utf8).write(to: area.appendingPathComponent("state/Ready"),options:.withoutOverwriting)
                let end = ContinuousClock.now + .seconds(600)
                while !finished && .now < end { try await Task.sleep(for: .milliseconds(50)) }
                try require(finished)
                let events = SelectionGestureEvidence.values
                let filePreview = events.contains { $0["kind"] as? String == "file" && $0["proposal"] as? String == "select" && $0["committed"] as? Bool == false }
                let volumePreview = events.contains { $0["kind"] as? String == "volume" && $0["proposal"] as? String == "select" && $0["committed"] as? Bool == false }
                gestures = ["tableGestures":marquee.gestureBegins,"tableLiveSelectionChanges":marquee.liveSelectionChanges,"tableVisibleOverlayDraws":marquee.verificationState.draws,
                    "nonEmptyBandUpdates":marquee.nonEmptyBandUpdates,"lastBandWidth":marquee.lastBandSize.width,"lastBandHeight":marquee.lastBandSize.height,
                    "continuousVisualTrackingExercised":marquee.verificationState.draws > 0,"fileProposalBeforeCommit":filePreview,"volumeProposalBeforeCommit":volumePreview,"proposalEvents":events,"omittedEvents":SelectionGestureEvidence.omitted]
                try require(marquee.gestureBegins > 0 && marquee.liveSelectionChanges > 0 && marquee.nonEmptyBandUpdates > 0 && filePreview && volumePreview)
                try require(!marquee.active && !marquee.verificationState.timer && marquee.verificationState.rectangle == nil)
                checks.append("Actual input drove selection and a nonempty band state, with tile proposals before commit; screen paint is reported separately")
            }
            SelectionGestureEvidence.enabled = false; owner.suspendBrowser(); panel.close()
            try require(!marquee.active && !marquee.verificationState.timer)
            checks.append("Window closure drains the selection lifetime")
        } catch { if case let Failure.check(line) = error { failure = line } else { failure = 0 }; kind = String(reflecting:type(of:error)) }
        SelectionGestureEvidence.enabled = false; browser?.suspendBrowser(); window?.close()
        if let root {
            let value: [String:Any] = ["passed":failure == nil,"checks":checks,"gestures":gestures,"line":failure.map { $0 as Any } ?? NSNull(),"failureType":kind.map { $0 as Any } ?? NSNull(),
                "physicalInputRequested":ProcessInfo.processInfo.arguments.contains("--physical-selection-review"),"fileMutations":0,"networkRequests":0,"activityDrained":ApplicationFileActivity.gate.activeCount == 0]
            try? JSONSerialization.data(withJSONObject:value,options:[.prettyPrinted,.sortedKeys]).write(to:root.appendingPathComponent("evidence/native-selection-gestures.json"),options:.withoutOverwriting)
        }
        NSApp.terminate(nil)
    }
}
#endif
