import Darwin
import Foundation
import NameStoreFaultSupport
import SQLite3
import Testing
@testable import FileMemory

/// Invoked by tools/verify_private_names_process.py in fresh, generated-only
/// child processes. Ordinary tests do not crash or register the fault VFS.
@Test func privateNamesProcessQualificationWorker() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard let path = environment["MAC_EXPLORER_B07_PROCESS_ROOT"],
          let phase = environment["MAC_EXPLORER_B07_PROCESS_PHASE"],
          let scenario = environment["MAC_EXPLORER_B07_PROCESS_SCENARIO"] else { return }
    let fixture = try NameStoreFixture(existingRoot: URL(fileURLWithPath: path))
    let initials: Set<String> = ["initRows", "initCommit", "ready"]
    let forgets: Set<String> = ["revocationCommit", "purgeRows", "purgeCommit", "acknowledged", "faultForgetPurge"]
    let boundary: [String: NameStoreBoundary] = [
        "initRows": .saveRows, "initCommit": .firstCommit, "ready": .ready,
        "saveRows": .saveRows, "saveCommit": .saveCommit,
        "revocationRows": .revocationRows, "revocationCommit": .revocationCommit,
        "purgeRows": .purgeRows, "purgeCommit": .purgeCommit, "acknowledged": .acknowledged,
    ]
    @Sendable func receipt(_ values: [String: String]) throws {
        var fields = values; fields["phase"] = phase; fields["pid"] = String(getpid()); fields["scenario"] = scenario
        let data = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
        let url = fixture.child(phase + ".json")
        try data.write(to: url, options: .withoutOverwriting); #expect(chmod(url.path, 0o600) == 0)
        let fd = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw NameStoreFailure.unavailable }
        defer { Darwin.close(fd) }; guard fsync(fd) == 0 else { throw NameStoreFailure.unavailable }
    }
    @Sendable func crash(_ observed: NameStoreBoundary) throws {
        guard observed == boundary[scenario] else { return }
        let journal = fixture.catalog.appendingPathComponent("names.sqlite-journal")
        let header = (try? Data(contentsOf: journal).prefix(8)) ?? Data().prefix(8)
        let hot = Array(header) == [0xd9,0xd5,0x05,0xf9,0x20,0xa1,0x63,0xd7]
        try receipt(["boundary": observed.rawValue, "terminationCode": "86", "realHotHeader": String(hot)])
        Darwin._exit(86)
    }
    if phase == "seed" {
        if !initials.contains(scenario) {
            let store = try await PersistentNameStore.create(directory: fixture.catalog, first: AuthoredNames(nickname: "Before"))
            if scenario == "purgeCommit" { try await store.qualificationSeed(600) }
            await store.close()
        }
        try receipt(["seeded": "true"]); return
    }
    if phase == "hold" {
        let store = try await PersistentNameStore.open(directory: fixture.catalog, action: .edit)
        try receipt(["holdingLock": "true"])
        let deadline = DispatchTime.now().uptimeNanoseconds + 20_000_000_000
        while !FileManager().fileExists(atPath: fixture.child("release").path) {
            guard DispatchTime.now().uptimeNanoseconds < deadline else { throw NameStoreFailure.busy }
            try await Task.sleep(for: .milliseconds(50))
        }
        await store.close(); return
    }
    if phase == "inspectBusy" {
        let before = try fixture.image()
        #expect(await PersistentNameStore.inspect(directory: fixture.catalog).status == .busy)
        await #expect(throws: NameStoreFailure.busy) { try await PersistentNameStore.open(directory: fixture.catalog, action: .edit) }
        #expect(try fixture.image() == before)
        try receipt(["busy": "true", "unchanged": "true"]); return
    }
    if phase == "crash" {
        if initials.contains(scenario) {
            _ = try await PersistentNameStore.create(directory: fixture.catalog, first: AuthoredNames(nickname: "Before"), probe: { try crash($0) }, vfs: nil)
        } else {
            let store = try await PersistentNameStore.open(directory: fixture.catalog, action: .edit, probe: { try crash($0) }, vfs: nil)
            try await store.qualificationCachePages(1)
            let id = try await store.firstItemID()
            if scenario == "saveRows" || scenario == "saveCommit" {
                let snapshot = try await store.snapshot(id)
                let edit = try await store.prepareEdit(snapshot, names: AuthoredNames(nickname: "After",
                    alternateNames: (0..<16).map { "Generated alias \($0) " + String(repeating: "x", count: 450) }))
                _ = try await store.apply(edit)
            } else {
                let request = try store.prepareForget(scenario == "purgeCommit" ? nil : id)
                _ = try await store.finishForget(request)
            }
        }
        Issue.record("The specified self-crash boundary was not reached"); return
    }
    if phase == "inspect1" || phase == "inspect2" || phase == "faultInspect" {
        let before = try fixture.image()
        let status = await PersistentNameStore.inspect(directory: fixture.catalog)
        #expect(try fixture.image() == before)
        if scenario == "initRows" || scenario == "initCommit" { #expect(status.status == .initializationIncomplete) }
        else if scenario == "saveRows" { #expect(status.status == .recoveryRequired) }
        else if scenario == "revocationCommit" || scenario == "purgeCommit" { #expect(status.status == .forgetPending) }
        else if scenario == "purgeRows" || scenario == "revocationRows" {
            #expect([NameStoreStatus.ready, .forgetPending, .recoveryRequired].contains(status.status))
        } else if !scenario.hasPrefix("fault") { #expect(status.status == .ready) }
        try receipt(["status": String(describing: status.status), "unchanged": "true"]); return
    }
    if phase == "recover" || phase == "cold" {
        if scenario == "initRows" {
            let before = try fixture.image()
            await #expect(throws: (any Error).self) { try await PersistentNameStore.open(directory: fixture.catalog, action: .recover) }
            #expect(try fixture.image() == before)
            try receipt(["preservedIncomplete": "true", "unchanged": "true"]); return
        }
        let before = try fixture.image()
        let store = try await PersistentNameStore.open(directory: fixture.catalog, action: phase == "recover" ? .recover : .readOnly)
        if phase == "recover", forgets.contains(scenario) { #expect(try await store.finishPendingForget() == .forgotten) }
        let records = try await store.qualificationStatistics().records
        if forgets.contains(scenario) { #expect(records == 0) }
        else {
            #expect(records == 1)
            let snapshot = try await store.snapshot(store.firstItemID())
            let name = try storedSnapshot(snapshot).names.nickname
            if scenario.hasPrefix("fault") { #expect(name == "Before" || name == "After") }
            else { #expect(name == (scenario == "saveCommit" ? "After" : "Before")) }
        }
        await store.close()
        if phase == "cold" { #expect(try fixture.image() == before) }
        try receipt(["records": String(records), "unchanged": String(phase == "cold"), "validated": "true"]); return
    }
    if phase == "fault" {
        #expect(menames_fault_register(fixture.root.path) == SQLITE_OK)
        let op = try #require(Int(environment["MAC_EXPLORER_B07_FAULT_OP"] ?? ""))
        let role = try #require(Int(environment["MAC_EXPLORER_B07_FAULT_ROLE"] ?? ""))
        let store = try await PersistentNameStore.open(directory: fixture.catalog, action: .edit, probe: {
            if scenario == "faultForgetPurge", $0 == .revocationCommit { menames_fault_arm(2, 1, 2) }
        }, vfs: "menames-generated-faults")
        try await store.qualificationCachePages(1)
        if scenario == "faultForgetFence" || scenario == "faultForgetPurge" {
            let id = try await store.firstItemID()
            if scenario == "faultForgetFence" { menames_fault_arm(2, 1, 2) }
            let outcome = try await store.finishForget(store.prepareForget(id))
            #expect(menames_fault_hits() == 1)
            #expect(outcome == (scenario == "faultForgetFence" ? .sessionHiddenOnly : .hiddenPending))
            await store.close()
            try receipt(["hits": String(menames_fault_hits()), "calls": String(menames_fault_seen()), "outcome": String(describing: outcome)]); return
        }
        if scenario == "faultFull" { try await store.qualificationPageLimit() }
        let snapshot = try await store.snapshot(store.firstItemID())
        let edit = try await store.prepareEdit(snapshot, names: AuthoredNames(nickname: "After",
            alternateNames: (0..<16).map { "Generated \($0) " + String(repeating: "y", count: 450) }))
        menames_fault_arm(Int32(op), 1, Int32(role))
        var outcome = "saved"
        do { _ = try await store.apply(edit) } catch { outcome = "error" }
        let hits = menames_fault_hits(), calls = menames_fault_seen()
        if scenario == "faultFull" { #expect(outcome == "error") }
        else { #expect(hits == 1 && calls >= 1 && outcome == "error") }
        await store.close()
        try receipt(["hits": String(hits), "calls": String(calls), "outcome": outcome]); return
    }
    if phase == "faultTruncate" {
        #expect(menames_fault_register(fixture.root.path) == SQLITE_OK)
        menames_fault_arm(3, 1, 1)
        await #expect(throws: (any Error).self) {
            try await PersistentNameStore.open(directory: fixture.catalog, action: .recover, probe: nil, vfs: "menames-generated-faults")
        }
        #expect(menames_fault_hits() == 1)
        try receipt(["hits": String(menames_fault_hits()), "calls": String(menames_fault_seen()), "outcome": "error"]); return
    }
    Issue.record("Unknown process qualification phase")
}
