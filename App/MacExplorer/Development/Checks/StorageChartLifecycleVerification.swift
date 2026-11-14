#if DEBUG
import AppKit

@MainActor enum StorageChartLifecycleVerification {
    static func run() async throws -> [String: Any] {
        let controller = StorageDimensionalReviewWindow()
        controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil); NSApplication.shared.activate()
        defer { controller.close() }
        let chart = controller.chart
        chart.forceVisiblePresentationForQualification = true
        controller.open(0)
        try UIVerification.require(chart.isTransitioning && chart.isAnimating, "Clock liveness control did not start a transition")
        chart.pauseDisplayClockForQualification()
        try await Task.sleep(for: .milliseconds(1100))
        try UIVerification.require(!chart.isTransitioning && !chart.isAnimating, "A paused display clock leaves chart input blocked after its transition deadline")
        var checks = ["paused display-clock forward transition settles"]
        func wait(_ message: String) async throws {
            let deadline = ProcessInfo.processInfo.systemUptime + 1.2
            while chart.isAnimating {
                try UIVerification.require(ProcessInfo.processInfo.systemUptime < deadline, message)
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        let backStarted = ProcessInfo.processInfo.systemUptime
        controller.goBack(0)
        try UIVerification.require(chart.isTransitioning, "Paused Back did not start")
        try await wait("Paused Back did not settle")
        let backSeconds = ProcessInfo.processInfo.systemUptime - backStarted
        try UIVerification.require(controller.deck.count == 1 && chart.frames.count == 1 && !chart.isTransitioning, "Back lost its exact target")
        checks += ["paused Back settles to target"]
        chart.hoverForQualification(.slice(0))
        try UIVerification.require(chart.isAnimating && chart.presentedHoverForQualification == .slice(0), "Hover did not start")
        chart.update(controller.deck, style: .tilted, reduceMotion: false, reduceTransparency: false)
        try UIVerification.require(chart.presentedHoverForQualification == .slice(0), "Identical native update cleared hover")
        try await wait("Paused hover did not settle")
        chart.hoverForQualification(nil); try await wait("Paused hover exit did not settle")
        try UIVerification.require(chart.presentedHoverForQualification == nil, "Hover exit retained its label")
        checks += ["paused hover and exit settle", "identical updates preserve hover"]
        // Superseding a transition invalidates its deadline, even if that old
        // callback has already been queued by the run loop.
        controller.open(0)
        try await Task.sleep(for: .milliseconds(500))
        let samples = controller.samples
        let replacement = [samples[0], samples[1], samples[2]]
        chart.update(replacement, style: .tilted, reduceMotion: false, reduceTransparency: false)
        try await Task.sleep(for: .milliseconds(330))
        try UIVerification.require(chart.isTransitioning && chart.isAnimating && chart.frames.count == 3,
            "An obsolete deadline stopped a newer transition")
        try await wait("Replacement transition did not settle")
        checks += ["superseded deadline rejected"]
        chart.update([samples[0]], style: .flat, reduceMotion: true, reduceTransparency: true)
        try UIVerification.require(!chart.isAnimating && !chart.isTransitioning, "Reduced motion/style kept old presentation work")
        checks += ["style and reduced motion retire work"]
        chart.update([samples[0]], style: .tilted, reduceMotion: false, reduceTransparency: false)
        chart.update([samples[0], samples[1]], style: .tilted, reduceMotion: false, reduceTransparency: false)
        chart.isHidden = true
        try UIVerification.require(!chart.isAnimating, "Hidden view retained the clock")
        chart.isHidden = false
        chart.update([samples[0]], style: .tilted, reduceMotion: false, reduceTransparency: false)
        controller.window?.orderOut(nil)
        NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: controller.window)
        try UIVerification.require(!chart.isAnimating && chart.frames.count == 1, "Order-out left input blocked")
        controller.window?.makeKeyAndOrderFront(nil)
        chart.update([samples[0], samples[1]], style: .tilted, reduceMotion: false, reduceTransparency: false)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        try UIVerification.require(!chart.isAnimating && !chart.isTransitioning, "Screen-sleep notification retained presentation")
        checks += ["hide and order-out retire work", "screen-sleep notification settles"]
        let second = NSWindow(contentRect: .init(x: 0, y: 0, width: 460, height: 380), styleMask: [.titled], backing: .buffered, defer: false)
        second.isReleasedWhenClosed = false; defer { second.close() }
        chart.update([samples[0]], style: .tilted, reduceMotion: false, reduceTransparency: false)
        chart.removeFromSuperview(); second.contentView?.addSubview(chart)
        try UIVerification.require(!chart.isAnimating && !chart.isTransitioning, "Reparented view retained its old display clock")
        second.orderFront(nil)
        chart.update([samples[0], samples[1]], style: .tilted, reduceMotion: false, reduceTransparency: false)
        second.close()
        try UIVerification.require(!chart.isAnimating && !chart.isTransitioning, "Closed window retained clock/deadline")
        checks += ["detach and reparent retire old clock", "close retires deadline"]
        let count = chart.settlementCountForQualification, ticks = chart.ticks
        try await Task.sleep(for: .milliseconds(850))
        try UIVerification.require(count == chart.settlementCountForQualification && ticks == chart.ticks && !chart.isAnimating,
            "Idle or closed view ran a deadline/driver loop")
        checks += ["no idle or stale deadline loop"]
        return ["passed": true, "checks": checks, "source_io": false, "paused_clock": true,
            "back_seconds": backSeconds, "finite_settlements": count, "display_ticks": ticks]
    }
}
#endif
