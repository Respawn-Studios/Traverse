import CryptoKit
import Darwin
import ExplorerCore
import Foundation
import XCTest
import zlib
@_spi(ArchiveProduction) @_spi(Qualification) @testable import FileOperations
@testable import LocalStorage

private func required<T>(_ value: T?) throws -> T { try XCTUnwrap(value) }

private struct RootZIP {
    struct Entry { let name: String; let body: Data; var directory = false; var deflated = false }
    static func put(_ data: inout Data, _ at: Int, _ value: UInt64, _ count: Int) {
        data.replaceSubrange(at..<(at + count), with: (0..<count).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
    }
    static func deflate(_ body: Data) throws -> Data {
        var state = z_stream(), output = Data(count: Int(compressBound(uLong(body.count))) + 64)
        guard deflateInit2_(&state, Z_DEFAULT_COMPRESSION, Z_DEFLATED, -15, 8, Z_DEFAULT_STRATEGY,
            ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw ZIPContentFailure.codecUnavailable }
        defer { deflateEnd(&state) }
        let result = output.withUnsafeMutableBytes { to in body.withUnsafeBytes { from in
            state.next_in = UnsafeMutablePointer(mutating: from.bindMemory(to: UInt8.self).baseAddress); state.avail_in = uInt(body.count)
            state.next_out = to.bindMemory(to: UInt8.self).baseAddress; state.avail_out = uInt(to.count)
            return zlib.deflate(&state, Z_FINISH)
        } }
        guard result == Z_STREAM_END else { throw ZIPContentFailure.codecUnavailable }
        output.removeLast(Int(state.avail_out)); return output
    }
    static func bytes(_ entries: [Entry]) throws -> Data {
        var local = Data(), central = Data()
        for entry in entries {
            let name = Data(entry.name.utf8), payload = entry.deflated ? try deflate(entry.body) : entry.body
            let crc = entry.body.withUnsafeBytes { zlib.crc32(0, $0.bindMemory(to: UInt8.self).baseAddress, uInt($0.count)) }
            var header = Data(repeating: 0, count: 30), record = Data(repeating: 0, count: 46)
            for (at, value, count): (Int, UInt64, Int) in [(0, 0x04034b50, 4), (4, 20, 2), (6, 0x0800, 2),
                (8, entry.deflated ? 8 : 0, 2), (14, UInt64(crc), 4), (18, UInt64(payload.count), 4),
                (22, UInt64(entry.body.count), 4), (26, UInt64(name.count), 2)] { put(&header, at, value, count) }
            for (at, value, count): (Int, UInt64, Int) in [(0, 0x02014b50, 4), (4, 0x0314, 2), (6, 20, 2),
                (8, 0x0800, 2), (10, entry.deflated ? 8 : 0, 2), (16, UInt64(crc), 4), (20, UInt64(payload.count), 4),
                (24, UInt64(entry.body.count), 4), (28, UInt64(name.count), 2),
                (38, UInt64(entry.directory ? 0x4000 : 0x8000) << 16, 4), (42, UInt64(local.count), 4)] { put(&record, at, value, count) }
            central += record + name; local += header + name + payload
        }
        var end = Data(repeating: 0, count: 22)
        for (at, value, count): (Int, UInt64, Int) in [(0, 0x06054b50, 4), (8, UInt64(entries.count), 2),
            (10, UInt64(entries.count), 2), (12, UInt64(central.count), 4), (16, UInt64(local.count), 4)] { put(&end, at, value, count) }
        return local + central + end
    }
}
private struct ExportFixture {
    let root: URL, source: URL, parent: URL, history: URL
    init(_ entries: [RootZIP.Entry]) throws {
        guard let raw = ProcessInfo.processInfo.environment["TRAVERSE_ZIP_ROOT_EXPORT_ROOT"] else {
            root = try LocalStorageTestFixtures.directory()
            source = root.appendingPathComponent("Generated.zip")
            parent = root.appendingPathComponent("Destination")
            history = root.appendingPathComponent("history")
            try FileManager().createDirectory(at: parent, withIntermediateDirectories: false,
                                             attributes: [.posixPermissions: 0o700])
            try RootZIP.bytes(entries).write(to: source, options: .withoutOverwriting)
            return
        }
        let admitted = URL(fileURLWithPath: raw), fm = FileManager()
        guard admitted.resolvingSymlinksInPath() == admitted,
              UUID(uuidString: admitted.lastPathComponent) != nil,
              admitted.deletingLastPathComponent().lastPathComponent == "traverse-development",
              fm.fileExists(atPath: admitted.appendingPathComponent("reservation.json").path),
              #filePath.hasPrefix(admitted.appendingPathComponent("source/package/Tests/LocalStorageTests/").path) else {
            throw FileOperationFailure.invalidRequest
        }
        root = admitted.appendingPathComponent("state/" + UUID().uuidString)
        source = root.appendingPathComponent("Generated.zip"); parent = root.appendingPathComponent("Destination")
        history = root.appendingPathComponent("history")
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        try RootZIP.bytes(entries).write(to: source, options: .withoutOverwriting)
    }
    func engine(_ hooks: RecoveryHooks = .init(), activity: (@Sendable () throws -> any Sendable)? = nil,
        publicZIP: ZIPOneFilePublicExtractionPolicy = .held) -> RecoverableFileOperations {
        .init(journalDirectory: history, hooks: hooks, activity: activity,
            zipOneFilePublicExtractionPolicy: publicZIP)
    }
    func selection(_ paths: Set<String>) async throws -> [ZIPRootExportSelection] {
        let session = try await ZIPArchiveReader().open(source)
        do {
            var pending = [session.root], ids = Set<ZIPItemID>()
            while let folder = pending.popLast() {
                let page = try await session.page(in: folder)
                for item in page.items {
                    if paths.contains(item.path) { ids.insert(item.id) }
                    if let folder = item.folder { pending.append(folder) }
                }
            }
            guard ids.count == paths.count else { throw ZIPArchiveFailure.invalidFolder }
            let result = try await session.rootsForExport(ids); await session.close(); return result
        } catch { await session.close(); throw error }
    }
    func plan(_ selection: ZIPRootExportSelection, _ engine: RecoverableFileOperations, name: String? = nil,
        hooks: ZIPProductionHooks = .init()) async throws -> ZIPRootExportPlan {
        let observation = try await engine.checkReceivedFileDestination(parent: parent, name: name ?? selection.name)
        return try await engine.prepareZIPRootExport(selection, parent: parent, name: name ?? selection.name,
            observing: observation, hooks: hooks)
    }
    func publicFilePlan(_ selection: ZIPRootExportSelection, _ engine: RecoverableFileOperations,
        name: String? = nil) async throws -> ZIPRootExportPlan {
        let offeredName = name ?? selection.name
        let observation = try await engine.checkReceivedFileDestination(parent: parent, name: offeredName)
        return try await engine.prepareZIPRootFilePublicExtraction(selection, parent: parent,
            name: offeredName, observing: observation)
    }
}
private final class ExportBarrier: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    private let lock = NSLock(); private var used = false
    func waitForEntry() -> Bool { entered.wait(timeout: .now() + 5) == .success }
    func holdOnce() {
        let first = lock.withLock { if used { return false }; used = true; return true }
        if first { entered.signal(); release.wait() }
    }
}
private struct EmptyReceivedFile: ArchiveFileProducer {
    let preview = ArchiveProductionPreview(files: 1, folders: 0, logicalBytes: 0, longestPathBytes: 0)
    func validate(check: @Sendable () throws -> Void) throws { try check() }
    func produce(into descriptor: Int32, check: @Sendable () throws -> Void,
        progress: @Sendable (UInt64, Int) -> Void) throws -> ArchiveProducedNode {
        try check(); var facts = stat()
        guard fchmod(descriptor, 0o644) == 0, fstat(descriptor, &facts) == 0 else { throw FileOperationFailure.ioFailure }
        progress(0, 1)
        return .init(relative: "", device: facts.st_dev, inode: facts.st_ino, kind: facts.st_mode & S_IFMT,
            birthSeconds: facts.st_birthtimespec.tv_sec, birthNanoseconds: facts.st_birthtimespec.tv_nsec,
            changedSeconds: facts.st_ctimespec.tv_sec, changedNanoseconds: facts.st_ctimespec.tv_nsec,
            size: facts.st_size, contentSHA256: Data(SHA256.hash(data: Data())))
    }
}

