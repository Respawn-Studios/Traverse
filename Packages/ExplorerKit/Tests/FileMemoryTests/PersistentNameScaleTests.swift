import Darwin
import Foundation
import Testing
@testable import FileMemory

private func diskMilliseconds(_ start: UInt64) -> Double { Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000 }

@Test(.enabled(if: ProcessInfo.processInfo.environment["MAC_EXPLORER_B07_DISK_SCALE"] == "1"))
func privateNamesDiskQualificationScale() async throws {
    for count in [10_000, 100_000] {
        let fixture = try NameStoreFixture(reservedBytes: (count == 100_000 ? 384 : 64) * 1_024 * 1_024, reservedEntries: 16)
        var timing: [String: Double] = [:]
        let start = DispatchTime.now().uptimeNanoseconds
        let initial = try await PersistentNameStore.create(directory: fixture.catalog, first: AuthoredNames(nickname: "Disk scale initial"))
        timing["firstDurableSave"] = diskMilliseconds(start)
        let seedStart = DispatchTime.now().uptimeNanoseconds
        try await initial.qualificationSeed(count - 1)
        timing["batchedStronglySyncedFixtureSeed"] = diskMilliseconds(seedStart)
        let stats = try await initial.qualificationStatistics()
        #expect(stats.records == count && stats.bytes < 512 * 1_024 * 1_024)
        await initial.close()
        let cold = DispatchTime.now().uptimeNanoseconds
        let read = try await PersistentNameStore.open(directory: fixture.catalog)
        timing["coldConnectionAndFullValidation"] = diskMilliseconds(cold)
        let requests: [(String, RememberedNameQuery)] = [
            ("exact", try RememberedNameQuery(text: "Project 000333", match: .exact)),
            ("multiword", try RememberedNameQuery(text: "Project 0003")),
            ("word", try RememberedNameQuery(text: "000333")),
            ("absent", try RememberedNameQuery(text: "absent-sentinel")),
            ("common", try RememberedNameQuery(text: "Project")),
            ("label", try RememberedNameQuery(text: "work", match: .exact, fields: [.label])),
        ]
        var queryMetrics: [[String: Any]] = []
        for (kind, request) in requests {
            let firstStart = DispatchTime.now().uptimeNanoseconds
            _ = try storedMatches(await read.query(request))
            let firstMilliseconds = diskMilliseconds(firstStart)
            #expect(firstMilliseconds <= 250)
            var samples: [Double] = []
            for _ in 0..<20 {
                let start = DispatchTime.now().uptimeNanoseconds
                let result = try await read.query(request)
                let matches = try storedMatches(result)
                samples.append(diskMilliseconds(start))
                #expect(matches.count <= 64)
                if kind == "exact" || kind == "word" { #expect(matches.count == 1) }
                if kind == "absent" { #expect(matches.isEmpty && result.coverage == .complete) }
                if kind == "common" { #expect(result.coverage == .candidateLimit) }
                #expect(result.visitedPostings <= 8_192)
            }
            samples.sort(); #expect(samples[18] <= 100)
            queryMetrics.append(["kind": kind, "firstMilliseconds": firstMilliseconds, "p95Milliseconds": samples[18], "samples": samples])
        }
        await read.close()
        let edit = try await PersistentNameStore.open(directory: fixture.catalog, action: .edit)
        let id = try await edit.firstItemID()
        var saves: [Double] = []
        for i in 0..<20 {
            let snapshot = try await edit.snapshot(id)
            let capture = try await edit.prepareEdit(snapshot, names: AuthoredNames(nickname: "Disk edit \(i)"))
            let start = DispatchTime.now().uptimeNanoseconds
            _ = try await edit.apply(capture); saves.append(diskMilliseconds(start))
        }
        let forgetStart = DispatchTime.now().uptimeNanoseconds
        #expect(try await edit.finishForget(edit.prepareForget(id)) == .forgotten)
        timing["selectedForget"] = diskMilliseconds(forgetStart)
        let allStart = DispatchTime.now().uptimeNanoseconds
        #expect(try await edit.finishForget(edit.prepareForget()) == .forgotten)
        timing["forgetAll"] = diskMilliseconds(allStart)
        #expect(try await edit.qualificationStatistics().records == 0)
        await edit.close()
        let verify = await PersistentNameStore.inspect(directory: fixture.catalog)
        #expect(verify.status == .ready && verify.records == 0)
        var usage = rusage(); #expect(getrusage(RUSAGE_SELF, &usage) == 0)
        #expect(usage.ru_maxrss < 256 * 1_024 * 1_024)
        let metrics: [String: Any] = ["records": count, "timingMilliseconds": timing, "queries": queryMetrics,
            "durableSaveMilliseconds": saves, "sqliteBytesBeforeForget": stats.bytes, "peakRSSBytes": usage.ru_maxrss,
            "sqliteVersion": stats.sqliteVersion, "coldDefinition": "Fresh connection and complete validation; OS filesystem cache not dropped",
            "seedDefinition": "Generated setup in 256-record fully synchronized transactions, not ordinary save throughput"]
        try JSONSerialization.data(withJSONObject: metrics, options: [.sortedKeys]).write(to: fixture.child("disk-metrics.json"), options: .withoutOverwriting)
        #expect(chmod(fixture.child("disk-metrics.json").path, 0o600) == 0)
    }
}
