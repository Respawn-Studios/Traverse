#if DEBUG
    import AppKit
    import CryptoKit
    import Foundation

    @MainActor enum BundledNoticesVerification {
        static func run(root: URL, settings: BrowserSettings, capture: Bool) async throws -> [String: Any] {
            let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent()
            try check(
                root.deletingLastPathComponent().path == repo.appendingPathComponent(".build/overnight-foundation").path
                    && root.resolvingSymlinksInPath() == root
                    && UUID(uuidString: root.lastPathComponent)?.uuidString == root.lastPathComponent,
                "Notices QA requires its reserved generated case")
            guard let resources = Bundle.main.resourceURL else { throw BundledNoticeReader.Failure.unavailable }
            let document = try await BundledNoticeReader().read(resources: resources)
            try check(
                (1...512).contains(document.components) && document.text.hasPrefix("Third-Party Software Notices")
                    && document.text.contains("Unicode") && document.text.contains("Rust standard-library"),
                "Actual bundled notices differ")
            let notices = ApplicationNotices.shared
            var beats: [Double] = []
            var last = ProcessInfo.processInfo.systemUptime
            let pulse = Task {
                while !Task.isCancelled {
                    let now = ProcessInfo.processInfo.systemUptime
                    beats.append((now - last) * 1000)
                    last = now
                    try? await Task.sleep(for: .milliseconds(10))
                }
            }
            settings.navigationStyle = .glass
            settings.appearance = .dark
            notices.show(settings: settings, offscreen: !capture)
            try await wait { !notices.isLoading }
            try check(
                notices.didLoad && notices.textForVerification == document.text,
                "Native notices did not load exact local text")
            guard let window = notices.window else { throw BundledNoticeReader.Failure.unavailable }
            window.title = "Third-Party Notices · generated review"
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            if capture {
                try await GlassVerification.captureOwnedWindow(
                    window, to: root.appendingPathComponent("evidence/notices-native.png"))
            }
            try await Task.sleep(for: .milliseconds(30))
            pulse.cancel()
            await pulse.value
            let worst = beats.max() ?? 0
            try check(worst < 250, "Bundled notice loading blocked native responsiveness")
            notices.find(nil)
            try check(window.firstResponder is NSTextView, "Native local Find did not focus the document")
            settings.navigationStyle = .solid
            try await Task.sleep(for: .milliseconds(20))
            try check(
                (window.contentViewController as? ToolWindowChrome)?.surface.isGlassEnabled == false,
                "Notices did not follow Solid")
            settings.navigationStyle = .glass
            settings.motion.mode = .off
            try await Task.sleep(for: .milliseconds(20))
            try check(
                (window.contentViewController as? ToolWindowChrome)?.motion.mode == .off,
                "Notices ignored motion preference")
            await notices.closeAndDrain()
            try check(notices.window == nil && !notices.isLoading, "Native notices retained work after closing")

            let fixtures = root.appendingPathComponent("source/notice-controls")
            let bad = fixtures.appendingPathComponent("bad")
            let large = fixtures.appendingPathComponent("large")
            try await Task.detached {
                let manager = FileManager()
                for folder in [bad, large] {
                    try manager.createDirectory(
                        at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                }
                try Data("Generated changed notice".utf8).write(to: bad.appendingPathComponent("ThirdPartyNotices.txt"))
                let manifest: [String: Any] = [
                    "version": 1, "components": [], "noticeSHA256": String(repeating: "a", count: 64),
                ]
                try JSONSerialization.data(withJSONObject: manifest).write(
                    to: bad.appendingPathComponent("ThirdPartyManifest.json"))
                try Data(repeating: 65, count: (4 << 20) + 1).write(
                    to: large.appendingPathComponent("ThirdPartyNotices.txt"))
                try JSONSerialization.data(withJSONObject: manifest).write(
                    to: large.appendingPathComponent("ThirdPartyManifest.json"))
            }.value
            for root in [bad, large] {
                var refused = false
                do { _ = try await BundledNoticeReader().read(resources: root) } catch { refused = true }
                try check(refused, "Changed or oversized notice input was accepted")
            }
            let hold = NoticeReadHold()
            let held = ApplicationNotices(reader: .init(beforeRead: { hold.pause() }))
            held.show(settings: settings, offscreen: true)
            try await wait { hold.entered }
            var closed = false
            let drain = Task {
                await held.closeAndDrain()
                closed = true
            }
            try await Task.sleep(for: .milliseconds(30))
            try check(!closed && held.isLoading, "Closing abandoned an active bundled read")
            hold.release()
            await drain.value
            try check(closed && !held.isLoading && held.window == nil, "Cancelled notices did not drain")
            let reopenHold = NoticeReadHold(), reopening = ApplicationNotices(reader: .init(beforeRead: { reopenHold.pause() }))
            reopening.show(settings: settings, offscreen: true)
            try await wait { reopenHold.entered }
            reopening.window?.close()
            reopening.show(settings: settings, offscreen: true)
            try check(reopening.window == nil && reopening.isLoading, "Reopen admitted overlapping notice readers")
            reopenHold.release()
            try await wait { !reopening.isLoading && reopening.window != nil }
            try check(reopening.didLoad, "Latest explicit reopen was lost after the first reader drained")
            await reopening.closeAndDrain()
            try check(ApplicationFileActivity.gate.activeCount == 0, "Bundled notice activity remained after drain")
            return [
                "passed": true, "components": document.components, "textBytes": document.text.utf8.count,
                "visualCaptureQualified": capture,
                "nativeWorstGapMilliseconds": worst, "localFind": true, "glassSolidAndMotion": true,
                "hashAndSizeRefusals": true, "actualCancelledReadDrain": true, "latestReopenAfterDrain": true,
                "networkRequests": 0, "personalFiles": 0,
            ]
        }
        private static func check(_ condition: Bool, _ message: String) throws {
            try UIVerification.require(condition, message)
        }
        private static func wait(_ condition: () -> Bool) async throws {
            let end = ProcessInfo.processInfo.systemUptime + 8
            while !condition() {
                guard ProcessInfo.processInfo.systemUptime < end else {
                    throw UIVerification.Failure(message: "Generated notice view timed out")
                }
                try await Task.sleep(for: .milliseconds(10))
            }
        }
    }
    private final class NoticeReadHold: @unchecked Sendable {
        private let condition = NSCondition()
        private var started = false, released = false
        var entered: Bool {
            condition.lock()
            defer { condition.unlock() }
            return started
        }
        func pause() {
            condition.lock()
            defer { condition.unlock() }
            started = true
            while !released { if !condition.wait(until: Date().addingTimeInterval(4)) { return } }
        }
        func release() {
            condition.lock()
            released = true
            condition.broadcast()
            condition.unlock()
        }
    }
#endif
