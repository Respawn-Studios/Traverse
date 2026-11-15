import CryptoKit
import Darwin
import Foundation
@_spi(ArchiveProduction) import FileOperations

/// Rewrites one regular member without unpacking the archive. Headers, padding,
/// ownership names and local PAX fields of every other member are copied intact.
internal final class PreparedTARTextEdit: TARCreationSourceWitness, NativeAuthoredArchiveFileProducer, Sendable {
    let preview: ArchiveProductionPreview
    var hasMarkedSource: Bool { security.marked }
    private let document: TARTextEditDocument
    private let contents: Data
    private let records: [TARRecord]
    private let header: Data
    private let security: ArchiveRewriteSourceSecurity
    private let hooks: ZIPCreationHooks
    private let updatesOriginal: Bool
    var authoredArchiveFormat: AuthoredArchiveFormat { .strictPortableTAR }

    init(_ document: TARTextEditDocument, contents: TextDocumentValue,
        check: @Sendable () throws -> Void, hooks: ZIPCreationHooks = .init(), updatesOriginal: Bool = false) throws {
        try check()
        guard document.selection.binding.compressed == nil,
              document.archiveURL.pathExtension.lowercased() == "tar" else {
            throw TARMemberEditFailure.compressedArchive
        }
        _ = try TARTextPreview.decode(contents.encoded, check: check)
        let source = try PinnedLocalFileSource(document.archiveURL)
        guard source.observed == document.selection.binding.stamp else { throw FileOperationFailure.sourceChanged }
        guard source.observed.size <= 1 << 30 else { throw TARMemberEditFailure.limitReached }
        let security = try ArchiveRewriteSourceSecurity(source)
        let parsed = try TARSourceCatalog.parse(source, limits: .init(), check: check)
        guard parsed.witness == document.selection.binding.witness else { throw FileOperationFailure.sourceChanged }
        let catalog = try TARCatalogBuilder.build(parsed, check: check)
        guard catalog.summary.blockedMembers == 0,
              parsed.records.filter({ $0.path.utf8.elementsEqual(document.archivePath.utf8) }).count == 1,
              let record = parsed.records.first(where: { $0.path.utf8.elementsEqual(document.archivePath.utf8) }),
              record.kind == .file, record.headerOffset == document.selection.record.headerOffset,
              record.bytes == document.selection.record.bytes else { throw TARMemberEditFailure.unsupportedArchive }
        guard try Self.digest(source.descriptor, offset: record.dataOffset, count: record.bytes, check: check)
                == document.sourceDigest else { throw FileOperationFailure.sourceChanged }
        let header = try TARMemberHeader.replacingSize(record, with: UInt64(contents.encoded.count), read: {
            try source.read($0, $1, maximum: 66_560, check: check)
        })
        let oldMetadata = record.dataOffset - (record.extensionOffset ?? record.headerOffset)
        let oldSpan = oldMetadata + Self.padded(record.bytes)
        let newSpan = UInt64(header.count) + Self.padded(UInt64(contents.encoded.count))
        guard oldSpan <= UInt64(source.observed.size),
              newSpan <= min(hooks.maximumEncodedBytes, 1 << 30),
              UInt64(source.observed.size) - oldSpan <= min(hooks.maximumEncodedBytes, 1 << 30) - newSpan else {
            throw TARMemberEditFailure.limitReached
        }
        try source.validate()
        guard try ArchiveRewriteSourceSecurity(source) == security else { throw FileOperationFailure.sourceChanged }
        self.document = document; self.contents = contents.encoded; self.records = parsed.records
        self.header = header; self.security = security; self.hooks = hooks; self.updatesOriginal = updatesOriginal
        preview = .init(files: catalog.summary.files, folders: catalog.summary.folders,
            logicalBytes: parsed.logicalBytes - record.bytes + UInt64(contents.encoded.count),
            longestPathBytes: parsed.records.map { $0.path.utf8.count }.max() ?? 0)
    }

