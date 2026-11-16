import AppKit
import Darwin
import DiskArbitration
import ExplorerCore
import FileOperations
import IOKit
import LocalStorage

#if DEBUG
@MainActor
enum NativeDriveLifecycleVerification {
    fileprivate typealias Receipt = GeneratedAPFSReceipt
    nonisolated static func validate(_ root: URL, output: URL) throws -> URL {
        let args = ProcessInfo.processInfo.arguments
        let apfsModes = ["--apfs-ui", "--apfs-format-preflight", "--apfs-format", "--apfs-format-cold"].filter(args.contains)
        guard apfsModes.count <= 1,
              apfsModes.isEmpty || args.contains("--verify-drive-lifecycle") else {
            throw UIVerification.Failure(message: "Generated APFS Format modes are ambiguous")
        }
        guard let declared = ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"],
              root.path == URL(fileURLWithPath: declared).standardizedFileURL.path,
              root.path == root.resolvingSymlinksInPath().path,
              root.deletingLastPathComponent().lastPathComponent == "fixtures",
              root.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == ".build",
              root.lastPathComponent.hasPrefix("drive-lifecycle-") else { throw UIVerification.Failure(message: "Native drive fixture root refused") }
        guard output.path == output.resolvingSymlinksInPath().path,
              output.deletingLastPathComponent() == root.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("evidence", isDirectory: true)
        else { throw UIVerification.Failure(message: "Native drive evidence root refused") }
        if args.contains("--apfs-format-preflight") {
            let job = String(root.lastPathComponent.dropFirst("drive-lifecycle-".count))
            var fixture = stat(), evidence = stat(), image = stat()
            guard let jobID = UUID(uuidString: job), jobID.uuidString == job,
                  lstat(root.path, &fixture) == 0, fixture.st_mode & S_IFMT == S_IFDIR,
                  fixture.st_uid == geteuid(),
                  lstat(output.path, &evidence) == 0, evidence.st_mode & S_IFMT == S_IFDIR,
                  evidence.st_uid == geteuid(),
                  apfsOwnerMarkerCurrent(root: root, jobID: jobID),
                  lstat(root.appendingPathComponent("fixture.dmg").path, &image) == -1,
                  errno == ENOENT else {
                throw UIVerification.Failure(message: "Pre-image Format fixture is not empty and owned")
            }
            return root.deletingLastPathComponent().deletingLastPathComponent()
        }
        let receipt = try readReceipt(output)
        var fixture = stat(), image = stat()
        guard receipt.version == 3, root.lastPathComponent == "drive-lifecycle-" + receipt.jobID.uuidString,
              (receipt.startsUnmounted ? receipt.initialMount.isEmpty && receipt.mountDevice == 0 : receipt.initialMount.hasPrefix("/")),
              receipt.mediaID != 0, receipt.outerMediaID != 0, lstat(root.path, &fixture) == 0,
              fixture.st_mode & S_IFMT == S_IFDIR, Int64(fixture.st_dev) == receipt.fixtureDevice, fixture.st_ino == receipt.fixtureInode,
              lstat(root.appendingPathComponent("fixture.dmg").path, &image) == 0, image.st_mode & S_IFMT == S_IFREG,
              Int64(image.st_dev) == receipt.imageDevice, image.st_ino == receipt.imageInode,
              image.st_uid == geteuid(), fixture.st_uid == geteuid(),
              image.st_size == (args.contains("--apfs-ui") || args.contains("--apfs-format")
                  || args.contains("--apfs-format-cold") ? off_t(1 << 30) : off_t(512 << 20)), image.st_nlink == 1
        else { throw UIVerification.Failure(message: "Native drive fixture receipt refused") }
        if args.contains("--apfs-format") || args.contains("--apfs-format-cold") {
            guard apfsOwnerMarkerCurrent(root: root, jobID: receipt.jobID) else {
                throw UIVerification.Failure(message: "Generated APFS Format owner marker refused")
            }
        }
        return root.deletingLastPathComponent().deletingLastPathComponent()
    }
    nonisolated private static func readReceipt(_ output: URL) throws -> Receipt {
        let path = output.appendingPathComponent("native-drive-receipt.json")
        let fd = open(path.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw UIVerification.Failure(message: "Native drive receipt unavailable") }
        defer { close(fd) }
        var value = stat()
        guard fstat(fd, &value) == 0, value.st_mode & S_IFMT == S_IFREG, value.st_uid == geteuid(),
              value.st_nlink == 1, (1...4096).contains(value.st_size) else { throw UIVerification.Failure(message: "Native drive receipt identity refused") }
        var data = Data(count: Int(value.st_size))
        let count = data.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
        guard count == data.count else { throw UIVerification.Failure(message: "Native drive receipt read failed") }
        return try JSONDecoder().decode(Receipt.self, from: data)
    }