final class ZIPRootExportTests: XCTestCase, @unchecked Sendable {
    func testFlattenedOfferNamesAreStableUniqueAndDoNotChangeRootIdentity() async throws {
        let f = try ExportFixture([.init(name: "A/Report.txt", body: Data("first".utf8)),
            .init(name: "B/report.txt", body: Data("second".utf8)), .init(name: "C/Report (2).txt", body: Data())])
        let roots = try await f.selection(["A/Report.txt", "B/report.txt", "C/Report (2).txt"])
        let names = try ZIPRootExportNames.offered(roots)
        XCTAssertEqual(names, try ZIPRootExportNames.offered(roots))
        XCTAssertEqual(names.map { $0.lowercased() }.count, Set(names.map { $0.lowercased() }).count)
        XCTAssertEqual(Set(roots.map(\.archivePath)), ["A/Report.txt", "B/report.txt", "C/Report (2).txt"])
        let engine = f.engine()
        for (index, root) in roots.enumerated() {
            let plan = try await f.plan(root, engine, name: names[index]), made = await engine.performZIPRootExport(plan)
            XCTAssertEqual(made.result.disposition, .succeeded)
            let expected = root.archivePath.hasPrefix("A/") ? Data("first".utf8) : root.archivePath.hasPrefix("B/") ? Data("second".utf8) : Data()
            XCTAssertEqual(try Data(contentsOf: plan.destination), expected)
        }
    }
    func testOfferNamesBoundUnicodeAndCanonicalEquivalentDuplicates() async throws {
        let f = try ExportFixture([.init(name: "Base", body: Data())]), root = try required(try await f.selection(["Base"]).first)
        let roots = ["é.txt", "e\u{301}.txt", String(repeating: "🗂️", count: 200) + ".txt"].map {
            ZIPRootExportSelection(binding: root.binding, root: .init(path: $0, kind: .file))
        }
        let names = try ZIPRootExportNames.offered(roots)
        XCTAssertEqual(names[0], "é.txt"); XCTAssertTrue(names[1].hasSuffix(" (2).txt"))
        XCTAssertTrue(names.allSatisfy { !$0.isEmpty && $0.utf8.count <= 255 && !$0.contains("/") })
        XCTAssertEqual(roots[2].archivePath, String(repeating: "🗂️", count: 200) + ".txt")
    }
    func testExistingReceivedFileAndFolderKeepTheirDownloadHistoryAndUndo() async throws {
        let f = try ExportFixture([.init(name: "One", body: Data("received".utf8))]), engine = f.engine()
        let observation = try await engine.checkReceivedFileDestination(parent: f.parent, name: "Received.txt")
        let file = try await engine.prepareReceivedFile(parent: f.parent, name: "Received.txt", observing: observation) { check in
            try check(); return EmptyReceivedFile()
        }
        let fileResult = await engine.performReceivedFile(file); XCTAssertEqual(fileResult.result.disposition, .succeeded)
        let first = try await engine.inspectExistingHistory(); XCTAssertEqual(first.records.first?.operation, "Download")
        let fileUndo = await f.engine().undo(recordID: try required(fileResult.recordID)); XCTAssertEqual(fileUndo.result.disposition, .succeeded)
        let folder = try await engine.prepareReceivedDirectory(parent: f.parent, name: "Received Folder", observing: observation) { check in
            try PreparedZIPDirectory(f.source, check: check)
        }
        let folderResult = await engine.performReceivedDirectory(folder); XCTAssertEqual(folderResult.result.disposition, .succeeded)
        let second = try await engine.inspectExistingHistory()
        XCTAssertEqual(second.records.first { $0.id == folderResult.recordID }?.operation, "Download Folder")
        let folderUndo = await f.engine().undo(recordID: try required(folderResult.recordID)); XCTAssertEqual(folderUndo.result.disposition, .succeeded)
    }
    func testExplicitRootDirectoryStreamAndCRCStillGetVerified() async throws {
        for corrupt in [false, true] {
            let f = try ExportFixture([.init(name: "Outer/Empty/", body: Data(), directory: true, deflated: true)])
            if corrupt {
                var bytes = try Data(contentsOf: f.source)
                let central = 30 + "Outer/Empty/".utf8.count + (try RootZIP.deflate(Data())).count
                RootZIP.put(&bytes, 14, 1, 4); RootZIP.put(&bytes, central + 16, 1, 4)
                try bytes.write(to: f.source)
            }
            let selection = try required(try await f.selection(["Outer/Empty"]).first), engine = f.engine()
            let plan = try await f.plan(selection, engine), made = await engine.performZIPRootExport(plan)
            if corrupt {
                XCTAssertNotEqual(made.result.disposition, .succeeded)
                XCTAssertFalse(FileManager().fileExists(atPath: plan.destination.path))
            } else {
                XCTAssertEqual(made.result.disposition, .succeeded)
                XCTAssertEqual(try FileManager().contentsOfDirectory(atPath: plan.destination.path), [])
            }
        }
    }
    func testStoredAndDeflatedMemberExportAfterCatalogCloseAndColdUndo() async throws {
        for compressed in [false, true] {
            let body = Data((0..<65_539).map { UInt8(truncatingIfNeeded: $0 * 13) })
            let f = try ExportFixture([.init(name: "Parent/Nested/Report.txt", body: body, deflated: compressed)])
            let selection = try required(try await f.selection(["Parent/Nested/Report.txt"]).first)
            XCTAssertEqual(selection.name, "Report.txt"); XCTAssertEqual(selection.kind, .file)
            XCTAssertFalse(selection.description.contains("Report")); XCTAssertEqual(selection.description, selection.debugDescription)
            let original = try Data(contentsOf: f.source), engine = f.engine(), plan = try await f.plan(selection, engine, name: "Receiver.txt")
            XCTAssertEqual(plan.files, 1); XCTAssertEqual(plan.folders, 0); XCTAssertEqual(plan.logicalBytes, UInt64(body.count))
            XCTAssertFalse(FileManager().fileExists(atPath: f.history.path))
            let made = await engine.performZIPRootExport(plan)
            XCTAssertEqual(made.result.disposition, .succeeded)
            do {
                _ = try await engine.inspectGeneratedPublicCatalog(recordID: try required(made.recordID))
                XCTFail("Ordinary legacy extraction was disclosed as public")
            } catch { XCTAssertEqual(error as? FileOperationFailure, .unsupported) }
            let history = try await engine.inspectExistingHistory()
            XCTAssertEqual(history.records.first?.operation, "Extract ZIP")
            let publicPolicyHistory = try await f.engine(publicZIP: .sourceQualification).inspectExistingHistory()
            XCTAssertTrue(try required(publicPolicyHistory.records.first).canUndo)
            XCTAssertEqual(try Data(contentsOf: plan.destination), body)
            let undone = await f.engine().undo(recordID: try required(made.recordID))
            XCTAssertEqual(undone.result.disposition, .succeeded)
            XCTAssertFalse(FileManager().fileExists(atPath: plan.destination.path))
            XCTAssertEqual(try Data(contentsOf: f.source), original)
        }
    }
    func testNestedDirectoryRebasesAndPreservesOnlySelectedChildren() async throws {
        let f = try ExportFixture([.init(name: "Outer/Selected/A.txt", body: Data("A".utf8)),
            .init(name: "Outer/Selected/Deep/B.txt", body: Data("B".utf8), deflated: true),
            .init(name: "Outer/Selected/Empty/", body: Data(), directory: true),
            .init(name: "Outer/Other.txt", body: Data("keep outside".utf8)), .init(name: "Selected2.txt", body: Data())])
        let selected = try required(try await f.selection(["Outer/Selected"]).first), engine = f.engine()
        let plan = try await f.plan(selected, engine, name: "Delivered")
        XCTAssertEqual(plan.files, 2); XCTAssertEqual(plan.folders, 2)
        let made = await engine.performZIPRootExport(plan); XCTAssertEqual(made.result.disposition, .succeeded)
        let history = try await engine.inspectExistingHistory()
        XCTAssertEqual(history.records.first?.operation, "Extract ZIP")
        XCTAssertEqual(try FileManager().contentsOfDirectory(atPath: plan.destination.path).sorted(), ["A.txt", "Deep", "Empty"])
        XCTAssertEqual(try Data(contentsOf: plan.destination.appendingPathComponent("Deep/B.txt")), Data("B".utf8))
        let undone = await f.engine().undo(recordID: try required(made.recordID)); XCTAssertEqual(undone.result.disposition, .succeeded)
    }
    func testEmptyFileAndEmptyExplicitUnicodeFolderAreRealRoots() async throws {
        let f = try ExportFixture([.init(name: "Parent/Café 日本語/", body: Data(), directory: true),
            .init(name: "Parent/Zero", body: Data(), deflated: true)])
        let selections = try await f.selection(["Parent/Café 日本語", "Parent/Zero"]), engine = f.engine()
        for selection in selections {
            let plan = try await f.plan(selection, engine), made = await engine.performZIPRootExport(plan)
            XCTAssertEqual(made.result.disposition, .succeeded); XCTAssertEqual(plan.logicalBytes, 0)
            if selection.kind == .directory { XCTAssertEqual(try FileManager().contentsOfDirectory(atPath: plan.destination.path), []) }
            else { XCTAssertEqual(try Data(contentsOf: plan.destination), Data()) }
            let undone = await engine.undo(recordID: try required(made.recordID)); XCTAssertEqual(undone.result.disposition, .succeeded)
        }
    }
    func testMetadataRootsDeduplicateAndRefuseForeignClosedEmptyAndTooManyIDs() async throws {
        let f = try ExportFixture([.init(name: "Folder/Deep/A", body: Data()), .init(name: "Other/A", body: Data())])
        let roots = try await f.selection(["Folder", "Folder/Deep", "Folder/Deep/A", "Other/A"])
        XCTAssertEqual(roots.map(\.name).sorted(), ["A", "Folder"])
        let first = try await ZIPArchiveReader().open(f.source), second = try await ZIPArchiveReader().open(f.source)
        let id = try required(try await first.page(in: first.root).items.first?.id)
        do { _ = try await second.rootsForExport([id]); XCTFail("Foreign catalog accepted") } catch {}
        do { _ = try await first.rootsForExport([]); XCTFail("Empty roots accepted") } catch {}
        let excess = Set((1...129).map { ZIPItemID(owner: first.root.owner, node: $0) })
        do { _ = try await first.rootsForExport(excess); XCTFail("Too many roots accepted") } catch {}
        await first.close()
        do { _ = try await first.rootsForExport([id]); XCTFail("Closed catalog accepted") } catch {}
        await second.close()
    }
    func testDuplicateBasenamesAndOccupiedReceiverNameNeverOverwrite() async throws {
        let f = try ExportFixture([.init(name: "A/Same.txt", body: Data("first".utf8)),
            .init(name: "B/Same.txt", body: Data("second".utf8))]), selections = try await f.selection(["A/Same.txt", "B/Same.txt"])
        let engine = f.engine(), first = try await f.plan(selections[0], engine), made = await engine.performZIPRootExport(first)
        XCTAssertEqual(made.result.disposition, .succeeded)
        let bytes = try Data(contentsOf: first.destination)
        do { _ = try await f.plan(selections[1], engine); XCTFail("Occupied name accepted") } catch {}
        XCTAssertEqual(try Data(contentsOf: first.destination), bytes)
        let renamed = try await f.plan(selections[1], engine, name: "Receiver 2.txt"), next = await engine.performZIPRootExport(renamed)
        XCTAssertEqual(next.result.disposition, .succeeded)
        XCTAssertNotEqual(try Data(contentsOf: renamed.destination), bytes)
    }
    func testChangedSourceBeforePreparationAndAfterPlanRefusesPublication() async throws {
        for after in [false, true] {
            let f = try ExportFixture([.init(name: "Folder/One", body: Data("original".utf8))])
            let root = try required(try await f.selection(["Folder/One"]).first), engine = f.engine()
            let plan = after ? try await f.plan(root, engine) : nil
            try Data("changed archive".utf8).write(to: f.source)
            if let plan { let outcome = await engine.performZIPRootExport(plan); XCTAssertNotEqual(outcome.result.disposition, .succeeded) }
            else { do { _ = try await f.plan(root, engine); XCTFail("Changed archive accepted") } catch {} }
            XCTAssertEqual(try FileManager().contentsOfDirectory(atPath: f.parent.path), [])
            XCTAssertFalse(FileManager().fileExists(atPath: f.history.path))
        }
    }
    func testChangedParentAndArrivalAfterPreparationCannotRedirectOrOverwrite() async throws {
        for replaceParent in [false, true] {
            let f = try ExportFixture([.init(name: "One", body: Data("source".utf8))])
            let root = try required(try await f.selection(["One"]).first), engine = f.engine(), plan = try await f.plan(root, engine)
            if replaceParent {
                try FileManager().moveItem(at: f.parent, to: f.root.appendingPathComponent("Original Parent"))
                try FileManager().createDirectory(at: f.parent, withIntermediateDirectories: false)
            } else { try Data("preserve existing".utf8).write(to: plan.destination, options: .withoutOverwriting) }
            let outcome = await engine.performZIPRootExport(plan); XCTAssertNotEqual(outcome.result.disposition, .succeeded)
            XCTAssertNil(outcome.recordID)
            if replaceParent { XCTAssertEqual(try FileManager().contentsOfDirectory(atPath: f.parent.path), []) }
            else { XCTAssertEqual(try Data(contentsOf: plan.destination), Data("preserve existing".utf8)) }
        }
    }
    func testCRCAndInjectedDiskFullRetainUncertainPrivateOutput() async throws {
        for corrupt in [false, true] {
            let f = try ExportFixture([.init(name: "Folder/One", body: Data(repeating: 0x41, count: 70_003))])
            if corrupt { var bytes = try Data(contentsOf: f.source); bytes[30 + "Folder/One".utf8.count] ^= 0xff; try bytes.write(to: f.source) }
            let original = try Data(contentsOf: f.source), root = try required(try await f.selection(["Folder/One"]).first), engine = f.engine()
            var hooks = ZIPProductionHooks(); if !corrupt { hooks.failAfterBytes = 8_192; hooks.writeChunk = 4_096 }
            let plan = try await f.plan(root, engine, hooks: hooks), outcome = await engine.performZIPRootExport(plan)
            XCTAssertNotEqual(outcome.result.disposition, .succeeded); XCTAssertFalse(FileManager().fileExists(atPath: plan.destination.path))
            let record = try await engine.retentionRecord(recordID: required(outcome.recordID))
            XCTAssertEqual(record.state, "needsReview"); XCTAssertFalse(record.canCleanup)
            XCTAssertEqual(try Data(contentsOf: f.source), original)
            if !corrupt { XCTAssertEqual(outcome.result.items.first?.status, .failed(.outOfSpace)) }
        }
    }
    func testCancellationHoldsFileAndDirectoryActivityUntilWriteActuallyDrains() async throws {
        for directory in [false, true] {
            let f = try ExportFixture([.init(name: "Folder/One", body: Data(repeating: 0x42, count: 70_003))])
            let root = try required(try await f.selection([directory ? "Folder" : "Folder/One"]).first)
            let gate = FileActivityGate(), barrier = ExportBarrier(), engine = f.engine(activity: { try gate.begin() })
            let plan = try await f.plan(root, engine, hooks: .init(beforeWrite: { _ in barrier.holdOnce() }))
            let task = Task { await engine.performZIPRootExport(plan) }
            let entered = await Task.detached { barrier.waitForEntry() }.value
            XCTAssertTrue(entered); task.cancel(); XCTAssertEqual(gate.activeCount, 1)
            barrier.release.signal(); let outcome = await task.value
            XCTAssertTrue(outcome.result.cancellationRequested); XCTAssertNotEqual(outcome.result.disposition, .succeeded)
            XCTAssertEqual(gate.activeCount, 0); XCTAssertFalse(FileManager().fileExists(atPath: plan.destination.path))
        }
    }
    func testQuarantineIsInheritedExactlyAndChangedMarkRefusesBeforePublication() async throws {
        let mark = Data("0081;65000001;Traverse-Generated;7BA9C2E3-19E7-46CE-A3BC-ECD4A33A3B6B".utf8)
        for directory in [false, true] {
            let f = try ExportFixture([.init(name: "Folder/One", body: Data("body".utf8))])
            XCTAssertEqual(mark.withUnsafeBytes { setxattr(f.source.path, "com.apple.quarantine", $0.baseAddress, $0.count, 0, XATTR_CREATE) }, 0)
            let root = try required(try await f.selection([directory ? "Folder" : "Folder/One"]).first), engine = f.engine()
            let plan = try await f.plan(root, engine), made = await engine.performZIPRootExport(plan)
            XCTAssertEqual(made.result.disposition, .succeeded)
            for target in directory ? [plan.destination, plan.destination.appendingPathComponent("One")] : [plan.destination] {
                var value = Data(count: mark.count)
                XCTAssertEqual(value.withUnsafeMutableBytes { getxattr(target.path, "com.apple.quarantine", $0.baseAddress, $0.count, 0, 0) }, mark.count)
                XCTAssertEqual(value, mark)
            }
            let next = try await f.plan(root, engine, name: "Changed Mark")
            let changed = Data("0081;65000002;Traverse-Generated;7BA9C2E3-19E7-46CE-A3BC-ECD4A33A3B6B".utf8)
            XCTAssertEqual(changed.withUnsafeBytes { setxattr(f.source.path, "com.apple.quarantine", $0.baseAddress, $0.count, 0, XATTR_REPLACE) }, 0)
            let refused = await engine.performZIPRootExport(next); XCTAssertNotEqual(refused.result.disposition, .succeeded)
            XCTAssertFalse(FileManager().fileExists(atPath: next.destination.path))
        }
    }
    func testMarkedZIPRejectsChangedOutputMarkBetweenWriteAndReceipt() async throws {
        let mark = Data("0081;65000001;Traverse-Generated;7BA9C2E3-19E7-46CE-A3BC-ECD4A33A3B6B".utf8)
        let changed = Data("0082;65000001;Traverse-Generated;7BA9C2E3-19E7-46CE-A3BC-ECD4A33A3B6B".utf8)
        for directory in [false, true] {
            let f = try ExportFixture([.init(name: "Folder/One", body: Data("body".utf8))])
            XCTAssertEqual(mark.withUnsafeBytes { setxattr(f.source.path, "com.apple.quarantine",
                $0.baseAddress, $0.count, 0, XATTR_CREATE) }, 0)
            let root = try required(try await f.selection([directory ? "Folder" : "Folder/One"]).first)
            var hooks = ZIPProductionHooks()
            hooks.afterSecurityWriteBeforeReceipt = { name, descriptor in
                guard name.hasSuffix("One"), changed.withUnsafeBytes({ fsetxattr(descriptor,
                    "com.apple.quarantine", $0.baseAddress, $0.count, 0, XATTR_REPLACE) }) == 0 else {
                    throw FileOperationFailure.ioFailure
                }
            }
            let engine = f.engine(), plan = try await f.plan(root, engine, hooks: hooks)
            let result = await engine.performZIPRootExport(plan)
            XCTAssertNotEqual(result.result.disposition, .succeeded)
            XCTAssertFalse(FileManager().fileExists(atPath: plan.destination.path))
            let record = try await engine.retentionRecord(recordID: required(result.recordID))
            XCTAssertEqual(record.state, "needsReview")
            XCTAssertFalse(record.canCleanup)
            var sourceMark = Data(count: mark.count)
            XCTAssertEqual(sourceMark.withUnsafeMutableBytes { getxattr(f.source.path, "com.apple.quarantine",
                $0.baseAddress, $0.count, 0, 0) }, mark.count)
            XCTAssertEqual(sourceMark, mark)
        }
    }
    func testMarkedZIPRejectsMarkChangeDuringFinalRename() async throws {
        let mark = Data("0081;65000001;Traverse-Generated;7BA9C2E3-19E7-46CE-A3BC-ECD4A33A3B6B".utf8)
        let changed = Data("0082;65000001;Traverse-Generated;7BA9C2E3-19E7-46CE-A3BC-ECD4A33A3B6B".utf8)
        for directory in [false, true] {
            let f = try ExportFixture([.init(name: "Folder/One", body: Data("body".utf8))])
            XCTAssertEqual(mark.withUnsafeBytes { setxattr(f.source.path, "com.apple.quarantine",
                $0.baseAddress, $0.count, 0, XATTR_CREATE) }, 0)
            let root = try required(try await f.selection([directory ? "Folder" : "Folder/One"]).first)
            let destination = f.parent.appendingPathComponent("Changed after rename")
            let affected = directory ? destination.appendingPathComponent("One") : destination
            var recovery = RecoveryHooks()
            recovery.afterRename = {
                XCTAssertEqual(changed.withUnsafeBytes { setxattr(affected.path, "com.apple.quarantine",
                    $0.baseAddress, $0.count, 0, XATTR_REPLACE) }, 0)
            }
            let engine = f.engine(recovery), plan = try await f.plan(root, engine,
                name: destination.lastPathComponent)
            let result = await engine.performZIPRootExport(plan)
            XCTAssertNotEqual(result.result.disposition, .succeeded)
            XCTAssertTrue(FileManager().fileExists(atPath: affected.path))
            let record = try await engine.retentionRecord(recordID: required(result.recordID))
            XCTAssertEqual(record.state, "needsReview")
            XCTAssertFalse(record.canCleanup)
        }
    }
    func testUnmarkedZIPStillRetainsNativeOutputMark() async throws {
        let f = try ExportFixture([.init(name: "One", body: Data("body".utf8))])
        let root = try required(try await f.selection(["One"]).first)
        let native = Data("0082;65000001;Traverse-Generated;7BA9C2E3-19E7-46CE-A3BC-ECD4A33A3B6B".utf8)
        var hooks = ZIPProductionHooks()
        hooks.afterSecurityWriteBeforeReceipt = { _, descriptor in
            guard native.withUnsafeBytes({ fsetxattr(descriptor, "com.apple.quarantine",
                $0.baseAddress, $0.count, 0, XATTR_CREATE) }) == 0 else {
                throw FileOperationFailure.ioFailure
            }
        }
        let engine = f.engine(), plan = try await f.plan(root, engine, hooks: hooks)
        let result = await engine.performZIPRootExport(plan)
        XCTAssertEqual(result.result.disposition, .succeeded)
        var output = Data(count: native.count)
        XCTAssertEqual(output.withUnsafeMutableBytes { getxattr(plan.destination.path, "com.apple.quarantine",
            $0.baseAddress, $0.count, 0, 0) }, native.count)
        XCTAssertEqual(output, native)
    }
    func testEngineOwnershipReplayAndConsumerChangedUndoStayGuarded() async throws {
        let f = try ExportFixture([.init(name: "One", body: Data("source".utf8))])
        let root = try required(try await f.selection(["One"]).first), engine = f.engine(), plan = try await f.plan(root, engine)
        let foreign = await f.engine().performZIPRootExport(plan); XCTAssertNotEqual(foreign.result.disposition, .succeeded)
        let made = await engine.performZIPRootExport(plan); XCTAssertEqual(made.result.disposition, .succeeded)
        let replay = await engine.performZIPRootExport(plan); XCTAssertNotEqual(replay.result.disposition, .succeeded)
        try Data("consumer changes stay".utf8).write(to: plan.destination)
        let undone = await f.engine().undo(recordID: try required(made.recordID)); XCTAssertNotEqual(undone.result.disposition, .succeeded)
        XCTAssertEqual(try Data(contentsOf: plan.destination), Data("consumer changes stay".utf8))
    }
    func testExistingSelectedExtractionStillKeepsArchiveAncestors() async throws {
        let f = try ExportFixture([.init(name: "Outer/Folder/One", body: Data("original".utf8)),
            .init(name: "Outer/Folder/Empty/", body: Data(), directory: true), .init(name: "Other", body: Data())])
        let session = try await ZIPArchiveReader().open(f.source), outer = try required(try await session.page(in: session.root).items.first { $0.name == "Outer" }?.folder)
        let child = try required(try await session.page(in: outer).items.first), selection = try await session.selectionForExtraction([child.id])
        let engine = f.engine(), plan = try await engine.prepareZIPExtraction(source: f.source, parent: f.parent, name: "Extracted",
            observing: engine.observeSelection([f.source]), members: selection)
        let made = await engine.performArchiveExtraction(plan); XCTAssertEqual(made.result.disposition, .succeeded)
        XCTAssertEqual(try Data(contentsOf: plan.destination.appendingPathComponent("Outer/Folder/One")), Data("original".utf8))
        XCTAssertFalse(FileManager().fileExists(atPath: plan.destination.appendingPathComponent("Other").path))
        let id = try required(made.recordID)
        let ordinaryRequirement = try await f.engine().undoAccessRequirement(recordID: id)
        XCTAssertNil(ordinaryRequirement)
        let undone = await f.engine().undo(recordID: id); XCTAssertEqual(undone.result.disposition, .succeeded)
        await session.close()
    }

