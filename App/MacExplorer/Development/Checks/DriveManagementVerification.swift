#if DEBUG
import AppKit
import LocalStorage

@MainActor enum DriveManagementVerification {
    static func run(root: URL) async throws -> [String: Any] {
        var repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        for _ in 0..<3 { repo.deleteLastPathComponent() }
        try require(root.deletingLastPathComponent() == repo.appendingPathComponent(".build/b04-drive-management")
            && root.resolvingSymlinksInPath() == root && UUID(uuidString: root.lastPathComponent) != nil
            && FileManager().fileExists(atPath: root.appendingPathComponent("reservation.json").path), "Requires generated overview packet")
        if DriveManagementFeature.ordinaryEnabled {
            let go = NSApplication.shared.mainMenu?.items.first(where: { $0.title == "Go" })?.submenu
            try require(go?.items.contains(where: { $0.title == "Drives…"
                && $0.action == #selector(BrowserViewController.showDriveManagement(_:)) }) == true,
                "Ordinary Go menu omitted read-only Drive Management")
        }
        let reader = Reader(snapshot: try fixture())
        defer { reader.release() }
        var details = 0
        let model = ApplicationDriveManagement(reader: reader, details: { _, _ in details += 1 })
        let settings = BrowserSettings(persist: false)
        settings.navigationStyle = .glass; settings.appearance = .dark
        let volumesHandoff = ProcessInfo.processInfo.arguments.contains("--drive-management-volumes")
        let offscreen = ProcessInfo.processInfo.arguments.contains("--offscreen")
        reader.arm(); model.show(settings: settings, offscreen: offscreen)
        try await wait { reader.isHeld }
        model.refresh(); model.refresh()
        try require(reader.calls == 1 && model.isReading, "Refresh started overlapping readers")
        reader.release(); await model.drain()
        try require(reader.calls == 2 && reader.maximum == 1 && model.snapshot?.nodes.count == 8,
                    "Latest refresh coalescing failed")
        func devices(in view: NSView) -> NSTableView? {
            if let table = view as? NSTableView, table.identifier?.rawValue == "drive-devices" { return table }
            return view.subviews.lazy.compactMap { devices(in: $0) }.first
        }
        let rootCount = model.snapshot?.roots.count ?? 0
        try require(rootCount > 1, "Generated overview needs separate device rows")
        try await wait { model.window?.contentView.flatMap { devices(in: $0) }?.numberOfRows == rootCount }
        guard let deviceList = model.window?.contentView.flatMap({ devices(in: $0) }) else {
            throw UIVerification.Failure(message: "Device navigation is missing")
        }
        let usbRow = model.deviceRoots.firstIndex { $0.id == 6 }!
        let internalRow = model.deviceRoots.firstIndex { $0.id == 1 }!
        deviceList.selectRowIndexes(IndexSet(integer: usbRow), byExtendingSelection: false)
        try await wait { model.selectedRootID == 6 }
        deviceList.selectRowIndexes(IndexSet(integer: internalRow), byExtendingSelection: false)
        try await wait { model.selectedRootID == 1 }
        model.selectRoot(1); model.selectNode(5)
        try require(model.selectedNodeID == 5 && model.protectionLabel(for: model.selectedRoot!) == "System storage",
                    "Selection or System/Data label failed")
        model.selectNode(7)
        try require(model.selectedNodeID == 5, "Cross-device selection escaped its root")
        model.showDetails(settings: settings)
        try require(details == 1, "Explicit Details was not bound to selected media")
        reader.arm(); model.refresh(); try await wait { reader.isHeld }
        model.window?.close()
        var drained = false
        let drain = Task { await model.drain(); drained = true }
        try await Task.sleep(for: .milliseconds(40))
        try require(!drained && model.window == nil && model.isReading, "Close falsely drained actual reader")
        reader.release(); await drain.value
        try require(model.snapshot == nil && !model.isReading, "Closed overview received a stale result")
        if volumesHandoff { settings.interfaceSize = .init(150); settings.appearance = .light }
        model.show(settings: settings,
            drives: volumesHandoff ? ApplicationOperationCoordinator.shared.drives : nil,
            offscreen: offscreen, initialPage: volumesHandoff ? .volumes : nil)
        await model.drain()
        reader.fail = true; model.refresh(); await model.drain()
        try require(!model.notice.isEmpty && model.snapshot != nil, "Failed refresh hid uncertainty or lost last observation")
        reader.fail = false; model.refresh(); await model.drain()
        try require(model.notice.isEmpty && model.snapshot?.nodes.count == 8, "Refresh did not recover")
        model.selectRoot(6); model.selectNode(7)
        if volumesHandoff {
            try require(model.page == .volumes && model.volumeCoordinator != nil,
                "Manual Disk Utility handoff layout did not reach embedded Volumes")
        }
        if let window = model.window {
            window.title = volumesHandoff
                ? "Generated Drive Management · manual Disk Utility handoff layout"
                : "Generated Drive Management · read-only layout review"
            try await UIVerification.snapshot(window, to: root.appendingPathComponent(
                volumesHandoff ? "evidence/volumes.png" : "evidence/overview.png"))
        }
        let review = ProcessInfo.processInfo.arguments.contains("--drive-management-input")
        if review {
            try JSONSerialization.data(withJSONObject: ["windowID": model.window?.windowNumber ?? 0,
                "generatedOnly": true], options: .sortedKeys)
                .write(to: root.appendingPathComponent("evidence/ready.json"), options: .withoutOverwriting)
            try await wait(seconds: 900) { model.window == nil
                || FileManager().fileExists(atPath: root.appendingPathComponent("evidence/close-review").path) }
        }
        await model.closeAndDrain()
        var nativeCount = 0, nativeRoots = 0, nativeUnresolved = false
        let began = ProcessInfo.processInfo.systemUptime
        for _ in 0..<100 {
            let native = try await VolumeLifecycle.shared.readTopology()
            if !native.nodes.isEmpty {
                nativeCount = native.nodes.count; nativeRoots = native.roots.count
                nativeUnresolved = native.hasUnresolvedRelationships; break
            }
            try await Task.sleep(for: .milliseconds(30))
        }
        try require(nativeCount > 0 && nativeRoots > 0, "Native device discovery returned no observations")
        return ["passed": true, "actualInputRequired": review, "volumesHandoffRoute": volumesHandoff,
            "nativeObservations": nativeCount,
            "nativeRoots": nativeRoots, "nativeUnresolved": nativeUnresolved,
            "nativeReadSeconds": ProcessInfo.processInfo.systemUptime - began,
            "maximumConcurrentReaders": reader.maximum, "deviceMutations": 0, "externalAppsOpened": 0,
            "checks": ["APFS device/partition/container/volume relationships with shared space labelled",
                "Latest refresh coalesces; close retains actual worker; no stale publication",
                "Failed refresh retains labelled prior observation; explicit refresh recovers",
                "Selection stays within device; Details handoff injected; real native snapshot reads metadata only"]]
    }
    static func fixture() throws -> DriveTopologySnapshot {
        func node(_ id: UInt64, _ parent: UInt64?, _ kind: DriveTopologyNode.Kind, _ name: String,
                  _ size: UInt64, path: String? = nil, fs: String? = nil, verified: Bool = true) -> DriveTopologyNode {
            let volume = ManagedVolume(id: UUID(), name: name, url: path.map { URL(fileURLWithPath: $0) },
                isInternal: id < 6, canMount: false, canUnmount: false, canEject: false,
                fileSystemID: nil, group: nil, mediaID: id)
            return .init(id: id, parentID: parent, kind: kind, name: name, deviceName: "generated-\(id)", capacity: size,
                fields: .init(fileSystem: fs, model: id < 6 ? "Generated internal storage" : "Generated USB storage",
                    transport: id < 6 ? "PCI-Express" : "USB", mediaBytes: size), volume: volume, relationshipVerified: verified)
        }
        return try .init(nodes: [
            node(1, nil, .device, "Internal SSD", 512 << 30), node(2, 1, .partition, "APFS physical store", 500 << 30),
            node(3, 2, .apfsContainer, "Startup container", 500 << 30),
            node(4, 3, .volume, "Macintosh HD", 500 << 30, path: "/", fs: "apfs"),
            node(5, 3, .volume, "Macintosh HD — Data", 500 << 30, path: "/System/Volumes/Data", fs: "apfs"),
            node(6, nil, .device, "Generated USB device", 256 << 30),
            node(7, 6, .volume, "Generated Media", 256 << 30, path: "/generated/media", fs: "exfat"),
            node(8, 999, .unresolved, "Unresolved generated storage", 64 << 30, verified: false)
        ])
    }
    private static func require(_ value: Bool, _ message: String) throws {
        if !value { throw UIVerification.Failure(message: message) }
    }
    private static func wait(seconds: Double = 5, _ condition: () -> Bool) async throws {
        let end = ProcessInfo.processInfo.systemUptime + seconds
        while !condition() {
            try require(ProcessInfo.processInfo.systemUptime < end, "Generated overview timed out")
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    private final class Reader: DriveTopologyReading, @unchecked Sendable {
        let snapshot: DriveTopologySnapshot
        private let queue = DispatchQueue(label: "MacExplorer.GeneratedTopology", attributes: .concurrent)
        private let lock = NSCondition()
        private var armed = false, held = false, released = false, failure = false
        private var count = 0, active = 0, peak = 0
        init(snapshot: DriveTopologySnapshot) { self.snapshot = snapshot }
        var calls: Int { lock.lock(); defer { lock.unlock() }; return count }
        var maximum: Int { lock.lock(); defer { lock.unlock() }; return peak }
        var isHeld: Bool { lock.lock(); defer { lock.unlock() }; return held }
        var fail: Bool {
            get { lock.lock(); defer { lock.unlock() }; return failure }
            set { lock.lock(); failure = newValue; lock.unlock() }
        }
        func arm() { lock.lock(); armed = true; held = false; released = false; lock.unlock() }
        func release() { lock.lock(); released = true; lock.broadcast(); lock.unlock() }
        func readTopology() async throws -> DriveTopologySnapshot {
            try await withCheckedThrowingContinuation { continuation in queue.async { [self] in
                lock.lock(); count += 1; active += 1; peak = max(peak, active)
                if armed { armed = false; held = true; lock.broadcast(); while !released { lock.wait() } }
                let failed = failure; active -= 1; lock.unlock()
                if failed { continuation.resume(throwing: VolumeLifecycleFailure.changed) }
                else { continuation.resume(returning: snapshot) }
            } }
        }
    }
}
#endif
