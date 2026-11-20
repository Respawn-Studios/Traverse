#if DEBUG
import AppKit
import Darwin
import ExplorerCore
import FileOperations
import LocalStorage
import SwiftUI

@MainActor enum DriveProtectionVerification {
    static func run(root: URL, browser: BrowserViewController) async throws -> [String: Any] {
        let base = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/b04-protected-drives")
        try require(root.deletingLastPathComponent() == base && root.resolvingSymlinksInPath() == root
            && UUID(uuidString: root.lastPathComponent) != nil && FileManager().fileExists(atPath: root.appendingPathComponent("reservation.json").path),
            "Protection QA requires its admitted generated root")
        var checks = try await storeChecks(root: root)
        checks += try await competingWriterCheck(root: root)
        checks += try await SnapshotIntegrityVerification.run(in: root)
        checks += try await coordinatorChecks(root: root, browser: browser)
        checks += try await DriveLifecycleVerification.run(in: root)
        checks += try await protectedStateCheck(root: root)
        checks += try await nativePreparationChecks()
        return ["passed": true, "mode": "generated-protected-drives", "checks": checks,
                "nativeDriveSubmissions": 0, "personalProtectionEdited": false]
    }

    private static func protectedStateCheck(root: URL) async throws -> [String] {
        let state = root.appendingPathComponent("guarded-state"), directory = root.appendingPathComponent("guarded-state/drive-protection")
        let store = DriveProtectionStore(directory: directory), absent = try await store.load()
        let saved = try await store.set(UUID(), name: "Generated protected drive", level: .keepMounted, expected: absent)
        let engine = ApplicationOperationCoordinator.shared.engine(at: state.appendingPathComponent("operation-recovery"))
        let outcome = await engine.perform(.createFolder(parent: directory, name: "Forbidden"))
        let after = try await store.load()
        try require(outcome.recordID == nil && outcome.result.items.contains { $0.status == .failed(.protectedLocation) }
            && after.bytes == saved.bytes, "Ordinary file command changed live protection storage")
        return ["Ordinary operation engine refuses writes inside live drive-protection storage without creating history"]
    }

    private static func nativePreparationChecks() async throws -> [String] {
        // Passive native facts only. This method never calls perform, Mount,
        // Unmount, Eject, an image command or a privilege helper.
        let backend = VolumeLifecycle.shared
        var latest: [ManagedVolume] = []
        let observer = Task { @MainActor in
            for await values in backend.updates { if Task.isCancelled { return }; latest = values }
        }
        try await Task.sleep(for: .milliseconds(900))
        observer.cancel(); await observer.value
        var checked = false
        for volume in latest where volume.deviceKind == .externalDisk && volume.canUnmount && volume.volumeUUID != nil {
            let rules = try VolumeRemovalProtection(saved: [volume.volumeUUID!: .keepMounted])
            var refused = false
            do { _ = try await backend.prepare(volume, action: .unmount, protecting: [], removalProtection: rules) }
            catch VolumeLifecycleFailure.userProtected { refused = true }
            catch VolumeLifecycleFailure.changed { continue }
            try require(refused, "Native preparation did not enforce the immutable saved rule")
            checked = true; break
        }
        var notes = [checked ? "Read-only native device preparation refuses Keep Mounted before submission; no native removal request" :
            "Native protection preparation not exercised: no stable eligible external observation; generated native-backend controls remain the evidence"]
        if let appVolume = latest.first(where: { volume in
            guard volume.canUnmount, let path = volume.url?.path else { return false }
            return Bundle.main.bundleURL.path.hasPrefix(path + "/")
        }) {
            var refused = false
            do { _ = try await backend.prepare(appVolume, action: .unmount, protecting: [Bundle.main.bundleURL], removalProtection: .empty) }
            catch { refused = true }
            try require(refused, "Removing extra protection bypassed live app-volume protection")
            notes.append("Read-only native app-volume Unmount preparation remains refused with no extra rules; no native request")
        }
        return notes
    }