    func testPublicOneFileExtractionIsHeldByDefaultAndMarkedArchiveHasGuardedColdUndo() async throws {
        let body = Data((0..<65_539).map { UInt8(truncatingIfNeeded: $0 * 17) })
        let f = try ExportFixture([.init(name: "Parent/Code.bin", body: body, deflated: true)])
        let sourceMark = Data("0086;65000001;Traverse-Generated;7BA9C2E3-19E7-46CE-A3BC-ECD4A33A3B6B".utf8)
        XCTAssertEqual(sourceMark.withUnsafeBytes { setxattr(f.source.path, "com.apple.quarantine",
            $0.baseAddress, $0.count, 0, XATTR_CREATE) }, 0)
        let selected = try required(try await f.selection(["Parent/Code.bin"]).first)
        do {
            _ = try await f.publicFilePlan(selected, f.engine())
            XCTFail("Default engine accepted public extraction")
        } catch { XCTAssertEqual(error as? FileOperationFailure, .unsupported) }
        let engine = f.engine(publicZIP: .sourceQualification)
        let plan = try await f.publicFilePlan(selected, engine, name: "Delivered.bin")
        let made = await engine.performZIPRootExport(plan), id = try required(made.recordID)
        XCTAssertEqual(made.result.disposition, .succeeded)
        XCTAssertEqual(try Data(contentsOf: plan.destination), body)
        XCTAssertNotNil(try plan.destination.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties)
        let record = try required(OperationJournal(f.history).inspectRecord(id))
        XCTAssertEqual(record.version, 15)
        XCTAssertEqual(record.operation, "Extract ZIP")
        XCTAssertEqual(record.steps.first?.publicZIPExtractionMarkRequired, true)
        XCTAssertEqual(record.steps.first?.before.osManagedSecurityV1, true)
        XCTAssertEqual(record.steps.first?.after?.osManagedSecurityV1, true)
        let typed = try await engine.inspectGeneratedPublicCatalog(recordID: id)
        XCTAssertEqual(typed.version, 15)
        XCTAssertEqual(typed.purpose, "zipFile")
        XCTAssertEqual(typed.state, "committed")
        XCTAssertTrue(typed.requiresPublicQuarantine)
        let requirement = try required(try await engine.undoAccessRequirement(recordID: id))
        XCTAssertEqual(requirement.recordID, id)
        XCTAssertEqual(requirement.directory.standardizedFileURL.pathComponents, f.parent.standardizedFileURL.pathComponents)
        let observed = try required(OperationJournal(f.history).inspectRecord(id))
        XCTAssertEqual(observed.state, record.state)
        XCTAssertEqual(observed.revision, record.revision)
        do {
            _ = try await f.engine().undoAccessRequirement(recordID: id)
            XCTFail("A held v15 engine disclosed an Undo access requirement")
        } catch { XCTAssertEqual(error as? FileOperationFailure, .unsupported) }
        let defaultHistory = try await f.engine().inspectExistingHistory()
        XCTAssertFalse(try required(defaultHistory.records.first { $0.id == id }).canUndo)
        let downloadOnly = RecoverableFileOperations(journalDirectory: f.history,
            receivedDownloadPublicQuarantinePolicy: .sourceQualification)
        let downloadHistory = try await downloadOnly.inspectExistingHistory()
        XCTAssertFalse(try required(downloadHistory.records.first { $0.id == id }).canUndo)
        let history = try await engine.inspectExistingHistory()
        let offered = try required(history.records.first { $0.id == id })
        XCTAssertTrue(offered.canUndo)
        XCTAssertFalse(offered.canRecover)
        let writable = try await engine.recoveryRecords()
        XCTAssertTrue(try required(writable.records.first { $0.id == id }).canUndo)
        let held = await f.engine().undo(recordID: id)
        XCTAssertNotEqual(held.result.disposition, .succeeded)
        XCTAssertEqual(try Data(contentsOf: plan.destination), body)
        let undone = await f.engine(publicZIP: .sourceQualification).undo(recordID: id)
        XCTAssertEqual(undone.result.disposition, .succeeded)
        let after = try await engine.inspectGeneratedPublicCatalog(recordID: id)
        XCTAssertEqual(after.state, "undone")
        XCTAssertEqual(after.version, typed.version)
        XCTAssertEqual(after.purpose, typed.purpose)
        XCTAssertEqual(after.requiresPublicQuarantine, typed.requiresPublicQuarantine)
        XCTAssertFalse(FileManager().fileExists(atPath: plan.destination.path))
        XCTAssertTrue(FileManager().fileExists(atPath: f.source.path))
    }

