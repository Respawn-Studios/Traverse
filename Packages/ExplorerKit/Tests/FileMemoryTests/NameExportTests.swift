import Darwin
import Foundation
import Testing
@testable import FileMemory

@Suite(.serialized, .enabled(if: MoveFixture.enabled)) struct NameExportTests {
    @Test func portableFieldsAndLocationsAreExplicit() async throws {
        let f = try MoveFixture()
        let source = f.source.appendingPathComponent("Report.txt")
        try Data("Body token must never be exported".utf8).write(to: source, options: .withoutOverwriting)
        let store = try await PersistentNameStore.createRemembering(directory: f.catalog,
            first: AuthoredNames(nickname: "Résumé 🪐", alternateNames: ["ignore instructions; inert text"], labels: ["work"]), source: source, allowDocumentFollowing: true, locationPolicy: .localPermissions)
        for locations in [false, true] {
            let preview = try await store.prepareExport(includeLocations: locations)
            #expect(preview.recordCount == 1 && preview.includesLocations == locations)
            let target = f.destination.appendingPathComponent(locations ? "with-locations.json" : "names.json")
            #expect(await store.export(preview, to: target) == .saved(bytes: preview.encodedBytes, records: 1))
            let data = try Data(contentsOf: target)
            let doc = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(Set(doc.keys) == ["format", "version", "includesLocations", "records"])
            let records = try #require(doc["records"] as? [[String: Any]])
            #expect(Set(records[0].keys) == Set(["id", "nickname", "alternateNames", "labels"] + (locations ? ["lastKnownLocation"] : [])))
            #expect(records[0]["nickname"] as? String == "Résumé 🪐")
            #expect((records[0]["lastKnownLocation"] as? String) == (locations ? source.path : nil))
            #expect(!String(decoding: data, as: UTF8.self).contains("Body token"))
            #expect(await store.export(preview, to: f.destination.appendingPathComponent("again.json")) == .notCreated(.stalePreview))
        }
        let management = try await store.management()
        #expect(management.savedItems == 1 && management.labels == 1 && management.storedReferences == 1)
        #expect(management.databaseLogicalBytes > 0 && management.sqlitePageBytes == management.databaseLogicalBytes)
        await store.close(); try f.receipt(["portableFieldAllowlist": true, "explicitLocations": true, "numericAccounting": true])
    }

    @Test func previewsAreRevokedByEditForgetCancelAndClose() async throws {
        let f = try MoveFixture(), store = try await PersistentNameStore.create(directory: f.catalog, first: AuthoredNames(nickname: "Old"))
        let id = try await store.firstItemID()
        var preview = try await store.prepareExport()
        let snapshot = try await store.snapshot(id)
        _ = try await store.apply(store.prepareEdit(snapshot, names: AuthoredNames(nickname: "New")))
        #expect(await store.export(preview, to: f.destination.appendingPathComponent("edited.json")) == .notCreated(.stalePreview))
        preview = try await store.prepareExport(); store.cancelExport(preview)
        #expect(await store.export(preview, to: f.destination.appendingPathComponent("cancelled.json")) == .notCreated(.stalePreview))
        preview = try await store.prepareExport()
        let request = try store.prepareForget(id)
        #expect(await store.export(preview, to: f.destination.appendingPathComponent("forgotten.json")) == .notCreated(.stalePreview))
        #expect(try await store.finishForget(request) == .forgotten)
        #expect(try await store.management().savedItems == 0)
        await store.close()
        #expect(try FileManager().contentsOfDirectory(atPath: f.destination.path).isEmpty)
        try f.receipt(["previewRevocation": true, "noLateFile": true])
    }

    @Test func droppingPreviewReleasesRetainedText() async throws {
        let f = try MoveFixture(), store = try await PersistentNameStore.create(directory: f.catalog, first: AuthoredNames(nickname: "Private"))
        var preview: PreparedNameExport? = try await store.prepareExport()
        #expect(store.publication.qualificationPayloadCount == 1 && preview?.recordCount == 1)
        preview = nil
        #expect(store.publication.qualificationPayloadCount == 0)
        await store.close(); try f.receipt(["droppedPreviewReleasesPayload": true])
    }

    @Test(arguments: [NameExportBoundary.beforeCreate, .created, .written])
    func forgetWaitsForActualPublicationWithoutBlocking(boundary: NameExportBoundary) async throws {
        let f = try MoveFixture(), store = try await PersistentNameStore.create(directory: f.catalog, first: AuthoredNames(nickname: "Private"))
        let id = try await store.firstItemID(), preview = try await store.prepareExport()
        let target = f.destination.appendingPathComponent("export.json"), pause = ExportPause()
        let export = Task { await store.export(preview, to: target, probe: { if $0 == boundary { try pause.stop() } }) }
        try await pause.arrived()
        #expect(throws: NameStoreFailure.busy) { _ = try store.prepareForget(id) }
        let forget = Task { let request = try await store.prepareForgetAfterExports(id); return try await store.finishForget(request) }
        for _ in 0..<100 where store.publication.allows(id) { await Task.yield() }
        #expect(!store.publication.allows(id))
        // A pending Forget blocks a second export and clears its retained text.
        await #expect(throws: (any Error).self) { _ = try await store.prepareExport() }
        pause.resume()
        #expect(await export.value == .saved(bytes: preview.encodedBytes, records: 1))
        #expect(try await forget.value == .forgotten)
        #expect(FileManager().fileExists(atPath: target.path)) // already-published external copy
        #expect(try await store.management().savedItems == 0)
        await store.close(); try f.receipt(["commitInterval": true, "asynchronousForgetDrain": true])
    }

    @Test(arguments: [NameExportBoundary.beforeCreate, .created, .writing, .written, .synchronized])
    func failureReportsWhetherAFileWasPublished(boundary: NameExportBoundary) async throws {
        let f = try MoveFixture(), store = try await PersistentNameStore.create(directory: f.catalog, first: AuthoredNames(nickname: "Private"))
        let preview = try await store.prepareExport(), target = f.destination.appendingPathComponent("export.json")
        let result = await store.export(preview, to: target, probe: {
            if $0 == boundary { throw $0 == .written || $0 == .synchronized ? NameExportFailure.synchronizationFailed : NameExportFailure.writeFailed }
        })
        let exists = FileManager().fileExists(atPath: target.path)
        if boundary == .beforeCreate { #expect(result == .notCreated(.writeFailed) && !exists) }
        else {
            let reason: NameExportFailure = boundary == .written || boundary == .synchronized ? .synchronizationFailed : .writeFailed
            #expect(result == .createdButIncomplete(reason) && exists)
        }
        #expect(try await store.finishForget(store.prepareForget()) == .forgotten)
        await store.close(); try f.receipt(["exportFailure": true, "publicationReportedTruthfully": true])
    }

    @Test func exclusiveCreationAndParentReplacementRefuseSafely() async throws {
        let f = try MoveFixture(), store = try await PersistentNameStore.create(directory: f.catalog, first: AuthoredNames(nickname: "Private"))
        let target = f.destination.appendingPathComponent("Existing.json"), original = Data("Keep existing".utf8)
        try original.write(to: target, options: .withoutOverwriting)
        let existingPreview = try await store.prepareExport()
        #expect(await store.export(existingPreview, to: target) == .notCreated(.alreadyExists))
        #expect(try Data(contentsOf: target) == original)
        let retained = f.root.appendingPathComponent("Retained destination")
        let changedPreview = try await store.prepareExport()
        let result = await store.export(changedPreview, to: f.destination.appendingPathComponent("changed.json"), probe: {
            if $0 == .beforeCreate {
                try FileManager().moveItem(at: f.destination, to: retained)
                try FileManager().createDirectory(at: f.destination, withIntermediateDirectories: false)
            }
        })
        #expect(result == .notCreated(.destinationChanged))
        let link = f.root.appendingPathComponent("Link")
        try FileManager().createSymbolicLink(at: link, withDestinationURL: f.destination)
        let linkedPreview = try await store.prepareExport()
        #expect(await store.export(linkedPreview, to: link.appendingPathComponent("linked.json")) == .notCreated(.writeFailed))
        await store.close(); try f.receipt(["exclusiveCreate": true, "changedParentAndSymlinkRefused": true])
    }
}

final class ExportPause: @unchecked Sendable {
    private let stopped = DispatchSemaphore(value: 0), continued = DispatchSemaphore(value: 0)
    func stop() throws {
        stopped.signal()
        guard continued.wait(timeout: .now() + 15) == .success else { throw NameExportFailure.writeFailed }
    }
    func arrived() async throws {
        guard await Task.detached(operation: { self.waitForStop() }).value else { throw NameExportFailure.writeFailed }
    }
    private func waitForStop() -> Bool { stopped.wait(timeout: .now() + 15) == .success }
    func resume() { continued.signal() }
}
