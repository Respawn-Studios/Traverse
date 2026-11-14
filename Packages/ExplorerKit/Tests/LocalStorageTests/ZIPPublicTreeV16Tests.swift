import CoreServices
import CryptoKit
import Darwin
import Foundation
import XCTest
@_spi(ArchiveProduction) @testable import FileOperations
@testable import LocalStorage

private struct PublicTreeZIPFixture {
    let root: URL, source: URL, parent: URL, journal: URL
    init(marked: Bool = true) throws {
        root = try LocalStorageTestFixtures.directory()
        source = root.appendingPathComponent("Generated.zip")
        parent = root.appendingPathComponent("Destination", isDirectory: true)
        journal = root.appendingPathComponent("history", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        try GeneratedZIP.bytes([.init("Folder/Report.txt"), .init("Empty/", mode: 0x4000, bytes: Data())])
            .write(to: source, options: .withoutOverwriting)
        if marked {
            var values = URLResourceValues()
            values.quarantineProperties = [
                kLSQuarantineAgentNameKey as String: "Generated ZIP tree test",
                kLSQuarantineTypeKey as String: kLSQuarantineTypeOtherDownload as String,
                kLSQuarantineTimeStampKey as String: Date()
            ]
            var archive = source
            try archive.setResourceValues(values)
        }
    }
    func engine(publicTree: Bool, hooks: RecoveryHooks = .init()) -> RecoverableFileOperations {
        .init(journalDirectory: journal, hooks: hooks,
            zipTreePublicExtractionPolicy: publicTree ? .sourceQualification : .held)
    }
    func plan(_ engine: RecoverableFileOperations, name: String = "Public") async throws -> ArchiveExtractionPlan {
        try await engine.prepareZIPExtraction(source: source, parent: parent, name: name,
            observing: engine.observeSelection([source]), publicQuarantineTreeV16: true)
    }
}

final class ZIPPublicTreeV16Tests: XCTestCase, @unchecked Sendable {
    func testSelectedZIPFolderUsesZIPPurposeAndDefaultHeldExportGate() async throws {
        let f = try PublicTreeZIPFixture()
        let session = try await ZIPArchiveReader().open(f.source)
        let page = try await session.page(in: session.root)
        let folder = try XCTUnwrap(page.items.first(where: { $0.name == "Folder" }))
        let roots = try await session.rootsForExport([folder.id])
        let selection = try XCTUnwrap(roots.first)
        await session.close()
        let held = f.engine(publicTree: false)
        let observed = try await held.checkReceivedDirectoryDestination(parent: f.parent, name: "Selected")
        do {
            _ = try await held.prepareZIPRootExport(selection, parent: f.parent, name: "Selected",
                observing: observed, publicQuarantineTreeV16: true)
            XCTFail("held selected ZIP folder was admitted")
        } catch {}
        let engine = f.engine(publicTree: true)
        let plan = try await engine.prepareZIPRootExport(selection, parent: f.parent, name: "Selected",
            observing: observed, publicQuarantineTreeV16: true)
        let result = await engine.performZIPRootExport(plan)
        let id = try XCTUnwrap(result.recordID)
        XCTAssertEqual(result.result.disposition, .succeeded, "\(result.result.items.map(\.status))")
        XCTAssertTrue(FileManager.default.fileExists(atPath: plan.destination.appendingPathComponent("Report.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: plan.destination.appendingPathComponent("Folder").path))
        if case .publicProducedTreeV16(let record) = try OperationHistoryInspector.record(
            f.journal, id: id, cancellation: .init()) {
            XCTAssertEqual(record.producedTreeV16, .zipExtraction(sourceMarked: true))
        } else { XCTFail("selected ZIP folder used the wrong history purpose") }
        let inverse = await f.engine(publicTree: true).undo(recordID: id)
        XCTAssertEqual(inverse.result.disposition, .succeeded)
    }

    func testMarkedZIPTreeNeedsOwnPolicyAndPublishesEveryMarkedNodeWithColdUndo() async throws {
        let f = try PublicTreeZIPFixture()
        let original = Data(SHA256.hash(data: try Data(contentsOf: f.source)))
        do { _ = try await f.plan(f.engine(publicTree: false)); XCTFail("held policy admitted ZIP tree") }
        catch {}
        let engine = f.engine(publicTree: true), plan = try await f.plan(engine)
        let result = await engine.performArchiveExtraction(plan)
        let id = try XCTUnwrap(result.recordID)
        XCTAssertEqual(result.result.disposition, .succeeded, "\(result.result.items.map(\.status))")
        if case .publicProducedTreeV16(let record) = try OperationHistoryInspector.record(
            f.journal, id: id, cancellation: .init()) {
            XCTAssertEqual(record.producedTreeV16, .zipExtraction(sourceMarked: true))
            XCTAssertEqual(record.steps.first?.before.publicTreeQuarantineV16?.nodeCount, 4)
            XCTAssertEqual(record.steps.first?.before.publicTreeQuarantineV16?.requiresEveryNode, true)
        } else { XCTFail("ZIP tree did not retain its typed v16 purpose") }
        for path in ["", "Folder", "Folder/Report.txt", "Empty"] {
            let url = path.isEmpty ? plan.destination : plan.destination.appendingPathComponent(path)
            XCTAssertNotNil(try url.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties)
        }
        let enabled = try await f.engine(publicTree: true).inspectExistingHistory()
        XCTAssertTrue(enabled.records.contains { $0.id == id && $0.canUndo })
        let retention = try await engine.retentionRecord(recordID: id)
        XCTAssertFalse(retention.canCleanup)
        let held = try await f.engine(publicTree: false).inspectExistingHistory()
        XCTAssertFalse(held.records.first(where: { $0.id == id })?.canUndo ?? true)
        let inverse = await f.engine(publicTree: true).undo(recordID: id)
        XCTAssertEqual(inverse.result.disposition, .succeeded, "\(inverse.result.items.map(\.status))")
        XCTAssertFalse(FileManager.default.fileExists(atPath: plan.destination.path))
        XCTAssertEqual(Data(SHA256.hash(data: try Data(contentsOf: f.source))), original)
    }

    func testMarkedZIPTreeRefusesDescendantMarkLossBeforePublication() async throws {
        let f = try PublicTreeZIPFixture()
        var hooks = RecoveryHooks()
        hooks.archiveProduction.stage = { stage, payload in
            if stage == .receiptsChecked {
                guard removexattr(payload.appendingPathComponent("Folder/Report.txt").path,
                    "com.apple.quarantine", 0) == 0 else { throw FileOperationFailure.ioFailure }
            }
        }
        let engine = f.engine(publicTree: true, hooks: hooks), plan = try await f.plan(engine)
        let result = await engine.performArchiveExtraction(plan)
        XCTAssertNotEqual(result.result.disposition, .succeeded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: plan.destination.path))
    }

    func testMarkedZIPTreeColdUndoRefusesLostDescendantMarkWithoutRemovingOutput() async throws {
        let f = try PublicTreeZIPFixture(), engine = f.engine(publicTree: true)
        let plan = try await f.plan(engine)
        let result = await engine.performArchiveExtraction(plan)
        let id = try XCTUnwrap(result.recordID)
        XCTAssertEqual(result.result.disposition, .succeeded)
        let child = plan.destination.appendingPathComponent("Folder/Report.txt")
        XCTAssertEqual(removexattr(child.path, "com.apple.quarantine", 0), 0)
        let inverse = await f.engine(publicTree: true).undo(recordID: id)
        XCTAssertNotEqual(inverse.result.disposition, .succeeded)
        XCTAssertTrue(FileManager.default.fileExists(atPath: child.path))
    }

    func testUnmarkedZIPTreeRetainsSourceMarkFactAndColdUndo() async throws {
        let f = try PublicTreeZIPFixture(marked: false), engine = f.engine(publicTree: true)
        let plan = try await f.plan(engine)
        let result = await engine.performArchiveExtraction(plan)
        let id = try XCTUnwrap(result.recordID)
        XCTAssertEqual(result.result.disposition, .succeeded)
        if case .publicProducedTreeV16(let record) = try OperationHistoryInspector.record(
            f.journal, id: id, cancellation: .init()) {
            XCTAssertEqual(record.producedTreeV16, .zipExtraction(sourceMarked: false))
            XCTAssertEqual(record.steps.first?.before.publicTreeQuarantineV16?.requiresEveryNode, false)
        } else { XCTFail("unmarked ZIP tree did not retain its typed purpose") }
        let inverse = await f.engine(publicTree: true).undo(recordID: id)
        XCTAssertEqual(inverse.result.disposition, .succeeded)
    }
}