    func testPublicOneFileColdUndoAccessDenialBeforeInverseKeepsCommittedRecord() async throws {
        let f = try ExportFixture([.init(name: "One", body: Data("body".utf8))])
        let selected = try required(try await f.selection(["One"]).first)
        let engine = f.engine(publicZIP: .sourceQualification)
        let plan = try await f.publicFilePlan(selected, engine)
        let made = await engine.performZIPRootExport(plan), id = try required(made.recordID)
        XCTAssertEqual(made.result.disposition, .succeeded)
        let before = try required(OperationJournal(f.history).inspectRecord(id))
        XCTAssertEqual(chmod(f.parent.path, 0o000), 0)
        defer { _ = chmod(f.parent.path, 0o700) }
        let denied = await f.engine(publicZIP: .sourceQualification).undo(recordID: id)
        XCTAssertEqual(chmod(f.parent.path, 0o700), 0)
        XCTAssertEqual(denied.result.items.first?.status, .failed(.accessDenied))
        let after = try required(OperationJournal(f.history).inspectRecord(id))
        XCTAssertEqual(after.state, "committed")
        XCTAssertEqual(after.revision, before.revision)
        XCTAssertEqual(after.steps.first?.undone, false)
        XCTAssertEqual(try Data(contentsOf: plan.destination), Data("body".utf8))
        let requirement = try required(try await engine.undoAccessRequirement(recordID: id))
        XCTAssertEqual(requirement.directory.standardizedFileURL.pathComponents, f.parent.standardizedFileURL.pathComponents)
        let undone = await f.engine(publicZIP: .sourceQualification).undo(recordID: id)
        XCTAssertEqual(undone.result.disposition, .succeeded)
    }

