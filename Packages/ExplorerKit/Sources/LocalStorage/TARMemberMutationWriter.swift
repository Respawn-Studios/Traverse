import CryptoKit
import Darwin
import Foundation
@_spi(ArchiveProduction) import FileOperations

/// One bounded TAR rewrite for text, namespace changes and local additions.
/// It preserves unmodified raw records and uses the shared archive publisher.
internal final class PreparedTARMemberMutation: TARCreationSourceWitness, NativeAuthoredArchiveFileProducer, Sendable {
    let preview: ArchiveProductionPreview
    var hasMarkedSource: Bool { security.marked || layout.additions?.hasMarkedSource == true }
    var authoredArchiveFormat: AuthoredArchiveFormat { .strictPortableTAR }
    private let binding: TARSourceBinding
    private let layout: TARMutationLayout
    private let security: ArchiveRewriteSourceSecurity
    private let hooks: ZIPCreationHooks
    private let updatesOriginal: Bool
    private let encodedBytes: UInt64

    convenience init(_ document: TARTextEditDocument, contents: TextDocumentValue,
        check: @Sendable () throws -> Void, hooks: ZIPCreationHooks = .init(), updatesOriginal: Bool = false) throws {
        try self.init(.replace(document, contents: contents), check: check, hooks: hooks, updatesOriginal: updatesOriginal)
    }
    init(_ mutation: TARMemberMutation, check: @Sendable () throws -> Void,
        hooks: ZIPCreationHooks = .init(), updatesOriginal: Bool = false) throws {
        let began = ProcessInfo.processInfo.systemUptime
        @Sendable func checkpoint() throws {
            try check()
            guard ProcessInfo.processInfo.systemUptime - began < 30 else { throw TARMemberEditFailure.limitReached }
        }
        try checkpoint(); let binding = mutation.binding
        guard binding.compressed == nil else { throw TARMemberEditFailure.compressedArchive }
        guard binding.source.pathExtension.lowercased() == "tar" else { throw TARMemberEditFailure.unsupportedArchive }
        let source = try PinnedLocalFileSource(binding.source)
        guard source.observed == binding.stamp else { throw FileOperationFailure.sourceChanged }
        guard source.observed.size <= 1 << 30 else { throw TARMemberEditFailure.limitReached }
        let security = try ArchiveRewriteSourceSecurity(source)
        let parsed = try TARSourceCatalog.parse(source, limits: .init(), check: checkpoint)
        guard parsed.witness == binding.witness else { throw FileOperationFailure.sourceChanged }
        let layout = try TARMutationLayout(mutation, source: source, parsed: parsed, check: checkpoint)
        let encodedBytes = try layout.encodedBytes(sourceLength: UInt64(source.observed.size))
        guard encodedBytes <= min(hooks.maximumEncodedBytes, 1 << 30) else { throw TARMemberEditFailure.limitReached }
        if let document = layout.replacement {
            guard try Self.digest(source.descriptor, offset: document.selection.record.dataOffset,
                count: document.selection.record.bytes, check: checkpoint) == document.sourceDigest else {
                throw FileOperationFailure.sourceChanged
            }
        }
        try source.validate()
        guard try ArchiveRewriteSourceSecurity(source) == security else { throw FileOperationFailure.sourceChanged }
        self.binding = binding; self.layout = layout; self.security = security
        self.hooks = hooks; self.updatesOriginal = updatesOriginal; self.encodedBytes = encodedBytes
        preview = layout.preview
    }
    func validate(check: @Sendable () throws -> Void) throws {
        do {
            _ = try checkedSource(check: check)
            try layout.additions?.validate(check: check)
        } catch { throw TARMemberEditFailure.operationError(error) }
    }
    private func checkedSource(check: () throws -> Void) throws -> PinnedLocalFileSource {
        try check(); let source = try PinnedLocalFileSource(binding.source)
        guard source.observed == binding.stamp,
              try ArchiveRewriteSourceSecurity(source) == security else { throw FileOperationFailure.sourceChanged }
        try source.validate(); return source
    }
    func produce(into descriptor: Int32, check: @Sendable () throws -> Void,
        progress: @Sendable (UInt64, Int) -> Void) throws -> ArchiveProducedNode {
        let began = ProcessInfo.processInfo.systemUptime
        @Sendable func checkpoint() throws {
            try check()
            guard ProcessInfo.processInfo.systemUptime - began < 300 else { throw TARMemberEditFailure.limitReached }
        }
        let source = try checkedSource(check: checkpoint)
        try layout.additions?.validate(check: checkpoint)
        let initial = try ArchiveProducedFacts.receipt(descriptor, relative: "", hash: nil)
        guard initial.kind == S_IFREG, initial.size == 0 else { throw FileOperationFailure.destinationChanged }
        let writer = ZIPFileEncoder(descriptor, hooks: hooks)
        func copy(_ start: UInt64, _ end: UInt64) throws {
            guard start <= end, end <= UInt64(source.observed.size) else { throw TARMemberEditFailure.contentMismatch }
            var offset = start
            while offset < end {
                try checkpoint(); try hooks.beforeSourceRead?(source.url)
                let count = Int(min(65_536, end - offset))
                try writer.write(source.read(offset, count, maximum: 65_536, check: checkpoint), check: checkpoint)
                offset += UInt64(count); progress(UInt64(count), 0)
            }
        }
        func write(_ entry: TARMutationLayout.Entry) throws {
            try checkpoint()
            if entry.header == nil, case .archive(let record) = entry.payload {
                try copy(record.extensionOffset ?? record.headerOffset, record.dataOffset + Self.padded(record.bytes))
            } else {
                guard let header = entry.header else { throw TARMemberEditFailure.contentMismatch }
                try writer.write(header, check: checkpoint)
                switch entry.payload {
                case .archive(let record): try copy(record.dataOffset, record.dataOffset + record.bytes)
                case .bytes(let bytes): try writer.write(bytes, check: checkpoint); progress(UInt64(bytes.count), 0)
                case .local(let node):
                    guard let inventory = layout.additions else { throw TARMemberEditFailure.contentMismatch }
                    let fd = try inventory.open(node, forReading: !node.stamp.directory, check: checkpoint)
                    defer { close(fd) }
                    var offset: UInt64 = 0
                    while offset < entry.bytes {
                        try hooks.beforeSourceRead?(node.url)
                        let amount = Int(min(65_536, entry.bytes - offset))
                        try writer.write(Self.read(fd, offset: offset, count: amount, check: checkpoint), check: checkpoint)
                        offset += UInt64(amount); progress(UInt64(amount), 0)
                    }
                    guard try ZIPInputStamp(fd) == node.stamp else { throw FileOperationFailure.sourceChanged }
                }
                let padding = Int(Self.padded(entry.bytes) - entry.bytes)
                if padding > 0 { try writer.write(Data(repeating: 0, count: padding), check: checkpoint) }
            }
            progress(0, 1)
        }
        do {
            var cursor: UInt64 = 0
            for (record, entry) in zip(layout.originalRecords, layout.originals) {
                try copy(cursor, record.extensionOffset ?? record.headerOffset)
                if let entry { try write(entry) }
                cursor = record.dataOffset + Self.padded(record.bytes)
            }
            // Preserve source root records and gaps; new entries precede the
            // original terminator, never follow an early zero-block end marker.
            try copy(cursor, layout.endOffset)
            for entry in layout.appended { try write(entry) }
            try copy(layout.endOffset, UInt64(source.observed.size))
            guard writer.count == encodedBytes else { throw TARMemberEditFailure.contentMismatch }
            try hooks.beforeValidation?(descriptor)
            try validate(check: checkpoint)
            if let document = layout.replacement {
                guard try Self.digest(source.descriptor, offset: document.selection.record.dataOffset,
                    count: document.selection.record.bytes, check: checkpoint) == document.sourceDigest else {
                    throw FileOperationFailure.sourceChanged
                }
            }
            let parsed = try TARMetadataParser.parse(length: writer.count, check: checkpoint, read: {
                try Self.read(descriptor, offset: $0, count: $1, check: checkpoint)
            })
            let expectedEntries = layout.entries
            guard parsed.records.count == expectedEntries.count, parsed.logicalBytes == preview.logicalBytes else {
                throw TARMemberEditFailure.contentMismatch
            }
            _ = try TARCatalogBuilder.build(parsed, check: checkpoint)
            for (expected, actual) in zip(expectedEntries, parsed.records) {
                try checkpoint()
                guard expected.path.utf8.elementsEqual(actual.path.utf8), expected.kind == actual.kind,
                      expected.modification == actual.modification, expected.bytes == actual.bytes else {
                    throw TARMemberEditFailure.contentMismatch
                }
            }
            let expected = writer.digest()
            guard try Self.digest(descriptor, offset: 0, count: writer.count, check: checkpoint) == expected else {
                throw TARMemberEditFailure.contentMismatch
            }
            try validate(check: checkpoint)
            guard fchmod(descriptor, updatesOriginal ? security.mode : 0o644) == 0 else { throw ZIPCreationInventory.failure() }
            let result = try ArchiveProducedFacts.receipt(descriptor, relative: "", hash: expected)
            guard ArchiveProducedFacts.sameObject(initial, result), result.size == Int64(writer.count) else {
                throw FileOperationFailure.destinationChanged
            }
            return result
        } catch { try validate(check: checkpoint); throw TARMemberEditFailure.operationError(error) }
    }
    func produceNativeArchive(into descriptor: Int32, stageSecurity: AuthoredZIPSecurityWitness,
        allowSourceMarkInheritance: Bool, check: @Sendable () throws -> Void,
        progress: @Sendable (UInt64, Int) -> Void) throws -> AuthoredZIPProducedFile {
        guard !allowSourceMarkInheritance, updatesOriginal,
              try ZIPSourceSecurity.nativeAuthoredWitness(descriptor) == stageSecurity,
              !hasMarkedSource || stageSecurity.quarantine != nil else { throw FileOperationFailure.copyMetadataMismatch }
        let node = try produce(into: descriptor, check: check, progress: progress)
        guard try ZIPSourceSecurity.nativeAuthoredWitness(descriptor) == stageSecurity else {
            throw FileOperationFailure.copyMetadataMismatch
        }
        return .init(node: node, security: stageSecurity)
    }
    func requirePublicQuarantineRecognition(_ descriptor: Int32, at url: URL) throws {
        _ = try ZIPSourceSecurity.extractionWitness(descriptor, url: url, allowingInheritance: true)
    }
    private static func padded(_ bytes: UInt64) -> UInt64 { ((bytes + 511) / 512) * 512 }
    private static func digest(_ descriptor: Int32, offset: UInt64, count: UInt64,
        check: () throws -> Void) throws -> Data {
        var hash = SHA256(), consumed: UInt64 = 0
        while consumed < count {
            let amount = Int(min(65_536, count - consumed))
            hash.update(data: try read(descriptor, offset: offset + consumed, count: amount, check: check))
            consumed += UInt64(amount)
        }
        try check(); return Data(hash.finalize())
    }
    private static func read(_ descriptor: Int32, offset: UInt64, count: Int,
        check: () throws -> Void) throws -> Data {
        guard count >= 0, count <= 65_536, offset <= UInt64(Int64.max) - UInt64(count) else { throw TARMemberEditFailure.limitReached }
        var result = Data(count: count)
        try result.withUnsafeMutableBytes { buffer in
            var done = 0
            while done < count {
                try check()
                let amount = pread(descriptor, buffer.baseAddress!.advanced(by: done), count - done, off_t(offset) + off_t(done))
                if amount < 0, errno == EINTR { continue }
                guard amount > 0 else { throw TARMemberEditFailure.contentMismatch }
                done += amount
            }
        }
        return result
    }
}
