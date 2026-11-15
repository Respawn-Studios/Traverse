#if DEBUG
    import AppKit
    import ExplorerCore

    @MainActor enum MotionModesVerification {
        static func run(root: URL, controller: BrowserWindowController) async throws -> [String: Any] {
            let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent()
            let sharedToolRegression = ProcessInfo.processInfo.arguments.contains("--check-shared-tool-motion")
                && root.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-release")
                && ((try? Data(contentsOf:root.appendingPathComponent("reservation.json")))
                    .flatMap {try? JSONSerialization.jsonObject(with:$0)as?[String:Any]})?["action"]as?String == "traverse-properties-storage"
            try UIVerification.require(
                (root.deletingLastPathComponent() == repo.appendingPathComponent(".build/overnight-foundation") || sharedToolRegression)
                    && root.resolvingSymlinksInPath() == root
                    && UUID(uuidString: root.lastPathComponent)?.uuidString == root.lastPathComponent,
                "Motion QA needs its admitted generated case")
            let modelChecks = try verifyModel()
            let settings = controller.browser.settings
            let persistence = root.appendingPathComponent("preferences/preferences.json")
            let stored = BrowserSettings(persist: false, persistenceFile: persistence)
            stored.motion.mode = .reduced
            stored.motion.folders = false
            await stored.drainPreferencesForVerification()
            let reopened = BrowserSettings(persist: false, persistenceFile: persistence)
            try UIVerification.require(
                reopened.motion.mode == .reduced && !reopened.motion.folders,
                "Three-mode preferences did not survive an actual save/reopen")
            let workspace = controller.workspace
            try await wait { workspace.sessionReady }
            var browser = controller.browser
            browser.permitsBackgroundVerification = true
            settings.navigationStyle = .glass
            settings.glassFileContent = true
            browser.navigate(to: .directory(root.appendingPathComponent("source/Folder A")))
            try await wait { !browser.isLoading && browser.orderingTask == nil }
            guard let window = controller.window else { throw UIVerification.Failure(message: "Motion window missing") }
            let chromeHost = NSViewController()
            chromeHost.view = NSView(frame: .init(x: 0, y: 0, width: 820, height: 540))
            let chartWindow = NSWindow(contentViewController: chromeHost)
            chartWindow.title = "Storage motion · generated review"
            chartWindow.isReleasedWhenClosed = false
            chartWindow.styleMask = [.titled, .closable]
            chartWindow.setContentSize(.init(width: 820, height: 540))
            ToolWindowChrome.install(in: chartWindow, settings: settings)
            let chart = StorageDimensionalChartView(frame: .init(x: 12, y: 30, width: 470, height: 430))
            chart.forceVisiblePresentationForQualification = true
            chromeHost.view.addSubview(chart)
            let title = NSTextField(labelWithString: "Generated storage breakdown")
            title.font = .systemFont(ofSize: 20, weight: .semibold)
            title.frame = .init(x: 20, y: 475, width: 700, height: 30)
            chromeHost.view.addSubview(title)
            let note = NSTextField(
                wrappingLabelWithString:
                    "Generated totals only. No scan, file-body reads or stored queries. Full retains the dimensional transition; Reduced is shorter and quieter; Off updates immediately."
            )
            note.frame = .init(x: 505, y: 175, width: 285, height: 150)
            note.textColor = .secondaryLabelColor
            chromeHost.view.addSubview(note)
            let samples = StorageDimensionalChartVerification.sampleFrames()
            var timings: [[String: Any]] = []
            var recordings: [NativeMotionRecorder.Report] = []
            let record = ProcessInfo.processInfo.arguments.contains("--record-motion-modes")
            let systemReduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            defer {
                chart.stopPresentation()
                chartWindow.close()
                settings.motion = .init()
            }
            for mode in BrowserMotionMode.allCases {
                settings.motion.mode = mode
                try await Task.sleep(for: .milliseconds(30))
                browser = controller.browser
                browser.permitsBackgroundVerification = true
                try UIVerification.require(
                    browser.tabStrip.motionMode == mode && browser.volumeBrowser.motion.mode == mode
                        && browser.footerOperationButton.motion.mode == mode,
                    "Open browser controls did not receive the chosen mode")
                window.setContentSize(.init(width: 900, height: 560))
                window.title = "Tab motion · generated review"
                window.center()
                window.makeKeyAndOrderFront(nil)
                if record {
                    recordings.append(
                        try await NativeMotionRecorder.record(
                            window: window, root: root, label: "tabs-" + mode.rawValue
                        ) { browser.newTab(nil) })
                } else {
                    browser.newTab(nil)
                }
                try await wait { !browser.isLoading && browser.orderingTask == nil }
                browser.closeTab(id: browser.activeID)
                try await wait { !browser.isLoading && browser.orderingTask == nil }
                let arrow = FileHeaderSortIndicator()
                arrow.place(in: .init(x: 0, y: 0, width: 16, height: 16))
                arrow.present(ascending: true, opacity: 1, motion: false, mode: mode)
                arrow.present(ascending: false, opacity: 1, motion: !systemReduced, mode: mode)
                let turn = arrow.glyphLayer.animation(forKey: "sortTurn")?.duration
                try UIVerification.require(
                    (mode == .off || systemReduced) ? turn == nil : turn != nil,
                    "Sort indicator did not honor the motion mode")
                if let turn {
                    try UIVerification.require(
                        abs(turn - 0.14 * mode.durationScale) < 0.001, "Sort motion duration differs")
                }
                arrow.finishMotion()
                window.setContentSize(.init(width: 1140, height: 760))
                workspace.view.layoutSubtreeIfNeeded()
                let beganPane = ProcessInfo.processInfo.systemUptime
                try UIVerification.require(workspace.splitActive(at: .trailing), "Generated pane split failed")
                let paneAnimated = workspace.hasPaneTransitionForVerification
                try await wait { !workspace.hasPaneTransitionForVerification }
                let paneSeconds = ProcessInfo.processInfo.systemUptime - beganPane
                try UIVerification.require(
                    (mode == .off || systemReduced) ? !paneAnimated : paneAnimated, "Pane animation admission differs")
                try UIVerification.require(workspace.closeActivePane(), "Generated pane close failed")
                try await wait { !workspace.hasPaneTransitionForVerification }
                chartWindow.center()
                chartWindow.makeKeyAndOrderFront(nil)
                title.stringValue = mode.title
                chart.update(
                    [samples[0]], style: .tilted, reduceMotion: systemReduced, reduceTransparency: false,
                    motionMode: mode)
                let beganChart = ProcessInfo.processInfo.systemUptime
                if record {
                    recordings.append(
                        try await NativeMotionRecorder.record(
                            window: chartWindow, root: root, label: "chart-" + mode.rawValue
                        ) {
                            chart.update(
                                [samples[0], samples[1]], style: .tilted, reduceMotion: systemReduced,
                                reduceTransparency: false, motionMode: mode)
                        })
                } else {
                    chart.update(
                        [samples[0], samples[1]], style: .tilted, reduceMotion: systemReduced,
                        reduceTransparency: false, motionMode: mode)
                }
                try await wait { !chart.isTransitioning && !chart.isAnimating }
                let chartSeconds = ProcessInfo.processInfo.systemUptime - beganChart
                let chrome = chartWindow.contentViewController as? ToolWindowChrome
                try UIVerification.require(
                    chrome?.motion.mode == mode
                        && chartWindow.animationBehavior == (mode == .full && !systemReduced ? .utilityWindow : .none),
                    "Tool-window opening does not follow motion preference")
                ToolContentMotion.reveal(chromeHost.view, effect: .windows)
                let entrance = chromeHost.view.layer?.animation(forKey: "tool-content-entrance")?.duration
                try UIVerification.require(
                    (mode == .off || systemReduced) ? entrance == nil : entrance != nil, "Tool entrance motion differs")
                timings.append([
                    "mode": mode.rawValue, "paneSeconds": paneSeconds, "paneAnimated": paneAnimated,
                    "chartWorkAndOptionalRecordingSeconds": chartSeconds, "arrowDuration": turn ?? 0,
                    "toolEntranceDuration": entrance ?? 0,
                ])
                chart.stopPresentation()
            }
            if !systemReduced, let full = timings.first?["paneSeconds"] as? Double,
                let reduced = timings.dropFirst().first?["paneSeconds"] as? Double
            {
                try UIVerification.require(
                    full > 0.20 && reduced < full * 0.85, "Reduced pane motion did not materially shorten presentation")
            }
            return [
                "passed": true, "modelChecks": modelChecks, "actualPreferenceSaveReopen": true,
                "systemReduceMotion": systemReduced, "modes": timings, "fileBodiesRead": 0, "operationMutations": 0,
                "recordings": try recordings.map { try JSONSerialization.jsonObject(with: JSONEncoder().encode($0)) },
                "notExercised": ["Changing the owner's system accessibility settings", "Full VoiceOver task"],
            ]
        }
        private static func verifyModel() throws -> Int {
            var count = 0
            for mode in BrowserMotionMode.allCases {
                for effect in BrowserMotionEffect.allCases {
                    var value = BrowserMotionPreferences(mode: mode)
                    value.set(false, for: effect)
                    let encoded = try JSONEncoder().encode(value)
                    let decoded = try JSONDecoder().decode(BrowserMotionPreferences.self, from: encoded)
                    try UIVerification.require(
                        decoded == value && !decoded.allows(effect), "Mode/effect round trip lost a preference")
                    let legacy = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
                    try UIVerification.require(
                        legacy["reduceMotion"] as? Bool == (mode != .full), "Older-build quiet fallback is incorrect")
                    value.set(true, for: effect)
                    try UIVerification.require(value.allows(effect) == (mode != .off), "Off mode admitted an effect")
                    count += 1
                }
            }
            let legacy = try JSONDecoder().decode(
                BrowserMotionPreferences.self, from: Data(#"{"reduceMotion":true,"folders":false}"#.utf8))
            try UIVerification.require(
                legacy.mode == .off && !legacy.folders && legacy.charts, "Legacy disabled motion was re-enabled")
            let old = try JSONDecoder().decode(
                BrowserMotionPreferences.self, from: Data(#"{"reduceMotion":false,"tabStrip":false}"#.utf8))
            try UIVerification.require(old.mode == .full && !old.tabStrip, "Legacy per-effect choice was lost")
            try UIVerification.require(
                BrowserMotionPreferences(reduceMotion: true).mode == .off, "Legacy native construction changed")
            var rejected = false
            do {
                _ = try JSONDecoder().decode(BrowserMotionPreferences.self, from: Data(#"{"mode":"future-mode"}"#.utf8))
            } catch { rejected = true }
            try UIVerification.require(rejected, "Unknown motion mode was silently interpreted")
            return count + 4
        }
        private static func wait(_ predicate: () -> Bool) async throws {
            for _ in 0..<1000 {
                if predicate() { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            throw UIVerification.Failure(message: "Generated motion did not settle")
        }
    }
#endif