    func testPublicOneFileAccessDenialAfterInverseIntentNeedsReview() async throws {
        let f = try ExportFixture([.init(name: "One", body: Data("body".utf8))])
        let selected = try required(try await f.selection(["One"]).first)
        let engine = f.engine(publicZIP: .sourceQualification)
        let plan = try await f.publicFilePlan(selected, engine)
        let made = await engine.performZIPRootExport(plan), id = try required(made.recordID)
        XCTAssertEqual(made.result.disposition, .succeeded)
        var hooks = RecoveryHooks()
        hooks.beforeExclusiveRename = { _, _ in throw FileOperationFailure.accessDenied }
        let denied = await f.engine(hooks, publicZIP: .sourceQualification).undo(recordID: id)
        XCTAssertEqual(denied.result.items.first?.status, .failed(.accessDenied))
        let record = try required(OperationJournal(f.history).inspectRecord(id))
        XCTAssertEqual(record.state, "needsReview")
        XCTAssertEqual(record.steps.first?.undone, false)
        XCTAssertEqual(try Data(contentsOf: plan.destination), Data("body".utf8))
        do {
            _ = try await engine.undoAccessRequirement(recordID: id)
            XCTFail("Needs Review v15 record offered a committed Undo access requirement")
        } catch { XCTAssertEqual(error as? FileOperationFailure, .recoveryUncertain) }
    }

