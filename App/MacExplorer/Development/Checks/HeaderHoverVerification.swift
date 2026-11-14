#if DEBUG
import AppKit
import Darwin
import ExplorerCore

@MainActor enum HeaderHoverVerification {
    @MainActor private final class Pulse {
        var previous = CACurrentMediaTime(), gap = 0.0, ticks = 0
        func tick() {let now = CACurrentMediaTime();gap = max(gap,now-previous);previous = now;ticks += 1}
    }
    static func run() async {
        guard let path = ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"] else {exit(2)}
        let root = URL(fileURLWithPath:path)
        let repo = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard root.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-release"),root.resolvingSymlinksInPath() == root,
            UUID(uuidString:root.lastPathComponent)?.uuidString == root.lastPathComponent,
            let bytes = try? Data(contentsOf:root.appendingPathComponent("reservation.json")),
            let marker = try? JSONSerialization.jsonObject(with:bytes)as?[String:Any],marker["action"]as?String == "traverse-header-hover" else {exit(2)}
        let baseline = ProcessInfo.processInfo.arguments.contains("--header-hover-baseline")
        let settings = BrowserSettings(persist:false)
        settings.autoRefreshFolders = false;settings.folderSummariesEnabled = false;settings.reviewsRecoveryAtStartup = false
        settings.showsDockProgress = false;settings.appearance = .dark;settings.navigationStyle = .glass;settings.glassFileContent = true
        settings.motion.mode = .full
        let owner = BrowserWindowController(settings:settings),pulse = Pulse()
        let timer = Timer(timeInterval:0.016,repeats:true) {_ in MainActor.assumeIsolated {pulse.tick()}}
        RunLoop.main.add(timer,forMode:.common)
        var checks:[String] = [],failures:[String] = [],metrics:[String:Any] = [:]
        do {
            try await verify(root:root,owner:owner,settings:settings,baseline:baseline,checks:&checks,metrics:&metrics)
            if baseline {try await wait("baseline sampler coverage") {pulse.ticks>=10}}
        }
        catch {failures.append(String(describing:error))}
        owner.suspendBrowsing();await owner.flushSession();owner.window?.close();timer.invalidate()
        var usage = rusage();getrusage(RUSAGE_SELF,&usage)
        if usage.ru_maxrss>256*1024*1024 {failures.append("Native memory gate failed")}
        if pulse.gap>0.4 || pulse.ticks<10 {failures.append("Native response gate failed")}
        if ApplicationFileActivity.gate.activeCount != 0 {failures.append("Actual file work remains")}
        try? JSONSerialization.data(withJSONObject:["passed":failures.isEmpty,"baseline":baseline,"checks":checks,"failures":failures,"metrics":metrics,
            "peakRSSBytes":usage.ru_maxrss,"maximumMainActorGapSeconds":pulse.gap,"sampledTurns":pulse.ticks,"activityCount":ApplicationFileActivity.gate.activeCount,
            "generatedOnly":true,"fileBodyIndexing":false,"clipboard":false,"network":false,"physicalPointer":false,"spokenVoiceOver":false],options:[.prettyPrinted,.sortedKeys])
            .write(to:root.appendingPathComponent("result.json"),options:.withoutOverwriting)
        NSApp.terminate(nil)
    }
    private static func verify(root:URL,owner:BrowserWindowController,settings:BrowserSettings,baseline:Bool,
        checks:inout[String],metrics:inout[String:Any]) async throws {
        try UIVerification.require(owner.isWorkspacePresentation,"Header check requires real workspace composition")
        guard let window = owner.window else {throw UIVerification.Failure(message:"Header window missing")}
        window.title = "Header hover · generated review";window.setFrame(.init(x:100,y:130,width:960,height:640),display:true)
        window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
        let browser = owner.browser;browser.permitsBackgroundVerification = true
        owner.beginBrowsing();try await wait("workspace") {owner.workspace.sessionReady}
        browser.navigate(to:.directory(root.appendingPathComponent("source/Files")));try await settle(browser)
        guard let header = browser.table.headerView as? FileTableHeaderView,
            let kind = browser.table.tableColumns.first(where:{$0.identifier.rawValue == "kind"}),
            let preview = header.indicatorForVerification(kind) else {throw UIVerification.Failure(message:"Actual header preview missing")}
        if baseline {
            try hover(kind,in:header);try await Task.sleep(for:.milliseconds(35))
            let opacity = preview.glyphLayer.presentation()?.opacity ?? preview.glyphLayer.opacity
            metrics["previewAt35ms"] = opacity;metrics["entranceAnimationPresent"] = preview.glyphLayer.animation(forKey:"sortHover") != nil
            try UIVerification.require(opacity>=0.5 && preview.glyphLayer.animation(forKey:"sortHover") == nil,"Baseline is not the current immediate hover")
            try hover(nil,in:header);checks.append("Generated baseline confirms current immediate preview without an entrance; no new feature gate claimed")
            return
        }
        metrics["originalHeaderRegression"] = try await HeaderPresentationVerification.run(root:root.appendingPathComponent("source"),
            output:root.appendingPathComponent("evidence"),browser:browser,review:false)
        try UIVerification.require((metrics["originalHeaderRegression"]as?[String:Any])?["passed"]as?Bool == true,"Original native header regression failed")
        checks.append("Original native header first-click, sort ownership/pixels, reversal, glass/opaque, old settings and accessibility guards pass")

        window.setFrame(.init(x:100,y:130,width:960,height:640),display:true)
        let backdrop = GlassVerification.makeBrowserBackdropWindow(behind:window);defer {backdrop.close()}
        let systemReduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        var modes:[[String:Any]] = []
        for mode in BrowserMotionMode.allCases {
            settings.motion.mode = mode
            browser.table.sortDescriptors = [NSSortDescriptor(key:"name",ascending:true)]
            try hover(nil,in:header);try await settle(browser);try await Task.sleep(for:.milliseconds(40))
            guard let name = browser.table.tableColumns.first(where:{$0.identifier.rawValue == "name"}),
                let active = header.indicatorForVerification(name),
                let preview = header.indicatorForVerification(kind) else {throw UIVerification.Failure(message:"Actual current sort or preview missing")}
            let began = CACurrentMediaTime();try hover(kind,in:header)
            let handler = CACurrentMediaTime()-began
            let entrance = preview.glyphLayer.animation(forKey:"sortHover")as?CABasicAnimation
            let animated = mode != .off && !systemReduced
            try UIVerification.require(handler<0.016 && preview.glyphLayer.opacity == 0.55 && active.glyphLayer.opacity == 1,"Hover input/model or actual sort ownership regressed")
            try UIVerification.require(animated ? entrance?.duration == 0.09*mode.durationScale : entrance == nil,"Hover does not follow its motion mode")
            if animated {
                try UIVerification.require((entrance?.fromValue as?NSNumber)?.floatValue == 0.32 && (entrance?.toValue as?NSNumber)?.floatValue == 0.55,"Entrance does not begin visibly")
                try await Task.sleep(for:.milliseconds(25))
                let before = preview.glyphLayer.presentation()?.opacity ?? preview.glyphLayer.opacity
                for _ in 0..<8 {header.needsDisplay = true;header.displayIfNeeded()}
                try await Task.sleep(for:.milliseconds(16))
                let after = preview.glyphLayer.presentation()?.opacity ?? preview.glyphLayer.opacity
                try UIVerification.require(after+0.03>=before,"Repeated drawing restarted the hover curve")
            }
            try hover(nil,in:header)
            try UIVerification.require(preview.glyphLayer.opacity == 0 && preview.glyphLayer.animation(forKey:"sortHover") == nil
                && active.glyphLayer.opacity == 1,"Exit retained a previous preview or hid the active sort")
            for column in browser.table.tableColumns where column.identifier.rawValue != "name" && !column.isHidden {
                try hover(column,in:header)
                for old in browser.table.tableColumns where old !== column && old.identifier.rawValue != "name" {
                    guard let oldGlyph = header.indicatorForVerification(old) else {continue}
                    try UIVerification.require(oldGlyph.glyphLayer.opacity == 0 && oldGlyph.glyphLayer.animation(forKey:"sortHover") == nil,"Rapid crossing leaves an old preview")
                }
            }
            try hover(kind,in:header);settings.motion.sortIndicators = false
            try UIVerification.require(preview.glyphLayer.animationKeys()?.isEmpty != false && preview.glyphLayer.opacity == 0.55,"Individual motion switch did not settle its preview")
            settings.motion.sortIndicators = true;try hover(nil,in:header)
            modes.append(["mode":mode.rawValue,"handlerMilliseconds":handler*1000,"animated":animated])
            if ProcessInfo.processInfo.arguments.contains("--record-motion") {
                window.title = "Header hover · generated review"
                var actionFailure:Error?
                let report = try await NativeMotionRecorder.record(window:window,root:root,label:"header-hover-"+mode.rawValue) {
                    do {try hover(kind,in:header)} catch {actionFailure = error}
                }
                if let actionFailure {throw actionFailure}
                try JSONEncoder().encode(report).write(to:root.appendingPathComponent("evidence/header-hover-"+mode.rawValue+".json"),options:.withoutOverwriting)
                try hover(nil,in:header)
            }
        }
        metrics["modes"] = modes
        checks.append("Full/Reduced/Off retain immediate input/visible feedback, do not restart on redraw, remove old previews on crossing/exit and settle when motion is disabled")
    }
    private static func hover(_ column:NSTableColumn?,in header:FileTableHeaderView)throws {
        guard let table = header.tableView else {throw UIVerification.Failure(message:"Header detached")}
        let index = column.flatMap {selected in table.tableColumns.firstIndex {$0 === selected}}
        let point = index.map {NSPoint(x:header.headerRect(ofColumn:$0).midX,y:header.bounds.midY)} ?? .init(x:-10,y:-10)
        guard let event = NSEvent.mouseEvent(with:.mouseMoved,location:header.convert(point,to:nil),modifierFlags:[],timestamp:CACurrentMediaTime(),
            windowNumber:header.window?.windowNumber ?? 0,context:nil,eventNumber:0,clickCount:0,pressure:0) else {throw UIVerification.Failure(message:"Local hover event unavailable")}
        header.mouseMoved(with:event);header.displayIfNeeded()
    }
    private static func settle(_ browser:BrowserViewController)async throws {
        try await wait("header listing") {!browser.isLoading && browser.orderingTask == nil && browser.canvasTransition == nil}
        browser.view.window?.contentView?.layoutSubtreeIfNeeded()
    }
    private static func wait(_ name:String,_ condition:()->Bool)async throws {
        let end = CACurrentMediaTime()+12
        while !condition() {try UIVerification.require(CACurrentMediaTime()<end,name);try await Task.sleep(for:.milliseconds(10))}
    }
}
#endif
