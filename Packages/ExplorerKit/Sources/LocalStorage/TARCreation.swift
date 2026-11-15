import CryptoKit
import Darwin
import Foundation
@_spi(ArchiveProduction) import FileOperations

public enum TARCreationFailure: Error, Sendable, Equatable {
    case unsupportedSource, limitReached, sourceChanged, contentMismatch
    public var userMessage: String {
        switch self {
        case .unsupportedSource: "Choose local files and folders without links, cloud-only items or Mac-specific file data."
        case .limitReached: "This selection exceeds the portable TAR limits. Choose fewer or smaller items."
        case .sourceChanged: "An item changed while preparing the TAR. Your originals are unchanged."
        case .contentMismatch: "The TAR did not verify. It was not published; your originals are unchanged."
        }
    }
    internal static func project(_ error: Error) -> Error {
        if let failure = error as? TARArchiveFailure {
            return failure == .limited ? Self.limitReached : Self.unsupportedSource
        }
        guard let failure = error as? ZIPCreationFailure else { return error }
        return switch failure {
        case .sourceChanged: Self.sourceChanged
        case .contentMismatch: Self.contentMismatch
        case .limitOrPrivacy: Self.limitReached
        case .unsupportedSource, .resourceFork, .codecUnavailable: Self.unsupportedSource
        }
    }
}

/// The same checked portable local inventory as ZIP, with a different encoder.
/// Only regular files/folders enter it; no shell tool, archive extraction or
/// second source-body copy is involved in creating an uncompressed TAR.
internal final class PreparedTARCreation: TARCreationSourceWitness, Sendable {
    let preview: ArchiveProductionPreview
    var hasMarkedSource: Bool { inventory.hasMarkedSource }
    private let inventory: ZIPCreationInventory
    private let headers: [TARCreationHeader]
    private let hooks: ZIPCreationHooks

    init(_ sources: [URL], allowNativeMarkedSources: Bool = false,
         check: @Sendable () throws -> Void, hooks: ZIPCreationHooks = .init()) throws {
        self.hooks = hooks
        do {
            let inventory = try ZIPCreationInventory(sources,
                allowNativeMarkedSources: allowNativeMarkedSources, check: check)
            var headers: [TARCreationHeader] = [], encodedBytes: UInt64 = 1024, physicalRecords = 0
            var metadataBytes = 1024, nameBytes = 0
            let limits = TARReadLimits()
            let ceiling = min(hooks.maximumEncodedBytes, 1 << 30)
            guard ceiling >= encodedBytes else { throw TARCreationFailure.limitReached }
            for (index, node) in inventory.nodes.enumerated() {
                try check()
                let safe = try TARMetadataParser.path(node.name, directory: node.stamp.directory, limits: limits)
                guard safe.utf8.elementsEqual(node.path.utf8) else { throw TARCreationFailure.unsupportedSource }
                let header = try TARCreationHeader(node, index: index)
                let payload = node.stamp.directory ? 0 : UInt64(node.stamp.size)
                let amount = header.encodedBytes + ((payload + 511) / 512) * 512
                physicalRecords += header.hasPAX ? 2 : 1
                guard node.path.utf8.count <= limits.nameBytes - nameBytes,
                      header.encoded.count <= limits.metadataBytes - metadataBytes,
                      physicalRecords <= limits.records, amount <= ceiling - encodedBytes else {
                    throw TARCreationFailure.limitReached
                }
                nameBytes += node.path.utf8.count; metadataBytes += header.encoded.count
                encodedBytes += amount; headers.append(header)
            }
            self.inventory = inventory; self.headers = headers
            preview = .init(files: inventory.files, folders: inventory.folders, logicalBytes: inventory.logical,
                longestPathBytes: inventory.nodes.map { $0.path.utf8.count }.max() ?? 0)
        } catch { throw TARCreationFailure.project(error) }
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
        let began = ProcessInfo.processInfo.systemUptime
        func checkpoint() throws {
            try check()
            guard ProcessInfo.processInfo.systemUptime - began < 300 else { throw TARCreationFailure.limitReached }
        }
        do {
            try validateInput(check: checkpoint)
            let initial = try ArchiveProducedFacts.receipt(descriptor, relative: "", hash: nil)
            guard initial.kind == S_IFREG, initial.size == 0 else { throw FileOperationFailure.destinationChanged }
            let writer = ZIPFileEncoder(descriptor, hooks: hooks)
            var hashes: [String: Data] = [:]
            for (index, node) in inventory.nodes.enumerated() {
                try checkpoint()
                let fd = try inventory.open(node, forReading: !node.stamp.directory, check: checkpoint)
                defer { close(fd) }
                try writer.write(headers[index].encoded, check: checkpoint)
                if !node.stamp.directory {
                    var offset: UInt64 = 0, hash = SHA256()
                    while offset < UInt64(node.stamp.size) {
                        try checkpoint(); try hooks.beforeSourceRead?(node.url)
                        let amount = Int(min(65_536, UInt64(node.stamp.size) - offset))
                        let bytes = try Self.read(fd, offset: offset, count: amount, check: checkpoint)
                        try writer.write(bytes, check: checkpoint); hash.update(data: bytes)
                        offset += UInt64(amount); progress(UInt64(amount), 0)
                    }
                    hashes[node.path] = Data(hash.finalize())
                    let padding = Int((512 - UInt64(node.stamp.size) % 512) % 512)
                    if padding > 0 { try writer.write(Data(repeating: 0, count: padding), check: checkpoint) }
                }
                guard try ZIPInputStamp(fd) == node.stamp else { throw FileOperationFailure.sourceChanged }
                progress(0, 1)
            }
            try writer.write(Data(repeating: 0, count: 1024), check: checkpoint)
            try hooks.beforeValidation?(descriptor)
            try validateInput(check: checkpoint)
            var limits = TARReadLimits(); limits.sourceBytes = 1 << 30
            let parsed: TARParsedDirectory
            do {
                parsed = try TARMetadataParser.parse(length: writer.count, limits: limits, check: checkpoint,
                    read: { try Self.read(descriptor, offset: $0, count: $1, check: checkpoint) })
            } catch { try checkpoint(); throw TARCreationFailure.contentMismatch }
            guard parsed.records.count == inventory.nodes.count, parsed.logicalBytes == inventory.logical else {
                throw TARCreationFailure.contentMismatch
            }
            for (index, values) in zip(parsed.records, inventory.nodes).enumerated() {
                let (record, node) = values
                try checkpoint()
                guard record.path.utf8.elementsEqual(node.path.utf8),
                      record.kind == (node.stamp.directory ? .directory : .file),
                      record.bytes == (node.stamp.directory ? 0 : UInt64(node.stamp.size)),
                      record.modification?.date == headers[index].modification else {
                    throw TARCreationFailure.contentMismatch
                }
                if !node.stamp.directory {
                    var hash = SHA256(), offset: UInt64 = 0
                    while offset < record.bytes {
                        let amount = Int(min(65_536, record.bytes - offset))
                        hash.update(data: try Self.read(descriptor, offset: record.dataOffset + offset, count: amount, check: checkpoint))
                        offset += UInt64(amount)
                    }
                    guard hashes.removeValue(forKey: node.path) == Data(hash.finalize()) else { throw TARCreationFailure.contentMismatch }
                }
            }
            guard hashes.isEmpty else { throw TARCreationFailure.contentMismatch }
            try validateInput(check: checkpoint)
            guard fchmod(descriptor, 0o644) == 0 else { throw ZIPCreationInventory.failure() }
            let result = try ArchiveProducedFacts.receipt(descriptor, relative: "", hash: writer.digest())
            guard ArchiveProducedFacts.sameObject(initial, result), result.size == Int64(writer.count) else {
                throw FileOperationFailure.destinationChanged
            }
            return result
        } catch { try validateInput(check: checkpoint); throw TARCreationFailure.project(error) }
    }

