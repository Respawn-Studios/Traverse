import CryptoKit
import Darwin
import Foundation
@_spi(ArchiveProduction) import FileOperations
import zlib

public enum ZIPCompression: String, Codable, CaseIterable, Sendable {
    case balanced, fast, store
    internal var method: UInt16 { self == .store ? 0 : 8 }
    internal var level: Int32 { self == .fast ? 1 : 6 }
}
public enum ZIPCreationFailure: Error, Equatable, Sendable {
    case unsupportedSource, limitOrPrivacy, resourceFork, sourceChanged, contentMismatch, codecUnavailable
    public var userMessage: String {
        switch self {
        case .unsupportedSource: "Choose local regular files and folders without links or cloud-only items."
        case .limitOrPrivacy: "This selection exceeds the current portable ZIP limits or includes a private location. Choose a smaller selection."
        case .resourceFork: "An item has resource-fork data that portable ZIP cannot preserve. Use the system Compress action for this selection."
        case .sourceChanged: "An item changed during ZIP preparation or creation. The originals are unchanged."
        case .contentMismatch: "The generated ZIP did not verify. It was not published; the originals are unchanged."
        case .codecUnavailable: "The compression engine could not finish this ZIP. The originals are unchanged."
        }
    }
}
internal struct ZIPCreationHooks: Sendable {
    var writeChunk = 65_536
    var failAfterBytes: UInt64?
    var maximumEncodedBytes: UInt64 = 1_024 * 1_024 * 1_024
    var beforeWrite: (@Sendable () throws -> Void)?
    var beforeSourceRead: (@Sendable (URL) throws -> Void)?
    var beforeValidation: (@Sendable (Int32) throws -> Void)?
}