    func testPublicOneFileUnmarkedSourceKeepsNativeStageMarkAndRecordsItsPresence() async throws {
        let native = Data("0081;65000001;NativeStage;7BA9C2E3-19E7-46CE-A3BC-ECD4A33A3B6B".utf8)
        for nativeMark in [false, true] {
            let f = try ExportFixture([.init(name: "One", body: Data("body".utf8))])
            var hooks = RecoveryHooks()
            if nativeMark {
                hooks.archiveProduction.stage = { stage, payload in
                    if stage == .payloadCreated {
                        guard native.withUnsafeBytes({ setxattr(payload.path, "com.apple.quarantine",
                            $0.baseAddress, $0.count, 0, XATTR_CREATE) }) == 0 else {
                            throw FileOperationFailure.ioFailure
                        }
                    }
                }
            }
            let selected = try required(try await f.selection(["One"]).first)
            let engine = f.engine(hooks, publicZIP: .sourceQualification)
            let plan = try await f.publicFilePlan(selected, engine)
            let made = await engine.performZIPRootExport(plan), id = try required(made.recordID)
            XCTAssertEqual(made.result.disposition, .succeeded)
            let record = try required(OperationJournal(f.history).inspectRecord(id))
            XCTAssertEqual(record.version, 15)
            XCTAssertEqual(record.steps.first?.publicZIPExtractionMarkRequired, nativeMark)
            let properties = try plan.destination.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties
            XCTAssertEqual(properties?.isEmpty == false, nativeMark)
            let undone = await f.engine(publicZIP: .sourceQualification).undo(recordID: id)
            XCTAssertEqual(undone.result.disposition, .succeeded)
        }
    }