    func validate(check: @Sendable () throws -> Void) throws {
        do { _ = try checkedSource(check: check) }
        catch { throw TARMemberEditFailure.operationError(error) }
    }
    private func checkedSource(check: () throws -> Void) throws -> PinnedLocalFileSource {
        try check()
        let source = try PinnedLocalFileSource(document.archiveURL)
        guard source.observed == document.selection.binding.stamp,
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
        let initial = try ArchiveProducedFacts.receipt(descriptor, relative: "", hash: nil)
        guard initial.kind == S_IFREG, initial.size == 0 else { throw FileOperationFailure.destinationChanged }
        let writer = ZIPFileEncoder(descriptor, hooks: hooks)
        let record = document.selection.record
        func copy(_ start: UInt64, _ end: UInt64) throws {
            var offset = start
            while offset < end {
                try checkpoint(); try hooks.beforeSourceRead?(source.url)
                let count = Int(min(65_536, end - offset))
                try writer.write(source.read(offset, count, maximum: 65_536, check: checkpoint), check: checkpoint)
                offset += UInt64(count); progress(UInt64(count), 0)
            }
        }
        do {
            try copy(0, record.extensionOffset ?? record.headerOffset)
            try writer.write(header, check: checkpoint)
            try writer.write(contents, check: checkpoint)
            let padding = Int(Self.padded(UInt64(contents.count)) - UInt64(contents.count))
            if padding > 0 { try writer.write(Data(repeating: 0, count: padding), check: checkpoint) }
            try copy(record.dataOffset + Self.padded(record.bytes), UInt64(source.observed.size))
            try hooks.beforeValidation?(descriptor)
            try validate(check: checkpoint)
            guard try Self.digest(source.descriptor, offset: record.dataOffset, count: record.bytes, check: checkpoint)
                    == document.sourceDigest else { throw FileOperationFailure.sourceChanged }
            let parsed = try TARMetadataParser.parse(length: writer.count, check: checkpoint, read: {
                try Self.read(descriptor, offset: $0, count: $1, check: checkpoint)
            })
            guard parsed.records.count == records.count, parsed.logicalBytes == preview.logicalBytes else {
                throw TARMemberEditFailure.contentMismatch
            }
            for (before, after) in zip(records, parsed.records) {
                try checkpoint()
                guard before.path.utf8.elementsEqual(after.path.utf8), before.kind == after.kind,
                      before.modification == after.modification,
                      after.bytes == (before.headerOffset == record.headerOffset ? UInt64(contents.count) : before.bytes) else {
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
            progress(0, preview.files + preview.folders)
            return result
        } catch { try validate(check: checkpoint); throw TARMemberEditFailure.operationError(error) }
    }
    func produceNativeArchive(into descriptor: Int32, stageSecurity: AuthoredZIPSecurityWitness,
        allowSourceMarkInheritance: Bool, check: @Sendable () throws -> Void,
        progress: @Sendable (UInt64, Int) -> Void) throws -> AuthoredZIPProducedFile {
        guard !allowSourceMarkInheritance, updatesOriginal,
              try ZIPSourceSecurity.nativeAuthoredWitness(descriptor) == stageSecurity,
              !hasMarkedSource || stageSecurity.quarantine != nil else {
            throw FileOperationFailure.copyMetadataMismatch
        }
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
        guard count >= 0, count <= 65_536, offset <= UInt64(Int64.max) - UInt64(count) else {
            throw TARMemberEditFailure.limitReached
        }
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

/// Root metadata that a rewritten archive can preserve. The native stage keeps
/// its own quarantine; these source bytes are only a revalidation witness.
internal struct ArchiveRewriteSourceSecurity: Equatable, Sendable {
    let witness: ZIPSourceSecurity.CreationInputWitness
    let mode: mode_t, owner: uid_t, group: gid_t, flags: UInt32
    var marked: Bool { witness.marked }
    init(_ source: PinnedLocalFileSource) throws {
        var facts = stat()
        guard fstat(source.descriptor, &facts) == 0, facts.st_nlink == 1,
              facts.st_uid == geteuid(), [mode_t(0o600), mode_t(0o644)].contains(facts.st_mode & 0o7777),
              facts.st_flags == 0 || facts.st_flags == UInt32(UF_TRACKED) else {
            throw TARMemberEditFailure.unsupportedArchive
        }
        errno = 0
        if let acl = acl_get_fd_np(source.descriptor, ACL_TYPE_EXTENDED) {
            acl_free(UnsafeMutableRawPointer(acl)); throw TARMemberEditFailure.unsupportedArchive
        }
        guard errno == ENOENT else { throw TARMemberEditFailure.unsupportedArchive }
        let count = flistxattr(source.descriptor, nil, 0, 0)
        guard count >= 0, count <= 4_096 else { throw TARMemberEditFailure.unsupportedArchive }
        var names = [CChar](repeating: 0, count: max(1, count))
        guard flistxattr(source.descriptor, &names, count, 0) == count else { throw FileOperationFailure.sourceChanged }
        for name in names.prefix(count).split(separator: 0) {
            let bytes = name.map { UInt8(bitPattern: $0) }
            guard bytes.elementsEqual("com.apple.quarantine".utf8) || bytes.elementsEqual("com.apple.provenance".utf8) else {
                throw TARMemberEditFailure.unsupportedArchive
            }
        }
        witness = try ZIPSourceSecurity.creationInputWitness(source.descriptor, url: source.url, allowingNativeMark: true)
        mode = facts.st_mode & 0o7777; owner = facts.st_uid; group = facts.st_gid; flags = facts.st_flags
    }
}
