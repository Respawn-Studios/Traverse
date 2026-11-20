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
        let formatHeld = ProcessInfo.processInfo.arguments.contains("--drive-management-format-held")
        let reader = Reader(snapshot: try fixture(formatHeld: formatHeld))
        defer { reader.release() }
        var details = 0
        let benchmark = ApplicationDriveBenchmark()
        let model = ApplicationDriveManagement(reader: reader, benchmark: benchmark, details: { _, _ in details += 1 })
        let settings = BrowserSettings(persist: false)
        settings.driveHealthLiveUpdates = false
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
            offscreen: offscreen, initialPage: volumesHandoff || formatHeld ? .volumes : nil)
        await model.drain()
        reader.fail = true; model.refresh(); await model.drain()
        try require(!model.notice.isEmpty && model.snapshot != nil, "Failed refresh hid uncertainty or lost last observation")
        reader.fail = false; model.refresh(); await model.drain()
        try require(model.notice.isEmpty && model.snapshot?.nodes.count == 8, "Refresh did not recover")
        model.selectRoot(6); model.selectNode(7)
        if formatHeld {
            try require(!NativeAPFSFormatFeature.ordinaryEnabled
                && model.volumeFormatTarget?.mediaID == 7 && model.page == .volumes,
                "Generated APFS image selection did not reach the held Format control")
            model.showVolumeFormat()
            try require(!model.showsVolumeFormat && !model.volumeFormat.isWorking,
                "Held ordinary Format opened a sheet or began a request")
        }
        if volumesHandoff {
            try require(model.page == .volumes && model.volumeCoordinator != nil,
                "Manual Disk Utility handoff layout did not reach embedded Volumes")
        }
        if let window = model.window {
            if formatHeld {
                window.title = "Generated APFS image · held Format control"
                settings.interfaceSize = .init(100); settings.appearance = .dark
                try await Task.sleep(for: .milliseconds(120))
                try await UIVerification.snapshot(window, to: root.appendingPathComponent("evidence/format-held-dark-100.png"))
                settings.interfaceSize = .init(150); settings.appearance = .light
                try await Task.sleep(for: .milliseconds(120))
                try await UIVerification.snapshot(window, to: root.appendingPathComponent("evidence/format-held-light-150.png"))
            } else {
                window.title = volumesHandoff
                    ? "Generated Drive Management · manual Disk Utility handoff layout"
                    : "Generated Drive Management · read-only layout review"
                try await UIVerification.snapshot(window, to: root.appendingPathComponent(
                    volumesHandoff ? "evidence/volumes.png" : "evidence/overview.png"))
            }
        }
        let review = ProcessInfo.processInfo.arguments.contains("--drive-management-input")
        let missingDeviceCheck = !review && !formatHeld && !volumesHandoff
        if missingDeviceCheck {
            try await verifyMissingDevice(model: model, reader: reader, benchmark: benchmark,
                settings: settings, offscreen: offscreen)
        }
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
            "formatHeldRoute": formatHeld, "ordinaryFormatEnabled": NativeAPFSFormatFeature.ordinaryEnabled,
            "nativeObservations": nativeCount,
            "nativeRoots": nativeRoots, "nativeUnresolved": nativeUnresolved,
            "nativeReadSeconds": ProcessInfo.processInfo.systemUptime - began,
            "maximumConcurrentReaders": reader.maximum, "deviceMutations": 0, "externalAppsOpened": 0,
            "checks": ["APFS device/partition/container/volume relationships with shared space labelled",
                "Latest refresh coalesces; close retains actual worker; no stale publication",
                "Failed refresh retains labelled prior observation; explicit refresh recovers",
                "Selection stays within device; Details handoff injected; real native snapshot reads metadata only"]
                + (missingDeviceCheck ? ["A removed device clears its native selection during a held folder choice; another device is refused until cancellation drains, then normal selection resumes without a workload"] : [])
                + (formatHeld ? ["Generated APFS image selection displays a held Format control without opening a sheet or submitting a request"] : [])]
    }
    private static func verifyMissingDevice(model: ApplicationDriveManagement, reader: Reader,
        benchmark: ApplicationDriveBenchmark, settings: BrowserSettings, offscreen: Bool) async throws {
        let source = BrowserViewController(settings: settings)
        source.folderAccess = FolderAccessController(stateDirectory: nil)
        let original = reader.snapshot
        var release: CheckedContinuation<FolderAccessChoice?, Never>?, choices = 0
        var stage = "attach"
        benchmark.chooseForVerification = { _ in
            choices += 1
            return await withCheckedContinuation { release = $0 }
        }
        defer { release?.resume(returning: nil); benchmark.chooseForVerification = nil; source.suspendBrowser() }
        func table() -> NSTableView? {
            func find(_ view: NSView) -> NSTableView? {
                if let value = view as? NSTableView, value.identifier?.rawValue == "drive-devices" { return value }
                return view.subviews.lazy.compactMap(find).first
            }
            return model.window?.contentView.flatMap(find)
        }
        func click(_ id: UInt64) async throws {
            guard let table = table(),
                  let row = model.deviceRoots.firstIndex(where: { $0.id == id }) else {
                throw UIVerification.Failure(message: "Generated device row missing")
            }
            try await UIVerification.clickRow(row, in: table)
        }
        do {
            model.show(settings: settings, offscreen: offscreen, browser: source, initialPage: .benchmark)
            await model.drain(); model.selectRoot(6)
            benchmark.chooseFolder()
            stage = "pending-choice"
            try await wait { choices == 1 && release != nil && benchmark.hasPendingWork }
            reader.replace(try .init(nodes: original.nodes.filter { $0.id != 6 && $0.id != 7 }))
            model.refresh(); await model.drain()
            stage = "missing-selection"
            try await wait { model.selectedRootID == nil && table()?.numberOfRows == model.deviceRoots.count
                && table()?.selectedRow == -1 && table()?.allowsEmptySelection == true }
            let selections = model.selectionCount
            stage = "blocked-click"
            try await click(1)
            try require(model.selectedRootID == nil && table()?.selectedRow == -1 && model.selectionCount == selections,
                "A blocked device click replaced the missing benchmark target")
            try require(model.notice == "Stop the current benchmark before switching drives.",
                "The native click never reached the drive-switch admission check")
            release?.resume(returning: nil); release = nil
            await benchmark.drain()
            try require(!benchmark.hasPendingWork && benchmark.result == nil && benchmark.folder == nil && choices == 1,
                "Generated folder choice started a workload or failed to drain")
            reader.replace(original); model.refresh(); await model.drain()
            stage = "restored-selection"
            try await wait { table()?.numberOfRows == model.deviceRoots.count && table()?.allowsEmptySelection == false }
            try await click(6)
            stage = "resumed-click"
            try await wait { model.selectedRootID == 6 && table()?.selectedRow == model.deviceRoots.firstIndex(where: { $0.id == 6 }) }
        } catch {
            let facts = "choice=\(choices),pending=\(benchmark.hasPendingWork),root=\(model.selectedRootID.map(String.init) ?? "none"),"
                + "row=\(table()?.selectedRow ?? -2),rows=\(table()?.numberOfRows ?? -1),roots=\(model.deviceRoots.count),"
                + "empty=\(table()?.allowsEmptySelection == true),embedded=\(model.window.map { benchmark.isEmbedded(in: $0) } == true)"
            release?.resume(returning: nil); release = nil
            await benchmark.drain(); await model.closeAndDrain()
            let detail = (error as? UIVerification.Failure)?.message ?? "wait-or-assertion"
            throw UIVerification.Failure(message: "Generated missing-device \(stage) failed: \(facts); \(detail)")
        }
    }
    static func fixture(formatHeld: Bool = false) throws -> DriveTopologySnapshot {
        func node(_ id: UInt64, _ parent: UInt64?, _ kind: DriveTopologyNode.Kind, _ name: String,
                  _ size: UInt64, path: String? = nil, fs: String? = nil, verified: Bool = true) -> DriveTopologyNode {
            let image = formatHeld && id == 7
            let volume = ManagedVolume(id: UUID(), name: name, url: path.map { URL(fileURLWithPath: $0) },
                isInternal: image ? false : id < 6, canMount: false, canUnmount: image, canEject: image,
                fileSystemID: image ? 717 : nil, group: image ? 6 : nil, deviceKind: image ? .diskImage : nil,
                mediaID: id, volumeUUID: image ? UUID(uuidString: "A5DF9D43-1D17-4953-B5E2-7023AB3CBB06") : nil)
            return .init(id: id, parentID: parent, kind: kind, name: name, deviceName: "generated-\(id)", capacity: size,
                fields: .init(fileSystem: fs, model: id < 6 ? "Generated internal storage" : "Generated USB storage",
                    transport: id < 6 ? "PCI-Express" : "USB", mediaBytes: size, writable: image),
                volume: volume, relationshipVerified: verified)
        }
        return try .init(nodes: [
            node(1, nil, .device, "Internal SSD", 512 << 30), node(2, 1, .partition, "APFS physical store", 500 << 30),
            node(3, 2, .apfsContainer, "Startup container", 500 << 30),
            node(4, 3, .volume, "Macintosh HD", 500 << 30, path: "/", fs: "apfs"),
            node(5, 3, .volume, "Macintosh HD — Data", 500 << 30, path: "/System/Volumes/Data", fs: "apfs"),
            node(6, nil, .device, "Generated USB device", 256 << 30),
            node(7, 6, .volume, formatHeld ? "Generated APFS Image" : "Generated Media", 256 << 30,
                 path: "/generated/media", fs: formatHeld ? "apfs" : "exfat"),
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
        private var storedSnapshot: DriveTopologySnapshot
        private let queue = DispatchQueue(label: "MacExplorer.GeneratedTopology", attributes: .concurrent)
        private let lock = NSCondition()
        private var armed = false, held = false, released = false, failure = false
        private var count = 0, active = 0, peak = 0
        init(snapshot: DriveTopologySnapshot) { storedSnapshot = snapshot }
        var snapshot: DriveTopologySnapshot { lock.lock(); defer { lock.unlock() }; return storedSnapshot }
        func replace(_ snapshot: DriveTopologySnapshot) { lock.lock(); storedSnapshot = snapshot; lock.unlock() }
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
                let failed = failure, snapshot = storedSnapshot; active -= 1; lock.unlock()
                if failed { continuation.resume(throwing: VolumeLifecycleFailure.changed) }
                else { continuation.resume(returning: snapshot) }
            } }
        }
    }
}
#endif
