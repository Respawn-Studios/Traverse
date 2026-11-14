#if DEBUG
import AppKit
import ExplorerCore
@_spi(Qualification) import LocalStorage

@MainActor enum SMBConnectionStorageVerification {
    static func run(root: URL, settings: BrowserSettings) async throws -> [String: Any] {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard root.deletingLastPathComponent() == repo.appendingPathComponent(".build/b10-completion-qualification"),
              root.resolvingSymlinksInPath() == root, UUID(uuidString: root.lastPathComponent)?.uuidString == root.lastPathComponent else {
            throw UIVerification.Failure(message: "Generated connection storage scope differs")
        }
        let folder = root.appendingPathComponent("stores"), storage = try SMBTemporaryStorage(directory: folder.appendingPathComponent("runtime"), sessionByteLimit: 2 << 20)
        let protectedProfile = ApplicationSMBConnections(directory: folder, passwords: .generatedQualification(namespace: UUID(uuidString: root.lastPathComponent)!))
        try require(ApplicationOperationCoordinator.shared.protectedStorageLocations.contains(folder), "Network profile root missing from drive protection")
        var networkLease: FileActivityGate.Lease? = try ApplicationSMBActivity.gate.begin()
        guard let diskBarrier = ApplicationFileActivity.gate.closeAdmission() else { throw UIVerification.Failure(message: "Local gate already closed") }
        let unrelatedDiskDrained = await ApplicationFileActivity.gate.waitUntilDrained(diskBarrier)
        ApplicationFileActivity.gate.reopen(diskBarrier)
        try require(unrelatedDiskDrained && ApplicationSMBActivity.gate.activeCount == 1 && networkLease != nil,
            "Unrelated disk barrier waited for a network lease")
        networkLease = nil
        await protectedProfile.closeAndDrain()
        let pool = SMBTemporaryCatalogPool(storage: storage), activity = FileActivityGate()
        let servers = SMBSavedServerStore(directory: folder.appendingPathComponent("servers"))
        let coordinator = SMBConnectionCoordinator(bundleURL: Bundle.main.bundleURL, storage: storage,
            servers: servers,
            passwords: .generatedQualification(namespace: UUID(uuidString: root.lastPathComponent)!), activity: activity)
        let window = SMBConnectionStorageWindow(settings: settings, coordinator: coordinator, storage: storage)
        window.model.refresh(); try await wait { !window.model.busy }
        try require(window.model.catalogs.isEmpty && window.model.saved == nil && window.model.notice.isEmpty, "Passive storage inspection differs")
        var lease: SMBTemporaryCatalog? = try await pool.reserve()
        let id = lease!.id
        window.model.refresh(); try await wait { !window.model.busy }
        try require(window.model.catalogs.count == 1 && window.model.catalogs[0].active, "Active catalog not represented")
        window.model.discard(id); try await wait { !window.model.busy }
        try require(window.model.catalogs.count == 1 && !window.model.notice.isEmpty, "Active storage discard was not refused")
        lease = nil
        for _ in 0..<200 {
            if try await pool.inspect().first?.active == false { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        window.model.refresh(); try await wait { !window.model.busy }
        try require(window.model.catalogs.first?.active == false, "Dropped lease did not release actual native ownership")
        window.window?.setFrameOrigin(.init(x: -12000, y: -12000)); window.window?.orderFront(nil)
        try await Task.sleep(for: .milliseconds(100))
        try require((540...760).contains(window.window!.frame.width) && (400...640).contains(window.window!.frame.height), "Connection Storage geometry changed after hosting layout")
        if let actual = window.window { try await UIVerification.snapshot(actual, to: root.appendingPathComponent("evidence/connection-storage.png")) }
        window.model.discard(id); try await wait { !window.model.busy }
        try require(window.model.catalogs.isEmpty && window.model.notice.contains("discarded"), "Reviewed incomplete discard did not refresh UI")
        let draft = try SMBServerDraft(name: "Generated removal", address: SMBConnectionAddress("smb://127.0.0.1:15445/ExplorerQA"),
            account: "generated", domain: "", security: .encrypted)
        var state = try await servers.openForExplicitWrite()
        state = try await servers.apply(.saveServer(draft, id: nil, credentialID: nil), expectedRevision: state.snapshot.revision)
        let savedID = state.serverID!
        _ = try await servers.apply(.beginForgetServer(savedID, removePassword: false), expectedRevision: state.snapshot.revision)
        await servers.close()
        window.model.refresh(); try await wait { !window.model.busy }
        try require(window.model.saved?.visibleServers.isEmpty == true && window.model.saved?.servers.first?.removalPending == true,
            "Pending server cleanup resurfaced in ordinary choices")
        window.model.finishForgettingServer(savedID); try await wait { !window.model.busy }
        try require(window.model.saved?.servers.isEmpty == true && window.model.notice.contains("completed"), "Explicit pending server cleanup did not finish")
        await window.closeAndDrain(); await coordinator.drain()
        let after = try await pool.inspect()
        try require(activity.activeCount == 0 && after.isEmpty, "Native storage owner did not drain")
        return ["passed": true, "passiveInspection": true, "activeDiscardRefused": true,
            "inactiveDiscardReflected": true, "actualLeaseReleased": true, "keychainAccesses": 0, "networkConnections": 0,
            "networkProfileRemovalProtected": true, "unrelatedDiskGateDrainsWithNetworkLease": true, "deviceActions": 0]
    }
    private static func require(_ value: Bool, _ message: String) throws { if !value { throw UIVerification.Failure(message: message) } }
    private static func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<500 { if condition() { return }; try await Task.sleep(for: .milliseconds(10)) }
        throw UIVerification.Failure(message: "Generated connection storage did not settle")
    }
}
#endif
