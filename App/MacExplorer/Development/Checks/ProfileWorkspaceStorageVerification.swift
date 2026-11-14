#if DEBUG
import AppKit
import ExplorerCore

@MainActor enum ProfileWorkspaceStorageVerification {
    private static let firstID = UUID(uuidString: "D9F9923E-69CF-493C-86A9-31EB49D00A01")!
    private static let secondID = UUID(uuidString: "D9F9923E-69CF-493C-86A9-31EB49D00A02")!
    static func run() async {
        guard let path = ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"] else { exit(2) }
        let root = URL(fileURLWithPath: path)
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let mode = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--profile-phase=") }).map { String($0.dropFirst(16)) } ?? "exercise"
        let allowed = ["exercise", "seed", "hold", "contend", "resume", "save-staged", "save-published", "disable-published", "forgotten"]
        guard allowed.contains(mode), root.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-release"),
              UUID(uuidString: root.lastPathComponent)?.uuidString == root.lastPathComponent,
              root.resolvingSymlinksInPath().path == root.path,
              let bytes = try? Data(contentsOf: root.appendingPathComponent("reservation.json")),
              let value = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              value["action"] as? String == "traverse-profile-workspaces-storage" else { exit(2) }
        var checks: [String] = [], failures: [String] = []
        do {
            let directory = root.appendingPathComponent("state"), store = WorkspaceProfileStore(directory: directory)
            let first = try profile(root, id: firstID), second = try profile(root, id: secondID, name: "Second")
            switch mode {
            case "seed":
                _ = try await store.enable(first, initial: first.snapshot)
                _ = try await store.enable(second, initial: second.snapshot)
                checks.append("Two explicitly opted-in generated profiles are durable")
            case "hold":
                let session = try await store.begin(first)
                try await write(["held": true], to: root.appendingPathComponent("evidence/lease-ready.json"))
                let deadline = ProcessInfo.processInfo.systemUptime + 15
                while ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(for: .milliseconds(25)) }
                await store.end(session.token)
                throw UIVerification.Failure(message: "Lease-holder test must be ended by its owning harness")
            case "contend":
                try UIVerification.require(await refuses { try await store.begin(first) }, "Another process acquired the active profile")
                let peer = try await store.begin(second); await store.end(peer.token)
                checks.append("A real second process refuses the owned profile while another profile remains available")
            case "save-staged", "save-published", "disable-published":
                let session = try await store.begin(first)
                await store.setCheckpointForVerification { boundary in
                    let crash = mode == "save-staged" ? { if case .staged = boundary { return true }; return false }()
                        : { if case .published = boundary { return true }; return false }()
                    if crash { raise(SIGKILL) }
                }
                if mode == "disable-published" { try await store.disable(first.id, expectedConsent: session.record.consent, ownedBy: session.token) }
                else { _ = try await store.save(session.token, snapshot: sample(root, name: "After Crash")) }
                throw UIVerification.Failure(message: "Requested process interruption did not occur")
            case "resume":
                let session = try await store.begin(first)
                _ = try await store.save(session.token, snapshot: sample(root, name: "Recovered"))
                await store.end(session.token)
                checks.append("A fresh process reacquires the released lease and saves a valid recovered workspace")
            case "forgotten":
                let value = try await store.load()
                try UIVerification.require(value.memory.record(for: first.id) == nil
                    && value.memory.record(for: second.id) != nil, "Interrupted Forget removed the wrong profile or resurrected the target")
                try UIVerification.require(await refuses { try await store.begin(first) }, "Forgotten profile resumed after process exit")
                checks.append("Interrupted published Forget remains absent; unrelated profile survives")
            default:
                try await exercise(root: root, store: store, first: first, second: second, checks: &checks)
            }
            await store.drain()
            try UIVerification.require(await store.heldSessionsForVerification() == 0, "Generated storage owner retains a session lease")
        } catch { failures.append(String(describing: error)) }
        try? await write(["passed": failures.isEmpty, "mode": mode, "checks": checks, "failures": failures,
            "sourceFileMutations": 0, "generatedStateWrites": true, "networkRequests": 0, "personalCatalogs": 0],
            to: root.appendingPathComponent("result-" + mode + ".json"))
        NSApp.terminate(nil)
    }
    private static func exercise(root: URL, store: WorkspaceProfileStore, first: WorkspaceLaunchProfile,
                                 second: WorkspaceLaunchProfile, checks: inout [String]) async throws {
        let directory = root.appendingPathComponent("state")
        checks += try await SnapshotIntegrityVerification.run(in: root)
        let absent = try await store.load()
        let created = await exists(directory)
        try UIVerification.require(!absent.exists && !created, "Passive profile reading created storage")
        try UIVerification.require(await refuses { try await store.begin(first) }, "Missing working state silently enabled remembering")
        try UIVerification.require(!(await exists(directory)), "Missing Resume repaired storage")
        let original = try await store.enable(first, initial: sample(root, name: "Initial"))
        let session = try await store.begin(first)
        try UIVerification.require(session.record == original && session.record.snapshot.panes[0].tabs.tabs[0].selection.isEmpty,
            "Enabled workspace loses its exact record or retains selected filenames")
        let peer = WorkspaceProfileStore(directory: directory)
        try UIVerification.require(await refuses { try await peer.begin(first) }, "A second store took an active profile lease")
        _ = try await peer.enable(second, initial: second.snapshot)
        let secondSession = try await peer.begin(second)
        _ = try await peer.save(secondSession.token, snapshot: sample(root, name: "Second Later"))
        checks.append("Passive reads/Resume create nothing; explicit Enable is durable; distinct profile sessions coexist")

        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        await store.setCheckpointForVerification { boundary in
            if case .staged = boundary {
                entered.signal()
                guard release.wait(timeout: .now() + 3) == .success else { throw WorkspaceProfileStore.Failure.unavailable }
            }
        }
        let saving = Task { try await store.save(session.token, snapshot: sample(root, name: "First Later")) }
        let reached = await Task.detached { waitForSignal(entered) }.value
        try UIVerification.require(reached, "Generated storage boundary was not reached")
        let refused = await refuses { try await peer.load() }
        release.signal()
        _ = try await saving.value
        await store.setCheckpointForVerification(nil)
        try UIVerification.require(refused, "A conflicting catalog reader ignored the active writer lease")
        let after = try await store.load()
        try UIVerification.require(after.memory.records.count == 2, "A checkpoint lost an unrelated profile")
        let firstSnapshot = sample(root, name: "Concurrent First"), secondSnapshot = sample(root, name: "Concurrent Second")
        async let firstWrite = store.save(session.token, snapshot: firstSnapshot)
        async let secondWrite = peer.save(secondSession.token, snapshot: secondSnapshot)
        let (firstSaved, secondSaved) = try await (firstWrite, secondWrite)
        let concurrent = try await store.load()
        try UIVerification.require(concurrent.memory.record(for: first.id) == firstSaved
            && concurrent.memory.record(for: second.id) == secondSaved, "Concurrent profile checkpoints lost an update")
        checks.append("Short catalog leases refuse in-flight contention without losing unrelated records")

        try await store.disable(first.id, expectedConsent: session.record.consent, ownedBy: session.token)
        try UIVerification.require(await refuses { try await store.save(session.token, snapshot: sample(root)) }, "Old queued token resurrected a disabled profile")
        let fresh = try await store.enable(first, initial: first.snapshot)
        try UIVerification.require(fresh.consent != original.consent, "Re-enable reuses old recording consent")
        let resumed = try await store.begin(first)
        try await store.disable(first.id, expectedConsent: resumed.record.consent, ownedBy: resumed.token)
        for _ in 0..<6 {
            let record = try await store.enable(first, initial: first.snapshot)
            try await store.disable(first.id, expectedConsent: record.consent)
        }
        let names = try await Task.detached { try FileManager().contentsOfDirectory(atPath: directory.path) }.value
        try UIVerification.require(names.filter { $0.contains(".session-") && !$0.contains("session-inventory") }.count == 1,
            "Disable/re-enable accumulates lifetime lock inodes")
        await peer.end(secondSession.token)
        checks.append("Disable drains/removes only its record; stale tokens fail; re-enable has new consent and retires inactive lease inodes")

        try await integrity(root: root, first: first, second: second)
        checks.append("Missing/replaced locks, corrupt/newer data and redirected parents refuse without repair or replacement")
        try await storageBound(root: root)
        checks.append("Four-megabyte catalog limit refuses an oversized checkpoint while preserving the last valid document")
    }
    private static func storageBound(root: URL) async throws {
        let directory = root.appendingPathComponent("capacity"), store = WorkspaceProfileStore(directory: directory)
        let ids = (0..<4).map { _ in UUID() }
        var layout = PaneLayout(paneID: ids[0])
        try layout.split(ids[0], inserting: ids[1], at: .trailing)
        try layout.split(ids[0], inserting: ids[2], at: .bottom)
        try layout.split(ids[1], inserting: ids[3], at: .bottom)
        let url = root.appendingPathComponent("source/" + String(repeating: "x", count: 6_000))
        let tabs = WorkspaceSession(tabs: (0..<32).map { _ in .init(location: .init(kind: .directory, url: url)) })
        let snapshot = PaneWorkspaceSnapshot(layout: layout, activePane: ids[0],
            panes: ids.map { .init(id: $0, tabs: tabs, viewMode: DirectoryViewMode.details.rawValue) })
        let file = directory.appendingPathComponent("profile-workspaces-v1.json")
        var previous: Data?, refused = false
        for index in 0..<8 {
            let profile = try WorkspaceLaunchProfile(name: "Capacity \(index)", snapshot: snapshot)
            do { _ = try await store.enable(profile, initial: snapshot) }
            catch BrowserSnapshotFile.Failure.oversized { refused = true; break }
            previous = try await Task.detached { try Data(contentsOf: file) }.value
        }
        let final = try await Task.detached { try Data(contentsOf: file) }.value
        try UIVerification.require(refused && previous != nil && previous == final && final.count <= 4 << 20,
            "Oversized working catalog was written or discarded prior valid data")
        _ = try await store.load()
    }
    private static func integrity(root: URL, first: WorkspaceLaunchProfile, second: WorkspaceLaunchProfile) async throws {
        for fault in ["writer", "mutation", "inventory", "session", "newer", "corrupt", "replaced"] {
            let directory = root.appendingPathComponent("integrity/" + fault), store = WorkspaceProfileStore(directory: directory)
            _ = try await store.enable(first, initial: first.snapshot)
            let token = fault == "replaced" ? try await store.begin(first) : nil
            let file = directory.appendingPathComponent("profile-workspaces-v1.json")
            let before = try await Task.detached { try Data(contentsOf: file) }.value
            try await Task.detached {
                let manager = FileManager(), base = "profile-workspaces-v1.json"
                switch fault {
                case "writer": try manager.removeItem(at: directory.appendingPathComponent(base + ".writer-lock"))
                case "mutation": try manager.removeItem(at: directory.appendingPathComponent(base + ".mutation-lock"))
                case "inventory": try manager.removeItem(at: directory.appendingPathComponent(base + ".session-inventory.lock"))
                case "session": try manager.removeItem(at: directory.appendingPathComponent(base + ".session-" + first.id.uuidString + ".lock"))
                case "replaced":
                    let named = directory.appendingPathComponent(base + ".session-" + first.id.uuidString + ".lock")
                    try manager.moveItem(at: named, to: directory.appendingPathComponent("retained-old-lock"))
                    try Data().write(to: named, options: .withoutOverwriting); try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: named.path)
                case "newer":
                    var object = try JSONSerialization.jsonObject(with: before) as! [String: Any]; object["version"] = 99
                    try JSONSerialization.data(withJSONObject: object).write(to: file); try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                default: try Data("{invalid".utf8).write(to: file); try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                }
            }.value
            let tampered = try await Task.detached { try Data(contentsOf: file) }.value
            if let token {
                try UIVerification.require(await refuses { try await store.save(token.token, snapshot: sample(root, name: "Must Not Save")) }, "Replaced session inode was adopted")
                await store.end(token.token)
            } else {
                try UIVerification.require(await refuses { try await store.begin(first) }, "Unsafe or incompatible profile state resumed")
                if fault != "session" {
                    try UIVerification.require(await refuses { try await store.enable(second, initial: second.snapshot) }, "Unsafe catalog coordination was repaired by Enable")
                }
            }
            let final = try await Task.detached { try Data(contentsOf: file) }.value
            try UIVerification.require(final == tampered, "Refused state mutation replaced retained data")
            if ["writer", "mutation", "inventory"].contains(fault) {
                let missing = file.path + (fault == "writer" ? ".writer-lock" : fault == "mutation" ? ".mutation-lock" : ".session-inventory.lock")
                try UIVerification.require(!(await exists(URL(fileURLWithPath: missing))), "Missing coordination inode was silently repaired")
            }
        }
    }
    private static func profile(_ root: URL, id: UUID, name: String = "First") throws -> WorkspaceLaunchProfile {
        try .init(id: id, name: name, snapshot: sample(root, name: name))
    }
    private static func sample(_ root: URL, name: String = "First") -> PaneWorkspaceSnapshot {
        let pane = UUID(uuidString: "C41FF5A4-F61F-48FC-AD13-45536CA5CD0B")!
        let folder = root.appendingPathComponent("source/" + name)
        return .init(layout: .init(paneID: pane), activePane: pane,
            panes: [.init(id: pane, tabs: .init(tabs: [.init(location: .init(kind: .directory, url: folder),
                selection: [folder.appendingPathComponent("Generated.txt")], scrollOffset: 12)]), viewMode: DirectoryViewMode.details.rawValue)])
    }
    private static func refuses<T>(_ action: () async throws -> T) async -> Bool {
        do { _ = try await action(); return false } catch { return true }
    }
    nonisolated private static func waitForSignal(_ signal: DispatchSemaphore) -> Bool { signal.wait(timeout: .now() + 3) == .success }
    private static func exists(_ url: URL) async -> Bool { await Task.detached { FileManager().fileExists(atPath: url.path) }.value }
    private static func write(_ value: [String: Any], to url: URL) async throws {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        try await Task.detached { try data.write(to: url, options: .withoutOverwriting) }.value
    }
}
#endif
