#if DEBUG
import AppKit
import CryptoKit
import ExplorerCore

/// Exact owned-window pixels for public column labels; generated fixtures only.
@MainActor enum HeaderPresentationVerification {
    static func run(root: URL, output: URL, browser: BrowserViewController, review: Bool) async throws -> [String: Any] {
        let settings = browser.settings
        settings.appearance = .dark; settings.navigationStyle = .glass; settings.glassFileContent = true
        settings.autoRefreshFolders = false; settings.reviewsRecoveryAtStartup = false
        browser.permitsBackgroundVerification = true
        guard let window = browser.view.window else { throw UIVerification.Failure(message: "Missing header check window") }
        window.setContentSize(.init(width: 1200, height: 820))
        window.makeKeyAndOrderFront(nil); NSApplication.shared.activate(ignoringOtherApps: true)
        browser.navigate(to: .directory(root.appendingPathComponent("Files")))
        try await settle(browser); try await Task.sleep(for: .milliseconds(350))
        guard let header = browser.table.headerView as? FileTableHeaderView else { throw UIVerification.Failure(message: "Missing sortable header") }
        try UIVerification.require(header.acceptsFirstMouse(for: nil)
            && header.trackingAreas.contains { $0.options.contains(.activeAlways) },
            "Header still consumes the activation click or waits for app activation to preview")
        try hover(nil, header: header, browser: browser)
        var columns: [[String: Any]] = [], failures: [String] = []
        let clicks = try await verifyNativeClicks(header: header, browser: browser, window: window, output: output, failures: &failures)
        let forceRedraw = ProcessInfo.processInfo.arguments.contains("--force-header-redraw")
        for field in [BrowserColumn.name, .modified, .kind, .size] {
            guard let column = browser.table.tableColumns.first(where: { $0.identifier.rawValue == field.rawValue }) else { continue }
            var masks: [[UInt8]] = []
            for ascending in [true, false] {
                browser.table.sortDescriptors = [NSSortDescriptor(key: field.rawValue, ascending: ascending)]
                try await settle(browser); try await Task.sleep(for: .milliseconds(240))
                if forceRedraw { browser.table.headerView?.needsDisplay = true; browser.table.headerView?.displayIfNeeded() }
                let png = output.appendingPathComponent("header-\(field.rawValue)-\(ascending ? "up" : "down").png")
                try await GlassVerification.captureOwnedWindow(window, to: png)
                let mask = try arrowPixels(column, browser: browser, png: png)
                masks.append(mask)
                if !mask.contains(1) { failures.append("Missing visible \(field.rawValue) \(ascending ? "ascending" : "descending") indicator") }
                for other in browser.table.tableColumns where other !== column && !other.isHidden {
                    if try arrowPixels(other, browser: browser, png: png).contains(1) {
                        failures.append("Inactive \(other.identifier.rawValue) retains an arrow while sorting \(field.rawValue)")
                    }
                }
                try UIVerification.require(browser.tabs[browser.activeIndex].sort.field == field.sortField
                    && browser.tabs[browser.activeIndex].sort.ascending == ascending, "Header action lost native sort state")
            }
            let changes = masks[0] != masks[1]
            if !changes { failures.append("\(field.rawValue) arrow does not reverse") }
            columns.append(["field": field.rawValue, "ascendingPixels": masks[0].filter { $0 == 1 }.count,
                "descendingPixels": masks[1].filter { $0 == 1 }.count, "reverses": changes,
                "upSHA256": hash(masks[0]), "downSHA256": hash(masks[1])])
        }
        browser.table.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]
        try await settle(browser); try await Task.sleep(for: .milliseconds(240))
        let hoverReport = try await verifyHoverAndMotion(header: header, browser: browser, window: window, output: output)
        if ProcessInfo.processInfo.arguments.contains("--header-interactions-only") {
            try await prepareReview(root: root, browser: browser, window: window, review: review)
            let result: [String: Any] = ["passed": failures.isEmpty, "readOnlyCatalog": true, "generatedOnly": true,
                "columns": columns, "failures": failures, "review": review, "hoverAndMotion": hoverReport,
                "nativeClicks": clicks, "navigationRecheck": false,
                "scope": "Native header tracking, exact arrow pixels and hover/turn responsiveness; navigation compositor not rerun"]
            try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
                .write(to: output.appendingPathComponent("header-regression.json"), options: .withoutOverwriting)
            return result
        }
        let baselinePNG = output.appendingPathComponent("transition-before.png")
        try await GlassVerification.captureOwnedWindow(window, to: baselinePNG)
        browser.prepareCanvasTransition(enabled: true)
        let bridge = browser.canvasTransition
        let bridgeParent = bridge?.superview.map { String(describing: type(of: $0)) } ?? "missing"
        let duringPNG = output.appendingPathComponent("transition-during.png")
        try await GlassVerification.captureOwnedWindow(window, to: duringPNG)
        let bridgeWasPresent = bridge?.isFinished == false
        let before = try quietPixels(browser, png: baselinePNG), during = try quietPixels(browser, png: duringPNG)
        let backgroundDelta = zip(before, during).map { abs($0 - $1) }.max() ?? 0
        var blankAlpha: [Double] = []
        if let parent = browser.contentSurface?.contentView,
           let bitmap = browser.canvasTransition?.image?.representations.first as? NSBitmapImageRep,
           let index = browser.table.tableColumns.firstIndex(where: { $0.identifier.rawValue == "name" }) {
            for row in 0..<min(2, browser.table.numberOfRows) {
                let rect = browser.table.frameOfCell(atColumn: index, row: row)
                let point = parent.convert(NSPoint(x: rect.minX + rect.width * 0.75, y: rect.midY), from: browser.table)
                let x = Int((point.x - parent.bounds.minX) / parent.bounds.width * CGFloat(bitmap.pixelsWide))
                let y = Int((parent.bounds.maxY - point.y) / parent.bounds.height * CGFloat(bitmap.pixelsHigh))
                if let color = bitmap.colorAt(x: x, y: y) { blankAlpha.append(Double(color.alphaComponent)) }
            }
        }
        browser.canvasTransition?.finish()
        if blankAlpha.isEmpty || blankAlpha.contains(where: { $0 > 0.02 }) { failures.append("Transition picture contains a tint over blank row space") }
        if !bridgeWasPresent { failures.append("Transition compositor sample missed its active picture") }
        if backgroundDelta > 0.02 { failures.append("Adding the transition picture changes the stationary glass background") }
        // Same source pixels and fixed geometry; the destination is generated
        // and empty, so any transient overshoot is not new destination ink.
        let points = motionPoints(browser)
        let sourceRange = try motionRange(window: window, points: points, png: baselinePNG)
        browser.navigate(to: .directory(root.appendingPathComponent("Files/Folder")))
        let navPNG = output.appendingPathComponent("navigation-during.png")
        try await GlassVerification.captureOwnedWindow(window, to: navPNG)
        let movingPixels = try pixels(window: window, points: points, png: navPNG)
        try await settle(browser)
        let endPNG = output.appendingPathComponent("navigation-after.png")
        try await GlassVerification.captureOwnedWindow(window, to: endPNG)
        let finalPixels = try pixels(window: window, points: points, png: endPNG)
        let overshoot = zip(zip(zip(sourceRange.low, sourceRange.high), finalPixels), movingPixels).map { values, during in
            max(0, during - max(values.0.1, values.1), min(values.0.0, values.1) - during)
        }.max() ?? 0
        if overshoot > 0.04 { failures.append("Navigation picture changes pixels outside the source/destination color range") }
        browser.navigate(to: .directory(root.appendingPathComponent("Files"))); try await settle(browser)
        try await prepareReview(root: root, browser: browser, window: window, review: review)
        let result: [String: Any] = ["passed": failures.isEmpty, "readOnlyCatalog": true, "generatedOnly": true,
            "columns": columns, "blankRowAlpha": blankAlpha, "failures": failures, "review": review,
            "forcedHeaderRedraw": forceRedraw, "transitionParent": bridgeParent,
            "hoverAndMotion": hoverReport,
            "nativeClicks": clicks,
            "compositedBackgroundDelta": backgroundDelta, "bridgePresentDuringCapture": bridgeWasPresent,
            "navigationPixelOvershoot": overshoot,
            "scope": "Actual owned header pixels and actual transition picture; no personal catalog or file mutation"]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("header-regression.json"), options: .withoutOverwriting)
        return result
    }
    private static func prepareReview(root: URL, browser: BrowserViewController, window: NSWindow, review: Bool) async throws {
        if review {
            let source = browser.activeID
            browser.newTab(nil); try await settle(browser)
            browser.navigate(to: .directory(root.appendingPathComponent("Files/Folder"))); try await settle(browser)
            browser.selectTab(source); try await settle(browser)
        }
        window.title = "Header interaction review · " + String(root.lastPathComponent.prefix(8))
    }
    private static func verifyNativeClicks(header: FileTableHeaderView, browser: BrowserViewController,
        window: NSWindow, output: URL, failures: inout [String]) async throws -> [[String: Any]] {
        var report: [[String: Any]] = []
        defer {
            try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: output.appendingPathComponent("native-clicks.json"), options: .withoutOverwriting)
        }
        for (step, field) in [BrowserColumn.kind, .modified, .size, .name, .kind].enumerated() {
            guard let index = browser.table.tableColumns.firstIndex(where: { $0.identifier.rawValue == field.rawValue }) else { continue }
            let column = browser.table.tableColumns[index]
            try hover(column, header: header, browser: browser)
            let previewUp = (header.indicatorForVerification(column)?.glyphLayer.transform.m11 ?? 0) > 0
            let milliseconds = try nativeClick(index: index, header: header, window: window)
            let firstUp = browser.table.sortDescriptors.first?.ascending
            report.append(["field": field.rawValue, "nativeClickMilliseconds": milliseconds,
                "descriptorKeys": browser.table.sortDescriptors.compactMap(\.key)])
            try UIVerification.require(browser.table.sortDescriptors.first?.key == field.rawValue,
                "Native header click did not select \(field.rawValue)")
            try UIVerification.require(firstUp == previewUp, "Hover direction differs from the native first-click direction")
            header.displayIfNeeded()
            let repeated = try nativeClick(index: index, header: header, window: window)
            try UIVerification.require(browser.table.sortDescriptors.first?.ascending != firstUp,
                "Second native click did not reverse \(field.rawValue)")
            try UIVerification.require(milliseconds < 50 && repeated < 50, "Native header handling exceeds the 50 ms fixture gate")
            report[report.count - 1]["repeatedClickMilliseconds"] = repeated
            report[report.count - 1]["previewDirectionMatches"] = true
            try hover(nil, header: header, browser: browser)
            try await settle(browser); try await Task.sleep(for: .milliseconds(240))
            let png = output.appendingPathComponent("native-click-\(step)-\(field.rawValue).png")
            try await GlassVerification.captureOwnedWindow(window, to: png)
            var retained: [String] = []
            for other in browser.table.tableColumns where other !== column && !other.isHidden {
                if try arrowPixels(other, browser: browser, png: png).contains(1) { retained.append(other.identifier.rawValue) }
            }
            if !retained.isEmpty { failures.append("Real native click on \(field.rawValue) leaves stale arrows: \(retained.joined(separator: ", "))") }
            report[report.count - 1]["retainedInactiveArrows"] = retained
        }
        return report
    }
    private static func nativeClick(index: Int, header: FileTableHeaderView, window: NSWindow) throws -> Double {
        let point = header.convert(NSPoint(x: header.headerRect(ofColumn: index).midX, y: header.bounds.midY), to: nil)
        let stamp = ProcessInfo.processInfo.systemUptime
        func event(_ type: NSEvent.EventType) throws -> NSEvent {
            guard let value = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: stamp,
                windowNumber: window.windowNumber, context: nil, eventNumber: 912, clickCount: 1, pressure: 0) else {
                throw UIVerification.Failure(message: "Missing local native header click")
            }
            return value
        }
        let down = try event(.leftMouseDown), up = try event(.leftMouseUp)
        NSApp.postEvent(up, atStart: true)
        // This is native component tracking, not physical pointer delivery.
        header.mouseDown(with: down)
        if let pending = NSApp.nextEvent(matching: .leftMouseUp, until: .distantPast, inMode: .default, dequeue: false),
           pending.windowNumber == up.windowNumber && pending.timestamp == up.timestamp && pending.eventNumber == up.eventNumber,
           let release = NSApp.nextEvent(matching: .leftMouseUp, until: .distantPast, inMode: .default, dequeue: true) { NSApp.sendEvent(release) }
        return (ProcessInfo.processInfo.systemUptime - stamp) * 1000
    }
    private static func verifyHoverAndMotion(header: FileTableHeaderView, browser: BrowserViewController,
                                            window: NSWindow, output: URL) async throws -> [String: Any] {
        let table = browser.table
        guard let name = table.tableColumns.first(where: { $0.identifier.rawValue == "name" }),
              let kind = table.tableColumns.first(where: { $0.identifier.rawValue == "kind" }) else {
            throw UIVerification.Failure(message: "Missing generated sort columns")
        }
        guard let active = header.indicatorForVerification(name), let preview = header.indicatorForVerification(kind) else {
            throw UIVerification.Failure(message: "Missing decorative sort glyphs")
        }
        let hoverStart = ProcessInfo.processInfo.systemUptime
        try hover(kind, header: header, browser: browser)
        let hoverMilliseconds = (ProcessInfo.processInfo.systemUptime - hoverStart) * 1000
        try await Task.sleep(for: .milliseconds(35))
        let hoverPresented = preview.glyphLayer.presentation()?.opacity ?? preview.glyphLayer.opacity
        let systemReduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let entrance = preview.glyphLayer.animation(forKey:"sortHover")as?CABasicAnimation
        try UIVerification.require(hoverMilliseconds<16 && preview.glyphLayer.opacity == 0.55 && hoverPresented>=0.30
            && (systemReduced ? entrance == nil : entrance?.duration == 0.09),
            "Hover preview missed immediate visible feedback or its bounded entrance")
        let hovered = output.appendingPathComponent("header-hover.png")
        try await GlassVerification.captureOwnedWindow(window, to: hovered)
        let baseline = output.appendingPathComponent("header-name-up.png")
        let difference = zip(try arrowValues(kind, browser: browser, png: baseline),
                             try arrowValues(kind, browser: browser, png: hovered)).filter { abs($0 - $1) > 0.06 }.count
        try UIVerification.require(difference >= 3 && table.sortDescriptors.first?.key == "name"
            && (try arrowPixels(name, browser: browser, png: hovered)).contains(1),
            "Hover did not show its preview alongside the actual sort arrow")
        guard let backing = header.layer, let superview = header.superview else {
            throw UIVerification.Failure(message: "Native header backing missing")
        }
        let activeSlot = header.convertFromLayer(active.containerLayer.frame)
        let previewSlot = header.convertFromLayer(preview.containerLayer.frame)
        let activePoint = header.convert(NSPoint(x: activeSlot.midX, y: activeSlot.midY), to: superview)
        let previewPoint = header.convert(NSPoint(x: previewSlot.midX, y: previewSlot.midY), to: superview)
        try UIVerification.require(active.containerLayer.superlayer === backing && preview.containerLayer.superlayer === backing
            && header.hitTest(activePoint) === header && header.hitTest(previewPoint) === header
            && name.headerCell.accessibilitySortDirection() == .ascending
            && kind.headerCell.accessibilitySortDirection() == .unknown,
            "Passive sort layers intercepted native header input or changed its accessibility sort state")
        try hover(nil, header: header, browser: browser)
        try await Task.sleep(for: .milliseconds(35))
        try UIVerification.require(preview.glyphLayer.opacity == 0 && active.glyphLayer.opacity == 1
            && (preview.glyphLayer.presentation()?.opacity ?? 0) <= 0.01,
            "Mouse exit lost the current arrow or retained the preview")
        table.sortDescriptors = [NSSortDescriptor(key: "name", ascending: false)]; header.displayIfNeeded()
        let turn = active.glyphLayer.animation(forKey: "sortTurn") as? CABasicAnimation
        let clockwise = ((turn?.toValue as? NSNumber)?.doubleValue ?? 0) - ((turn?.fromValue as? NSNumber)?.doubleValue ?? 0)
        try UIVerification.require(systemReduced ? turn == nil : (turn?.duration == 0.14 && abs(clockwise - .pi) < 0.02),
            "Sort reversal missed its bounded native turn or ignored system Reduce Motion")
        try await Task.sleep(for: .milliseconds(60))
        let angle = active.glyphLayer.presentation().map { atan2(Double($0.transform.m12), Double($0.transform.m11)) } ?? 0
        table.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]; header.displayIfNeeded()
        let reverse = active.glyphLayer.animation(forKey: "sortTurn") as? CABasicAnimation
        if !systemReduced {
            let from = (reverse?.fromValue as? NSNumber)?.doubleValue ?? -10
            let to = (reverse?.toValue as? NSNumber)?.doubleValue ?? 10
            try UIVerification.require(abs(from - angle) < 0.4 && abs(from) > 0.01 && to < from,
                "Rapid reversal restarted from an endpoint instead of the current presentation")
        }
        browser.settings.motion.sortIndicators = false
        try UIVerification.require(!header.motionEnabled && active.glyphLayer.animationKeys()?.isEmpty != false,
            "Disabling sort motion did not drain the current turn")
        table.sortDescriptors = [NSSortDescriptor(key: "name", ascending: false)]; header.displayIfNeeded()
        try UIVerification.require(active.glyphLayer.animation(forKey: "sortTurn") == nil, "Sort switch left disabled animation running")
        browser.settings.motion.sortIndicators = true; browser.settings.motion.reduceMotion = true
        try UIVerification.require(!header.motionEnabled, "App Reduce Motion left sort turning enabled")
        browser.settings.motion.reduceMotion = false
        let old = Data(#"{"version":16,"motion":{"reduceMotion":false,"tabStrip":false,"tabContent":true,"folders":false,"panes":true,"windows":true,"pages":true}}"#.utf8)
        let restored = BrowserSettings(persist: false, restoredData: old)
        try UIVerification.require(restored.motion.sortIndicators && !restored.motion.tabStrip && !restored.motion.folders,
            "Adding sort motion erased older individual motion choices")
        restored.motion.sortIndicators = false
        let roundtrip = BrowserSettings(persist: false, restoredData: try restored.encodedSnapshot())
        try UIVerification.require(roundtrip.motion == restored.motion, "Sort motion preferences failed to round-trip")
        browser.settings.glassFileContent = false
        try await Task.sleep(for: .milliseconds(80))
        try hover(kind, header: header, browser: browser)
        try await Task.sleep(for: .milliseconds(160))
        try UIVerification.require(!header.usesGlass && preview.glyphLayer.opacity == 0.55,
            "Opaque content lost the same hover behavior")
        browser.settings.glassFileContent = true
        try hover(nil, header: header, browser: browser)
        table.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]; header.displayIfNeeded()
        try await settle(browser); try await Task.sleep(for: .milliseconds(240))
        kind.isHidden = true; header.needsDisplay = true; header.displayIfNeeded()
        header.layoutSubtreeIfNeeded()
        try UIVerification.require(header.indicatorForVerification(kind) == nil && preview.containerLayer.superlayer == nil,
            "Hidden column retained a decorative layer")
        kind.isHidden = false; header.needsLayout = true; header.layoutSubtreeIfNeeded(); header.displayIfNeeded()
        guard let restoredPreview = header.indicatorForVerification(kind) else {
            throw UIVerification.Failure(message: "Restored column has no decorative owner")
        }
        try UIVerification.require(restoredPreview.containerLayer.superlayer === header.layer && restoredPreview.glyphLayer.opacity == 0,
            "Restored column lost its backing or retained a stale arrow")
        return ["passed": true, "previewChangedPixels": difference, "activeArrowRetained": true,
            "turnSeconds":0.14,"hoverEntranceSeconds":0.09,"hoverImmediate":true,"hoverHandlerMilliseconds":hoverMilliseconds,
            "hoverPresentationAt35ms": hoverPresented, "rapidRetarget": !systemReduced,
            "systemReduceMotion": systemReduced, "appAndIndividualMotionDisable": true,
            "headerAcceptsActivationClick": header.acceptsFirstMouse(for: nil),
            "oldPreferencesAndRoundtrip": true, "opaqueAndGlass": true, "nativeInputRetained": true,
            "hiddenColumnLayerDetachedAndRestored": true]
    }
    private static func hover(_ column: NSTableColumn?, header: FileTableHeaderView, browser: BrowserViewController) throws {
        let index = column.flatMap { selected in browser.table.tableColumns.firstIndex { $0 === selected } }
        let point = index.map { NSPoint(x: header.headerRect(ofColumn: $0).midX, y: header.bounds.midY) } ?? NSPoint(x: -10, y: -10)
        guard let event = NSEvent.mouseEvent(with: .mouseMoved, location: header.convert(point, to: nil),
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: header.window?.windowNumber ?? 0,
            context: nil, eventNumber: 0, clickCount: 0, pressure: 0) else { throw UIVerification.Failure(message: "Missing local header event") }
        header.mouseMoved(with: event); header.displayIfNeeded()
    }
    private static func motionRange(window: NSWindow, points: [NSPoint], png: URL) throws -> (low: [Double], high: [Double]) {
        guard let bitmap = NSBitmapImageRep(data: try Data(contentsOf: png)) else { throw UIVerification.Failure(message: "Missing source motion pixels") }
        var low: [Double] = [], high: [Double] = []
        for point in points {
            var minimum = [Double](repeating: 1, count: 3), maximum = [Double](repeating: 0, count: 3)
            // Admit the intended 10-point horizontal movement and subpixel
            // interpolation, so movement itself cannot be called a flicker.
            for dx in -11...11 {
                let x = Int((point.x + CGFloat(dx)) / window.frame.width * CGFloat(bitmap.pixelsWide))
                let y = Int((window.frame.height - point.y) / window.frame.height * CGFloat(bitmap.pixelsHigh))
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { throw UIVerification.Failure(message: "Source sample outside owned window") }
                let value = [Double(color.redComponent), Double(color.greenComponent), Double(color.blueComponent)]
                for channel in 0..<3 { minimum[channel] = min(minimum[channel], value[channel]); maximum[channel] = max(maximum[channel], value[channel]) }
            }
            low += minimum; high += maximum
        }
        return (low, high)
    }
    private static func motionPoints(_ browser: BrowserViewController) -> [NSPoint] {
        let rect = browser.table.rect(ofRow: 0).intersection(browser.table.visibleRect).insetBy(dx: 12, dy: 0)
        var points: [NSPoint] = []
        for y in stride(from: rect.minY + 3, to: rect.maxY - 3, by: 2) {
            for x in stride(from: rect.minX + 3, to: rect.maxX - 3, by: 2) {
                points.append(browser.table.convert(.init(x: x, y: y), to: nil))
            }
        }
        return points
    }
    private static func pixels(window: NSWindow, points: [NSPoint], png: URL) throws -> [Double] {
        guard let bitmap = NSBitmapImageRep(data: try Data(contentsOf: png)) else { throw UIVerification.Failure(message: "Missing generated motion pixels") }
        return try points.flatMap { point in
            let x = Int(point.x / window.frame.width * CGFloat(bitmap.pixelsWide))
            let y = Int((window.frame.height - point.y) / window.frame.height * CGFloat(bitmap.pixelsHigh))
            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { throw UIVerification.Failure(message: "Motion sample outside owned window") }
            return [Double(color.redComponent), Double(color.greenComponent), Double(color.blueComponent)]
        }
    }
    private static func quietPixels(_ browser: BrowserViewController, png: URL) throws -> [Double] {
        guard let header = browser.table.headerView, let window = browser.view.window,
              let bitmap = NSBitmapImageRep(data: try Data(contentsOf: png)) else { throw UIVerification.Failure(message: "Missing compositor sample") }
        let row = browser.table.frameOfCell(atColumn: 0, row: 0)
        let points = [header.convert(NSPoint(x: header.headerRect(ofColumn: 0).midX, y: header.bounds.midY), to: nil),
            browser.table.convert(NSPoint(x: row.minX + row.width * 0.75, y: row.midY), to: nil)]
        var values: [Double] = []
        for point in points { for dy in -2...2 { for dx in -2...2 {
            let x = Int((point.x + CGFloat(dx)) / window.frame.width * CGFloat(bitmap.pixelsWide))
            let y = Int((window.frame.height - point.y + CGFloat(dy)) / window.frame.height * CGFloat(bitmap.pixelsHigh))
            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { throw UIVerification.Failure(message: "Compositor sample outside window") }
            values += [Double(color.redComponent), Double(color.greenComponent), Double(color.blueComponent)]
        } } }
        return values
    }
    private static func arrowPixels(_ column: NSTableColumn, browser: BrowserViewController, png: URL) throws -> [UInt8] {
        try arrowValues(column, browser: browser, png: png).map { $0 > 0.65 ? 1 : 0 }
    }
    private static func arrowValues(_ column: NSTableColumn, browser: BrowserViewController, png: URL) throws -> [Double] {
        guard let header = browser.table.headerView, let window = browser.view.window,
              let index = browser.table.tableColumns.firstIndex(where: { $0 === column }),
              let bitmap = NSBitmapImageRep(data: try Data(contentsOf: png)) else {
            throw UIVerification.Failure(message: "Missing exact owned header pixels")
        }
        let rect = header.headerRect(ofColumn: index)
        var values: [Double] = []
        for y in -6..<6 { for x in 4..<24 {
            let point = header.convert(NSPoint(x: rect.maxX - CGFloat(x), y: rect.midY + CGFloat(y)), to: nil)
            let px = Int(point.x / window.frame.width * CGFloat(bitmap.pixelsWide))
            let py = Int((window.frame.height - point.y) / window.frame.height * CGFloat(bitmap.pixelsHigh))
            guard px >= 0, py >= 0, px < bitmap.pixelsWide, py < bitmap.pixelsHigh,
                  let color = bitmap.colorAt(x: px, y: py)?.usingColorSpace(.deviceRGB) else {
                throw UIVerification.Failure(message: "Header arrow sample outside owned window")
            }
            values.append(Double(max(color.redComponent, color.greenComponent, color.blueComponent)))
        } }
        return values
    }
    private static func hash(_ value: [UInt8]) -> String { SHA256.hash(data: Data(value)).map { String(format: "%02x", $0) }.joined() }
    private static func settle(_ browser: BrowserViewController) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        while browser.isLoading || browser.orderingTask != nil || browser.canvasTransition != nil {
            try UIVerification.require(ProcessInfo.processInfo.systemUptime < deadline, "Header check listing did not settle")
            try await Task.sleep(for: .milliseconds(10))
        }
        browser.view.window?.contentView?.layoutSubtreeIfNeeded()
    }
}
#endif
