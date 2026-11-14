import Darwin
import Foundation
import Testing
@testable import FileMemory

@Test func b075ExportProcessWorker() async throws {
    let env = ProcessInfo.processInfo.environment
    guard MoveFixture.enabled, MoveFixture.extended, let path = env["MAC_EXPLORER_B074_ROOT"],
          let scenario = env["MAC_EXPLORER_B074_SCENARIO"], let phase = env["MAC_EXPLORER_B074_PHASE"] else { return }
    let f = try MoveFixture(existingRoot: URL(fileURLWithPath: path)), target = f.destination.appendingPathComponent("saved-names.json")
    @Sendable func receipt(_ values: [String: String]) throws {
        var values = values; values["scenario"] = scenario; values["phase"] = phase
        let url = f.root.appendingPathComponent(phase + ".json")
        try JSONSerialization.data(withJSONObject: values, options: .sortedKeys).write(to: url, options: .withoutOverwriting)
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC); guard fd >= 0 else { throw NameStoreFailure.unsafe }
        defer { close(fd) }; guard fsync(fd) == 0 else { throw NameStoreFailure.unsafe }
    }
    if phase == "seed" {
        let store = try await PersistentNameStore.create(directory: f.catalog,
            first: AuthoredNames(nickname: "Generated private export", alternateNames: ["inert saved text"], labels: ["private"]))
        await store.close(); try receipt(["seeded": "true"]); return
    }
    if phase == "crash" {
        let store = try await PersistentNameStore.open(directory: f.catalog, action: .edit,
            probe: { if $0.rawValue == scenario { try receipt(["boundary": scenario]); Darwin._exit(86) } }, vfs: nil)
        let preview = try await store.prepareExport()
        if scenario.hasPrefix("export") {
            let boundary = String(scenario.dropFirst(6))
            _ = await store.export(preview, to: target, probe: { if $0.rawValue == boundary { try receipt(["boundary": scenario]); Darwin._exit(86) } })
        } else {
            _ = try await store.finishForget(store.prepareForget())
        }
        Issue.record("Export/Forget crash boundary was not reached"); return
    }
    if phase == "fault" {
        let store = try await PersistentNameStore.open(directory: f.catalog, action: .edit)
        let preview = try await store.prepareExport()
        signal(SIGXFSZ, SIG_IGN)
        var original = rlimit(); guard getrlimit(RLIMIT_FSIZE, &original) == 0 else { throw NameStoreFailure.unsafe }
        var bounded = rlimit(rlim_cur: 64, rlim_max: original.rlim_max)
        guard setrlimit(RLIMIT_FSIZE, &bounded) == 0 else { throw NameStoreFailure.unsafe }
        let outcome = await store.export(preview, to: target)
        guard setrlimit(RLIMIT_FSIZE, &original) == 0 else { throw NameStoreFailure.unsafe }
        #expect(outcome == .createdButIncomplete(.writeFailed))
        #expect(try Data(contentsOf: target).count == 64)
        await store.close(); try receipt(["realShortWriteAndEFBIG": "true"]); return
    }
    if phase == "inspect" {
        let status = await PersistentNameStore.inspect(directory: f.catalog).status
        #expect([.ready, .forgetPending, .recoveryRequired].contains(status))
        try receipt(["status": String(describing: status), "fileExists": String(FileManager().fileExists(atPath: target.path))]); return
    }
    if phase == "recover" || phase == "cold" {
        let store = try await PersistentNameStore.open(directory: f.catalog, action: phase == "recover" ? .recover : .readOnly)
        if phase == "recover", try await store.pendingMaintenance().forget { _ = try await store.finishPendingForget() }
        let metadata = try await store.management()
        let exists = FileManager().fileExists(atPath: target.path)
        let expected = ["exportcreated", "exportwriting", "exportwritten", "exportsynchronized", "realWriteLimit"].contains(scenario)
        #expect(exists == expected)
        let revoked = ["revocationCommit", "purgeRows", "purgeCommit", "acknowledged"].contains(scenario) || (phase == "cold" && expected)
        #expect(metadata.savedItems == (revoked ? 0 : 1))
        if exists {
            // A created external export stays outside subsequent Forget.
            let before = try Data(contentsOf: target)
            if phase == "recover" { _ = try await store.finishForget(store.prepareForget()) }
            #expect(try Data(contentsOf: target) == before)
        }
        await store.close(); try receipt(["noExportResumed": "true", "createdCopyPreserved": String(exists)]); return
    }
}