    static func run(browser: BrowserViewController, fixture: URL, output: URL) async throws -> [String] {
        if ProcessInfo.processInfo.arguments.contains("--apfs-format-preflight") {
            return try await apfsFormatPreflight(browser: browser, fixture: fixture, output: output)
        }
        let receipt = try await Task.detached { try readReceipt(output) }.value
        let operations = browser.operationCoordinator
        let original = operations.drives
        let backend = VolumeLifecycle.shared
        let drives = ApplicationVolumeCoordinator(operations: operations, backend: backend)
        operations.drives = drives; drives.startDiscovery()
        defer {
            // Cancellation cannot withdraw a submitted native request. Retain
            // its real owner until callback completion; the app's close guard
            // remains active if the qualification itself fails in the meantime.
            if drives.isBusy { drives.cancel() }
            if !drives.isBusy { operations.drives = original }
        }
        var checks: [String] = []
        var initial = try await observed(drives) {
            $0.mediaID == receipt.mediaID && $0.group == receipt.outerMediaID
                && (receipt.startsUnmounted ? $0.url == nil && $0.canMount : $0.url?.path == receipt.initialMount && $0.fileSystemID == receipt.mountDevice)
        }
        if ProcessInfo.processInfo.arguments.contains("--apfs-format-cold") {
            return try await GeneratedAPFSFormatVerification.cold(drives: drives, initial: initial, receipt: receipt, fixture: fixture, output: output)
        }
        if ProcessInfo.processInfo.arguments.contains("--apfs-ui") {
            return try await apfsUI(browser: browser, drives: drives, initial: initial, receipt: receipt, output: output)
        }
        if ProcessInfo.processInfo.arguments.contains("--apfs-format") {
            return try await GeneratedAPFSFormatVerification.warm(operations: browser.operationCoordinator, drives: drives, initial: initial, receipt: receipt, fixture: fixture, output: output)
        }
        if receipt.startsUnmounted {
            try await stage("00-retained-unmounted-observed", output: output)
            drives.request(initial, action: .mount, policy: .requireCancel)
            try await until("Retained native initial Mount") { !drives.isBusy }
            try require(drives.message.hasSuffix(" mounted."), "Retained image could not mount: " + drives.message)
            initial = try await observed(drives) { $0.mediaID == receipt.mediaID && $0.group == receipt.outerMediaID && $0.canUnmount }
            try await GeneratedAPFSFormatVerification.verifyMarker(initial, receipt: receipt)
            try await stage("00-retained-initial-mount-verified", output: output)
        }
        guard let initialMount = initial.url?.path else { throw UIVerification.Failure(message: "Initial generated mount unavailable") }
        try JSONSerialization.data(withJSONObject: ["internalKnown": initial.isInternal != nil,
            "isInternal": initial.isInternal as Any? ?? NSNull(), "canMount": initial.canMount,
            "canUnmount": initial.canUnmount, "canEject": initial.canEject, "groupKnown": initial.group != nil],
            options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("owned-drive-capabilities.json"), options: .withoutOverwriting)
        try require(initial.deviceKind == .diskImage && initial.canUnmount && initial.canEject && initial.group != nil,
                    "Disposable device is not a qualified normal-unmount/eject target")
        try await GeneratedAPFSFormatVerification.verifyMarker(initial, receipt: receipt)
        try await stage("01-target-observed", output: output)
        let appDevice = try await Task.detached { () -> Int64 in
            var value = stat(); guard stat(Bundle.main.bundleURL.path, &value) == 0 else { throw UIVerification.Failure(message: "App volume cannot be observed") }
            return Int64(value.st_dev)
        }.value
        let appVolume = try await observed(drives) { $0.fileSystemID == appDevice }
        do {
            _ = try await backend.prepare(appVolume, action: .unmount, protecting: [Bundle.main.bundleURL])
            throw UIVerification.Failure(message: "App volume unexpectedly passed normal unmount preparation")
        } catch is VolumeLifecycleFailure { checks.append("Actual app volume refuses preparation without submission") }

        browser.settings.autoRefreshFolders = true
        browser.navigate(to: .directory(URL(fileURLWithPath: initialMount, isDirectory: true)))
        try await until("Generated volume listing") { !browser.isLoading && browser.orderingTask == nil && browser.directoryObservation != nil }
        try require(await browser.directoryObservation?.waitUntilStarted() == true, "Generated volume watcher did not start")
        drives.request(initial, action: .unmount, policy: .requireCancel)
        try await until("Native normal Unmount") { !drives.isBusy }
        try require(drives.message.hasSuffix(" unmounted."), "Native Unmount did not succeed: " + drives.message)
        try require(browser.location.directoryURL?.path == initialMount && browser.isOfflineCurrentFolder,
                    "Unmount lost the tab's address or allowed the host mountpoint folder")
        checks.append("Native normal Unmount closes the actual vnode watcher and preserves the tab/address as offline")
        try await stage("02-unmount-completed", output: output)
        let unmounted = try await observed(drives) { $0.id == initial.id && $0.url == nil && $0.canMount }
        do {
            _ = try await backend.prepare(initial, action: .unmount, protecting: [])
            throw UIVerification.Failure(message: "Stale pre-unmount target passed preparation")
        } catch is VolumeLifecycleFailure { checks.append("Native stale mounted observation is refused") }

        drives.request(unmounted, action: .mount, policy: .requireCancel)
        try await until("Native normal Mount") { !drives.isBusy }
        try require(drives.message.hasSuffix(" mounted."), "Native Mount did not succeed: " + drives.message)
        let mounted = try await observed(drives) { $0.id == initial.id && $0.url != nil && $0.canUnmount }
        try require(mounted.group == initial.group && mounted.deviceKind == .diskImage, "Remounted attachment group changed")
        try await GeneratedAPFSFormatVerification.verifyMarker(mounted, receipt: receipt)
        checks.append("Native normal Mount retains the observed attachment and generated data")
        try await stage("03-mount-verified", output: output)

        guard let mount = mounted.url else { throw UIVerification.Failure(message: "Remounted generated destination missing") }
        let observer = LocalFileOperations(activity: ApplicationFileActivity.beginOperation)
        let destinationName = "Generated destination-" + UUID().uuidString
        let parent = try await observer.observeDirectory(mount)
        let created = await observer.perform(.createFolder(parent: mount, name: destinationName), observing: parent)
        try require(created.items.count == 1 && created.items[0].status == .succeeded, "Generated destination preparation failed")
        let destination = mount.appendingPathComponent(destinationName, isDirectory: true)
        let source = fixture.appendingPathComponent("Source/Generated copy.txt")
        let engine = RecoverableFileOperations(journalDirectory: fixture.appendingPathComponent("journal-" + UUID().uuidString), activity: ApplicationFileActivity.beginOperation)
        let queue = operations.transfers
        queue.pause()
        guard let id = queue.enqueue(sources: [source], destination: destination, move: false,
            title: "Generated native drive Copy", origin: browser, engine: engine, metadataPolicy: .strict) else {
            throw UIVerification.Failure(message: "Native drive queue admission refused")
        }
        try await until("Native drive queue preparation") { queue.state.waiting.contains { $0.id == id && $0.phase == .ready } }
        try await stage("04-copy-queued", output: output)
        drives.request(mounted, action: .eject, policy: .requireCancel)
        try await until("Native drive captured cohort preparation") { !drives.isPreparing }
        try require(drives.pending?.intent.phase == .waiting, "Native drive did not capture its queued cohort: " + drives.message)
        try require(drives.jobs.contains { $0.id == id } && !ApplicationFileActivity.gate.isClosed,
                    "Native eject did not wait for its accepted transfer")
        try await stage("05-eject-waits-for-cohort", output: output)
        _ = queue.resume()
        try await until("Native queued Copy then Eject") { !drives.isBusy || drives.pending?.intent.phase == .needsAttention }
        if let result = drives.lastResult {
            let data = try JSONSerialization.data(withJSONObject: ["unmounted": result.unmounted, "ejected": result.ejected,
                "failure": result.failure.map { String(describing: $0) } as Any? ?? NSNull()], options: [.sortedKeys])
            try await Task.detached { try data.write(to: output.appendingPathComponent("native-action-result.json"), options: .withoutOverwriting) }.value
        }
        try require(drives.message.hasSuffix(" ejected.") && queue.reviewResult == nil, "Native queued eject failed: " + drives.message)
        guard let result = queue.results.first(where: { $0.id == id }) else { throw UIVerification.Failure(message: "Native copy result missing") }
        try require(result.outcome.result.items.filter { $0.status == .succeeded }.count == 1, "Native drive Copy did not commit before Eject")
        checks.append("Real generated Copy commits before native whole-device Unmount and Eject")
        try require(!ApplicationFileActivity.gate.isClosed && operations.volumeBarrierOwner == nil,
                    "Native drive action leaked its activity barrier")
        checks.append("Native callbacks release actual application admission after completion")
        try await stage("06-copy-and-eject-completed", output: output)
        try JSONSerialization.data(withJSONObject: ["checks": checks, "passed": true], options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("drive-lifecycle.json"), options: .withoutOverwriting)
        return checks
    }