    static func crash(root: URL, boundary: String) async throws {
        guard let declared = ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"], root.path == declared,
              root.pathComponents.contains("b04-protected-drives"), UUID(uuidString: root.lastPathComponent) != nil,
              ["staged", "validated", "published", "synchronized"].contains(boundary) else { throw DriveProtectionLibrary.Failure.invalid }
        let store = DriveProtectionStore(directory: root.appendingPathComponent("state"), writeCheckpoint: { event in
            let name: String
            switch event { case .staged: name = "staged"; case .validated: name = "validated"; case .published: name = "published"; case .synchronized: name = "synchronized" }
            if name == boundary { _exit(86) }
        })
        let before = try await store.load()
        let id = try requireValue(before.library.rules.first?.id, "Crash fixture has no original protection")
        _ = try await store.set(id, name: "Generated drive", level: .preventEject, expected: before)
        throw DriveProtectionLibrary.Failure.invalid
    }

    private static func competingWriterCheck(root: URL) async throws -> [String] {
        let directory = root.appendingPathComponent("competing-writers"), id = UUID(), another = UUID()
        let ordinary = DriveProtectionStore(directory: directory), absent = try await ordinary.load()
        let first = try await ordinary.set(id, name: "Generated first drive", level: .keepMounted, expected: absent)
        let gate = WriterGate()
        defer { gate.release() }
        let held = DriveProtectionStore(directory: directory, writeCheckpoint: { event in if case .validated = event { gate.hold() } })
        let saving = Task { try await held.set(id, name: "Generated first drive", level: .preventEject, expected: first) }
        try await wait { gate.isHeld }
        var readRejected = false
        do { _ = try await ordinary.load() } catch { readRejected = true }
        var rejected = false
        do { _ = try await ordinary.set(another, name: "Generated other drive", level: .keepMounted, expected: first) } catch { rejected = true }
        gate.release()
        _ = try await saving.value
        let final = try await ordinary.load()
        try require(rejected && readRejected && final.library.rules.count == 1 && final.library.saved[id] == .preventEject,
                    "Two independent writers acknowledged saves across the final publication gap")
        return ["Independent writer/shared-reader owners refuse the final publication gap; readers and writers resume only after actual lock release"]
    }

    private final class WriterGate: @unchecked Sendable {
        private let condition = NSCondition()
        private var held = false
        private var released = false
        private var armed = false
        var isHeld: Bool { condition.lock(); defer { condition.unlock() }; return held }
        func hold() { condition.lock(); held = true; condition.broadcast(); while !released { condition.wait() }; condition.unlock() }
        func arm() { condition.lock(); armed = true; held = false; released = false; condition.unlock() }
        func holdIfArmed() {
            condition.lock(); defer { condition.unlock() }
            guard armed else { return }; armed = false; held = true; condition.broadcast()
            while !released { condition.wait() }
        }
        func release() { condition.lock(); released = true; condition.broadcast(); condition.unlock() }
    }

    static func reopen(root: URL) async throws -> [String: Any] {
        guard let declared = ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"], root.path == declared,
              root.pathComponents.contains("b04-protected-drives"), UUID(uuidString: root.lastPathComponent) != nil else {
            throw DriveProtectionLibrary.Failure.invalid
        }
        let expectedBusy = ProcessInfo.processInfo.arguments.contains("--expect-protection-busy")
        let snapshot: DriveProtectionStore.Snapshot
        do { snapshot = try await DriveProtectionStore(directory: root.appendingPathComponent("state")).load() }
        catch BrowserSnapshotFile.Failure.writerBusy {
            guard expectedBusy else { throw BrowserSnapshotFile.Failure.writerBusy }
            return ["passed": true, "refusedBusy": true, "readOnly": true]
        }
        try require(!expectedBusy, "A different process's held writer lock was bypassed")
        return ["passed": true, "rules": snapshot.library.rules.map { ["id": $0.id.uuidString, "level": $0.level.rawValue] }, "readOnly": true]
    }