internal final class PreparedZIPFile: NativeZIPCreationSourceWitness, Sendable {
    let preview: ArchiveProductionPreview
    var hasMarkedSource: Bool { inventory.hasMarkedSource }
    private let inventory: ZIPCreationInventory
    private let compression: ZIPCompression
    private let hooks: ZIPCreationHooks
    init(_ sources: [URL], compression: ZIPCompression, allowNativeMarkedSources: Bool = false,
         check: @Sendable () throws -> Void,
         hooks: ZIPCreationHooks = .init()) throws {
        let started = ProcessInfo.processInfo.systemUptime
        let inventory = try ZIPCreationInventory(sources,
            allowNativeMarkedSources: allowNativeMarkedSources) {
            try check()
            guard ProcessInfo.processInfo.systemUptime - started < 300 else { throw ZIPCreationFailure.limitOrPrivacy }
        }
        self.inventory = inventory; self.compression = compression; self.hooks = hooks
        preview = .init(files: inventory.files, folders: inventory.folders, logicalBytes: inventory.logical,
            longestPathBytes: inventory.nodes.map { $0.name.utf8.count }.max() ?? 0)
    }
    func validate(check: @Sendable () throws -> Void) throws {
        try validateInput(check: check)
    }
    private func validateInput(check: () throws -> Void) throws {
        do { try inventory.validate(check: check) }
        catch ZIPCreationFailure.sourceChanged { throw FileOperationFailure.sourceChanged }
    }
    func produce(into descriptor: Int32, check: @Sendable () throws -> Void,
                 progress: @Sendable (UInt64, Int) -> Void) throws -> ArchiveProducedNode {
        let started = ProcessInfo.processInfo.systemUptime
        func checkpoint() throws {
            try check()
            guard ProcessInfo.processInfo.systemUptime - started < 300 else { throw ZIPCreationFailure.limitOrPrivacy }
        }
        try validate(check: check)
        var initial = stat()
        guard fstat(descriptor, &initial) == 0, initial.st_mode & S_IFMT == S_IFREG,
              initial.st_uid == geteuid(), initial.st_nlink == 1, initial.st_size == 0 else { throw FileOperationFailure.destinationChanged }
        let writer = ZIPFileEncoder(descriptor, hooks: hooks)
        var witnesses: [String: ZIPEncodedNode] = [:], central = Data()
        do {
            let encoded = try ZIPNodeEncoder.append(inventory, compression: compression, writer: writer,
                hooks: hooks, check: checkpoint, progress: progress)
            for node in encoded {
                guard central.count <= (16 << 20) - node.centralEntry.count else { throw ZIPCreationFailure.limitOrPrivacy }
                central += node.centralEntry
                if !node.directory { witnesses[node.name] = node }
            }
            let centralOffset = writer.count
            try writer.write(central, check: checkpoint)
            var trailer = ZIPFileEncoder.le(0x06054b50, 4) + Data(repeating: 0, count: 4)
            trailer += ZIPFileEncoder.le(UInt64(inventory.nodes.count), 2); trailer += ZIPFileEncoder.le(UInt64(inventory.nodes.count), 2)
            trailer += ZIPFileEncoder.le(UInt64(central.count), 4); trailer += ZIPFileEncoder.le(centralOffset, 4); trailer += Data(repeating: 0, count: 2)
            try writer.write(trailer, check: checkpoint)
            try hooks.beforeValidation?(descriptor)
            try validateInput(check: checkpoint)
            var records: [ZIPPayloadRecord] = []
            func read(_ offset: UInt64, _ count: Int) throws -> Data {
                try checkpoint()
                guard offset <= writer.count, count >= 0, count <= 32 * 1_024 * 1_024,
                      UInt64(count) <= writer.count - offset else { throw ZIPCreationFailure.contentMismatch }
                var bytes = Data(count: count)
                try bytes.withUnsafeMutableBytes { buffer in
                    var completed = 0
                    while completed < count {
                        try checkpoint()
                        let result = pread(descriptor, buffer.baseAddress!.advanced(by: completed), min(65_536, count - completed), off_t(offset) + off_t(completed))
                        if result < 0 && errno == EINTR { continue }
                        guard result > 0 else { throw ZIPCreationFailure.contentMismatch }; completed += result
                    }
                }
                return bytes
            }
            let catalog = try ZIPMetadataParser.parse(length: writer.count, capture: { records.append($0) },
                cancelled: { (try? checkpoint()) == nil }, read: read)
            guard catalog.summary.files == inventory.files, catalog.summary.folders == inventory.folders,
                  catalog.summary.logicalBytes == inventory.logical, records.count == inventory.nodes.count else { throw ZIPCreationFailure.contentMismatch }
            for (record, node) in zip(records, encoded) {
                guard node.matches(record) else { throw ZIPCreationFailure.contentMismatch }
            }
            let layout = try ZIPContentVerifier.prepare(records, limits: .init(), check: checkpoint, read: read)
            for extent in layout.extents {
                try checkpoint(); var actual = SHA256()
                try ZIPContentDecoder.check(method: extent.record.method, packed: extent.record.packed, logical: extent.record.logical,
                    expectedCRC: extent.record.crc, check: checkpoint, read: { try read(extent.payload + $0, $1) }, decoded: { _ in },
                    consume: { actual.update(bufferPointer: $0) })
                if extent.record.kind == .file {
                    guard let witness = witnesses.removeValue(forKey: extent.record.name), witness.size == extent.record.logical,
                          witness.crc == extent.record.crc, witness.digest == Data(actual.finalize()) else { throw ZIPCreationFailure.contentMismatch }
                }
            }
            guard witnesses.isEmpty else { throw ZIPCreationFailure.contentMismatch }
            try validateInput(check: checkpoint); try checkpoint()
            guard fchmod(descriptor, 0o644) == 0 else { throw ZIPCreationInventory.failure() }
            var final = stat()
            guard fstat(descriptor, &final) == 0, final.st_dev == initial.st_dev, final.st_ino == initial.st_ino,
                  final.st_size == writer.count, final.st_nlink == 1, final.st_uid == geteuid() else { throw FileOperationFailure.destinationChanged }
            return .init(relative: "", device: final.st_dev, inode: final.st_ino, kind: S_IFREG,
                birthSeconds: final.st_birthtimespec.tv_sec, birthNanoseconds: final.st_birthtimespec.tv_nsec,
                changedSeconds: final.st_ctimespec.tv_sec, changedNanoseconds: final.st_ctimespec.tv_nsec,
                size: final.st_size, contentSHA256: writer.digest())
        } catch {
            try validateInput(check: checkpoint)
            if let failure = error as? ZIPCreationFailure {
                switch failure {
                case .sourceChanged: throw FileOperationFailure.sourceChanged
                case .contentMismatch: throw FileOperationFailure.copyContentMismatch
                case .unsupportedSource, .limitOrPrivacy, .resourceFork, .codecUnavailable: throw FileOperationFailure.unsupported
                }
            }
            throw error
        }
    }
}

