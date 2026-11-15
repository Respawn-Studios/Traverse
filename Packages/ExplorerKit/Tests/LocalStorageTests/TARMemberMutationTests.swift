import Foundation
import Darwin
@_spi(ArchiveProduction) @testable import FileOperations
@testable import LocalStorage
import Testing

struct TARMemberMutationTests {
    enum Action: String, CaseIterable, Sendable {
        case renameFile, renameFolder, removeFile, removeFolder, duplicateFile, duplicateFolder
        case moveFile, moveFolder, group, newFile, newFolder, add
    }
    private enum Member: Equatable { case file(Data), folder }
    private func snapshot(_ bytes: Data) throws -> [String: Member] {
        let parsed = try TARMetadataParser.parse(length: UInt64(bytes.count), check: {}, read: {
            bytes.subdata(in: Int($0)..<(Int($0) + $1))
        })
        return Dictionary(uniqueKeysWithValues: parsed.records.map {
            ($0.path, $0.kind == .directory ? .folder : .file(bytes.subdata(in: Int($0.dataOffset)..<Int($0.dataOffset + $0.bytes))))
        })
    }
    private func select(_ paths: [String], in session: TARArchiveSession) async throws -> TARMemberSelection {
        var ids = Set<TARItemID>()
        for path in paths {
            let components = path.split(separator: "/").map(String.init)
            let folder = try await session.folder(at: Array(components.dropLast()))
            let page = try await session.page(in: folder)
            let item = try #require(page.items.first { $0.path.utf8.elementsEqual(path.utf8) })
            ids.insert(item.id)
        }
        return try await session.selectionForMemberChanges(ids)
    }
    private func destination(_ path: String, in session: TARArchiveSession) async throws -> TARMemberDestination {
        try await session.destinationForMemberChanges(session.folder(at: path.split(separator: "/").map(String.init)))
    }