    /// Read only the Development app's exact private job slot before the
    /// Python owner creates or attaches an image. No discovery or recorder is
    /// started by this visit.
    private static func apfsFormatPreflight(browser: BrowserViewController, fixture: URL,
                                            output: URL) async throws -> [String] {
        let expectedState = fixture.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("runtime", isDirectory: true)
        let channel = Bundle.main.object(forInfoDictionaryKey: "MacExplorerDistributionChannel") as? String
        try require(Bundle.main.bundleIdentifier == "local.macexplorer.development"
                    && channel == "development"
                    && AppStorageLocations.stateDirectory?.standardizedFileURL.path == expectedState.path,
                    "Pre-image Format check requires the isolated Development job store")
        guard let store = NativeDriveJobStore.applicationStore() else {
            throw UIVerification.Failure(message: "Pre-image Format job store is unavailable")
        }
        let before = try await store.load()
        let drives = ApplicationVolumeCoordinator(operations: browser.operationCoordinator,
                                                  backend: VolumeLifecycle.shared)
        await drives.waitForNativeDriveJobLoad()
        try require(drives.nativeFormatSavedJobIsClean(),
                    "A prior or unreadable native Format job blocks image creation")
        let after = try await store.load()
        try require(before.bytes == after.bytes,
                    "Pre-image Format job changed during passive admission")
        _ = try await Task.detached { try validate(fixture, output: output) }.value
        let result: [String: Any] = ["passed": true, "cleanAdmission": true,
                                     "imageAbsent": true, "recorderCreated": false, "jobUnchanged": true]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("apfs-format-preflight.json"), options: .withoutOverwriting)
        return ["Development job store admitted a clean slot before image creation"]
    }

    private static func apfsUI(browser: BrowserViewController, drives: ApplicationVolumeCoordinator,
                               initial: ManagedVolume, receipt: Receipt, output: URL) async throws -> [String] {
        try require(!receipt.startsUnmounted && initial.deviceKind == .diskImage && initial.volumeUUID != nil,
                    "APFS UI requires the exact mounted generated image")
        let members = drives.volumes.filter { $0.group == receipt.outerMediaID && $0.volumeUUID != nil }
        let originalIDs = Set(members.compactMap(\.volumeUUID))
        try require(originalIDs.count == 1 && members.contains(initial), "APFS UI requires one original generated member")
        let markerBefore = try await GeneratedAPFSFormatVerification.verifyMarker(initial, receipt: receipt)
        let settings = BrowserSettings(persist: false)
        settings.appearance = browser.settings.appearance; settings.interfaceSize = browser.settings.interfaceSize
        settings.navigationStyle = browser.settings.navigationStyle; settings.glassFileContent = browser.settings.glassFileContent
        settings.motion.mode = browser.settings.motion.mode; settings.driveHealthLiveUpdates = false
        let health = ApplicationDriveDetails(reader: VolumeLifecycle.shared)
        let workspace = ApplicationDriveManagement(reader: VolumeLifecycle.shared, health: health)
        let creation = workspace.volumeCreation
        creation.restrictCreationForVerification(to: initial)
        workspace.show(settings: settings, drives: drives,
            protectedLocations: browser.operationCoordinator.protectedStorageLocations, browser: browser, initialPage: .overview)
        workspace.selectVolume(initial)
        workspace.window?.center(); workspace.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        do {
            try await until("Generated APFS workspace") {
                !workspace.isReading && drives.protectionReady && workspace.volumeCreationTarget?.mediaID == receipt.mediaID
            }
            try require(!ApplicationAPFSVolumeCreation.permitsInAppCreation(nil)
                && drives.volumes.filter({ $0.deviceKind != .diskImage }).allSatisfy({ !ApplicationAPFSVolumeCreation.permitsInAppCreation($0) }),
                "Physical storage unexpectedly passed image-only creation admission")
            workspace.showVolumeCreation()
            try await until("Generated APFS sheet") { workspace.window?.attachedSheet != nil && creation.canReview }
            creation.name = "Invalid/Generated Name"
            try await Task.sleep(for: .milliseconds(80))
            creation.review(); await creation.drain()
            try require(creation.plan == nil && creation.result == nil && creation.verificationCreationAttempts == 0
                && creation.notice == APFSVolumeCreationFailure.invalidName.userMessage, "Invalid name submitted or retained a review")
            let name = "Traverse-UI-" + receipt.jobID.uuidString
            creation.name = name
            try await Task.sleep(for: .milliseconds(80))
            creation.review(); await creation.drain()
            try require(creation.plan?.name == name && creation.verificationCreationAttempts == 0,
                        "Generated APFS review did not remain read-only")
            workspace.showsVolumeCreation = false; creation.dismiss()
            try await until("Generated review cancellation") { workspace.window?.attachedSheet == nil }
            try require(creation.verificationCreationAttempts == 0 && creation.result == nil, "Cancelled review submitted creation")
            workspace.showVolumeCreation(); creation.name = name
            try await until("Generated APFS confirmation sheet") { workspace.window?.attachedSheet != nil && creation.canReview }
            let refreshBefore = workspace.refreshCount
            try await stage("apfs-ui-ready", output: output)
            // CUA owns Review and the explicit Add Volume confirmation. This
            // deadline applies only before Create admission, never to a child.
            let deadline = ContinuousClock.now + .seconds(600)
            while creation.verificationCreationAttempts == 0 {
                guard ContinuousClock.now < deadline, workspace.window != nil, workspace.showsVolumeCreation else {
                    creation.cancelCheck()
                    throw UIVerification.Failure(message: "APFS UI confirmation ended before submission")
                }
                try await Task.sleep(for: .milliseconds(25))
            }
            // No deadline or cancellation after admission. The actual backend,
            // reconciliation and operation lease own this interval until drain.
            await creation.drain()
            guard let result = creation.result, let added = result.created else {
                throw UIVerification.Failure(message: "APFS UI creation did not produce a verified member")
            }
            try require(creation.verificationCreationAttempts == 1 && result.submitted && result.failure == nil
                && added.name == name && !originalIDs.contains(added.id), "APFS UI result exceeded its single reviewed request")
            let expected = originalIDs.union([added.id])
            try await until("APFS result discovery refresh") {
                let discovered = Set(drives.volumes.filter { $0.group == receipt.outerMediaID }.compactMap(\.volumeUUID))
                let shown = Set((workspace.snapshot?.nodes ?? []).filter {
                    $0.kind == .volume && $0.volume.group == receipt.outerMediaID
                }.compactMap { $0.volume.volumeUUID })
                return discovered == expected && shown == expected && workspace.refreshCount > refreshBefore && !workspace.isReading
            }
            for original in members {
                try require(drives.volumes.contains { current in
                    current.volumeUUID == original.volumeUUID && current.mediaID == original.mediaID && current.group == original.group
                        && current.name == original.name && current.url == original.url && current.fileSystemID == original.fileSystemID
                }, "Original generated member changed during Add Volume")
            }
            let current = try await observed(drives) { $0.mediaID == receipt.mediaID && $0.group == receipt.outerMediaID }
            try require(try await GeneratedAPFSFormatVerification.verifyMarker(current, receipt: receipt) == markerBefore, "Original marker changed during Add Volume")
            try require(workspace.selectedNode?.volume.volumeUUID == initial.volumeUUID && !creation.isWorking && !creation.canReview,
                        "APFS result lost source selection or reopened creation admission")
            let checks = ["Invalid name and cancelled review submit no creation request",
                "CUA confirms the real image-only Drives sheet; one creation request returns after actual backend drain",
                "Exact original members and marker survive; discovery and ordinary workspace show exactly one new volume"]
            try JSONSerialization.data(withJSONObject: ["passed": true, "checks": checks, "creationAttempts": 1,
                "createdVolumeUUID": added.id.uuidString, "originalMarkerPreserved": true, "discoveryRefreshed": true],
                options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("apfs-ui-result.json"), options: .withoutOverwriting)
            // Keep the actual result and refreshed workspace visible for CUA.
            // This bounded viewing interval begins only after full child drain.
            let reviewEnd = ContinuousClock.now + .seconds(120)
            while workspace.window != nil && ContinuousClock.now < reviewEnd { try await Task.sleep(for: .milliseconds(25)) }
            await workspace.closeAndDrain(); await health.closeAndDrain()
            try await until("APFS workspace close") { workspace.window == nil }
            return checks
        } catch {
            // Even verifier failure must not let outer teardown signal a live
            // creation child. Dismissal suppresses publication, never cleanup.
            await creation.drain(); await workspace.closeAndDrain(); await health.closeAndDrain()
            throw error
        }
    }

    private static func stage(_ phase: String, output: URL) async throws {
        try await Task.detached {
            let data = try JSONSerialization.data(withJSONObject: ["phase": phase], options: [.sortedKeys])
            let directory = open(output.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard directory >= 0 else { throw UIVerification.Failure(message: "Native phase directory unavailable") }
            defer { close(directory) }
            let fd = openat(directory, "stage-" + phase + ".json", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw UIVerification.Failure(message: "Native phase receipt refused") }
            defer { close(fd) }
            let count = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            guard count == data.count, fsync(fd) == 0, fsync(directory) == 0 else {
                throw UIVerification.Failure(message: "Native phase receipt synchronization failed")
            }
        }.value
    }

    private static func observed(_ drives: ApplicationVolumeCoordinator, _ predicate: (ManagedVolume) -> Bool) async throws -> ManagedVolume {
        try await until("Native drive observation") { drives.volumes.contains(where: predicate) }
        return drives.volumes.first(where: predicate)!
    }
    private static func until(_ stage: String, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(120)
        while ContinuousClock.now < deadline {
            if condition() { return }; try await Task.sleep(for: .milliseconds(10))
        }
        throw UIVerification.Failure(message: stage + " did not settle within two minutes")
    }
    private static func require(_ value: Bool, _ message: String) throws {
        if !value { throw UIVerification.Failure(message: message) }
    }
}


#endif