internal final class ZIPFileEncoder {
    let descriptor: Int32, hooks: ZIPCreationHooks
    private(set) var count: UInt64 = 0
    private var hash = SHA256()
    init(_ descriptor: Int32, hooks: ZIPCreationHooks) { self.descriptor = descriptor; self.hooks = hooks }
    func digest() -> Data { Data(hash.finalize()) }
    func write(_ bytes: Data, check: () throws -> Void) throws { try bytes.withUnsafeBytes { try write($0, check: check) } }
    func write(_ bytes: UnsafeRawBufferPointer, check: () throws -> Void) throws {
        try check(); try hooks.beforeWrite?()
        guard UInt64(bytes.count) <= min(1_024 * 1_024 * 1_024, hooks.maximumEncodedBytes) - count else { throw ZIPCreationFailure.limitOrPrivacy }
        var offset = 0
        while offset < bytes.count {
            try check()
            var amount = min(bytes.count - offset, max(1, hooks.writeChunk), 65_536)
            if let limit = hooks.failAfterBytes {
                guard count < limit else { throw FileOperationFailure.outOfSpace }
                amount = Int(min(UInt64(amount), limit - count))
            }
            let result = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), amount)
            if result < 0 && errno == EINTR { continue }
            guard result > 0 else { throw ZIPCreationInventory.failure() }
            hash.update(bufferPointer: .init(start: bytes.baseAddress!.advanced(by: offset), count: result))
            count += UInt64(result); offset += result
        }
    }
    static func le(_ value: UInt64, _ count: Int) -> Data { Data((0..<count).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }) }
    static func dates(_ seconds: Int) -> (time: UInt16, date: UInt16) {
        var value = time_t(seconds), calendar = tm()
        guard gmtime_r(&value, &calendar) != nil else { return (0, 0x21) }
        let year = max(1980, min(2107, Int(calendar.tm_year) + 1900)) - 1980
        return (UInt16(max(0, min(23, calendar.tm_hour))) << 11 | UInt16(max(0, min(59, calendar.tm_min))) << 5 | UInt16(max(0, min(59, calendar.tm_sec)) / 2),
            UInt16(year) << 9 | UInt16(max(1, min(12, calendar.tm_mon + 1))) << 5 | UInt16(max(1, min(31, calendar.tm_mday))))
    }
    static func timestamp(_ seconds: Int) -> Data {
        guard seconds >= 0, UInt64(seconds) <= UInt32.max else { return Data() }
        return le(0x5455, 2) + le(5, 2) + Data([1]) + le(UInt64(seconds), 4)
    }
}
internal enum ZIPDeflateEncoder {
    static func encode(level: Int32, check: () throws -> Void, read: () throws -> Data,
                       output: (UnsafeRawBufferPointer) throws -> Void) throws {
        var state = z_stream()
        try withUnsafeMutablePointer(to: &state) { stream in
            guard deflateInit2_(stream, level, Z_DEFLATED, -15, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw ZIPCreationFailure.codecUnavailable }
            defer { _ = deflateEnd(stream) }
            let buffer = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: 65_536); defer { buffer.deallocate() }
            while true {
                try check(); let bytes = try read(), finishing = bytes.isEmpty
                try bytes.withUnsafeBytes { input in
                    stream.pointee.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: UInt8.self).baseAddress)
                    stream.pointee.avail_in = uInt(bytes.count)
                    defer { stream.pointee.next_in = nil; stream.pointee.next_out = nil }
                    repeat {
                        try check(); let before = stream.pointee.avail_in
                        stream.pointee.next_out = buffer.baseAddress; stream.pointee.avail_out = uInt(buffer.count)
                        let status = zlib.deflate(stream, finishing ? Z_FINISH : Z_NO_FLUSH), count = buffer.count - Int(stream.pointee.avail_out)
                        if count > 0 { try output(.init(start: buffer.baseAddress, count: count)) }
                        guard status == Z_OK || status == Z_STREAM_END else { throw ZIPCreationFailure.codecUnavailable }
                        if status == Z_STREAM_END {
                            guard finishing && stream.pointee.avail_in == 0 else { throw ZIPCreationFailure.codecUnavailable }
                            break
                        }
                        guard count > 0 || stream.pointee.avail_in < before else { throw ZIPCreationFailure.codecUnavailable }
                    } while finishing || stream.pointee.avail_in > 0
                }
                if finishing { return }
            }
        }
    }
}

extension RecoverableFileOperations {
    public func prepareZIPCreation(sources: [URL], parent: URL, name: String, compression: ZIPCompression = .balanced,
                                   observing selection: FileOperationSelection) async throws -> ArchiveCreationPlan {
        let allowNativeMarkedSources = nativeZIPCreationAcceptsMarkedSources
        return try await prepareArchiveCreation(sources: sources, parent: parent, name: name, observing: selection) { check in
            try PreparedZIPFile(sources, compression: compression,
                allowNativeMarkedSources: allowNativeMarkedSources, check: check)
        }
    }
}
