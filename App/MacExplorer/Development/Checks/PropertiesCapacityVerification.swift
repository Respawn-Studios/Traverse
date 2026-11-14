#if DEBUG
import AppKit
import ObjectiveC
import ExplorerCore

/// Initial user-visible capacity, using the ordinary controller and in-memory facts.
@MainActor enum PropertiesCapacityVerification {
    private enum Failure: Error { case scope, check(UInt) }
    private static func require(_ value: Bool, _ line: UInt = #line) throws { if !value { throw Failure.check(line) } }
    private struct Reader: FilePropertiesReading {
        func read(_ urls: [URL]) async throws -> FilePropertiesReport {
            .init(selectedCount:1,observations:[.init(id:0,url:urls[0],kind:"Drive",byteCount:nil,createdAt:nil,modifiedAt:nil,accessedAt:nil,
                mode:0o700,ownerID:nil,groupID:nil,isSymbolicLink:false,isDirectory:true,isImmutable:false,isVolumeReadOnly:false,failure:nil,
                volumeCapacity:.init(capacity:1_000_000_000_000,available:400_000_000_000,free:420_000_000_000,observedAt:Date(),reportedUsed:nil))])
        }
    }
    private static func value(_ object: NSObject, _ name: String) -> Any? {
        let selector = NSSelectorFromString(name)
        guard object.responds(to:selector),let method = class_getInstanceMethod(type(of:object),selector),method_getNumberOfArguments(method) == 2 else { return nil }
        let encoding = method_copyReturnType(method); defer { free(encoding) }
        guard String(cString:encoding).hasPrefix("@") else { return nil }
        return object.perform(selector)?.takeUnretainedValue()
    }
    private static func frame(_ object: NSObject) -> NSRect {
        let selector = NSSelectorFromString("accessibilityFrame")
        guard let method = class_getInstanceMethod(type(of:object),selector),method_getNumberOfArguments(method) == 2 else { return .zero }
        let encoding = method_copyReturnType(method); defer { free(encoding) }
        guard String(cString:encoding) == "{CGRect={CGPoint=dd}{CGSize=dd}}" else { return .zero }
        typealias Function = @convention(c) (AnyObject,Selector) -> CGRect
        return unsafeBitCast(method_getImplementation(method),to:Function.self)(object,selector)
    }
    private static func visibleTexts(_ window: NSWindow) -> [String] {
        guard let content = window.contentView else { return [] }
        let visible = window.convertToScreen(content.convert(content.bounds,to:nil))
        var visited = Set<ObjectIdentifier>(), count = 0
        func visit(_ item: Any, depth: Int) -> [String] {
            guard depth <= 24,count < 4096,let object = item as? NSObject,visited.insert(ObjectIdentifier(object)).inserted else { return [] }
            count += 1
            let role = value(object,"accessibilityRole") as? String
            let strings = [value(object,"accessibilityLabel"),value(object,"accessibilityTitle"),value(object,"accessibilityValue")].compactMap{$0 as? String}
            let own = role == NSAccessibility.Role.staticText.rawValue && frame(object).intersects(visible) ? strings : []
            var children = (value(object,"accessibilityChildren") as? [Any] ?? []) + (value(object,"accessibilityContents") as? [Any] ?? [])
            if let view = item as? NSView { children += view.subviews }
            return own + children.flatMap{visit($0,depth:depth+1)}
        }
        return visit(content,depth:0)
    }
    static func run() async {
        var area: URL?, owner: FilePropertiesWindowController?, checks: [String] = [], failure: UInt?, observed: [String] = []
        do {
            guard let raw = ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"] else { throw Failure.scope }
            let root = URL(fileURLWithPath:raw), repo = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let marker = try JSONSerialization.jsonObject(with:Data(contentsOf:root.appendingPathComponent("reservation.json"))) as? [String:Any]
            try require(root.resolvingSymlinksInPath() == root && root.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-development")
                && marker?["action"] as? String == "native-properties-capacity" && Bundle.main.bundleIdentifier == "local.macexplorer.development")
            area = root
            let args = ProcessInfo.processInfo.arguments, large = args.contains("--large-interface"), startup = args.contains("--startup-capacity"), unavailable = args.contains("--unavailable-capacity")
            let settings = BrowserSettings(persist:false); settings.navigationStyle = .glass; settings.glassFileContent = true
            settings.appearance = large ? .light : .dark; settings.interfaceSize = .init(large ? 150 : 100); settings.motion.mode = .reduced
            InterfacePresentation.shared.bind(settings)
            let controller = FilePropertiesWindowController(reader:Reader(),settings:settings,copyPaths:{_ in}); owner = controller
            if args.contains("--startup-data-fallback") {
                try await checkStartupFallback(controller, checks: &checks)
                observed = visibleTexts(controller.window!)
            } else {
            controller.show(urls:[URL(fileURLWithPath:"/Generated/Capacity/Volume")])
            guard let window = controller.window else { throw Failure.scope }
            window.title = "Properties capacity · generated review"
            window.setContentSize(.init(width:large ? 700 : 580,height:large ? 760 : 640))
            let end = ContinuousClock.now + .seconds(6)
            while controller.model.isLoading { try require(.now < end); try await Task.sleep(for:.milliseconds(10)) }
            if startup {
                let volume = controller.model.selectedObservation?.volumeCapacity
                controller.model.showStartupCapacityForVerification(.init(capacity:nil,available:nil,system:nil,data:nil,dataVolume:unavailable ? nil : volume))
            }
            let expected = startup ? (unavailable ? "Shared container capacity" : "Data volume capacity") : "Capacity"
            let layoutEnd = ContinuousClock.now + .seconds(2)
            repeat {
                window.contentView?.layoutSubtreeIfNeeded(); observed = visibleTexts(window)
                if observed.contains(expected) { break }
                try await Task.sleep(for:.milliseconds(25))
            } while .now < layoutEnd
            try require(controller.model.analysisValue == nil && ApplicationFileActivity.gate.activeCount == 0)
            checks.append("The ordinary Properties controller reads only generated volume facts; no scan starts")
            try require(observed.contains(expected))
            checks.append("Capacity is present in the initial visible native accessibility tree without expanding a disclosure")
            try require(observed.contains(startup ? (unavailable ? "Container free at discovery" : "Available to apps on Data") : "Available to apps"))
            checks.append("Availability is visible alongside capacity with honest shared-space/unavailable facts")
            if args.contains("--capacity-review") {
                try Data("generated capacity review ready".utf8).write(to:root.appendingPathComponent("state/Ready"),options:.withoutOverwriting)
                let deadline = ContinuousClock.now + .seconds(90)
                while window.isVisible && .now < deadline { try await Task.sleep(for:.milliseconds(30)) }
                try require(!window.isVisible)
            }
            controller.cancel(); window.close()
            try require(ApplicationFileActivity.gate.activeCount == 0)
            checks.append("Closing Properties drains without a file operation or analysis catalog")
            }
        } catch { if case let Failure.check(line) = error { failure = line } else { failure = 0 } }
        owner?.cancel(); owner?.window?.close()
        if let area {
            let report: [String:Any] = ["passed":failure == nil,"checks":checks,"initialVisibleTexts":observed,"line":failure.map{$0 as Any} ?? NSNull(),
                "fileMutations":0,"sourceBodyReads":0,"networkRequests":0,"activityDrained":ApplicationFileActivity.gate.activeCount == 0]
            try? JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:area.appendingPathComponent("evidence/properties-capacity.json"),options:.withoutOverwriting)
        }
        NSApp.terminate(nil)
    }

