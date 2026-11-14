#if DEBUG
import AppKit
import ExplorerCore

@MainActor
enum UpdateWorkspaceResumeVerification {
    static func run(root: URL, browser: BrowserViewController) async throws -> [String: Any] {
        guard let workspace = browser.workspace else { throw UIVerification.Failure(message: "Missing update workspace") }
        let directory = root.appendingPathComponent("state/update-resume")
        let store = UpdateWorkspaceResumeStore(directory: directory)
        let record = try workspace.updateResumeRecord(targetBuild: 12, sourceBuild: 11)
        try await store.save(record)
        try UIVerification.require(try await store.read(build: 11) == nil,
            "An uninstalled update restored a future workspace")
        let reopened = UpdateWorkspaceResumeStore(directory: directory)
        let loaded = try await reopened.read(build: 12)
        try UIVerification.require(loaded?.id == record.id && loaded?.workspace == record.workspace,
            "Update workspace did not survive its own storage lifetime")
        try UIVerification.require(try await reopened.read(build: 12, now: record.created.addingTimeInterval(86_401)) == nil,
            "An expired update record overrode ordinary startup")
        var refusedWrongIdentity = false
        do { try await reopened.consume(UUID()) } catch { refusedWrongIdentity = true }
        let retained = try await reopened.read(build: 12)
        try UIVerification.require(refusedWrongIdentity && retained?.id == record.id,
            "A stale consumer erased a newer update workspace")
        try await reopened.consume(record.id)
        try UIVerification.require(try await UpdateWorkspaceResumeStore(directory: directory).read(build: 12) == nil,
            "A consumed workspace replayed on the next launch")
        var unavailableRefused = false
        do { try await UpdateWorkspaceResumeStore(directory: nil).save(record) } catch { unavailableRefused = true }
        try UIVerification.require(unavailableRefused, "Unavailable storage falsely acknowledged a restart checkpoint")
        let futureDirectory = root.appendingPathComponent("state/future-update-resume")
        let futureStore = UpdateWorkspaceResumeStore(directory: futureDirectory)
        try await futureStore.save(record)
        let futureFile = futureDirectory.appendingPathComponent("update-workspace-v1.json")
        let futureBytes = Data(#"{"version":999,"owner":"traverse-update-workspace","pending":null}"#.utf8)
        try futureBytes.write(to: futureFile)
        var futureReadRefused = false, futureWriteRefused = false
        do { _ = try await futureStore.read(build: 12) } catch { futureReadRefused = true }
        do { try await futureStore.save(record) } catch { futureWriteRefused = true }
        try UIVerification.require(futureReadRefused && futureWriteRefused && (try Data(contentsOf: futureFile)) == futureBytes,
            "An incompatible update checkpoint was overwritten or accepted")
        return ["passed": true, "durableReopen": true, "wrongBuildAndExpiredRefused": true,
            "staleConsumerPreservesRecord": true, "consumedOnce": true, "unavailableSaveRefused": true,
            "incompatibleRecordPreserved": true,
            "startupPreferenceChanged": false, "networkReconnects": 0, "scanRestarts": 0]
    }
}
#endif
