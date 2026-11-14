#if DEBUG
import AppKit
import ExplorerCore
@_spi(Qualification) import LocalStorage

@MainActor enum SMBRuntimeVerification {
    static func run(root: URL, mode: String) async throws -> [String: Any] {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        try require([".build/b10-completion-qualification", ".build/b10-helper-identity"].contains(where: { root.deletingLastPathComponent() == repo.appendingPathComponent($0) })
            && root.resolvingSymlinksInPath() == root && UUID(uuidString: root.lastPathComponent)?.uuidString == root.lastPathComponent
            && ["offline-stop", "malformed", "crash"].contains(mode), "Unadmitted SMB runtime qualification")
        let fixture = Bundle.main.object(forInfoDictionaryKey: "MacExplorerSMBRuntimeFixture") as? String
        try require(mode == "offline-stop" ? fixture == nil : fixture == mode, "Runtime fixture/actual worker scope differs")
        let storage = try SMBTemporaryStorage(directory: root.appendingPathComponent("stores/runtime"), sessionByteLimit: 2 << 20)
        let pool = SMBTemporaryCatalogPool(storage: storage), activity = FileActivityGate(maximumActivities: 2)
        let address = try SMBConnectionAddress("smb://127.0.0.1:15445/ExplorerQA")
        let request = try SMBServerDraft(name: "Generated runtime", address: address, account: "nobody", domain: "", security: .encrypted)
        let password = try SMBPassword("generated-offline-only")
        let began = ProcessInfo.processInfo.systemUptime
        var ticks = 0
        let pulse = Task { while !Task.isCancelled { ticks += 1; try? await Task.sleep(for: .milliseconds(10)) } }
        defer { pulse.cancel() }
        let prepared = try await SMBPreparedConnection.prepare(address, bundleURL: Bundle.main.bundleURL, activity: activity)
        let connecting = Task { try await SMBBrowserSession.connectPrepared(bundleURL: Bundle.main.bundleURL, request: request,
            endpoint: prepared, storage: storage, activity: activity, password: password) }
        if mode == "offline-stop" {
            do {
                try await Task.detached {
                    let marker = root.appendingPathComponent("evidence/browser-ready.json")
                    let started = ProcessInfo.processInfo.systemUptime
                    while !FileManager().fileExists(atPath: marker.path) {
                        guard ProcessInfo.processInfo.systemUptime - started < 15 else { throw UIVerification.Failure(message: "Generated negotiation marker missing") }
                        try await Task.sleep(for: .milliseconds(20))
                    }
                }.value
                let live = try await pool.inspect()
                try require(live.count == 1 && live[0].active, "Runtime catalog lease missing while network is active")
            } catch {
                connecting.cancel(); if let late = try? await connecting.value { _ = await late.close() }; throw error
            }
            connecting.cancel()
        }
        var refused = false
        do { let unexpected = try await connecting.value; _ = await unexpected.close() }
        catch { refused = true }
        try require(refused && activity.activeCount == 0 && ticks > 0, "Runtime failure did not drain or blocked native updates")
        let retained = try await pool.inspect()
        if mode == "offline-stop" { try require(retained.isEmpty, "Clean cancelled worker left a runtime catalog") }
        else {
            try require(retained.count == 1 && !retained[0].active, "Uncertain worker storage was removed or still leased")
            try await pool.discardIncomplete(retained[0].id)
            let discarded = try await pool.inspect(); try require(discarded.isEmpty, "Explicit incomplete discard failed")
        }
        return ["passed": true, "mode": mode, "actualNetworkWorker": mode == "offline-stop", "networkAuthenticationQualified": false,
            "activityAfterDrain": activity.activeCount, "mainExecutorTicks": ticks,
            "temporaryStoreRemovedAfterCleanDrain": mode == "offline-stop", "uncertainStoreRequiredExplicitDiscard": mode != "offline-stop",
            "elapsedSeconds": ProcessInfo.processInfo.systemUptime - began, "keychainAccesses": 0, "personalCredentialQueries": 0]
    }
    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw UIVerification.Failure(message: message) }
    }
}
#endif
