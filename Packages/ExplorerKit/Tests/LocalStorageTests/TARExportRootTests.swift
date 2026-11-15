import Foundation
import ExplorerCore
import FileOperations
import Testing
@testable import LocalStorage

struct TARExportRootTests {
    @Test func capturesAbsorbedRootsAndRefusesForeignOrClosedIDs() async throws {
        let fixture = try TARTestFixture()
        let bytes = TARTestFixture.member("Folder/Report.txt", body: Data("generated report".utf8))
            + TARTestFixture.member("Empty/", body: Data(), type: 53)
            + Data(repeating: 0, count: 1024)
        try bytes.write(to: fixture.source)
        let first = try await TARArchiveReader().open(fixture.source)
        let second = try await TARArchiveReader().open(fixture.source)
        let page = try await first.page(in: first.root)
        let folder = try #require(page.items.first { $0.name == "Folder" })
        let empty = try #require(page.items.first { $0.name == "Empty" })
        let nested = try await first.folder(at: ["Folder"])
        let child = try #require(try await first.page(in: nested).items.first)
        let roots = try await first.rootsForExport([folder.id, child.id, empty.id])
        #expect(roots.count == 2)
        #expect(Set(roots.compactMap(\.singleFolderName)) == ["Folder", "Empty"])
        #expect(roots.allSatisfy { $0.archiveURL == fixture.source && $0.count == 1 && !$0.isWholeArchive })
        do { _ = try await second.rootsForExport([folder.id]); Issue.record("Foreign root accepted") } catch { }
        do { _ = try await first.rootsForExport([]); Issue.record("Empty root capture accepted") } catch { }
        await first.close()
        do { _ = try await first.rootsForExport([folder.id]); Issue.record("Closed catalog accepted") } catch { }
        await second.close()
        #expect(try Data(contentsOf: fixture.source) == bytes)
    }

    @Test func offeredNamesShareCaseAndLengthHandlingWithZIP() async throws {
        let fixture = try TARTestFixture()
        let bytes = TARTestFixture.member("a/Report.txt", body: Data([1]))
            + TARTestFixture.member("b/report.txt", body: Data([2]))
            + Data(repeating: 0, count: 1024)
        try bytes.write(to: fixture.source)
        let session = try await TARArchiveReader().open(fixture.source)
        let page = try await session.searchNames("report")
        let roots = try await session.rootsForExport(Set(page.items.map(\.id)))
        let names = try ArchiveRootExportNames.offeredTAR(roots)
        #expect(names.count == 2 && names.contains("Report.txt"))
        #expect(Set(names.map { $0.lowercased() }).count == 2)
        #expect(names.allSatisfy { $0.hasSuffix(".txt") && $0.utf8.count <= 255 && !$0.contains("/") })
        #expect(names == (try ArchiveRootExportNames.offeredTAR(roots)))
        await session.close()
    }

    @Test(arguments: [false, true]) func compressedRootSurvivesSessionCloseAndReleasesAfterPublication(_ bzip2: Bool) async throws {
        let fixture = try TARTestFixture()
        let source = try (bzip2 ? fixture.bzip2Source() : fixture.gzipSource())
        let expected = try await fixture.document().contents.encoded
        let cache = fixture.root.appendingPathComponent("cache")
        let parent = fixture.root.appendingPathComponent("Destination")
        for directory in [cache, parent] {
            try FileManager().createDirectory(at: directory, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
        }
        let pool = TARCompressedPreparationPool(cacheDirectory: cache, activity: FileActivityGate())
        let session = try await TARArchiveReader(compressedPool: pool).prepareCompressed(source, publicQuarantineSource: true)
        let page = try await session.page(in: session.root)
        let file = try #require(page.items.first { $0.name == "data.json" })
        var roots: [TARExtractionSelection]? = try await session.rootsForExport([file.id])
        await session.close()
        #expect(roots?.first?.singleFileName == "data.json" && roots?.first?.archiveURL == source)
        #expect(pool.usage.entryCount == 1)
        let engine = RecoverableFileOperations(journalDirectory: fixture.root.appendingPathComponent("history"),
            tarOneFilePublicExtractionPolicy: .sourceQualification)
        let destination = try await engine.checkReceivedFileDestination(parent: parent, name: "Export.json")
        let plan = try await engine.prepareTARFilePublicExtraction(try #require(roots?.first),
            parent: parent, name: "Export.json", observing: destination)
        roots = nil
        let result = await engine.performReceivedFile(plan)
        #expect(result.result.disposition == .succeeded)
        #expect(try Data(contentsOf: plan.destination) == expected)
        // Keep the consumed plan alive: completion must drop the producer's
        // spool graph, rather than wait for its caller to release this value.
        #expect(await pool.drain())
        withExtendedLifetime(plan) {}
        let cold = RecoverableFileOperations(journalDirectory: fixture.root.appendingPathComponent("history"),
            tarOneFilePublicExtractionPolicy: .sourceQualification)
        let undone = await cold.undo(recordID: try #require(result.recordID))
        #expect(undone.result.disposition == .succeeded)
        #expect(!FileManager().fileExists(atPath: plan.destination.path))
    }
}