    @Test(arguments: Action.allCases, [(false, TARCompression.none), (true, .none), (false, .gzipBalanced), (true, .gzipBalanced), (false, .bzip2Balanced), (true, .bzip2Balanced)])
    func memberChangesVerifyExpectedContentsAndColdUndo(action: Action, variant: (original: Bool, compression: TARCompression)) async throws {
        let (original, compression) = variant
        let compressed = compression != .none
        let fixture = try TARTestFixture(pax: true, folderTree: true)
        let source: URL
        switch compression {
        case .none: source = fixture.source
        case .bzip2Balanced: source = try fixture.bzip2Source()
        default: source = try fixture.gzipSource()
        }
        let before = try Data(contentsOf: source), cache = fixture.root.appendingPathComponent("cache")
        try FileManager().createDirectory(at: cache, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let pool = TARCompressedPreparationPool(cacheDirectory: cache, activity: .init())
        let reader = TARArchiveReader(compressedPool: pool)
        let session = try await (compressed ? reader.prepareCompressed(source) : reader.open(source))
        func flow() async throws {
        var expected = try snapshot(fixture.bytes)
        func relocated(_ root: String, to target: String, duplicate: Bool = false) {
            for (path, member) in Array(expected) where path == root || path.hasPrefix(root + "/") {
                if !duplicate { expected.removeValue(forKey: path) }
                expected[target + path.dropFirst(root.count)] = member
            }
        }
        let mutation: TARMemberMutation
        switch action {
        case .renameFile:
            mutation = .rename(try await select(["data.json"], in: session), to: "Renamed.json")
            relocated("data.json", to: "Renamed.json")
        case .renameFolder:
            mutation = .rename(try await select(["Folder"], in: session), to: "日本のフォルダ")
            relocated("Folder", to: "日本のフォルダ")
        case .removeFile, .removeFolder:
            let path = action == .removeFile ? "data.json" : "Folder"
            mutation = .remove(try await select([path], in: session))
            for key in expected.keys.filter({ $0 == path || $0.hasPrefix(path + "/") }) { expected.removeValue(forKey: key) }
        case .duplicateFile, .duplicateFolder:
            let path = action == .duplicateFile ? "data.json" : "Folder"
            mutation = .duplicate(try await select([path], in: session), into: nil)
            relocated(path, to: action == .duplicateFile ? "data (1).json" : "Folder (1)", duplicate: true)
        case .moveFile, .moveFolder:
            let path = action == .moveFile ? "data.json" : "Folder"
            mutation = .move(try await select([path], in: session), into: try await destination("Destination", in: session))
            relocated(path, to: "Destination/" + path)
        case .group:
            mutation = .group(try await select(["data.json", "other.bin"], in: session), name: "Grouped")
            relocated("data.json", to: "Grouped/data.json"); relocated("other.bin", to: "Grouped/other.bin")
            expected["Grouped"] = .folder
        case .newFile:
            mutation = .newFile(try await destination("", in: session), name: "fresh.json")
            expected["fresh.json"] = .file(Data())
        case .newFolder:
            mutation = .newFolder(try await destination("", in: session), name: "New Folder")
            expected["New Folder"] = .folder
        case .add:
            let incoming = fixture.root.appendingPathComponent("data.json")
            let directory = fixture.root.appendingPathComponent("Added", isDirectory: true)
            try FileManager().createDirectory(at: directory.appendingPathComponent("Empty"), withIntermediateDirectories: true)
            try Data("new local file\n".utf8).write(to: incoming, options: .withoutOverwriting)
            try Data("nested local file\n".utf8).write(to: directory.appendingPathComponent("nested.txt"), options: .withoutOverwriting)
            mutation = .add(try await destination("", in: session), sources: [incoming, directory])
            expected["data (1).json"] = .file(Data("new local file\n".utf8))
            expected["Added"] = .folder; expected["Added/Empty"] = .folder
            expected["Added/nested.txt"] = .file(Data("nested local file\n".utf8))
        }
        let history = fixture.root.appendingPathComponent("history")
        let engine = RecoverableFileOperations(journalDirectory: history,
            strictPortableTARCreationPolicy: .nativeCreateQualification,
            tarGzipCreationPolicy: .developmentNativeCreate,
            tarBzip2CreationPolicy: .developmentNativeCreate,
            authoredTAROriginalUpdatePolicy: .developmentNativeStage,
            authoredTARGzipOriginalUpdatePolicy: .developmentNativeStage,
            authoredTARBzip2OriginalUpdatePolicy: .developmentNativeStage)
        let observed = try await engine.observeSelection([source] + mutation.addedSources)
        let result: RecoverableOperationResult, output: URL
        if original {
            let plan = try await engine.prepareTARMemberMutationOriginal(mutation, observing: observed)
            result = await engine.performArchiveOriginalUpdate(plan); output = source
        } else {
            let plan = try await engine.prepareTARMemberMutationCopy(mutation, outputName: "Edited." + compression.fileExtension, observing: observed)
            result = await engine.performArchiveCreation(plan); output = plan.destination
            #expect(try Data(contentsOf: source) == before)
        }
        #expect(result.result.disposition == .succeeded)
        let decoded = try compression == .none ? Data(contentsOf: output)
            : compression == .bzip2Balanced ? TARTestFixture.decodedBzip2(output) : TARTestFixture.decodedGzip(output)
        #expect(try snapshot(decoded) == expected)
        let id = try #require(result.recordID)
        let cold = RecoverableFileOperations(journalDirectory: history,
            authoredTAROriginalUpdatePolicy: .developmentNativeStage,
            authoredTARGzipOriginalUpdatePolicy: .developmentNativeStage,
            authoredTARBzip2OriginalUpdatePolicy: .developmentNativeStage)
        let undone = await cold.undo(recordID: id)
        #expect(undone.result.disposition == .succeeded)
        #expect(try Data(contentsOf: source) == before)
        if !original { #expect(!FileManager().fileExists(atPath: output.path)) }
        }
        try await flow()
        await session.close(); #expect(await pool.closeAndDrain())
    }

    @Test func conflictsSelfDescentsAndForeignDestinationsRefuseBeforePublication() async throws {
        let fixture = try TARTestFixture(folderTree: true), other = try TARTestFixture()
        let session = try await TARArchiveReader().open(fixture.source)
        let foreign = try await TARArchiveReader().open(other.source)
        let file = try await select(["data.json"], in: session), folder = try await select(["Folder"], in: session)
        let root = try await destination("", in: session)
        let refused: [TARMemberMutation] = [
            .rename(file, to: "other.bin"), .newFolder(root, name: "Folder"), .newFile(root, name: "other.bin"),
            .move(folder, into: try await destination("Folder/Nested", in: session)),
            .move(file, into: try await destination("", in: foreign)),
            .rename(file, to: "../escape"), .newFile(root, name: "bad\nname")
        ]
        for mutation in refused {
            #expect(throws: (any Error).self) { try PreparedTARMemberMutation(mutation, check: {}) }
        }
        #expect(try Data(contentsOf: fixture.source) == fixture.bytes)
        #expect(try Data(contentsOf: other.source) == other.bytes)
    }

    @Test func caseOnlyRenameAndCoveredSelectionPreserveExactMemberData() async throws {
        let fixture = try TARTestFixture(folderTree: true)
        let session = try await TARArchiveReader().open(fixture.source)
        let covered = try await select(["Folder", "Folder/Nested/note.json"], in: session)
        #expect(covered.archivePaths == ["Folder"] && covered.coveredSelectionCount == 1)
        let change = TARMemberMutation.rename(try await select(["data.json"], in: session), to: "Data.json")
        let producer = try PreparedTARMemberMutation(change, check: {})
        let (output, fd) = try fixture.output(); defer { Darwin.close(fd) }
        _ = try producer.produce(into: fd, check: {}, progress: { _, _ in })
        let result = try snapshot(Data(contentsOf: output))
        #expect(result["Data.json"] == .file(Data("{}\n".utf8)) && result["data.json"] == nil)
    }

    @Test func changedLocalAdditionRefusesAndKeepsOriginal() async throws {
        let fixture = try TARTestFixture()
        let added = fixture.root.appendingPathComponent("Added.txt")
        try Data("before".utf8).write(to: added, options: .withoutOverwriting)
        let session = try await TARArchiveReader().open(fixture.source)
        let change = TARMemberMutation.add(try await destination("", in: session), sources: [added])
        let producer = try PreparedTARMemberMutation(change, check: {})
        try Data("changed".utf8).write(to: added)
        #expect(throws: FileOperationFailure.sourceChanged) { try producer.validate(check: {}) }
        #expect(try Data(contentsOf: fixture.source) == fixture.bytes)
    }

    @Test(arguments: [Action.renameFolder, .duplicateFolder, .moveFolder, .removeFolder])
    func gnuLongNamesImplicitParentsAndRootRecordsSurvive(action: Action) async throws {
        let leaf = String(repeating: "n", count: 110) + ".txt", path = "Implicit/" + leaf
        let rootRecord = TARTestFixture.member("./", body: Data(), type: 53)
        var member = TARTestFixture.member("placeholder", body: Data("gnu body\n".utf8))
        member.replaceSubrange(257..<265, with: Array("ustar ".utf8) + [32, 0])
        member.replaceSubrange(345..<357, with: "14524770401\0".utf8)
        member.replaceSubrange(357..<369, with: "14524770402\0".utf8)
        var header = Data(member.prefix(512)); TARMemberHeader.checksum(&header)
        member.replaceSubrange(0..<512, with: header)
        let extensionRecord = TARTestFixture.member("././@LongLink", body: Data(path.utf8) + Data([0]), type: 76)
        let destinationRecord = TARTestFixture.member("Destination/", body: Data(), type: 53)
        let fixture = try TARTestFixture(rawMembers: extensionRecord + member + rootRecord + destinationRecord)
        let session = try await TARArchiveReader().open(fixture.source)
        let selected = try await select(["Implicit"], in: session)
        let mutation: TARMemberMutation
        let target: String?
        switch action {
        case .renameFolder: target = "日本のフォルダ/" + leaf; mutation = .rename(selected, to: "日本のフォルダ")
        case .duplicateFolder: target = "Implicit (1)/" + leaf; mutation = .duplicate(selected, into: nil)
        case .moveFolder: target = "Destination/Implicit/" + leaf; mutation = .move(selected, into: try await destination("Destination", in: session))
        default: target = nil; mutation = .remove(selected)
        }
        let producer = try PreparedTARMemberMutation(mutation, check: {})
        let (output, fd) = try fixture.output(); defer { Darwin.close(fd) }
        _ = try producer.produce(into: fd, check: {}, progress: { _, _ in })
        let bytes = try Data(contentsOf: output), values = try snapshot(bytes)
        #expect(bytes.range(of: rootRecord) != nil && bytes.range(of: destinationRecord) != nil)
        if let target {
            #expect(values[target] == .file(Data("gnu body\n".utf8)))
            let parsed = try TARMetadataParser.parse(length: UInt64(bytes.count), check: {}, read: { bytes.subdata(in: Int($0)..<(Int($0) + $1)) })
            let record = try #require(parsed.records.first { $0.path == target })
            let retained = bytes.subdata(in: Int(record.headerOffset)..<Int(record.headerOffset + 512))
            #expect(retained[345..<369] == header[345..<369])
            #expect(retained[100..<124] == header[100..<124] && retained[265..<345] == header[265..<345])
        }
        #expect((values[path] != nil) == (action == .duplicateFolder))
        // Read-only interoperability with macOS's independent archive reader.
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-tf", output.path]; process.standardOutput = pipe; process.standardError = pipe
        try process.run(); process.waitUntilExit()
        let listing = pipe.fileHandleForReading.readDataToEndOfFile()
        #expect(process.terminationStatus == 0)
        if let target { #expect(String(decoding: listing, as: UTF8.self).contains(target)) }
    }

    @Test func paxPathGrowthPreservesOtherAttributesAcrossPaddingBoundary() async throws {
        let owner = TARMemberHeader.attribute("uname", String(repeating: "owner", count: 60))
        let unchanged = owner + TARMemberHeader.attribute("uid", "123456789")
            + TARMemberHeader.attribute("mtime", "1700000000.125") + TARMemberHeader.attribute("size", "3")
        let pax = unchanged + TARMemberHeader.attribute("path", "A/data.json")
        #expect(pax.count < 512)
        let fixture = try TARTestFixture(rawMembers: TARTestFixture.member("Pax", body: pax, type: 120)
            + TARTestFixture.member("placeholder", body: Data("{}\n".utf8), declaredSize: 0))
        let session = try await TARArchiveReader().open(fixture.source)
        let name = String(repeating: "界", count: 80), target = name + "/data.json"
        let producer = try PreparedTARMemberMutation(.rename(try await select(["A"], in: session), to: name), check: {})
        let (output, fd) = try fixture.output(); defer { Darwin.close(fd) }
        _ = try producer.produce(into: fd, check: {}, progress: { _, _ in })
        let bytes = try Data(contentsOf: output)
        #expect(try snapshot(bytes)[target] == .file(Data("{}\n".utf8)))
        #expect(bytes.range(of: unchanged) != nil)
        #expect(bytes.count == fixture.bytes.count + 512)
    }

    @Test func collidingLeavesEmptyArchiveAndNontextFailureRemainGuarded() async throws {
        let fixture = try TARTestFixture(rawMembers:
            TARTestFixture.member("A/same.txt", body: Data("a".utf8))
            + TARTestFixture.member("B/same.txt", body: Data("b".utf8))
            + TARTestFixture.member("Destination/", body: Data(), type: 53))
        let session = try await TARArchiveReader().open(fixture.source)
        let chosen = try await select(["A/same.txt", "B/same.txt"], in: session)
        let target = try await destination("Destination", in: session)
        #expect(throws: (any Error).self) { try PreparedTARMemberMutation(.move(chosen, into: target), check: {}) }
        let selected = try await select(["A", "B", "Destination"], in: session)
        let empty = try PreparedTARMemberMutation(.remove(selected), check: {})
        let (output, fd) = try fixture.output(); defer { Darwin.close(fd) }
        _ = try empty.produce(into: fd, check: {}, progress: { _, _ in })
        #expect(try snapshot(Data(contentsOf: output)).isEmpty)
        let destination = fixture.root.appendingPathComponent("Cancelled.tar")
        let cancelledFD = Darwin.open(destination.path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        try #require(cancelledFD >= 0); defer { Darwin.close(cancelledFD) }
        let cancelled = try PreparedTARMemberMutation(.duplicate(chosen, into: nil), check: {},
            hooks: .init(beforeSourceRead: { _ in throw CancellationError() }))
        #expect(throws: CancellationError.self) { try cancelled.produce(into: cancelledFD, check: {}, progress: { _, _ in }) }
        #expect(try Data(contentsOf: fixture.source) == fixture.bytes)
    }
}