    private static func read(_ fd: Int32, offset: UInt64, count: Int, check: () throws -> Void) throws -> Data {
        guard count >= 0, count <= 64 << 10, offset <= UInt64(Int64.max) - UInt64(count) else {
            throw TARCreationFailure.limitReached
        }
        var bytes = Data(count: count)
        try bytes.withUnsafeMutableBytes { buffer in
            var done = 0
            while done < count {
                try check()
                let amount = pread(fd, buffer.baseAddress!.advanced(by: done), count - done, off_t(offset) + off_t(done))
                if amount < 0, errno == EINTR { continue }
                guard amount > 0 else { throw TARCreationFailure.contentMismatch }
                done += amount
            }
        }
        return bytes
    }
}

extension RecoverableFileOperations {
    public func prepareTARCreation(sources: [URL], parent: URL, name: String,
        observing selection: FileOperationSelection) async throws -> ArchiveCreationPlan {
        try await prepareTARCreation(sources: sources, parent: parent, name: name, observing: selection, hooks: .init())
    }
    internal func prepareTARCreation(sources: [URL], parent: URL, name: String,
        observing selection: FileOperationSelection, hooks: ZIPCreationHooks) async throws -> ArchiveCreationPlan {
        guard (name as NSString).pathExtension.lowercased() == "tar" else { throw FileOperationFailure.invalidRequest }
        let allowNativeMarkedSources = nativeTARCreationAcceptsMarkedSources
        return try await prepareArchiveCreation(sources: sources, parent: parent, name: name,
            observing: selection, authoredFormat: .strictPortableTAR) { check in
            try PreparedTARCreation(sources, allowNativeMarkedSources: allowNativeMarkedSources,
                check: check, hooks: hooks)
        }
    }
}

/// POSIX ustar with local PAX path/mtime records where the fixed fields cannot
/// represent a name or timestamp. Ownership names and private metadata are omitted.
internal struct TARCreationHeader: Sendable {
    let encoded: Data
    let modification: Date
    let hasPAX: Bool
    var encodedBytes: UInt64 { UInt64(encoded.count) }

