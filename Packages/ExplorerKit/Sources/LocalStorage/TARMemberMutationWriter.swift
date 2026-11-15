import CryptoKit
import Darwin
import Foundation
@_spi(ArchiveProduction) import FileOperations

/// One bounded TAR rewrite for text, namespace changes and local additions.
/// It preserves unmodified raw records and uses the shared archive publisher.
internal final class PreparedTARMemberMutation: TARCreationSourceWitness, NativeAuthoredArchiveFileProducer, @unchecked Sendable {
    let preview: ArchiveProductionPreview
    let hasMarkedSource: Bool
    let authoredArchiveFormat: AuthoredArchiveFormat
    private struct State: Sendable { let source: TARMutationSource; let layout: TARMutationLayout }
    private let stateLock = NSLock()
    private var state: State?
    private let security: ArchiveRewriteSourceSecurity
    private let hooks: ZIPCreationHooks
    private let updatesOriginal: Bool
    private let encodedBytes: UInt64
    private let encoding: TAROutputStream.Encoding

    convenience init(_ document: TARTextEditDocument, contents: TextDocumentValue,
        check: @Sendable () throws -> Void, hooks: ZIPCreationHooks = .init(), updatesOriginal: Bool = false) throws {
        try self.init(.replace(document, contents: contents), check: check, hooks: hooks, updatesOriginal: updatesOriginal)
    }
    init(_ mutation: TARMemberMutation, compression: TARCompression? = nil, check: @Sendable () throws -> Void,
        hooks: ZIPCreationHooks = .init(), updatesOriginal: Bool = false) throws {
        let began = ProcessInfo.processInfo.systemUptime
        @Sendable func checkpoint() throws {
            try check()
            guard ProcessInfo.processInfo.systemUptime - began < 30 else { throw TARMemberEditFailure.limitReached }
        }
        try checkpoint(); let binding = mutation.binding
        let source = try TARMutationSource(binding, check: checkpoint)
        let encoding: TAROutputStream.Encoding
        if let compression {
            guard compression.authoredFormat == binding.authoredFormat else { throw TARMemberEditFailure.unsupportedArchive }
            encoding = compression.encoding
        } else if let block = source.bzip2BlockSize { encoding = .bzip2(block) }
        else { encoding = binding.compressed == nil ? .plain : .gzip(6) }
        let security = source.security
        let parsed = try source.parse(check: checkpoint)
        guard parsed.witness == binding.witness else { throw FileOperationFailure.sourceChanged }
        let layout = try TARMutationLayout(mutation, source: source, parsed: parsed, check: checkpoint)
        let encodedBytes = try layout.encodedBytes(sourceLength: source.length)
        let limit: UInt64 = binding.compressed == nil ? 1 << 30 : TARCompressedDecoder.maximumBytes
        guard encodedBytes <= min(hooks.maximumEncodedBytes, limit) else { throw TARMemberEditFailure.limitReached }
        if let document = layout.replacement {
            guard try Self.digest(source, offset: document.selection.record.dataOffset,
                count: document.selection.record.bytes, check: checkpoint) == document.sourceDigest else {
                throw FileOperationFailure.sourceChanged
            }
        }
        try source.validate()
        self.state = .init(source: source, layout: layout); self.security = security
        authoredArchiveFormat = binding.authoredFormat
        hasMarkedSource = security.marked || layout.additions?.hasMarkedSource == true
        self.hooks = hooks; self.updatesOriginal = updatesOriginal; self.encodedBytes = encodedBytes
        self.encoding = encoding
        preview = layout.preview
    }
    func validate(check: @Sendable () throws -> Void) throws {
        do {
            let state = try checkedState(check: check)
            try state.layout.additions?.validate(check: check)
        } catch { throw TARMemberEditFailure.operationError(error) }
    }
    private func checkedState(check: () throws -> Void) throws -> State {
        try check()
        guard let state = stateLock.withLock({ self.state }) else { throw FileOperationFailure.invalidRequest }
        try state.source.validate(); return state
    }
    // Drop the complete transitive graph, including layout selections and text
    // documents. Clearing only source.spool would leave hidden lease owners.
    func finished() { stateLock.withLock { state = nil } }
    func produce(into descriptor: Int32, check: @Sendable () throws -> Void,
        progress: @Sendable (UInt64, Int) -> Void) throws -> ArchiveProducedNode {
        try withoutActuallyEscaping(check) { check in
            let began = ProcessInfo.processInfo.systemUptime
            @Sendable func checkpoint() throws {
                try check()
                guard ProcessInfo.processInfo.systemUptime - began < 300 else { throw TARMemberEditFailure.limitReached }
            }
            let state = try checkedState(check: checkpoint), source = state.source, layout = state.layout
            try layout.additions?.validate(check: checkpoint)
            let initial = try ArchiveProducedFacts.receipt(descriptor, relative: "", hash: nil)
            guard initial.kind == S_IFREG, initial.size == 0 else { throw FileOperationFailure.destinationChanged }
            let writer = try TAROutputStream(descriptor,
                encoding: encoding, gzipHeader: source.gzipHeader, hooks: hooks, check: checkpoint)
            defer { writer.retire() }
            func copy(_ start: UInt64, _ end: UInt64, metadata: Bool = false) throws {
                guard start <= end, end <= source.length else { throw TARMemberEditFailure.contentMismatch }
                var offset = start
                while offset < end {
                    try checkpoint(); try hooks.beforeSourceRead?(source.original.url)
                    let count = Int(min(65_536, end - offset))
                    try writer.write(source.read(offset, count, check: checkpoint), metadata: metadata, check: checkpoint)
                    offset += UInt64(count); progress(UInt64(count), 0)
                }
            }
            func write(_ entry: TARMutationLayout.Entry) throws {
                try checkpoint()
                if entry.header == nil, case .archive(let record) = entry.payload {
                    try copy(record.extensionOffset ?? record.headerOffset, record.dataOffset, metadata: true)
                    try copy(record.dataOffset, record.dataOffset + Self.padded(record.bytes))
                } else {
                    guard let header = entry.header else { throw TARMemberEditFailure.contentMismatch }
                    try writer.write(header, metadata: true, check: checkpoint)
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
                    try copy(cursor, record.extensionOffset ?? record.headerOffset, metadata: true)
                    if let entry { try write(entry) }
                    cursor = record.dataOffset + Self.padded(record.bytes)
                }
                // Preserve source root records and gaps; new entries precede the
                // original terminator, never follow an early zero-block end marker.
                try copy(cursor, layout.endOffset, metadata: true)
                for entry in layout.appended { try write(entry) }
                try copy(layout.endOffset, source.length, metadata: true)
                guard writer.count == encodedBytes else { throw TARMemberEditFailure.contentMismatch }
                try writer.finish(check: checkpoint)
                try hooks.beforeValidation?(descriptor)
                try validate(check: checkpoint)
                if let document = layout.replacement {
                    guard try Self.digest(source, offset: document.selection.record.dataOffset,
                        count: document.selection.record.bytes, check: checkpoint) == document.sourceDigest else {
                        throw FileOperationFailure.sourceChanged
                    }
                }
                let parsed = try writer.verify(check: checkpoint)
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
                let expected = writer.digest
                try validate(check: checkpoint)
                guard fchmod(descriptor, updatesOriginal ? security.mode : 0o644) == 0 else { throw ZIPCreationInventory.failure() }
                let result = try ArchiveProducedFacts.receipt(descriptor, relative: "", hash: expected)
                guard ArchiveProducedFacts.sameObject(initial, result), result.size == Int64(writer.encodedCount) else {
                    throw FileOperationFailure.destinationChanged
                }
                return result
            } catch { try validate(check: checkpoint); throw TARMemberEditFailure.operationError(error) }
        }
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
    private static func digest(_ source: TARMutationSource, offset: UInt64, count: UInt64,
        check: () throws -> Void) throws -> Data {
        var hash = SHA256(), consumed: UInt64 = 0
        while consumed < count {
            let amount = Int(min(65_536, count - consumed))
            hash.update(data: try source.read(offset + consumed, amount, check: check))
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
