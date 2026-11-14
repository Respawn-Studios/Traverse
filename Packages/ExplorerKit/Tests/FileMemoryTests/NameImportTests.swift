import Foundation
import Testing
@testable import FileMemory

@Suite(.serialized, .enabled(if: MoveFixture.enabled)) struct NameImportTests {
    @Test func newCatalogIsOneBatchWithNoImportedAccess() async throws {
        let f = try MoveFixture(), ids = [UUID(), UUID()]
        let file = try writeImport(f, rows: [row(ids[0], "Orion", path: "/Generated/Example/not-an-access-request"), row(ids[1], "Orion")], locations: true)
        let session = NameImportSession(target: .newCatalog(directory: f.catalog))
        let preview = try await session.preview(selectedFile: file)
        #expect(preview.recordCount == 2 && preview.repeatedDescriptions == 1 && preview.discardedLocations == 1)
        #expect(!FileManager().fileExists(atPath: f.catalog.path))
        guard case .imported(let attempt) = await session.apply(preview) else { Issue.record("Whole new import did not succeed"); return }
        let store = try #require(await session.takeCreatedStore())
        #expect(try await store.management().savedItems == 2)
        #expect(try await store.management().storedReferences == 0)
        #expect(try await store.resolveImport(attempt) == .allPresent(records: 2))
        let matches = try storedMatches(await store.library())
        #expect(matches.count == 2 && !matches.contains { ids.contains($0.item.id.rawValue) })
        for item in matches {
            var state: RememberedReferenceAvailability?
            let reference = try await store.resolveReference(item.item.id)
            #expect(reference.publish { state = $0.availability } && state == .needsRelink)
            await #expect(throws: (any Error).self) { _ = try await store.withVerifiedReference(item.item.id) { _ in true } }
        }
        #expect(await session.apply(preview) == .notImported(.stalePreview))
        await session.close(); await store.close()
        let reopened = try await PersistentNameStore.open(directory: f.catalog)
        #expect(try await reopened.resolveImport(attempt) == .allPresent(records: 2))
        await reopened.close(); try f.receipt(["wholeInitialBatch": true, "freshIDsNoGrants": true, "positiveNoncePresence": true])
    }

    @Test func existingDescriptionsWarnButAreNeverMergedOrReplaced() async throws {
        let f = try MoveFixture(), store = try await PersistentNameStore.create(directory: f.catalog, first: AuthoredNames(nickname: "Orion"))
        let id = try await store.firstItemID(), file = try writeImport(f, rows: [row(id.rawValue, "Orion"), row(UUID(), "Different")])
        let session = NameImportSession(target: .existing(store)), preview = try await session.preview(selectedFile: file)
        #expect(preview.matchingDescriptions == 1 && preview.matchingSourceIDs == 1)
        guard case .imported(let attempt) = await session.apply(preview) else { Issue.record("Existing import failed"); return }
        #expect(try await store.management().savedItems == 3)
        #expect(try storedSnapshot(await store.snapshot(id)).names.nickname == "Orion")
        #expect(try await store.resolveImport(attempt) == .allPresent(records: 2))
        #expect(try await store.finishForget(store.prepareForget(id)) == .forgotten)
        #expect(try await store.management().savedItems == 2)
        // Identical imported text is an explicitly separate description.
        #expect(try await store.resolveImport(attempt) == .allPresent(records: 2))
        let imported = try #require(try storedMatches(await store.library()).first)
        #expect(try await store.finishForget(store.prepareForget(imported.item.id)) == .forgotten)
        #expect(try await store.resolveImport(attempt) == .unknown)
        await session.close(); await store.close(); try f.receipt(["duplicatesAreWarnings": true, "separateForget": true])
    }

    @Test func cancelAndChangedCatalogInvalidateWithoutLateRows() async throws {
        let f = try MoveFixture(), file = try writeImport(f, rows: [row(UUID(), "Incoming")])
        let initial = NameImportSession(target: .newCatalog(directory: f.catalog))
        let preview = try await initial.preview(selectedFile: file); initial.cancel()
        #expect(await initial.apply(preview) == .notImported(.stalePreview))
        await initial.close(); #expect(!FileManager().fileExists(atPath: f.catalog.path))
        let store = try await PersistentNameStore.create(directory: f.catalog, first: AuthoredNames(nickname: "Existing"))
        let session = NameImportSession(target: .existing(store)), pending = try await session.preview(selectedFile: file)
        let id = try await store.firstItemID(), snapshot = try await store.snapshot(id)
        _ = try await store.apply(store.prepareEdit(snapshot, names: AuthoredNames(nickname: "Edited")))
        #expect(await session.apply(pending) == .notImported(.stalePreview))
        #expect(try await store.management().savedItems == 1)
        await session.close(); await store.close(); try f.receipt(["cancelAndStalePreview": true])
    }

    @Test(arguments: [NameImportBoundary.rows, .beforeCommit]) func failingBeforeCommitKeepsNoPrefix(boundary: NameImportBoundary) async throws {
        let f = try MoveFixture(), store = try await PersistentNameStore.create(directory: f.catalog, first: AuthoredNames(nickname: "Existing"))
        let file = try writeImport(f, rows: [row(UUID(), "First"), row(UUID(), "Last")])
        let session = NameImportSession(target: .existing(store)), preview = try await session.preview(selectedFile: file)
        #expect(await session.apply(preview, probe: { if $0 == boundary { throw NameImportFailure.quota } }) == .notImported(.quota))
        #expect(try await store.management().savedItems == 1)
        await session.close(); await store.close(); try f.receipt(["atomicRollback": true])
    }

    @Test(arguments: [NameImportBoundary.rows, .commitAdmitted]) func forgetOrdersWithActualImportCommit(boundary: NameImportBoundary) async throws {
        let f = try MoveFixture(), store = try await PersistentNameStore.create(directory: f.catalog, first: AuthoredNames(nickname: "Existing"))
        let file = try writeImport(f, rows: [row(UUID(), "Incoming")]), session = NameImportSession(target: .existing(store))
        let preview = try await session.preview(selectedFile: file), pause = ExportPause()
        let importing = Task { await session.apply(preview, probe: { if $0 == boundary { try pause.stop() } }) }
        try await pause.arrived()
        if boundary == .commitAdmitted { #expect(throws: NameStoreFailure.busy) { _ = try store.prepareForget() } }
        let forget = Task { let request = try await store.prepareForgetAfterExports(); return try await store.finishForget(request) }
        for _ in 0..<100 where !store.publication.hasPending { await Task.yield() }
        #expect(store.publication.hasPending); pause.resume()
        let result = await importing.value
        if boundary == .rows { #expect(result == .notImported(.stalePreview)) }
        else { guard case .committedButHidden = result else { Issue.record("Admitted import did not remain hidden"); return } }
        #expect(try await forget.value == .forgotten)
        #expect(try await store.management().savedItems == 0)
        await session.close(); await store.close(); try f.receipt(["importForgetCommitOrdering": true])
    }

    @Test(arguments: [NameImportBoundary.readOpened, .readComplete]) func changedInputAndCancelDrain(boundary: NameImportBoundary) async throws {
        let f = try MoveFixture(), file = try writeImport(f, rows: [row(UUID(), "Incoming")])
        let session = NameImportSession(target: .newCatalog(directory: f.catalog))
        await #expect(throws: (any Error).self) {
            _ = try await session.preview(selectedFile: file, probe: {
                if $0 == boundary { try FileManager().moveItem(at: file, to: f.source.appendingPathComponent("retained.json")); try Data("{}".utf8).write(to: file, options: .withoutOverwriting) }
            })
        }
        await session.close(); #expect(!FileManager().fileExists(atPath: f.catalog.path))
        try f.receipt(["changedInputRefused": true])
    }

    @Test func oneReaderAndCloseDrainRetainedPreview() async throws {
        let f = try MoveFixture(), file = try writeImport(f, rows: [row(UUID(), "Incoming")])
        let store = try await PersistentNameStore.create(directory: f.catalog, first: AuthoredNames(nickname: "Existing"))
        let first = NameImportSession(target: .existing(store)), second = NameImportSession(target: .existing(store)), pause = ExportPause()
        let reading = Task { try await first.preview(selectedFile: file, probe: { if $0 == .readOpened { try pause.stop() } }) }
        try await pause.arrived()
        await #expect(throws: NameStoreFailure.busy) { _ = try await second.preview(selectedFile: file) }
        first.cancel(); pause.resume()
        _ = try? await reading.value
        await first.close(); await second.close()
        #expect(store.publication.qualificationPayloadCount == 0)
        let third = NameImportSession(target: .existing(store)), preview = try await third.preview(selectedFile: file)
        #expect(preview.recordCount == 1)
        await third.close()
        #expect(store.publication.qualificationPayloadCount == 0)
        #expect(try await store.finishForget(store.prepareForget()) == .forgotten)
        await store.close(); try f.receipt(["oneReaderActualDrain": true, "closedPreviewReleased": true])
    }

    @Test func actualSQLiteFullKeepsTheWholeOldCatalog() async throws {
        let f = try MoveFixture(), store = try await PersistentNameStore.create(directory: f.catalog, first: AuthoredNames(nickname: "Keep existing"))
        let file = try writeImport(f, rows: (0..<200).map { row(UUID(), "Row \($0) " + String(repeating: "x", count: 450)) })
        let session = NameImportSession(target: .existing(store)), preview = try await session.preview(selectedFile: file)
        try await store.qualificationPageLimit()
        let outcome = await session.apply(preview)
        if case .imported = outcome { Issue.record("Page-limited import unexpectedly succeeded") }
        if case .committedButHidden = outcome { Issue.record("Page-limited import unexpectedly committed") }
        await session.close(); await store.close()
        let reopened = try await PersistentNameStore.open(directory: f.catalog, action: .recover)
        #expect(try await reopened.management().savedItems == 1)
        #expect(try storedMatches(await reopened.library()).first?.item.names.nickname == "Keep existing")
        await reopened.close(); try f.receipt(["nativeSQLiteFullNoPartialBatch": true])
    }
}

func row(_ id: UUID, _ nickname: String, path: String? = nil) -> [String: Any] {
    var value: [String: Any] = ["id": id.uuidString, "nickname": nickname, "alternateNames": [], "labels": []]
    if let path { value["lastKnownLocation"] = path }; return value
}
func writeImport(_ f: MoveFixture, rows: [[String: Any]], locations: Bool = false) throws -> URL {
    let url = f.source.appendingPathComponent("saved-names.json")
    let data = try JSONSerialization.data(withJSONObject: ["format": "MacExplorer.PrivateNames", "version": 1,
        "includesLocations": locations, "records": rows], options: [.sortedKeys, .withoutEscapingSlashes])
    try data.write(to: url, options: .withoutOverwriting); return url
}

@Suite(.serialized) struct PortableNameInputTests {
    @Test func strictKeysTypesAndPartialDocuments() throws {
        let id = UUID().uuidString
        let valid = "{\"format\":\"MacExplorer.PrivateNames\",\"version\":1,\"includesLocations\":false,\"records\":[{\"id\":\"\(id)\",\"nickname\":\"Orion 🪐\",\"alternateNames\":[],\"labels\":[]}]}"
        #expect(try PortableNameInput.decode(Data(valid.utf8)).names.first?.nickname == "Orion 🪐")
        for invalid in [String(valid.dropLast()), valid + "{}", valid.replacingOccurrences(of: "\"version\":1", with: "\"version\":1,\"version\":1"),
            valid.replacingOccurrences(of: "\"version\":1", with: "\"version\":true"), valid.replacingOccurrences(of: "\"version\":1", with: "\"version\":1.0"),
            valid.replacingOccurrences(of: "\"labels\":[]", with: "\"labels\":[],\"bookmarks\":[]"),
            valid.replacingOccurrences(of: "\"labels\":[]", with: "\"labels\":[\"x\",\"x\"]"),
            valid.replacingOccurrences(of: "\"nickname\":", with: "\"nick\\u006eame\":"),
            valid.replacingOccurrences(of: "\"labels\":[]", with: "\"labels\":[],\"lastKnownLocation\":\"/not-read\"")] {
            #expect(throws: (any Error).self) { _ = try PortableNameInput.decode(Data(invalid.utf8)) }
        }
    }
}
