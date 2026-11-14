#if DEBUG
import AppKit
import ExplorerCore
import ObjectiveC
@_spi(Qualification) import LocalStorage

/// Generated metadata/review only. No connection, credential or upload token.
@MainActor enum SFTPFolderUploadPreviewVerification {
    private enum Failure: Error { case scope, check(UInt) }
    private static func require(_ value: Bool, _ line: UInt = #line) throws { if !value { throw Failure.check(line) } }
    private static func wait(_ predicate: () -> Bool) async throws {
        let end = ProcessInfo.processInfo.systemUptime + 10
        while !predicate() { try require(ProcessInfo.processInfo.systemUptime < end); try await Task.sleep(for: .milliseconds(10)) }
    }
    /// AppKit/SwiftUI can implement the public informal accessibility methods
    /// without declaring NSAccessibilityButton/NSAccessibility conformance. Walk
    /// only objects reachable from this owned window; never query another app.
    @MainActor private struct Control {
        let object: NSObject
        var role: String { (value(object, "accessibilityRole") as? String) ?? "none" }
        var name: String { (value(object, "accessibilityLabel") as? String) ?? (value(object, "accessibilityTitle") as? String) ?? "" }
        func accessibilityLabel() -> String? { name }
        func accessibilityFrame() -> NSRect {
            let selector = NSSelectorFromString("accessibilityFrame")
            guard let method = class_getInstanceMethod(type(of: object), selector), method_getNumberOfArguments(method) == 2 else { return .zero }
            let encoding = method_copyReturnType(method)
            defer { free(encoding) }
            guard String(cString: encoding) == "{CGRect={CGPoint=dd}{CGSize=dd}}" else { return .zero }
            typealias Function = @convention(c) (AnyObject, Selector) -> CGRect
            return unsafeBitCast(method_getImplementation(method), to: Function.self)(object, selector)
        }
        func accessibilityPerformPress() -> Bool {
            let selector = NSSelectorFromString("accessibilityPerformPress")
            guard let method = class_getInstanceMethod(type(of: object), selector), method_getNumberOfArguments(method) == 2 else { return false }
            let encoding = method_copyReturnType(method)
            defer { free(encoding) }
            guard ["B", "c"].contains(String(cString: encoding)) else { return false }
            typealias Function = @convention(c) (AnyObject, Selector) -> ObjCBool
            return unsafeBitCast(method_getImplementation(method), to: Function.self)(object, selector).boolValue
        }
    }
    private static func value(_ object: NSObject, _ name: String) -> Any? {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector), let method = class_getInstanceMethod(type(of: object), selector),
              method_getNumberOfArguments(method) == 2 else { return nil }
        let encoding = method_copyReturnType(method)
        defer { free(encoding) }
        guard String(cString: encoding).hasPrefix("@") else { return nil }
        return object.perform(selector)?.takeUnretainedValue()
    }
    private static func buttons(_ root: Any) -> [Control] {
        var visited = Set<ObjectIdentifier>(), count = 0
        func visit(_ element: Any, depth: Int) -> [Control] {
            guard depth <= 24, count < 2048, let object = element as? NSObject,
                  visited.insert(ObjectIdentifier(object)).inserted else { return [] }
            count += 1
            var children = (value(object, "accessibilityChildren") as? [Any] ?? []) + (value(object, "accessibilityContents") as? [Any] ?? [])
            if let view = element as? NSView { children += view.subviews }
            if let window = element as? NSWindow, let content = window.contentView { children.append(content) }
            let role = value(object, "accessibilityRole") as? String
            let own = [NSAccessibility.Role.button.rawValue, NSAccessibility.Role.disclosureTriangle.rawValue].contains(role ?? "") ? [Control(object: object)] : []
            return own + children.flatMap { visit($0, depth: depth + 1) }
        }
        return visit(root, depth: 0)
    }
    static func pressUpload(in preview:SFTPFolderUploadPreview)->Bool {
        guard preview.model.valid,let panel=preview.window,
              let control=buttons(panel).first(where:{$0.name=="Upload Folder"})else{return false}
        let frame=control.accessibilityFrame()
        guard frame.width>30,frame.height>15,panel.frame.insetBy(dx:-2,dy:-2).contains(frame)else{return false}
        return control.accessibilityPerformPress()
    }
    static func pressDownload(in preview: SFTPFolderDownloadPreview, cancel: Bool) -> Bool {
        guard preview.model.valid, let panel = preview.window,
              let control = buttons(panel).first(where: { $0.name == (cancel ? "Cancel" : "Download Folder") }) else { return false }
        let frame = control.accessibilityFrame()
        guard frame.width > 30, frame.height > 15, panel.frame.insetBy(dx: -2, dy: -2).contains(frame) else { return false }
        return control.accessibilityPerformPress()
    }
    static func pressMove(in preview: RemoteMoveDestination, cancel: Bool) -> Bool {
        guard cancel || preview.model.canMove, let panel = preview.window,
              let control = buttons(panel).first(where: { $0.name == (cancel ? "Cancel" : preview.model.operation.buttonTitle) }) else { return false }
        let frame = control.accessibilityFrame()
        guard frame.width > 30, frame.height > 15,
              panel.frame.insetBy(dx: -2, dy: -2).contains(frame) else { return false }
        return control.accessibilityPerformPress()
    }
    static func run() async {
        var root: URL?, owner: BrowserWindowController?, preview: SFTPFolderUploadPreview?, pending: Task<String?, Never>?
        var checkpoint = "scope"
        do {
            let args = ProcessInfo.processInfo.arguments
            let profiling=args.contains("--profile-sheet")
            guard let raw = ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"], let at = args.firstIndex(of: "--generated-motion"),
                  args.indices.contains(at + 1), let motion = BrowserMotionMode(rawValue: args[at + 1]) else { throw Failure.scope }
            let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let admitted = URL(fileURLWithPath: raw), marker = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: raw).appendingPathComponent("reservation.json"))) as? [String: Any]
            try require(admitted.resolvingSymlinksInPath() == admitted && admitted.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-development")
                && UUID(uuidString: admitted.lastPathComponent)?.uuidString == admitted.lastPathComponent && marker?["packet"] as? String == "traverse-development-v1"
                && marker?["action"] as? String == (profiling ? "routed-folder-upload-review-profile":"folder-upload-preview") && Bundle.main.bundleIdentifier == "local.macexplorer.development"
                && Bundle.main.bundleURL == repo.appendingPathComponent(".build/traverse-release/tooling/derived/Build/Products/Debug/Mac Explorer.app"))
            root = admitted
            let large = args.contains("--large-interface"), settings = BrowserSettings(persist: false)
            settings.appearance = large ? .light : .dark; settings.navigationStyle = args.contains("--solid") ? .solid : .glass
            settings.glassFileContent = true; settings.motion.mode = motion; settings.interfaceSize = .init(large ? 150 : 100)
            settings.restoresSession = false; settings.reviewsRecoveryAtStartup = false; settings.autoRefreshFolders = false
            InterfacePresentation.shared.bind(settings)
            checkpoint = "source-review"
            let source = try await SFTPFolderUploadSourceReview.inspect(admitted.appendingPathComponent("source/Local/Folder"), excluding: [])
            try require(profiling ? source.files==1 && source.folders==2 && source.logicalBytes==3 : source.files == 3 && source.folders == 2 && source.logicalBytes == 65556)
            let parent = BrowserWindowController(settings: settings); owner = parent
            let browser = parent.browser; browser.readVolumesForVerification = { [] }; browser.permitsBackgroundVerification = true
            browser.tabs = [.init(location: .directory(admitted.appendingPathComponent("source/Local")))]; browser.activeID = browser.tabs[0].id; browser.loadLocation()
            guard let window = parent.window else { throw Failure.scope }
            window.setContentSize(.init(width: large ? 1140 : 970, height: 650)); window.center(); window.title = "Folder Upload · generated review"
            window.makeKeyAndOrderFront(nil); NSApplication.shared.activate(ignoringOtherApps: true)
            if profiling {
                let report:[String:Any]
                if args.contains("--record-title") {
                    window.setContentSize(.init(width:1180,height:680))
                    report=try await profileCaptureTitle(source:source,window:window,settings:settings,root:admitted)
                } else {
                    report=try await profile(source:source,window:window,settings:settings,settledFirst:args.contains("--settled-first"))
                }
                try write(report,root:admitted);window.close();NSApplication.shared.terminate(nil);return
            }
            let review = SFTPFolderUploadPreview(source: source, destination: "Generated server · selected destination", settings: settings); preview = review
            let choice = Task { @MainActor in await review.choose(in: window) }; pending = choice
            try await wait { window.attachedSheet === review.window }; guard let panel = review.window else { throw Failure.scope }
            try await Task.sleep(for: .milliseconds(250)); var clips = [[String: Any]]()
            let controls = buttons(panel) + (panel.contentView.map { buttons($0) } ?? [])
            try JSONSerialization.data(withJSONObject: controls.map { ["role": $0.role, "label": $0.name] }, options: [.prettyPrinted, .sortedKeys]).write(to: admitted.appendingPathComponent("evidence/owned-controls.json"), options: .withoutOverwriting)
            checkpoint = "disclosure-lookup"
            for (label, expanded) in [("folder-upload-details-open", true), ("folder-upload-details-close", false)] {
                checkpoint = label
                guard let button = (buttons(panel) + (panel.contentView.map { buttons($0) } ?? [])).first(where: { $0.accessibilityLabel() == "What happens during Upload" }) else { throw Failure.scope }
                let disclosureFrame = button.accessibilityFrame(); try require(disclosureFrame.width >= 120 && disclosureFrame.height >= 15)
                var pressed = false
                let report = try await NativeMotionRecorder.record(window: window, root: admitted, label: label, sampling: .diagnostic(for: window)) { pressed = button.accessibilityPerformPress() }
                try require(pressed && review.model.details == expanded)
                try JSONEncoder().encode(report).write(to: admitted.appendingPathComponent("evidence/\(label).json"), options: .withoutOverwriting)
                clips.append(DevelopmentMotionVerification.clip(label, report: report, field: nil, window: window))
            }
            checkpoint = "native-field"
            func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
            guard let content = panel.contentView, let field = descendants(content).compactMap({ $0 as? NSTextField }).first(where: { $0.placeholderString == "Folder name" }),
                  panel.makeFirstResponder(field), let editor = field.currentEditor() as? NSTextView else { throw Failure.scope }
            let label = "folder-upload-name-edit"
            let report = try await NativeMotionRecorder.record(window: window, root: admitted, label: label, sampling: .diagnostic(for: window)) {
                editor.selectAll(nil); editor.insertText("Reviewed Folder", replacementRange: .init(location: 0, length: field.stringValue.utf16.count))
            }
            try require(review.model.name == "Reviewed Folder" && review.model.valid)
            try JSONEncoder().encode(report).write(to: admitted.appendingPathComponent("evidence/\(label).json"), options: .withoutOverwriting)
            var clip = DevelopmentMotionVerification.clip(label, report: report, field: nil, window: window)
            let screen = panel.convertToScreen(field.convert(field.bounds, to: nil))
            clip["fieldRegion"] = ["x": screen.minX - window.frame.minX, "y": window.frame.maxY - screen.maxY, "width": screen.width, "height": screen.height]
            clips.append(clip)
            review.model.name = "../refused"; try require(!review.model.valid); review.model.name = "Reviewed Folder"
            checkpoint = "fixed-actions"
            let actionControls = buttons(panel) + (panel.contentView.map { buttons($0) } ?? [])
            for title in ["Cancel", "Upload Folder"] {
                guard let control = actionControls.first(where: { $0.accessibilityLabel() == title }) else { throw Failure.scope }
                let frame = control.accessibilityFrame(); try require(frame.width > 30 && frame.height > 15 && panel.frame.insetBy(dx: -2, dy: -2).contains(frame))
            }
            review.finish(nil); try require(await choice.value == nil); pending = nil
            try require(window.attachedSheet == nil && browser.operationTask == nil && browser.operationPreparationTask == nil && browser.sftpTabs.isEmpty && browser.smbTabs.isEmpty)
            try write(["passed": true, "surface": "folder-upload-preview", "clips": clips, "motion": motion.rawValue, "interfacePercent": settings.interfaceSize.percent,
                "glass": settings.navigationStyle == .glass, "nativeAccessibleDisclosurePresses": 2, "nativeFieldEdited": true, "fixedActionsVisible": true,
                "invalidNameRefused": true, "cancelDrained": true, "networkRequests": 0, "keychainCalls": 0, "sourceBodyReads": 0, "transferAuthority": false], root: admitted)
        } catch {
            preview?.finish(nil); _ = await pending?.value
            var line: UInt = 0; if case let Failure.check(value) = error { line = value }
            if let root { try? write(["passed": false, "line": line, "checkpoint": checkpoint, "errorType": String(reflecting: type(of: error)), "captureFailure": (error as? NativeMotionRecorder.Failure)?.rawValue ?? "none"], root: root) }
        }
        owner?.window?.close(); NSApplication.shared.terminate(nil)
    }
    private static func write(_ value: [String: Any], root: URL) throws {
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("evidence/native-folder-upload-preview.json"), options: .withoutOverwriting)
    }
    @MainActor private final class Pulse {
        var phase="idle",previous=ProcessInfo.processInfo.systemUptime,gap=0.0,byPhase=[String:Double](),samples=0
        func sample(){let now=ProcessInfo.processInfo.systemUptime,elapsed=now-previous;previous=now;gap=max(gap,elapsed);byPhase[phase]=max(byPhase[phase] ?? 0,elapsed);samples+=1}
        func change(_ value:String){phase=value}
    }
    private static func profileCaptureTitle(source:SFTPFolderUploadSourceReview,window:NSWindow,settings:BrowserSettings,root:URL)async throws->[String:Any] {
        let review=SFTPFolderUploadPreview(source:source,destination:"Generated destination",settings:settings)
        let choice=Task{@MainActor in await review.choose(in:window)}
        do {
            try await wait{window.attachedSheet===review.window && review.window?.isVisible==true}
            try await Task.sleep(for:.milliseconds(30))
            let label="folder-review-title-scope"
            window.title="Generated destination folder"
            var refused=false
            do{try NativeMotionRecorder.validateScope(window:window,root:root,label:label)}
            catch NativeMotionRecorder.Failure.scope{refused=true}
            try require(refused)
            window.title="Folder Upload · generated review"
            try NativeMotionRecorder.validateScope(window:window,root:root,label:label)
            let report=try await NativeMotionRecorder.record(window:window,root:root,label:label,sampling:.diagnostic(for:window)){review.model.details=true}
            try JSONEncoder().encode(report).write(to:root.appendingPathComponent("evidence/\(label).json"),options:.withoutOverwriting)
            try require(review.model.details)
            review.finish(nil);try require(await choice.value==nil && window.attachedSheet==nil)
            return["passed":true,"diagnosticOnly":true,"captureTitleRefusalAndAcceptance":true,
                "clips":[DevelopmentMotionVerification.clip(label,report:report,field:nil,window:window)],
                "networkRequests":0,"transferAuthority":false,"keychainCalls":0,"sourceBodyReads":0]
        } catch {
            review.finish(nil);_ = await choice.value;throw error
        }
    }
    private static func profile(source:SFTPFolderUploadSourceReview,window:NSWindow,settings:BrowserSettings,settledFirst:Bool)async throws->[String:Any] {
        var rows=[[String:Any]]()
        for delay in settledFirst ? [350,0]:[0,350] {
            let timerPulse=Pulse(),taskPulse=Pulse()
            let timer=Timer(timeInterval:0.01,repeats:true){_ in MainActor.assumeIsolated{timerPulse.sample()}}
            RunLoop.main.add(timer,forMode:.common);RunLoop.main.add(timer,forMode:.eventTracking)
            let task=Task{@MainActor in while !Task.isCancelled{taskPulse.sample();do{try await Task.sleep(for:.milliseconds(10))}catch{return}}}
            func phase(_ value:String){timerPulse.change(value);taskPulse.change(value)}
            var spans=[String:Double]();phase("construct-review");let began=ProcessInfo.processInfo.systemUptime
            let review=SFTPFolderUploadPreview(source:source,destination:"Generated destination",settings:settings)
            spans["construct-review"]=ProcessInfo.processInfo.systemUptime-began
            review.lifecycleForVerification={name,seconds in spans[name]=seconds;phase(name)}
            let choice=Task{@MainActor in await review.choose(in:window)}
            try await wait{window.attachedSheet===review.window};phase("visible-sheet")
            if delay>0{try await Task.sleep(for:.milliseconds(delay))}
            phase("finish-review");let finishing=ProcessInfo.processInfo.systemUptime;review.finish(nil)
            spans["finish-total"]=ProcessInfo.processInfo.systemUptime-finishing
            _=await choice.value;phase("completed")
            try await Task.sleep(for:.milliseconds(50));task.cancel();await task.value;timer.invalidate()
            try require(window.attachedSheet==nil)
            rows.append(["delayBeforeFinishMilliseconds":delay,"synchronousSpans":spans,"taskGapSeconds":taskPulse.gap,"taskGapsByPhase":taskPulse.byPhase,
                "commonModeTimerGapSeconds":timerPulse.gap,"timerGapsByPhase":timerPulse.byPhase,"timerSamples":timerPulse.samples])
        }
        return["passed":true,"diagnosticOnly":true,"samples":rows,"networkRequests":0,"transferAuthority":false,"keychainCalls":0,"sourceBodyReads":0]
    }
}
#endif