    func testPublicOneFileMarkedStageMarkLossBeforeReceiptRefusesPublication() async throws {
        let f = try ExportFixture([.init(name: "One", body: Data("body".utf8))])
        let sourceMark = Data("0081;65000001;Traverse-Generated;7BA9C2E3-19E7-46CE-A3BC-ECD4A33A3B6B".utf8)
        XCTAssertEqual(sourceMark.withUnsafeBytes { setxattr(f.source.path, "com.apple.quarantine",
            $0.baseAddress, $0.count, 0, XATTR_CREATE) }, 0)
        var hooks = RecoveryHooks()
        hooks.archiveProduction.stage = { stage, payload in
            if stage == .produced {
                guard removexattr(payload.path, "com.apple.quarantine", 0) == 0 else {
                    throw FileOperationFailure.ioFailure
                }
            }
        }
        let selected = try required(try await f.selection(["One"]).first)
        let engine = f.engine(hooks, publicZIP: .sourceQualification)
        let plan = try await f.publicFilePlan(selected, engine)
        let made = await engine.performZIPRootExport(plan)
        XCTAssertNotEqual(made.result.disposition, .succeeded)
        XCTAssertFalse(FileManager().fileExists(atPath: plan.destination.path))
        XCTAssertNotNil(try f.source.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties)
    }