    private static func checkStartupFallback(_ controller: FilePropertiesWindowController,
                                              checks: inout [String]) async throws {
        let analysis = ApplicationStorageAnalysis.shared
        analysis.startupFailureForVerification = .unavailable
        analysis.requiresAnalysisSelectionForVerification = false
        var chosenInitial: URL?
        analysis.chooseFolderForVerification = { _, initial in chosenInitial = initial; return nil }
        defer {
            analysis.startupFailureForVerification = nil
            analysis.requiresAnalysisSelectionForVerification = nil
            analysis.chooseFolderForVerification = nil
        }
        controller.show(urls: [URL(fileURLWithPath: "/", isDirectory: true)])
        let loaded = ContinuousClock.now + .seconds(6)
        while controller.model.isLoading {
            try require(.now < loaded); try await Task.sleep(for: .milliseconds(10))
        }
        controller.model.analyzeStorage()
        let failed = ContinuousClock.now + .seconds(10)
        while !controller.model.canAnalyzeStartupData {
            try require(.now < failed); try await Task.sleep(for: .milliseconds(10))
        }
        try require(controller.model.analysisValue?.counts == nil
            && controller.model.analysisValue?.isRunning == false
            && analysis.activeSession == nil && analysis.activePagedSession == nil)
        checks.append("A refused combined startup request offers an explicit separate Data-volume choice without starting a scanner")
        controller.model.analyzeStartupDataVolume()
        let selected = ContinuousClock.now + .seconds(5)
        while chosenInitial == nil || analysis.hasWork {
            try require(.now < selected); try await Task.sleep(for: .milliseconds(10))
        }
        try require(chosenInitial?.path == "/System/Volumes/Data"
            && analysis.currentRoot?.path == "/"
            && analysis.activeSession == nil && analysis.activePagedSession == nil)
        checks.append("The ordinary chooser starts at Data; Cancel preserves the failed original scope and scans nothing")
        analysis.toolWindow?.close()
        controller.cancel(); controller.window?.close()
        let drained = ContinuousClock.now + .seconds(5)
        while analysis.hasWork {
            try require(.now < drained); try await Task.sleep(for: .milliseconds(10))
        }
        try require(ApplicationFileActivity.gate.activeCount == 0)
        checks.append("Properties and full-window cancellation drain their ordinary owners")
    }
}
#endif
