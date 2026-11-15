import CoreServices
import CryptoKit
import Darwin
import Foundation
@_spi(ArchiveProduction) @testable import FileOperations
@testable import LocalStorage
import Testing

struct TARCompressedCreationTests {
    private struct Fixture {
        let root: URL, folder: URL, file: URL
        let bytes = Data((0..<65_539).map { UInt8(truncatingIfNeeded: $0 * 19) })
        init() throws {
            root = try LocalStorageTestFixtures.directory()
            folder = root.appendingPathComponent("Folder 日本", isDirectory: true)
            file = folder.appendingPathComponent("data.bin")
            try FileManager().createDirectory(at: folder.appendingPathComponent("Empty"), withIntermediateDirectories: true)
            try bytes.write(to: file, options: .withoutOverwriting)
        }
        func output(_ name: String) throws -> Int32 {
            let fd = open(root.appendingPathComponent(name).path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            try #require(fd >= 0); return fd
        }
    }
    @Test(arguments: [TARCompression.gzipFast, .gzipBalanced, .gzipSmallest, .bzip2Fast, .bzip2Balanced, .bzip2Smallest])
    func sharedPublisherNativeCompressedTARAndColdUndo(compression: TARCompression) async throws {
        let f = try Fixture(), history = f.root.appendingPathComponent("history")
        let held = RecoverableFileOperations(journalDirectory: history, strictPortableTARCreationPolicy: .nativeCreateQualification)
        let observed = try await held.observeSelection([f.folder])
        await #expect(throws: FileOperationFailure.unsupported) {
            try await held.prepareTARCreation(sources: [f.folder], parent: f.root, name: "Created." + compression.fileExtension, compression: compression, observing: observed)
        }
        let engine = RecoverableFileOperations(journalDirectory: history, tarGzipCreationPolicy: .developmentNativeCreate, tarBzip2CreationPolicy: .developmentNativeCreate)
        let plan = try await engine.prepareTARCreation(sources: [f.folder], parent: f.root,
            name: "Created." + compression.fileExtension, compression: compression, observing: observed)
        let result = await engine.performArchiveCreation(plan)
        #expect(result.result.disposition == .succeeded)
        let id = try #require(result.recordID), output = f.root.appendingPathComponent("Created." + compression.fileExtension)
        let bytes = try Data(contentsOf: output)
        if compression.authoredFormat == .strictPortableTARGzip {
            #expect(bytes.prefix(3) == Data([0x1f, 0x8b, 8]))
            #expect(bytes[4..<8].allSatisfy { $0 == 0 })
        } else { #expect(bytes.prefix(4) == Data([66, 90, 104, UInt8(48 + compression.level!)])) }
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-xOf", output.path, "Folder 日本/data.bin"]
        process.standardOutput = pipe
        try process.run()
        let extracted = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        #expect(process.terminationStatus == 0 && extracted == f.bytes)
        let cache = f.root.appendingPathComponent("cache")
        try FileManager().createDirectory(at: cache, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let pool = TARCompressedPreparationPool(cacheDirectory: cache, activity: .init())
        let session = try await TARArchiveReader(compressedPool: pool).prepareCompressed(output)
        #expect(session.summary.files == 1 && session.summary.folders == 2)
        await session.close(); #expect(await pool.closeAndDrain())
        let cold = RecoverableFileOperations(journalDirectory: history, tarGzipCreationPolicy: .developmentNativeCreate, tarBzip2CreationPolicy: .developmentNativeCreate)
        let undone = await cold.undo(recordID: id)
        #expect(undone.result.disposition == .succeeded && !FileManager().fileExists(atPath: output.path))
        #expect(try Data(contentsOf: f.file) == f.bytes)
    }

    @Test(arguments: [TARCompression.gzipBalanced, .bzip2Balanced])
    func markedInputKeepsItsProtectionAndOutputKeepsItsOwnStageProtection(compression: TARCompression) async throws {
        let f = try Fixture(), history = f.root.appendingPathComponent("history")
        @Sendable func mark(_ url: URL, agent: String) throws {
            var values = URLResourceValues()
            values.quarantineProperties = [
                kLSQuarantineAgentNameKey as String: agent,
                kLSQuarantineTypeKey as String: kLSQuarantineTypeOtherDownload as String,
                kLSQuarantineTimeStampKey as String: Date()
            ]
            var target = url; try target.setResourceValues(values)
        }
        try mark(f.file, agent: "Generated compressed input")
        let sourceProperties = try #require(try f.file.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties)
        var hooks = RecoveryHooks()
        hooks.archiveProduction.stage = { stage, payload in
            if stage == .payloadCreated { try mark(payload, agent: "Generated compressed stage") }
        }
        let engine = RecoverableFileOperations(journalDirectory: history, hooks: hooks,
            tarGzipCreationPolicy: .developmentNativeCreate, tarBzip2CreationPolicy: .developmentNativeCreate)
        let selection = try await engine.observeSelection([f.folder])
        let plan = try await engine.prepareTARCreation(sources: [f.folder], parent: f.root,
            name: "Marked." + compression.fileExtension, compression: compression, observing: selection)
        let result = await engine.performArchiveCreation(plan)
        #expect(result.result.disposition == .succeeded)
        let output = f.root.appendingPathComponent("Marked." + compression.fileExtension)
        let outputProperties = try #require(try output.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties)
        #expect(outputProperties[kLSQuarantineAgentNameKey as String] as? String == "Generated compressed stage")
        let inputProperties = try #require(try f.file.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties)
        #expect((inputProperties as NSDictionary).isEqual(to: sourceProperties))
        let cold = RecoverableFileOperations(journalDirectory: history)
        let undone = await cold.undo(recordID: try #require(result.recordID))
        #expect(undone.result.disposition == .succeeded && !FileManager().fileExists(atPath: output.path))
        #expect(try Data(contentsOf: f.file) == f.bytes)
    }

    @Test(arguments: [TARCompression.gzipBalanced, .bzip2Balanced])
    func corruptionQuotaAndCancellationReturnNoReceipt(compression: TARCompression) throws {
        for failure in 0..<3 {
            let f = try Fixture()
            var hooks = ZIPCreationHooks()
            if failure == 0 {
                hooks.beforeValidation = { fd in
                    var byte: UInt8 = 255
                    guard pwrite(fd, &byte, 1, 0) == 1 else { throw FileOperationFailure.ioFailure }
                }
            } else if failure == 1 { hooks.maximumEncodedBytes = 20 }
            else { hooks.beforeSourceRead = { _ in throw CancellationError() } }
            let producer = try PreparedTARCreation([f.folder], compression: compression, check: {}, hooks: hooks)
            let fd = try f.output("Failed.tar.gz"); defer { close(fd) }
            #expect(throws: (any Error).self) { try producer.produce(into: fd, check: {}, progress: { _, _ in }) }
            #expect(try Data(contentsOf: f.file) == f.bytes)
        }
    }

    @Test(arguments: [TARCompression.gzipBalanced, .bzip2Balanced])
    func metadataMustDescribeTheActualEmittedStream(compression: TARCompression) throws {
        let f = try Fixture(), fd = try f.output("Invalid.tar.gz"); defer { close(fd) }
        let stream = try TAROutputStream(fd, encoding: compression.encoding, hooks: .init(), check: {})
        let header = try TARCreationHeader(path: "bad.txt", directory: false, bytes: 0, seconds: 0, index: 0)
        try stream.write(header.encoded, metadata: true, check: {})
        // A wrong size cannot be hidden by a correct compression round trip.
        try stream.write(Data(repeating: 65, count: 512), check: {})
        try stream.write(Data(repeating: 0, count: 1024), metadata: true, check: {})
        try stream.finish(check: {})
        #expect(throws: TAROutputStream.Failure.mismatch) { try stream.verify(check: {}) }
        #expect(stream.peakCodecHeap > 0 && stream.peakCodecHeap <= (compression.authoredFormat == .strictPortableTARGzip ? 1 : 8) << 20)
    }

    @Test(arguments: [TARCompression.gzipBalanced, .bzip2Balanced])
    func trailingMembersAndBytesAreRefused(compression: TARCompression) throws {
        let f = try Fixture(), plainFD = try f.output("Plain.tar"), gzipFD = try f.output("Encoded.tar.gz")
        defer { close(plainFD); close(gzipFD) }
        _ = try PreparedTARCreation([f.folder], check: {}).produce(into: plainFD, check: {}, progress: { _, _ in })
        _ = try PreparedTARCreation([f.folder], compression: compression, check: {}).produce(into: gzipFD, check: {}, progress: { _, _ in })
        let plain = try Data(contentsOf: f.root.appendingPathComponent("Plain.tar"))
        let encoded = try Data(contentsOf: f.root.appendingPathComponent("Encoded.tar.gz"))
        var badCRC = encoded; badCRC[badCRC.count - 5] ^= 1
        for (index, bytes) in [encoded + encoded, encoded + Data([0]), Data(encoded.dropLast()), badCRC].enumerated() {
            let name = "Invalid-\(index).compressed"
            try bytes.write(to: f.root.appendingPathComponent(name), options: .withoutOverwriting)
            let fd = open(f.root.appendingPathComponent(name).path, O_RDONLY | O_NOFOLLOW)
            try #require(fd >= 0); defer { close(fd) }
            #expect(throws: (any Error).self) {
                try CompressedArchiveEncoder.verify(fd, codec: compression.authoredFormat == .strictPortableTARGzip ? .gzip : .bzip2, rawBytes: UInt64(plain.count), encodedBytes: UInt64(bytes.count),
                    expected: Data(SHA256.hash(data: plain)), check: {})
            }
        }
    }
}