    func testPublicOneFileColdUndoRefusesLostRequiredMark() async throws {
        let f = try ExportFixture([.init(name: "One", body: Data("body".utf8))])
        let sourceMark = Data("0081;65000001;Traverse-Generated;7BA9C2E3-19E7-46CE-A3BC-ECD4A33A3B6B".utf8)
        XCTAssertEqual(sourceMark.withUnsafeBytes { setxattr(f.source.path, "com.apple.quarantine",
            $0.baseAddress, $0.count, 0, XATTR_CREATE) }, 0)
        let selected = try required(try await f.selection(["One"]).first)
        let engine = f.engine(publicZIP: .sourceQualification)
        let plan = try await f.publicFilePlan(selected, engine)
        let made = await engine.performZIPRootExport(plan), id = try required(made.recordID)
        XCTAssertEqual(made.result.disposition, .succeeded)
        XCTAssertEqual(removexattr(plan.destination.path, "com.apple.quarantine", 0), 0)
        let history = try await f.engine(publicZIP: .sourceQualification).inspectExistingHistory()
        XCTAssertTrue(try required(history.records.first { $0.id == id }).canUndo)
        let refused = await f.engine(publicZIP: .sourceQualification).undo(recordID: id)
        XCTAssertNotEqual(refused.result.disposition, .succeeded)
        XCTAssertEqual(try Data(contentsOf: plan.destination), Data("body".utf8))
        XCTAssertTrue(FileManager().fileExists(atPath: f.source.path))
    }

    func testPublicOneFilePostRenameMarkLossHoldsRecovery() async throws {
        let f = try ExportFixture([.init(name: "One", body: Data("body".utf8))])
        let sourceMark = Data("0081;65000001;Traverse-Generated;7BA9C2E3-19E7-46CE-A3BC-ECD4A33A3B6B".utf8)
        XCTAssertEqual(sourceMark.withUnsafeBytes { setxattr(f.source.path, "com.apple.quarantine",
            $0.baseAddress, $0.count, 0, XATTR_CREATE) }, 0)
        let published = f.parent.appendingPathComponent("One")
        var hooks = RecoveryHooks()
        hooks.afterRename = { _ = removexattr(published.path, "com.apple.quarantine", 0) }
        let selected = try required(try await f.selection(["One"]).first)
        let engine = f.engine(hooks, publicZIP: .sourceQualification)
        let plan = try await f.publicFilePlan(selected, engine)
        let made = await engine.performZIPRootExport(plan), id = try required(made.recordID)
        XCTAssertNotEqual(made.result.disposition, .succeeded)
        XCTAssertEqual(try Data(contentsOf: published), Data("body".utf8))
        let record = try required(OperationJournal(f.history).inspectRecord(id))
        XCTAssertEqual(record.version, 15)
        XCTAssertEqual(record.state, "needsReview")
        XCTAssertNil(record.steps.first?.after)
        let recovery = await f.engine(publicZIP: .sourceQualification).recover(recordID: id)
        XCTAssertNotEqual(recovery.result.disposition, .succeeded)
        XCTAssertEqual(try Data(contentsOf: published), Data("body".utf8))
    }

    func testInterruptedPublicOneFileKeepsDirectRecoveryHeld() async throws {
        let body = Data("Generated ZIP member".utf8)
        let f = try ExportFixture([.init(name: "One", body: body)])
        let sourceMark = Data("0081;65000001;Traverse-Generated;7BA9C2E3-19E7-46CE-A3BC-ECD4A33A3B6B".utf8)
        XCTAssertEqual(sourceMark.withUnsafeBytes { setxattr(f.source.path, "com.apple.quarantine",
            $0.baseAddress, $0.count, 0, XATTR_CREATE) }, 0)
        let destination = f.parent.appendingPathComponent("One")
        var hooks = RecoveryHooks()
        hooks.beforeSync = { url in
            if url == destination { throw FileOperationFailure.ioFailure }
        }
        let selected = try required(try await f.selection(["One"]).first)
        let engine = f.engine(hooks, publicZIP: .sourceQualification)
        let plan = try await f.publicFilePlan(selected, engine)
        let interrupted = await engine.performZIPRootExport(plan)
        let id = try required(interrupted.recordID)
        XCTAssertNotEqual(interrupted.result.disposition, .succeeded)
        XCTAssertEqual(try Data(contentsOf: destination), body)

        let cold = f.engine(publicZIP: .sourceQualification)
        let before = try await cold.inspectExistingHistory()
        XCTAssertEqual(before.records.first(where: { $0.id == id })?.state, "needsReview")
        XCTAssertFalse(before.records.first(where: { $0.id == id })?.canRecover ?? true)
        let revision = try required(OperationJournal(f.history).inspectRecord(id)?.revision)
        let recovery = await cold.recover(recordID: id)
        XCTAssertEqual(recovery.result.items.first?.status, .failed(.unsupported))
        XCTAssertEqual(try Data(contentsOf: destination), body)
        let after = try await cold.inspectExistingHistory()
        XCTAssertEqual(after.records.first(where: { $0.id == id })?.state, "needsReview")
        XCTAssertEqual(try OperationJournal(f.history).inspectRecord(id)?.revision, revision)
    }

    func testPublicOneFileRefusesLateDestinationAndChangedSource() async throws {
        for changeSource in [false, true] {
            let f = try ExportFixture([.init(name: "One", body: Data("archive body".utf8))])
            let selected = try required(try await f.selection(["One"]).first)
            let engine = f.engine(publicZIP: .sourceQualification)
            let plan = try await f.publicFilePlan(selected, engine)
            if changeSource {
                try Data("changed archive".utf8).write(to: f.source)
            } else {
                try Data("Keep".utf8).write(to: plan.destination)
            }
            let made = await engine.performZIPRootExport(plan)
            XCTAssertNotEqual(made.result.disposition, .succeeded)
            if changeSource { XCTAssertFalse(FileManager().fileExists(atPath: plan.destination.path)) }
            else { XCTAssertEqual(try Data(contentsOf: plan.destination), Data("Keep".utf8)) }
        }
    }
}
