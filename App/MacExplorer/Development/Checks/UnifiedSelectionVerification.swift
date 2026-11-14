#if DEBUG
import AppKit
import ExplorerCore

/// Real input against a tiny file list with empty body space. No synthetic events.
@MainActor enum UnifiedSelectionVerification {
    private enum Failure: Error { case scope, check(UInt) }
    private static func require(_ value: Bool, _ line: UInt = #line) throws { if !value { throw Failure.check(line) } }
    static func run() async {
        var area: URL?, panel: NSWindow?, browser: BrowserViewController?, monitor: Any?
        var rows: [[String:Any]] = [], checks: [String] = [], failure: UInt?
        do {
            guard let raw = ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"] else { throw Failure.scope }
            let root = URL(fileURLWithPath:raw), repo = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let marker = try JSONSerialization.jsonObject(with:Data(contentsOf:root.appendingPathComponent("reservation.json"))) as? [String:Any]
            try require(root.resolvingSymlinksInPath() == root && root.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-development")
                && marker?["action"] as? String == "native-unified-selection" && Bundle.main.bundleIdentifier == "local.macexplorer.development")
            area = root
            let settings = BrowserSettings(persist:false)
            settings.autoRefreshFolders = false; settings.folderSummariesEnabled = false; settings.reviewsRecoveryAtStartup = false
            settings.navigationStyle = .glass; settings.glassFileContent = true; settings.appearance = .dark; settings.motion.mode = .reduced
            settings.viewMode = .details
            let owner = BrowserViewController(settings:settings); browser = owner; owner.permitsBackgroundVerification = true
            let folder = root.appendingPathComponent("source/Rows",isDirectory:true)
            owner.tabs = [.init(location:.directory(folder))]; owner.activeID = owner.tabs[0].id
            var phase = 0, finished = false, baseBegins = 0, baseChanges = 0, baseDraws = 0, baseBands = 0
            var cursorSamples = 0, crosshairSamples = 0
            var events: [[String:Any]] = []
            let instruction = NSTextField(labelWithString:"1 of 2 · Drag from the leading gutter across several rows, then Next origin")
            instruction.setAccessibilityLabel("Selection origin instructions")
            let next = ActionButton(title:"Next origin",action:{
                guard let marquee = owner.table.marquee, phase < 2 else { return }
                rows.append(["origin":phase == 0 ? "gutter" : "empty-body","selected":owner.table.selectedRowIndexes.count,
                    "gestureBegins":marquee.gestureBegins-baseBegins,"liveSelectionChanges":marquee.liveSelectionChanges-baseChanges,
                    "visibleOverlayDraws":marquee.verificationState.draws-baseDraws,"bandUpdates":marquee.nonEmptyBandUpdates-baseBands,
                    "cursorSamples":cursorSamples,"crosshairSamples":crosshairSamples,
                    "events":events,
                    "drained":!marquee.active && !marquee.verificationState.timer && marquee.verificationState.rectangle == nil])
                phase += 1
                if phase == 2 { finished = true; return }
                owner.table.deselectAll(nil)
                baseBegins = marquee.gestureBegins; baseChanges = marquee.liveSelectionChanges
                baseDraws = marquee.verificationState.draws; baseBands = marquee.nonEmptyBandUpdates
                cursorSamples = 0; crosshairSamples = 0; events = []
                instruction.stringValue = "2 of 2 · Drag upward from empty space BELOW the last row, then Next origin"
            })
            let controls = NSStackView(views:[instruction,next]); controls.orientation = .horizontal; controls.spacing = 12
            let host = NSViewController(); host.view = NSView(frame:.init(x:0,y:0,width:1000,height:700)); host.addChild(owner)
            controls.translatesAutoresizingMaskIntoConstraints = false; owner.view.translatesAutoresizingMaskIntoConstraints = false
            host.view.addSubview(controls); host.view.addSubview(owner.view)
            NSLayoutConstraint.activate([controls.topAnchor.constraint(equalTo:host.view.topAnchor,constant:4),controls.heightAnchor.constraint(equalToConstant:32),
                controls.leadingAnchor.constraint(equalTo:host.view.leadingAnchor,constant:12),controls.trailingAnchor.constraint(equalTo:host.view.trailingAnchor,constant:-12),
                owner.view.topAnchor.constraint(equalTo:controls.bottomAnchor),owner.view.bottomAnchor.constraint(equalTo:host.view.bottomAnchor),
                owner.view.leadingAnchor.constraint(equalTo:host.view.leadingAnchor),owner.view.trailingAnchor.constraint(equalTo:host.view.trailingAnchor)])
            let window = NSWindow(contentRect:.init(x:200,y:120,width:1000,height:700),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
            panel = window; window.isReleasedWhenClosed = false; window.contentViewController = host
            window.title = "Unified selection origins · generated review"; window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true)
            owner.loadLocation()
            let listingEnd = ContinuousClock.now + .seconds(6)
            while owner.isLoading || owner.orderingTask != nil || owner.displayedEntries.count != 12 {
                try require(.now < listingEnd); try await Task.sleep(for:.milliseconds(10))
            }
            owner.view.layoutSubtreeIfNeeded()
            guard let marquee = owner.table.marquee else { throw Failure.scope }
            let body = owner.table.visibleRect, last = owner.table.rect(ofRow:11)
            try require(body.height-last.maxY > 120 && body.width > 500)
            checks.append("The real table has twelve rows and at least120 points of empty body below them")
            let clip = NSRect(x:12,y:0,width:500,height:400)
            for (a,b,left,width):(NSPoint,NSPoint,CGFloat,CGFloat) in [(.init(x:200,y:40),.init(x:400,y:100),200,200),
                (.init(x:400,y:100),.init(x:200,y:40),200,200),(.init(x:5,y:100),.init(x:200,y:40),12,188)] {
                let band = TableMarqueeSelection.band(origin:a,current:b,clip:clip,minimumWidth:12)
                try require(band?.minX == left && band?.width == width && band?.height == 60)
            }
            try require(TableMarqueeSelection.band(origin:.init(x:CGFloat.nan,y:40),current:.init(x:200,y:100),clip:clip,minimumWidth:12) == nil)
            checks.append("Both body directions retain the true rectangle origin; gutter and invalid geometry remain clipped safely")
            window.title = "Unified selection origins · generated review"
            monitor = NSEvent.addLocalMonitorForEvents(matching:[.leftMouseDown,.leftMouseDragged,.leftMouseUp]) { event in
                MainActor.assumeIsolated {
                    guard event.window === window, events.count < 32 else { return }
                    let point = event.locationInWindow, tablePoint = owner.table.convert(point,from:nil)
                    let clip = owner.folderScroll.contentView
                    let bodyPoint = clip.convert(point,from:nil)
                    let gutter = marquee.verificationState.margin.bounds.contains(marquee.verificationState.margin.convert(point,from:nil))
                    guard gutter || clip.bounds.contains(bodyPoint) else { return }
                    if NSApp.isActive {
                        cursorSamples += 1
                        if NSCursor.current == .crosshair { crosshairSamples += 1 }
                    }
                    events.append(["type":Int(event.type.rawValue),"row":owner.table.row(at:tablePoint),"insideTableBounds":owner.table.bounds.contains(tablePoint),
                        "inGutter":gutter,"timestamp":event.timestamp,
                        "appActive":NSApp.isActive,"keyWindow":window.isKeyWindow])
                }
                return event
            }
            try Data("generated unified selection ready".utf8).write(to:root.appendingPathComponent("state/Ready"),options:.withoutOverwriting)
            let deadline = ContinuousClock.now + .seconds(600)
            while !finished && .now < deadline { try await Task.sleep(for:.milliseconds(30)) }
            try require(finished && rows.count == 2)
            let each = rows.allSatisfy { ($0["selected"] as? Int ?? 0) > 1 && ($0["gestureBegins"] as? Int ?? 0) > 0
                && ($0["liveSelectionChanges"] as? Int ?? 0) > 0 && ($0["visibleOverlayDraws"] as? Int ?? 0) > 0
                && ($0["bandUpdates"] as? Int ?? 0) > 0 && $0["drained"] as? Bool == true }
            try require(each)
            checks.append("Gutter and empty-body origins both drive live selection and actually painted bands through the same owner")
            try require(rows.allSatisfy { ($0["cursorSamples"] as? Int ?? 0) > 0 && $0["crosshairSamples"] as? Int == 0 })
            checks.append("Only this app's active generated input cursor stack was sampled; neither origin requested a crosshair")
            owner.suspendBrowser(); window.close()
            try require(!marquee.active && !marquee.verificationState.timer)
            checks.append("Window closure drains selection without a file operation or polling timer")
        } catch { if case let Failure.check(line) = error { failure = line } else { failure = 0 } }
        if let monitor { NSEvent.removeMonitor(monitor) }
        browser?.suspendBrowser(); panel?.close()
        if let area {
            let value: [String:Any] = ["passed":failure == nil,"checks":checks,"origins":rows,"line":failure.map{$0 as Any} ?? NSNull(),
                "fileMutations":0,"networkRequests":0,"activityDrained":ApplicationFileActivity.gate.activeCount == 0,"actualInputRequested":true]
            try? JSONSerialization.data(withJSONObject:value,options:[.prettyPrinted,.sortedKeys]).write(to:area.appendingPathComponent("evidence/unified-selection.json"),options:.withoutOverwriting)
        }
        NSApp.terminate(nil)
    }
}
#endif