    init(_ node: ZIPCreationInventory.Node, index: Int) throws {
        let stamp = node.stamp
        try self.init(path: node.path, directory: stamp.directory,
            bytes: stamp.directory ? 0 : UInt64(stamp.size), mode: UInt64(stamp.mode & 0o777),
            seconds: stamp.modifiedSeconds, nanos: stamp.modifiedNanoseconds, index: index)
    }
    init(path: String, directory: Bool, bytes: UInt64 = 0, mode: UInt64 = 0o644,
        seconds: Int, nanos: Int = 0, index: Int) throws {
        guard (0..<1_000_000_000).contains(nanos) else { throw TARCreationFailure.unsupportedSource }
        let timestamp = Self.timestamp(seconds, nanos)
        guard let parsedTime = Double(timestamp), let recorded = ArchiveMemberModification.unix(parsedTime) else {
            throw TARCreationFailure.unsupportedSource
        }
        modification = recorded.date
        var attributes = Data()
        let name = path + (directory ? "/" : "")
        let fields = Self.ustarName(name)
        if fields == nil { attributes += Self.attribute("path", name) }
        if nanos != 0 || seconds < 0 || seconds > 8_589_934_591 { attributes += Self.attribute("mtime", timestamp) }
        let headerName = fields ?? ("TraverseItem-\(index)", "")
        let header = try Self.header(name: headerName.0, prefix: headerName.1,
            mode: mode, bytes: directory ? 0 : bytes,
            modified: UInt64(clamping: seconds), kind: directory ? 53 : 48)
        hasPAX = !attributes.isEmpty
        if attributes.isEmpty { encoded = header }
        else {
            guard attributes.count <= 64 << 10 else { throw TARCreationFailure.limitReached }
            var result = try Self.header(name: "PaxHeaders/\(index)", prefix: "", mode: 0o644,
                bytes: UInt64(attributes.count), modified: 0, kind: 120)
            result += attributes
            result += Data(repeating: 0, count: (512 - attributes.count % 512) % 512)
            result += header; encoded = result
        }
    }

    static func ustarName(_ name: String) -> (String, String)? {
        guard name.utf8.allSatisfy({ $0 < 128 }) else { return nil }
        if name.utf8.count <= 100 { return (name, "") }
        for split in name.indices.reversed() where name[split] == "/" {
            let prefix = String(name[..<split]), leaf = String(name[name.index(after: split)...])
            if !leaf.isEmpty, prefix.utf8.count <= 155, leaf.utf8.count <= 100 { return (leaf, prefix) }
        }
        return nil
    }

    private static func timestamp(_ seconds: Int, _ nanos: Int) -> String {
        if nanos == 0 { return String(seconds) }
        let fraction = seconds < 0 ? 1_000_000_000 - nanos : nanos
        var digits = String(repeating: "0", count: 9 - String(fraction).count) + String(fraction)
        while digits.last == "0" { digits.removeLast() }
        return seconds < 0 ? "-\(-(seconds + 1)).\(digits)" : "\(seconds).\(digits)"
    }

    private static func attribute(_ key: String, _ value: String) -> Data {
        let body = Data(" \(key)=\(value)\n".utf8)
        var length = body.count + 1
        while String(length).utf8.count + body.count != length { length = String(length).utf8.count + body.count }
        return Data(String(length).utf8) + body
    }

    static func header(name: String, prefix: String, mode: UInt64, bytes: UInt64,
                               modified: UInt64, kind: UInt8) throws -> Data {
        var header = Data(repeating: 0, count: 512)
        func text(_ value: String, at offset: Int, width: Int) throws {
            let data = Data(value.utf8)
            guard data.count <= width else { throw TARCreationFailure.limitReached }
            header.replaceSubrange(offset..<(offset + data.count), with: data)
        }
        func octal(_ value: UInt64, at offset: Int, width: Int) throws {
            let digits = String(value, radix: 8)
            guard digits.count < width else { throw TARCreationFailure.limitReached }
            try text(String(repeating: "0", count: width - digits.count - 1) + digits, at: offset, width: width)
        }
        try text(name, at: 0, width: 100); try octal(mode, at: 100, width: 8)
        try octal(0, at: 108, width: 8); try octal(0, at: 116, width: 8)
        try octal(bytes, at: 124, width: 12); try octal(min(modified, 8_589_934_591), at: 136, width: 12)
        header.replaceSubrange(148..<156, with: Data(repeating: 32, count: 8)); header[156] = kind
        try text("ustar", at: 257, width: 6); try text("00", at: 263, width: 2)
        try text(prefix, at: 345, width: 155)
        let checksum = header.reduce(0) { $0 + UInt64($1) }, digits = String(checksum, radix: 8)
        guard digits.count <= 6 else { throw TARCreationFailure.limitReached }
        try text(String(repeating: "0", count: 6 - digits.count) + digits + "\0 ", at: 148, width: 8)
        return header
    }
}