    private static func storeChecks(root: URL) async throws -> [String] {
        let directory = root.appendingPathComponent("private-rules"), store = DriveProtectionStore(directory: root.appendingPathComponent("private-rules"))
        let absent = try await store.load(), id = UUID()
        try require(absent.bytes == nil && !FileManager().fileExists(atPath: directory.path), "Passive protection load created state")
        let rereadAbsent = try await store.load()
        try require(rereadAbsent.bytes == nil && rereadAbsent.library == absent.library
            && store.matchesSaved(absent) && store.matchesSaved(rereadAbsent),
            "An unchanged absent protection document failed the final Format gate")
        let first = try await store.set(id, name: "Generated USB", level: .keepMounted, expected: absent)
        try require(!store.matchesSaved(absent) && store.matchesSaved(first),
            "The final Format gate accepted a changed saved protection document")
        let reopened = try await DriveProtectionStore(directory: directory).load()
        try require(reopened.bytes == first.bytes && reopened.library.saved[id] == .keepMounted, "Saved protection did not reopen")
        let path = directory.appendingPathComponent("drive-protection-v1.json")
        try await Task.detached {
            var info = stat(); try require(lstat(path.path, &info) == 0 && info.st_mode & 0o777 == 0o600 && info.st_nlink == 1,
                                                        "Protection file is not private")
            try require(lstat(directory.path, &info) == 0 && info.st_mode & 0o777 == 0o700, "Protection directory is not private")
        }.value
        var rejected = false
        do { _ = try await store.set(id, name: "Generated", level: .none, expected: absent) } catch { rejected = true }
        let afterStale = try await store.load()
        try require(rejected && afterStale.bytes == first.bytes, "Stale save changed protection")
        let second = try await store.set(id, name: "Generated USB", level: .preventEject, expected: reopened)
        try require(second.library.saved[id] == .preventEject, "Protection reduction did not save")
        // An error after publication is deliberately not an acknowledgement.
        enum Injected: Error { case failure }
        let uncertain = DriveProtectionStore(directory: directory, writeCheckpoint: { event in
            if case .published = event { throw Injected.failure }
        })
        rejected = false
        do { _ = try await uncertain.set(id, name: "Generated USB", level: .keepMounted, expected: second) } catch { rejected = true }
        let afterUncertain = try await store.load()
        try require(rejected && afterUncertain.library.saved[id] == .keepMounted, "Uncertain publication was misreported or unreadable")
        let checks = try await Task.detached { try storageRefusals(root: root, valid: first.bytes!) }.value
        let missingDirectory = root.appendingPathComponent("missing-document")
        try await Task.detached { try FileManager().createDirectory(at: missingDirectory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }.value
        rejected = false
        do { _ = try await DriveProtectionStore(directory: missingDirectory).load() } catch { rejected = true }
        try require(rejected, "An existing empty protection directory silently became default rules")
        try require(!DriveProtectionStore(directory: missingDirectory).matchesSaved(absent),
            "The final Format gate accepted unreadable protection storage")
        let beforePublication = DriveProtectionStore(directory: directory, writeCheckpoint: { event in
            if case .staged = event { throw Injected.failure }
        })
        rejected = false
        do { _ = try await beforePublication.set(id, name: "Generated USB", level: .none, expected: afterUncertain) } catch { rejected = true }
        let afterFailedStage = try await store.load()
        try require(rejected && afterFailedStage.bytes == afterUncertain.bytes, "Failed unpublished edit changed acknowledged protection")
        await store.drain()
        return ["Repeated absent reads retain one stable policy identity; final Format gate accepts unchanged absence and refuses changed or unreadable state",
                "Passive read creates nothing; private 0700/0600 storage, bounded versioned save/reopen and exact stale-save refusal",
                "Published-but-unacknowledged write throws; fresh read identifies its actual saved protection"] + checks
    }

    nonisolated private static func storageRefusals(root: URL, valid: Data) throws -> [String] {
        let fm = FileManager(), fileName = "drive-protection-v1.json"
        func make(_ label: String) throws -> (URL, URL) {
            let directory = root.appendingPathComponent(label)
            try fm.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            return (directory, directory.appendingPathComponent(fileName))
        }
        func refuses(_ work: () throws -> Void) throws {
            var rejected = false; do { try work() } catch { rejected = true }
            try require(rejected, "Unsafe protection snapshot accepted")
        }
        for (label, bytes) in [("invalid", Data("not JSON".utf8)), ("future", Data("{\"version\":9}".utf8))] {
            let (directory, file) = try make(label); try bytes.write(to: file, options: .withoutOverwriting); try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            let snapshot = BrowserSnapshotFile(directory: directory, name: fileName, maximumBytes: 131_072, requiresPrivateDurability: true)
            try refuses { let data = try snapshot.read()!; let library = try JSONDecoder().decode(DriveProtectionLibrary.self, from: data); try library.validate() }
            try require(try Data(contentsOf: file) == bytes, "Invalid protection changed")
        }
        let (directory, file) = try make("unsafe"), sentinel = root.appendingPathComponent("sentinel")
        try valid.write(to: sentinel, options: .withoutOverwriting)
        try fm.createSymbolicLink(at: file, withDestinationURL: sentinel)
        let snapshot = BrowserSnapshotFile(directory: directory, name: fileName, maximumBytes: 131_072, requiresPrivateDurability: true)
        try refuses { _ = try snapshot.read() }; try refuses { try snapshot.write(valid) { _ in } }
        try fm.removeItem(at: file); try fm.linkItem(at: sentinel, to: file)
        try refuses { _ = try snapshot.read() }
        try fm.removeItem(at: file); try valid.write(to: file, options: .withoutOverwriting)
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path); try refuses { _ = try snapshot.read() }
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path); try refuses { _ = try snapshot.read() }
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let redirect = root.appendingPathComponent("redirect")
        try fm.createSymbolicLink(at: redirect, withDestinationURL: directory)
        let redirected = BrowserSnapshotFile(directory: redirect, name: fileName, maximumBytes: 131_072, requiresPrivateDurability: true)
        try refuses { _ = try redirected.read() }
        for label in ["symlink-lock", "fifo-lock", "nonempty-lock"] {
            let (directory, file) = try make(label)
            try valid.write(to: file, options: .withoutOverwriting); try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            let lock = directory.appendingPathComponent(fileName + ".writer-lock")
            if label == "symlink-lock" { try fm.createSymbolicLink(at: lock, withDestinationURL: sentinel) }
            else if label == "fifo-lock" { try require(mkfifo(lock.path, 0o600) == 0, "Lock FIFO fixture failed") }
            else { try Data("foreign".utf8).write(to: lock); try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: lock.path) }
            let snapshot = BrowserSnapshotFile(directory: directory, name: fileName, maximumBytes: 131_072, requiresPrivateDurability: true)
            try refuses { _ = try snapshot.read() }; try refuses { try snapshot.write(valid) { _ in } }
            try require(try Data(contentsOf: file) == valid, "Unsafe lock changed its catalog")
        }
        try require(try Data(contentsOf: sentinel) == valid, "Snapshot guard changed sentinel")
        return ["Malformed/future rules preserved; final/ancestor symlink, hard link and broad file/directory permissions refuse",
                "Symlink/FIFO/nonempty writer locks refuse before reading or changing the catalog; no blocking lock wait"]
    }

    private static func coordinatorChecks(root: URL, browser: BrowserViewController) async throws -> [String] {
        let operations = ApplicationOperationCoordinator.shared, original = operations.drives
        let gate = WriterGate(); defer { gate.release() }
        let backend = Backend(), store = DriveProtectionStore(directory: root.appendingPathComponent("coordinator-rules"), writeCheckpoint: { event in
            if case .validated = event { gate.holdIfArmed() }
        })
        let drives = ApplicationVolumeCoordinator(operations: operations, backend: backend, protectionStore: store)
        operations.drives = drives
        defer { drives.cancel(); operations.drives = original }
        func volume(name: String, uuid: UUID? = UUID(), group: UInt64 = 999) -> ManagedVolume {
            ManagedVolume(id: UUID(), name: name, url: root.appendingPathComponent(name), isInternal: false,
                canMount: false, canUnmount: true, canEject: true, fileSystemID: 999, group: group, mediaID: UInt64.random(in: 100...999), volumeUUID: uuid)
        }
        let target = volume(name: "Generated USB"), sibling = volume(name: "Sibling")
        backend.emit([target, sibling]); drives.startDiscovery(); await drives.drainProtection()
        try await wait { drives.volumes.count == 2 && drives.protectionReady }
        drives.setProtection(.keepMounted, for: target); await drives.drainProtection()
        drives.request(target, action: .unmount, policy: .requireCancel)
        drives.request(target, action: .eject, policy: .requireCancel)
        try require(backend.submissions == 0 && !drives.isBusy && drives.protectionLevel(for: target) == .keepMounted,
                                  "Protected action reached backend")
        let menu = try requireValue(browser.driveMenu(for: target.url!), "Missing shared drive menu")
        try require(!menu.items.contains { ["Unmount", "Eject when ready"].contains($0.title) }
            && menu.items.contains { $0.title == "Drive Protection" } && browser.isSidebarEjectHidden(for: target), "Protected menu/sidebar retained removal action")
        drives.setProtection(.none, for: target); await drives.drainProtection()
        drives.setProtection(.preventEject, for: sibling); await drives.drainProtection()
        drives.request(target, action: .eject, policy: .requireCancel)
        try require(backend.submissions == 0 && !drives.isBusy && drives.permitsRemoval(target, action: .unmount),
                                  "Sibling protection was bypassed or blocked ordinary Unmount")
        drives.request(target, action: .unmount, policy: .requireCancel)
        try await wait { !drives.isBusy && backend.submissions == 1 }
        // A second serial owner changes generated rules behind the cached UI.
        let other = DriveProtectionStore(directory: root.appendingPathComponent("coordinator-rules"))
        let before = try await other.load()
        _ = try await other.set(target.volumeUUID!, name: target.name, level: .keepMounted, expected: before)
        drives.request(target, action: .unmount, policy: .requireCancel)
        try await wait { !drives.isBusy }
        try require(backend.submissions == 1 && drives.protectionLevel(for: target) == .keepMounted,
                                  "Removal used cached rules instead of freshly reading them")
        drives.setProtection(.none, for: target); await drives.drainProtection()
        drives.setProtection(.none, for: sibling); await drives.drainProtection()
        let temporary = volume(name: "No UUID", uuid: nil)
        backend.emit([target, sibling, temporary]); try await wait { drives.volumes.count == 3 }
        drives.setProtection(.keepMounted, for: temporary); await drives.drainProtection()
        try require(!drives.savesProtection(for: temporary) && drives.savedProtections.isEmpty
            && !drives.permitsRemoval(temporary, action: .eject), "Session protection leaked into persistent associations")
        let bytes = try await store.load().bytes!
        let file = root.appendingPathComponent("coordinator-rules/drive-protection-v1.json")
        try await Task.detached { try Data("invalid".utf8).write(to: file) }.value
        drives.reloadProtection(); await drives.drainProtection()
        try require(!drives.protectionReady && !drives.permitsRemoval(target, action: .unmount), "Invalid library silently became defaults")
        drives.request(target, action: .eject, policy: .requireCancel)
        try require(backend.submissions == 1, "Unavailable protection submitted removal")
        try await Task.detached { try bytes.write(to: file); try FileManager().setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }.value
        drives.reloadProtection(); await drives.drainProtection()
        try require(drives.protectionReady && drives.protectionLevel(for: temporary) == .keepMounted, "Reload lost session protection")
        drives.setProtection(.preventEject, for: target); await drives.drainProtection()
        drives.setProtection(.keepMounted, for: sibling); await drives.drainProtection()
        browser.settings.navigationStyle = .glass; browser.settings.appearance = .dark
        let host = NSHostingController(rootView: DriveControlsView(drives: drives, settings: browser.settings, inspectQueue: {}))
        let window = NSWindow(contentViewController: host)
        window.title = "Generated drive protection · no native actions"
        _ = ToolWindowChrome.install(in: window, settings: browser.settings)
        window.setFrame(NSRect(x: 300, y: 180, width: 440, height: 670), display: false)
        window.isReleasedWhenClosed = false
        if ProcessInfo.processInfo.arguments.contains("--offscreen") { window.setFrameOrigin(NSPoint(x: -12000, y: -12000)) }
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(160))
        try await UIVerification.snapshot(window, to: root.appendingPathComponent("evidence/drive-protection.png"))
        if ProcessInfo.processInfo.arguments.contains("--drive-protection-controls") {
            // The actual picker must change a real generated rule; no native
            // action button can reach anything except this injected backend.
            for _ in 0..<1800 {
                if drives.protectionLevel(for: target) == .keepMounted && !drives.isEditingProtection { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            try require(drives.protectionLevel(for: target) == .keepMounted, "Native picker input did not update the exact generated rule")
        }
        window.close()
        await drives.drainProtection()
        gate.arm(); drives.setProtection(.keepMounted, for: target)
        try await wait { gate.isHeld }
        try require(drives.isEditingProtection && drives.isBusy && !drives.hasDriveRequest && !browser.hasPendingFileOperation,
                    "Saving a drive preference invented pending file/drive work")
        var drained = false
        let draining = Task { await drives.drainProtection(); drained = true }
        try await Task.sleep(for: .milliseconds(60))
        try require(!drained, "Close/quit drain released the real protection writer early")
        gate.release(); await draining.value
        try require(!drives.isBusy && drives.protectionLevel(for: target) == .keepMounted && backend.submissions == 1,
                    "Quiet preference drain lost a save or submitted a drive request")
        return ["Real coordinator hides/refuses protected actions before backend; sibling protection blocks Eject while allowing Unmount",
                "Removal reloads changed saved rules; invalid storage blocks removal until explicit successful Reload; session rules survive Reload without persistence",
                "Preference saves drain actual held writers on close/quit without inventing a file-work popup or native drive request"]
    }

    nonisolated private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw UIVerification.Failure(message: message) }
    }
    nonisolated private static func requireValue<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw UIVerification.Failure(message: message) }; return value
    }
    private static func wait(_ condition: @escaping @MainActor () -> Bool) async throws {
        for _ in 0..<500 { if condition() { return }; try await Task.sleep(for: .milliseconds(10)) }
        throw DriveProtectionLibrary.Failure.unavailable
    }
    private final class Backend: VolumeLifecycleManaging, @unchecked Sendable {
        let updates: AsyncStream<[ManagedVolume]>
        private let output: AsyncStream<[ManagedVolume]>.Continuation
        private let lock = NSLock()
        private var values: [ManagedVolume] = []
        private var count = 0
        var submissions: Int { lock.withLock { count } }
        init() { (updates, output) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1)) }
        func emit(_ volumes: [ManagedVolume]) { lock.withLock { values = volumes }; output.yield(volumes) }
        func prepare(_ target: ManagedVolume, action: VolumeAction, protecting locations: [URL], removalProtection: VolumeRemovalProtection) async throws -> PreparedVolumeAction {
            let members = lock.withLock { action == .unmount ? [target] : values.filter { $0.group == target.group } }
            try removalProtection.validate(target: target, action: action, members: members)
            return PreparedVolumeAction(target: target, affected: [target], action: action, protecting: locations,
                                        protectionMembers: members, removalProtection: removalProtection)
        }
        func perform(_ prepared: PreparedVolumeAction) async -> VolumeActionResult {
            lock.withLock { count += 1 }
            return VolumeActionResult(unmounted: false, ejected: false, failure: .busy)
        }
    }
}
#endif
