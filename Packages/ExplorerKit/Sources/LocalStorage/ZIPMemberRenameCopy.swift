import CryptoKit
import Darwin
import Foundation
import zlib
@_spi(ArchiveProduction) import FileOperations

internal struct ZIPCopyBoundRecord: Equatable, Sendable {
    let archivePath: String
    let centralPosition: UInt64
}

/// A file or folder from one live ZIP session. The displayed path is not an
/// output URL or permission to replace the source archive. Folder paths omit
/// the trailing slash; exact affected records stay sealed in the target.
public struct ZIPMemberRenameSelection: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    internal enum Target: Sendable {
        case regular(centralPosition: UInt64)
        case directory(records: [ZIPCopyBoundRecord])
    }
    public var archiveURL: URL { binding.source }
    public let archivePath: String
    public let currentName: String
    /// Empty for a member at the archive root.
    public let virtualParent: String
    public var isDirectory: Bool { if case .directory = target { true } else { false } }
    public var description: String { "Selected ZIP member" }
    public var debugDescription: String { description }
    internal let binding: ZIPSourceBinding
    internal let target: Target
}

/// Effective file and folder roots from one live ZIP session. Paths are for
/// review only; callers cannot replace the sealed source or record union.
public struct ZIPMemberSetSelection: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    internal struct Root: Sendable {
        let archivePath: String
        let isDirectory: Bool
        let firstPosition: UInt64
    }
    public var archiveURL: URL { binding.source }
    /// Effective selected roots, ordered by first affected central record.
    /// Folder paths use catalog spelling without a trailing slash.
    public let archivePaths: [String]
    /// The folder subset of archivePaths, in the same order.
    public let folderPaths: [String]
    /// Selected descendant rows already covered by a selected ancestor folder.
    public let coveredSelectionCount: Int
    public var description: String { "Selected ZIP members" }
    public var debugDescription: String { description }
    internal let binding: ZIPSourceBinding
    internal let roots: [Root]
    internal let members: [ZIPCopyBoundRecord]
}

public enum ZIPMemberRemovalFailure: Error, Equatable, Sendable {
    case invalidSelection, invalidOutputName, unsupportedArchive, unsupportedSecurity
    case sourceChanged, contentMismatch, limitReached

    public var userMessage: String {
        switch self {
        case .invalidSelection: "Choose one to 128 files or folders in the open ZIP."
        case .invalidOutputName: "Choose a different name for the new ZIP copy."
        case .unsupportedArchive: "This ZIP has a format or metadata this copy cannot preserve. The original is unchanged."
        case .unsupportedSecurity: "This ZIP has file security metadata this copy cannot safely carry. The original is unchanged."
        case .sourceChanged: "The ZIP changed while preparing its copy. Review the original and try again."
        case .contentMismatch: "The ZIP contents did not verify. No copy was published."
        case .limitReached: "This ZIP exceeds the current copy limits. The original is unchanged."
        }
    }

    internal init(_ failure: ZIPMemberRenameFailure) {
        switch failure {
        case .invalidMember: self = .invalidSelection
        case .invalidName: self = .invalidOutputName
        case .ambiguousName, .unsupportedArchive: self = .unsupportedArchive
        case .unsupportedSecurity: self = .unsupportedSecurity
        case .sourceChanged: self = .sourceChanged
        case .contentMismatch: self = .contentMismatch
        case .limitReached: self = .limitReached
        }
    }
}

public enum ZIPMemberRenameFailure: Error, Equatable, Sendable {
    case invalidMember, invalidName, ambiguousName, unsupportedArchive, unsupportedSecurity
    case sourceChanged, contentMismatch, limitReached

    public var userMessage: String {
        switch self {
        case .invalidMember: "Choose one file or folder in the open ZIP."
        case .invalidName: "Choose a different safe file name within this ZIP folder."
        case .ambiguousName: "That name conflicts with another ZIP item. Nothing was changed."
        case .unsupportedArchive: "This ZIP has a format or metadata this copy cannot preserve. The original is unchanged."
        case .unsupportedSecurity: "This ZIP has file security metadata this copy cannot safely carry. The original is unchanged."
        case .sourceChanged: "The ZIP changed while preparing its copy. Review the original and try again."
        case .contentMismatch: "The ZIP contents did not verify. No copy was published."
        case .limitReached: "This ZIP exceeds the current editing limits. The original is unchanged."
        }
    }
}

extension RecoverableFileOperations {
    public func prepareZIPMemberBatchRenameOriginal(_ selection: ZIPMemberSetSelection, to names: [String],
        observing source: FileOperationSelection) async throws -> ArchiveUpdatePlan {
        try await prepareArchiveOriginalUpdate(sources: [selection.archiveURL], original: selection.archiveURL,
            observing: source) { check in
            try PreparedZIPCopyEdit(.renameMany(selection, names), check: check, updateOriginal: true)
        }
    }
    public func prepareZIPMemberBatchRenameCopy(_ selection: ZIPMemberSetSelection, to names: [String],
        outputName: String, observing source: FileOperationSelection) async throws -> ArchiveCreationPlan {
        guard (outputName as NSString).pathExtension.lowercased() == "zip" else { throw ZIPMemberRenameFailure.invalidName }
        return try await prepareArchiveCreation(sources: [selection.archiveURL], parent: selection.archiveURL.deletingLastPathComponent(),
            name: outputName, observing: source) { check in
            try PreparedZIPCopyEdit(.renameMany(selection, names), check: check)
        }
    }
    /// Rewrites the selected member into the same observed ZIP. The original
    /// survives in one journaled recovery area until Undo or explicit cleanup.
    public func prepareZIPMemberRenameOriginal(_ member: ZIPMemberRenameSelection,
        to newBaseName: String, observing source: FileOperationSelection) async throws -> ArchiveUpdatePlan {
        try await prepareZIPMemberRenameOriginal(member, to: newBaseName, observing: source, hooks: .init())
    }
    internal func prepareZIPMemberRenameOriginal(_ member: ZIPMemberRenameSelection,
        to newBaseName: String, observing source: FileOperationSelection,
        hooks: ZIPCreationHooks) async throws -> ArchiveUpdatePlan {
        try await prepareArchiveOriginalUpdate(sources: [member.archiveURL], original: member.archiveURL,
            observing: source) { check in
            try PreparedZIPCopyEdit(.rename(member, newBaseName), check: check,
                                    hooks: hooks, updateOriginal: true)
        }
    }

    public func prepareZIPMemberRemovalOriginal(_ selection: ZIPMemberSetSelection,
        observing source: FileOperationSelection) async throws -> ArchiveUpdatePlan {
        try await prepareZIPMemberRemovalOriginal(selection, observing: source, hooks: .init())
    }
    internal func prepareZIPMemberRemovalOriginal(_ selection: ZIPMemberSetSelection,
        observing source: FileOperationSelection,
        hooks: ZIPCreationHooks) async throws -> ArchiveUpdatePlan {
        do {
            return try await prepareArchiveOriginalUpdate(sources: [selection.archiveURL],
                original: selection.archiveURL, observing: source) { check in
                try PreparedZIPCopyEdit(.remove(selection), check: check,
                                        hooks: hooks, updateOriginal: true)
            }
        } catch let failure as ZIPMemberRenameFailure { throw ZIPMemberRemovalFailure(failure) }
    }

    /// The only publication is a new, absent sibling ZIP. The caller retains
    /// access to the original source until the one-use plan has drained.
    public func prepareZIPMemberRenameCopy(_ member: ZIPMemberRenameSelection, to newBaseName: String,
        outputName: String, observing source: FileOperationSelection) async throws -> ArchiveCreationPlan {
        try await prepareZIPMemberRenameCopy(member, to: newBaseName, outputName: outputName,
                                             observing: source, hooks: .init())
    }
    internal func prepareZIPMemberRenameCopy(_ member: ZIPMemberRenameSelection, to newBaseName: String,
        outputName: String, observing source: FileOperationSelection,
        hooks: ZIPCreationHooks) async throws -> ArchiveCreationPlan {
        guard (outputName as NSString).pathExtension.lowercased() == "zip" else {
            throw ZIPMemberRenameFailure.invalidName
        }
        return try await prepareArchiveCreation(sources: [member.archiveURL],
            parent: member.archiveURL.deletingLastPathComponent(), name: outputName, observing: source) { check in
            try PreparedZIPCopyEdit(.rename(member, newBaseName), check: check, hooks: hooks)
        }
    }
    /// Removes selected records only in a new, absent sibling ZIP. The same
    /// journaled file-production path protects publication, Results and Undo.
    public func prepareZIPMemberRemovalCopy(_ selection: ZIPMemberSetSelection,
        outputName: String, observing source: FileOperationSelection) async throws -> ArchiveCreationPlan {
        try await prepareZIPMemberRemovalCopy(selection, outputName: outputName, observing: source, hooks: .init())
    }
    internal func prepareZIPMemberRemovalCopy(_ selection: ZIPMemberSetSelection,
        outputName: String, observing source: FileOperationSelection,
        hooks: ZIPCreationHooks) async throws -> ArchiveCreationPlan {
        guard (outputName as NSString).pathExtension.lowercased() == "zip" else {
            throw ZIPMemberRemovalFailure.invalidOutputName
        }
        do {
            return try await prepareArchiveCreation(sources: [selection.archiveURL],
                parent: selection.archiveURL.deletingLastPathComponent(), name: outputName, observing: source) { check in
                try PreparedZIPCopyEdit(.remove(selection), check: check, hooks: hooks)
            }
        } catch let failure as ZIPMemberRenameFailure { throw ZIPMemberRemovalFailure(failure) }
    }

    public func prepareZIPMemberDuplicateOriginal(_ selection: ZIPMemberSetSelection,
        into folder: ZIPMemberAdditionSelection? = nil, observing source: FileOperationSelection) async throws -> ArchiveUpdatePlan {
        try await prepareArchiveOriginalUpdate(sources: [selection.archiveURL],
            original: selection.archiveURL, observing: source) { check in
            try PreparedZIPCopyEdit(.duplicate(selection, folder), check: check, updateOriginal: true)
        }
    }

    public func prepareZIPMemberDuplicateCopy(_ selection: ZIPMemberSetSelection,
        into folder: ZIPMemberAdditionSelection? = nil, outputName: String,
        observing source: FileOperationSelection) async throws -> ArchiveCreationPlan {
        guard (outputName as NSString).pathExtension.lowercased() == "zip" else {
            throw ZIPMemberRenameFailure.invalidName
        }
        return try await prepareArchiveCreation(sources: [selection.archiveURL],
            parent: selection.archiveURL.deletingLastPathComponent(), name: outputName, observing: source) { check in
            try PreparedZIPCopyEdit(.duplicate(selection, folder), check: check)
        }
    }

    public func prepareZIPMemberMoveOriginal(_ selection: ZIPMemberSetSelection,
        into folder: ZIPMemberAdditionSelection, observing source: FileOperationSelection) async throws -> ArchiveUpdatePlan {
        try await prepareArchiveOriginalUpdate(sources: [selection.archiveURL],
            original: selection.archiveURL, observing: source) { check in
            try PreparedZIPCopyEdit(.move(selection, folder), check: check, updateOriginal: true)
        }
    }

    public func prepareZIPMemberMoveCopy(_ selection: ZIPMemberSetSelection,
        into folder: ZIPMemberAdditionSelection, outputName: String,
        observing source: FileOperationSelection) async throws -> ArchiveCreationPlan {
        guard (outputName as NSString).pathExtension.lowercased() == "zip" else {
            throw ZIPMemberRenameFailure.invalidName
        }
        return try await prepareArchiveCreation(sources: [selection.archiveURL],
            parent: selection.archiveURL.deletingLastPathComponent(), name: outputName, observing: source) { check in
            try PreparedZIPCopyEdit(.move(selection, folder), check: check)
        }
    }

    public func prepareZIPFolderWithSelectionOriginal(_ selection: ZIPMemberSetSelection,
        name: String, observing source: FileOperationSelection) async throws -> ArchiveUpdatePlan {
        let seconds = Int(Date().timeIntervalSince1970)
        return try await prepareArchiveOriginalUpdate(sources: [selection.archiveURL],
            original: selection.archiveURL, observing: source) { check in
            try PreparedZIPCopyEdit(.group(selection, name, seconds), check: check, updateOriginal: true)
        }
    }

    public func prepareZIPFolderWithSelectionCopy(_ selection: ZIPMemberSetSelection,
        name: String, outputName: String, observing source: FileOperationSelection) async throws -> ArchiveCreationPlan {
        guard (outputName as NSString).pathExtension.lowercased() == "zip" else {
            throw ZIPMemberRenameFailure.invalidName
        }
        let seconds = Int(Date().timeIntervalSince1970)
        return try await prepareArchiveCreation(sources: [selection.archiveURL],
            parent: selection.archiveURL.deletingLastPathComponent(), name: outputName, observing: source) { check in
            try PreparedZIPCopyEdit(.group(selection, name, seconds), check: check)
        }
    }
}

internal enum ZIPCopyEditIntent: Sendable {
    case rename(ZIPMemberRenameSelection, String)
    case renameMany(ZIPMemberSetSelection, [String])
    case remove(ZIPMemberSetSelection)
    case duplicate(ZIPMemberSetSelection, ZIPMemberAdditionSelection?)
    case move(ZIPMemberSetSelection, ZIPMemberAdditionSelection)
    case group(ZIPMemberSetSelection, String, Int)
    case add(ZIPMemberAdditionSelection, [URL], ZIPCompression, ZIPMemberAdditionCollisionPolicy)
    case newMember(ZIPMemberAdditionSelection, String, ZIPNewMemberKind, Int)
    case replace(ZIPTextEditDocument, TextDocumentValue)

    var binding: ZIPSourceBinding {
        switch self {
        case .rename(let member, _): member.binding
        case .remove(let selection), .duplicate(let selection, _), .move(let selection, _), .renameMany(let selection, _), .group(let selection, _, _): selection.binding
        case .add(let selection, _, _, _): selection.binding
        case .newMember(let selection, _, _, _): selection.binding
        case .replace(let document, _): document.selection.binding
        }
    }

    var memberSet: ZIPMemberSetSelection? {
        switch self {
        case .remove(let selection), .duplicate(let selection, _), .move(let selection, _), .renameMany(let selection, _), .group(let selection, _, _): selection
        default: nil
        }
    }

    var duplicatesMembers: Bool { if case .duplicate = self { true } else { false } }
    var renamedBaseNames: [String]? { if case .renameMany(_, let names) = self { names } else { nil } }
    var duplicateDestination: ZIPMemberAdditionSelection? {
        if case .duplicate(_, let folder) = self { folder } else { nil }
    }
    var moveDestination: ZIPMemberAdditionSelection? {
        if case .move(_, let folder) = self { folder } else { nil }
    }
    var groupingFolder: String? {
        guard case .group(let selection, let name, _) = self,
              let first = selection.roots.first else { return nil }
        let parent = first.archivePath.split(separator: "/").dropLast().joined(separator: "/")
        return parent.isEmpty ? name : parent + "/" + name
    }
}

internal enum ZIPNewMemberKind: Equatable, Sendable {
    case file, directory
}

/// Preserves a bounded, known ordinary ZIP record profile. Browsing accepts a
/// wider set of ZIPs; copying refuses metadata it cannot represent exactly.
internal final class PreparedZIPCopyEdit: AuthoredZIPFileProducer, Sendable {
    private struct NewMember: Sendable {
        let path: String
        let kind: ZIPNewMemberKind
        let modifiedSeconds: Int
        var groupsSelection = false
    }
    internal struct Entry: Equatable, Sendable {
        let record: ZIPPayloadRecord
        let centralPosition: UInt64
        let payload: UInt64
        let end: UInt64
        let localFixed: Data
        let centralFixed: Data
        let localExtra: Data
        let centralExtra: Data
        let centralComment: Data
        let descriptor: Data
    }
    private struct Security: Equatable, Sendable {
        let quarantine: ZIPSourceSecurity.ExtractionWitness
        let provenance: Data?
        let rootMode: mode_t
        let rootOwner: uid_t
        let rootGroup: gid_t
        let rootFlags: UInt32
    }
    internal struct Manifest: Equatable, Sendable {
        let entries: [Entry]
        let retained: [Bool]
        let outputNames: [String]
        let rawOutputNames: [Data]
        /// Appended output records reuse their corresponding input payloads.
        let duplicateSources: [Int]
        let replacementIndex: Int?
        let trailer: Data
        let logical: UInt64
        let files: Int
        let folders: Int
    }
    private struct EditedRecord {
        let localOffset: UInt64
        let localFixed: Data
        let centralFixed: Data
        let descriptor: Data
        let centralEntry: Data
        let crc: UInt32
        let packed: UInt64
        let logical: UInt64
        let digest: Data
    }
    let preview: ArchiveProductionPreview
    var hasMarkedSource: Bool { security.quarantine.expectedQuarantineSHA256 != nil || additions?.hasMarkedSource == true }
    private let intent: ZIPCopyEditIntent
    private let manifest: Manifest
    private let security: Security
    private let hooks: ZIPCreationHooks
    private let additions: ZIPCreationInventory?
    private let additionReplacementNames: Set<Data>
    private let newMember: NewMember?
    private let updateOriginal: Bool

    init(_ intent: ZIPCopyEditIntent,
         check: @Sendable () throws -> Void, hooks: ZIPCreationHooks = .init(),
         updateOriginal: Bool = false) throws {
        switch intent {
        case .rename(let member, let newBaseName):
            guard Self.validBaseName(newBaseName), newBaseName != member.currentName else {
                throw ZIPMemberRenameFailure.invalidName
            }
            if case .directory(let records) = member.target {
                guard !member.archivePath.isEmpty, !member.archivePath.hasSuffix("/"),
                      !records.isEmpty, records.count <= 20_000,
                      Set(records.map(\.centralPosition)).count == records.count else {
                    throw ZIPMemberRenameFailure.invalidMember
                }
            }
        case .remove(let selection), .duplicate(let selection, _), .move(let selection, _), .renameMany(let selection, _), .group(let selection, _, _):
            guard selection.coveredSelectionCount >= 0,
                  (1...128).contains(selection.roots.count + selection.coveredSelectionCount),
                  (1...20_000).contains(selection.members.count),
                  selection.archivePaths == selection.roots.map(\.archivePath),
                  selection.folderPaths == selection.roots.filter(\.isDirectory).map(\.archivePath),
                  Set(selection.members.map(\.centralPosition)).count == selection.members.count else {
                throw ZIPMemberRemovalFailure.invalidSelection
            }
            if let folder = intent.moveDestination ?? intent.duplicateDestination {
                guard selection.archiveURL.path.utf8.elementsEqual(folder.archiveURL.path.utf8),
                      selection.binding.stamp == folder.binding.stamp else {
                    throw ZIPMemberRenameFailure.sourceChanged
                }
            }
            if let names = intent.renamedBaseNames {
                guard selection.coveredSelectionCount == 0, (2...128).contains(names.count),
                      names.count == selection.roots.count, names.allSatisfy(Self.validBaseName),
                      zip(selection.roots, names).contains(where: {
                          $0.archivePath.split(separator: "/").last?.utf8.elementsEqual($1.utf8) != true
                      }) else { throw ZIPMemberRenameFailure.invalidName }
            }
            if case .group(_, let name, _) = intent {
                guard Self.validBaseName(name), selection.coveredSelectionCount == 0 else {
                    throw ZIPMemberNewEntryFailure.invalidName
                }
            }
        case .add(let selection, let sources, _, _):
            guard !sources.isEmpty, sources.count <= 511, !sources.contains(selection.archiveURL) else {
                throw ZIPMemberAdditionFailure.invalidSelection
            }
        case .newMember(_, let name, _, _):
            guard Self.validBaseName(name) else { throw ZIPMemberNewEntryFailure.invalidName }
        case .replace(let document, let contents):
            guard document.sourceDigest.count == 32,
                  try TextDocumentValue.original(contents.encoded) == contents else {
                throw ZIPMemberRenameFailure.invalidMember
            }
            // A saved member must remain eligible for exact rebind and a
            // second Save through the same selected-text admission path.
            guard document.contents.encoded.count <= Int(ZIPTextPreview.maximumUTF8Bytes),
                  contents.encoded.count <= Int(ZIPTextPreview.maximumUTF8Bytes) else {
                throw ZIPTextPreviewFailure.tooLarge
            }
            _ = try ZIPTextPreviewReader.validatedText(contents.encoded)
        }
        self.intent = intent
        self.hooks = hooks
        self.updateOriginal = updateOriginal
        let member: NewMember?
        if case .newMember(let selection, let name, let kind, let modifiedSeconds) = intent {
            member = .init(path: (selection.virtualFolder.isEmpty ? "" : selection.virtualFolder + "/")
                + name + (kind == .directory ? "/" : ""), kind: kind, modifiedSeconds: modifiedSeconds)
        } else if case .group(_, _, let seconds) = intent, let folder = intent.groupingFolder {
            member = .init(path: folder + "/", kind: .directory, modifiedSeconds: seconds, groupsSelection: true)
        } else { member = nil }
        newMember = member
        do {
            let started = ProcessInfo.processInfo.systemUptime
            func checkpoint() throws {
                try check()
                guard ProcessInfo.processInfo.systemUptime - started < ZIPContentLimits().seconds else {
                    throw ZIPMemberRenameFailure.limitReached
                }
            }
            let (source, security) = try Self.openSource(intent.binding, check: checkpoint)
            if updateOriginal {
                guard [mode_t(0o600), mode_t(0o644)].contains(security.rootMode),
                      security.rootFlags == 0 || security.rootFlags == UInt32(UF_TRACKED) else {
                    throw ZIPMemberRenameFailure.unsupportedSecurity
                }
            }
            // Replacement names come only from fully checked regular-file
            // roots. Descendants and folder roots never authorize a merge.
            var additions: ZIPCreationInventory?
            if case .add(let selection, let sources, _, .replaceFiles) = intent {
                additions = try ZIPCreationInventory(sources, prefix: selection.virtualFolder, check: checkpoint)
            }
            let replacing = Set(additions?.roots.filter { !$0.isDirectory }.map { Data($0.archivePath.utf8) } ?? [])
            let manifest = try Self.manifest(length: UInt64(source.observed.size), intent: intent,
                replacingAdditionFiles: replacing,
                check: checkpoint, read: { try source.read($0, $1, maximum: 16 << 20, check: checkpoint) })
            if case .replace(let document, _) = intent {
                guard let index = manifest.replacementIndex,
                      try Self.digest(manifest.entries[index], source: source, check: checkpoint) == document.sourceDigest else {
                    throw ZIPMemberRenameFailure.sourceChanged
                }
            }
            if additions == nil, case .add(let selection, let sources, _, let collisions) = intent {
                let names = collisions == .keepBoth
                    ? try Self.occupiedChildren(of: selection.virtualFolder, manifest: manifest, check: checkpoint) : nil
                additions = try ZIPCreationInventory(sources, prefix: selection.virtualFolder, reserving: names, check: checkpoint)
            }
            let combined = try Self.combinedPreview(manifest, additions: additions,
                newMember: member, check: checkpoint)
            try source.validate()
            self.security = security
            self.manifest = manifest
            self.additions = additions
            self.additionReplacementNames = replacing
            preview = combined
        } catch { throw Self.preparationFailure(error) }
    }

    func validate(check: @Sendable () throws -> Void) throws {
        do {
            let (source, observedSecurity) = try Self.openSource(intent.binding, check: check)
            guard observedSecurity == security else { throw FileOperationFailure.sourceChanged }
            try additions?.validate(check: check)
            if case .replace(let document, _) = intent {
                guard let index = manifest.replacementIndex,
                      try Self.digest(manifest.entries[index], source: source, check: check) == document.sourceDigest else {
                    throw FileOperationFailure.sourceChanged
                }
            }
            try source.validate()
        } catch is CancellationError { throw CancellationError() }
          catch { throw FileOperationFailure.sourceChanged }
    }

    func produce(into descriptor: Int32, check: @Sendable () throws -> Void,
        progress: @Sendable (UInt64, Int) -> Void) throws -> ArchiveProducedNode {
        try produce(into: descriptor, stageSecurity: nil, check: check, progress: progress).node
    }

    func produceAuthoredZIP(into descriptor: Int32, stageSecurity: AuthoredZIPSecurityWitness,
        allowSourceMarkInheritance: Bool,
        check: @Sendable () throws -> Void,
        progress: @Sendable (UInt64, Int) -> Void) throws -> AuthoredZIPProducedFile {
        let produced = try produce(into: descriptor, stageSecurity: stageSecurity,
            allowSourceMarkInheritance: allowSourceMarkInheritance,
            check: check, progress: progress)
        guard let security = produced.security else { throw FileOperationFailure.copyMetadataMismatch }
        return .init(node: produced.node, security: security)
    }

    func requirePublicQuarantineRecognition(_ descriptor: Int32, at url: URL) throws {
        _ = try ZIPSourceSecurity.extractionWitness(descriptor, url: url, allowingInheritance: true)
    }

    private func produce(into descriptor: Int32, stageSecurity: AuthoredZIPSecurityWitness?,
        allowSourceMarkInheritance: Bool = true,
        check: @Sendable () throws -> Void,
        progress: @Sendable (UInt64, Int) -> Void) throws -> (node: ArchiveProducedNode, security: AuthoredZIPSecurityWitness?) {
        let started = ProcessInfo.processInfo.systemUptime
        func checkpoint() throws {
            try check()
            guard ProcessInfo.processInfo.systemUptime - started < ZIPContentLimits().seconds else {
                throw ZIPMemberRenameFailure.limitReached
            }
        }
        do {
            try validate(check: check)
            var initial = stat()
            guard fstat(descriptor, &initial) == 0, initial.st_mode & S_IFMT == S_IFREG,
                  initial.st_uid == geteuid(), initial.st_nlink == 1, initial.st_size == 0 else {
                throw FileOperationFailure.destinationChanged
            }
            if let stageSecurity, try Self.outputSecurity(descriptor) != stageSecurity {
                throw FileOperationFailure.copyMetadataMismatch
            }
            if stageSecurity?.quarantine == nil && !allowSourceMarkInheritance
                && security.quarantine.expectedQuarantineSHA256 != nil {
                throw FileOperationFailure.copyMetadataMismatch
            }
            let (source, observedSecurity) = try Self.openSource(intent.binding, check: checkpoint)
            guard observedSecurity == security else { throw FileOperationFailure.sourceChanged }
            let fresh = try Self.manifest(length: UInt64(source.observed.size), intent: intent,
                replacingAdditionFiles: additionReplacementNames, check: checkpoint,
                read: { try source.read($0, $1, maximum: 16 << 20, check: checkpoint) })
            guard fresh == manifest else {
                throw FileOperationFailure.sourceChanged
            }
            // Full body checks begin only after Save. The first digest pass is
            // the baseline for every record, including those omitted from the
            // copy; the writing pass below must match it before publication.
            let sourceDigests: [Data]?
            if case .remove = intent {
                sourceDigests = try Self.digestAll(fresh.entries, source: source, check: checkpoint)
                try source.validate(); try validate(check: check)
            } else if case .replace = intent {
                sourceDigests = try Self.digestAll(fresh.entries, source: source, check: checkpoint)
                try source.validate(); try validate(check: check)
            } else if !additionReplacementNames.isEmpty && fresh.retained.contains(false) {
                sourceDigests = try Self.digestAll(fresh.entries, source: source, check: checkpoint)
                try source.validate(); try validate(check: check)
            } else { sourceDigests = nil }
            let writer = ZIPFileEncoder(descriptor, hooks: hooks)
            var central = Data()
            var contentDigests = [Data](repeating: Data(), count: fresh.entries.count)
            var outputOffsets = [UInt64](repeating: 0, count: fresh.entries.count)
            var editedRecord: EditedRecord?
            let duplicateStart = fresh.entries.count - fresh.duplicateSources.count
            for index in fresh.entries.indices.sorted(by: {
                let a = fresh.entries[$0].record.localOffset, b = fresh.entries[$1].record.localOffset
                return a == b ? $0 < $1 : a < b
            }) {
                let entry = fresh.entries[index]
                try checkpoint(); try source.validate()
                let retained = fresh.retained[index]
                if index == fresh.replacementIndex, case .replace(let document, let contents) = intent {
                    guard let sourceDigests,
                          sourceDigests[index] == document.sourceDigest,
                          try Self.digest(entry, source: source, check: checkpoint) == sourceDigests[index] else {
                        throw ZIPMemberRenameFailure.contentMismatch
                    }
                    let edited = try Self.writeEditedRecord(entry, contents: contents,
                        writer: writer, check: checkpoint)
                    editedRecord = edited
                    outputOffsets[index] = edited.localOffset
                    contentDigests[index] = edited.digest
                    progress(edited.logical, 1)
                    try source.validate()
                    continue
                }
                if retained {
                    outputOffsets[index] = writer.count
                    try writer.write(Self.localHeader(entry, name: fresh.rawOutputNames[index]), check: checkpoint)
                }
                let payloadStart = writer.count
                var content = SHA256()
                try ZIPContentDecoder.check(method: entry.record.method, packed: entry.record.packed,
                    logical: entry.record.logical, expectedCRC: entry.record.crc, check: checkpoint,
                    read: { offset, count in
                        try hooks.beforeSourceRead?(source.url)
                        let bytes = try source.read(entry.payload + offset, count, maximum: 65_536, check: checkpoint)
                        if retained { try writer.write(bytes, check: checkpoint) }
                        return bytes
                    }, decoded: { if retained { progress($0, 0) } },
                    consume: { content.update(bufferPointer: $0) })
                let digest = Data(content.finalize())
                if let sourceDigests, digest != sourceDigests[index] {
                    throw ZIPMemberRenameFailure.contentMismatch
                }
                if index >= duplicateStart, digest != contentDigests[fresh.duplicateSources[index - duplicateStart]] {
                    throw ZIPMemberRenameFailure.contentMismatch
                }
                if retained {
                    guard writer.count - payloadStart == entry.record.packed else {
                        throw ZIPMemberRenameFailure.contentMismatch
                    }
                    try writer.write(entry.descriptor, check: checkpoint)
                    contentDigests[index] = digest
                    progress(0, 1)
                }
                try source.validate()
            }
            if fresh.replacementIndex != nil, editedRecord == nil {
                throw ZIPMemberRenameFailure.contentMismatch
            }
            let retainedIndices = fresh.entries.indices.filter { fresh.retained[$0] }
            for index in retainedIndices {
                try checkpoint()
                let entry = fresh.entries[index]
                let centralEntry: Data
                if index == fresh.replacementIndex, let editedRecord {
                    centralEntry = editedRecord.centralEntry
                } else {
                    centralEntry = Self.centralHeader(entry, name: fresh.rawOutputNames[index],
                        localOffset: outputOffsets[index])
                }
                guard centralEntry.count <= 16 << 20, central.count <= (16 << 20) - centralEntry.count else {
                    throw ZIPMemberRenameFailure.limitReached
                }
                central += centralEntry
            }
            let added: [ZIPEncodedNode]
            if let additions, case .add(_, _, let compression, _) = intent {
                added = try ZIPNodeEncoder.append(additions, compression: compression, writer: writer,
                    hooks: hooks, check: checkpoint, progress: progress)
                for node in added {
                    guard central.count <= (16 << 20) - node.centralEntry.count else {
                        throw ZIPMemberRenameFailure.limitReached
                    }
                    central += node.centralEntry
                }
            } else if let newMember {
                added = [try ZIPNodeEncoder.appendEmptyMember(name: newMember.path,
                    modifiedSeconds: newMember.modifiedSeconds,
                    mode: newMember.kind == .directory ? S_IFDIR | 0o755 : S_IFREG | 0o644,
                    writer: writer, check: checkpoint)]
                guard central.count <= (16 << 20) - added[0].centralEntry.count else {
                    throw ZIPMemberRenameFailure.limitReached
                }
                central += added[0].centralEntry
                progress(0, 1)
            } else { added = [] }
            let recordCount = retainedIndices.count + added.count
            let centralOffset = writer.count
            try writer.write(central, check: checkpoint)
            try writer.write(Self.trailer(fresh.trailer, centralBytes: central.count,
                                         centralOffset: centralOffset, records: recordCount), check: checkpoint)
            try hooks.beforeValidation?(descriptor)
            try source.validate(); try checkpoint(); try validate(check: check)
            let output = try Self.manifest(length: writer.count, intent: nil,
                check: checkpoint, read: { try Self.readOutput(descriptor, length: writer.count,
                    offset: $0, count: $1, check: checkpoint) })
            guard output.outputNames == retainedIndices.map({ fresh.outputNames[$0] }) + added.map(\.name),
                  output.rawOutputNames == retainedIndices.map({ fresh.rawOutputNames[$0] }) + added.map({ Data($0.name.utf8) }),
                  output.trailer == Self.trailer(fresh.trailer, centralBytes: central.count,
                      centralOffset: centralOffset, records: recordCount), output.files == preview.files,
                  output.folders == preview.folders, output.logical == preview.logicalBytes,
                  output.entries.count == recordCount else {
                throw ZIPMemberRenameFailure.contentMismatch
            }
            for (index, entry) in output.entries.prefix(retainedIndices.count).enumerated() {
                try checkpoint()
                let sourceIndex = retainedIndices[index], old = fresh.entries[sourceIndex]
                if sourceIndex == fresh.replacementIndex, let editedRecord {
                    guard entry.record.kind == .file, entry.record.flags == old.record.flags,
                          entry.record.rawName == old.record.rawName,
                          entry.record.name == old.record.name,
                          entry.record.localOffset == editedRecord.localOffset,
                          entry.record.method == old.record.method,
                          entry.record.crc == editedRecord.crc,
                          entry.record.logical == editedRecord.logical,
                          entry.record.packed == editedRecord.packed,
                          entry.localFixed == editedRecord.localFixed,
                          entry.centralFixed == editedRecord.centralFixed,
                          entry.localExtra == old.localExtra,
                          entry.centralExtra == old.centralExtra,
                          entry.centralComment == old.centralComment,
                          entry.descriptor == editedRecord.descriptor else {
                        throw ZIPMemberRenameFailure.contentMismatch
                    }
                    var content = SHA256()
                    try ZIPContentDecoder.check(method: entry.record.method,
                        packed: entry.record.packed, logical: entry.record.logical,
                        expectedCRC: entry.record.crc, check: checkpoint,
                        read: { try Self.readOutput(descriptor, length: writer.count,
                            offset: entry.payload + $0, count: $1, check: checkpoint) },
                        decoded: { _ in }, consume: { content.update(bufferPointer: $0) })
                    guard Data(content.finalize()) == editedRecord.digest else {
                        throw ZIPMemberRenameFailure.contentMismatch
                    }
                    continue
                }
                guard entry.record.kind == old.record.kind, entry.record.flags == old.record.flags,
                      entry.record.rawName == fresh.rawOutputNames[sourceIndex],
                      entry.record.localOffset == outputOffsets[sourceIndex],
                      entry.record.method == old.record.method,
                      entry.record.crc == old.record.crc, entry.record.logical == old.record.logical,
                      entry.record.packed == old.record.packed,
                      entry.localFixed == Self.patchedLocalFixed(old.localFixed, name: fresh.rawOutputNames[sourceIndex]),
                      entry.centralFixed == Self.patchedCentralFixed(old.centralFixed,
                          name: fresh.rawOutputNames[sourceIndex], localOffset: outputOffsets[sourceIndex]),
                      entry.localExtra == old.localExtra, entry.centralExtra == old.centralExtra,
                      entry.centralComment == old.centralComment,
                      entry.descriptor == old.descriptor else { throw ZIPMemberRenameFailure.contentMismatch }
                var content = SHA256()
                try ZIPContentDecoder.check(method: entry.record.method, packed: entry.record.packed,
                    logical: entry.record.logical, expectedCRC: entry.record.crc, check: checkpoint,
                    read: { try Self.readOutput(descriptor, length: writer.count,
                        offset: entry.payload + $0, count: $1, check: checkpoint) },
                    decoded: { _ in }, consume: { content.update(bufferPointer: $0) })
                guard Data(content.finalize()) == contentDigests[sourceIndex] else {
                    throw ZIPMemberRenameFailure.contentMismatch
                }
            }
            for (entry, node) in zip(output.entries.dropFirst(retainedIndices.count), added) {
                try checkpoint()
                guard node.matches(entry.record),
                      Self.localHeader(entry, name: entry.record.rawName) == node.localHeader,
                      Self.centralHeader(entry, name: entry.record.rawName, localOffset: entry.record.localOffset) == node.centralEntry,
                      entry.descriptor == node.dataDescriptor else { throw ZIPMemberRenameFailure.contentMismatch }
                var content = SHA256()
                try ZIPContentDecoder.check(method: entry.record.method, packed: entry.record.packed,
                    logical: entry.record.logical, expectedCRC: entry.record.crc, check: checkpoint,
                    read: { try Self.readOutput(descriptor, length: writer.count,
                        offset: entry.payload + $0, count: $1, check: checkpoint) },
                    decoded: { _ in }, consume: { content.update(bufferPointer: $0) })
                guard Data(content.finalize()) == node.digest else { throw ZIPMemberRenameFailure.contentMismatch }
            }
            try source.validate(); try checkpoint(); try validate(check: check)
            guard fchmod(descriptor, updateOriginal ? security.rootMode : 0o644) == 0 else {
                throw ZIPCreationInventory.failure()
            }
            let producedSecurity: AuthoredZIPSecurityWitness?
            do {
                if let stageSecurity {
                    // A native mark on the fresh payload is its own exact
                    // baseline. An unmarked stage retains the older exact
                    // source-inheritance rule for a marked source.
                    if stageSecurity.quarantine == nil && allowSourceMarkInheritance {
                        try security.quarantine.apply(to: descriptor)
                    }
                    let actual = try Self.outputSecurity(descriptor)
                    if stageSecurity.quarantine == nil,
                       !security.quarantine.matchesOutputMark(actual.quarantine) {
                        throw FileOperationFailure.copyMetadataMismatch
                    }
                    let expected = AuthoredZIPSecurityWitness(
                        quarantine: stageSecurity.quarantine ?? actual.quarantine,
                        provenance: stageSecurity.provenance ?? security.provenance)
                    guard actual == expected else { throw FileOperationFailure.copyMetadataMismatch }
                    producedSecurity = expected
                } else {
                    try security.quarantine.apply(to: descriptor)
                    guard try security.quarantine.matchesOutput(descriptor),
                          try Self.outputProvenance(descriptor, source: security.provenance,
                                                    exactAbsence: updateOriginal) else {
                        throw FileOperationFailure.copyMetadataMismatch
                    }
                    producedSecurity = nil
                }
            } catch { throw FileOperationFailure.copyMetadataMismatch }
            try source.validate(); try checkpoint(); try validate(check: check)
            var final = stat()
            guard fstat(descriptor, &final) == 0, final.st_dev == initial.st_dev,
                  final.st_ino == initial.st_ino, final.st_size == writer.count,
                  final.st_nlink == 1, final.st_uid == geteuid(),
                  !updateOriginal || (final.st_uid == security.rootOwner
                      && final.st_gid == security.rootGroup
                      && final.st_flags == security.rootFlags
                      && final.st_mode & 0o7777 == security.rootMode) else {
                throw FileOperationFailure.destinationChanged
            }
            let node = ArchiveProducedNode(relative: "", device: final.st_dev, inode: final.st_ino, kind: S_IFREG,
                birthSeconds: final.st_birthtimespec.tv_sec, birthNanoseconds: final.st_birthtimespec.tv_nsec,
                changedSeconds: final.st_ctimespec.tv_sec, changedNanoseconds: final.st_ctimespec.tv_nsec,
                size: final.st_size, contentSHA256: writer.digest())
            return (node, producedSecurity)
        } catch {
            try validate(check: check)
            throw Self.operationFailure(error)
        }
    }

    /// The first execution pass checks every source body and records a digest.
    /// Omitted bytes never enter the output descriptor in the second pass.
    private static func digest(_ entry: Entry, source: ZIPSourceFile,
        check: () throws -> Void) throws -> Data {
        try check(); try source.validate()
        var content = SHA256()
        try ZIPContentDecoder.check(method: entry.record.method, packed: entry.record.packed,
            logical: entry.record.logical, expectedCRC: entry.record.crc, check: check,
            read: { try source.read(entry.payload + $0, $1, maximum: 65_536, check: check) },
            decoded: { _ in }, consume: { content.update(bufferPointer: $0) })
        try source.validate()
        return Data(content.finalize())
    }

    private static func digestAll(_ entries: [Entry], source: ZIPSourceFile,
        check: () throws -> Void) throws -> [Data] {
        var digests = [Data](repeating: Data(), count: entries.count)
        for index in entries.indices.sorted(by: { entries[$0].record.localOffset < entries[$1].record.localOffset }) {
            digests[index] = try digest(entries[index], source: source, check: check)
        }
        return digests
    }

    /// Rewrite only content fields in the selected record. Preserve its name,
    /// timestamps, permissions, supported extras and descriptor form exactly.
    private static func writeEditedRecord(_ entry: Entry, contents: TextDocumentValue,
        writer: ZIPFileEncoder, check: () throws -> Void) throws -> EditedRecord {
        try check()
        let bytes = contents.encoded
        let logical = UInt64(bytes.count), localOffset = writer.count
        guard logical <= UInt32.max, localOffset <= UInt32.max,
              entry.record.kind == .file,
              entry.record.method == 0 || entry.record.method == 8,
              entry.record.flags & 0x0006 == 0 else {
            throw ZIPMemberRenameFailure.unsupportedArchive
        }
        let crc = bytes.withUnsafeBytes {
            UInt32(truncatingIfNeeded: zlib.crc32(0,
                $0.bindMemory(to: UInt8.self).baseAddress, uInt(bytes.count)))
        }
        let digest = Data(SHA256.hash(data: bytes))
        let packedBytes: Data
        if entry.record.method == 0 {
            packedBytes = bytes
        } else {
            var encoded = Data()
            var cursor = 0
            try ZIPDeflateEncoder.encode(level: ZIPCompression.balanced.level,
                check: check, read: {
                    try check()
                    guard cursor < bytes.count else { return Data() }
                    let end = min(bytes.count, cursor + 65_536)
                    defer { cursor = end }
                    return Data(bytes[cursor..<end])
                }, output: { chunk in
                    try check()
                    guard encoded.count <= (2 << 20) - chunk.count else {
                        throw ZIPMemberRenameFailure.limitReached
                    }
                    encoded.append(contentsOf: chunk)
                })
            packedBytes = encoded
        }
        let packed = UInt64(packedBytes.count)
        guard packed <= UInt32.max else { throw ZIPMemberRenameFailure.limitReached }
        var localFixed = entry.localFixed
        let streamed = entry.record.flags & 8 != 0
        if !streamed || ZIPMetadataParser.u32(localFixed, 14) != 0 {
            localFixed.replaceSubrange(14..<18, with: ZIPFileEncoder.le(UInt64(crc), 4))
        }
        if !streamed || ZIPMetadataParser.u32(localFixed, 18) != 0 {
            localFixed.replaceSubrange(18..<22, with: ZIPFileEncoder.le(packed, 4))
        }
        if !streamed || ZIPMetadataParser.u32(localFixed, 22) != 0 {
            localFixed.replaceSubrange(22..<26, with: ZIPFileEncoder.le(logical, 4))
        }
        var centralFixed = entry.centralFixed
        centralFixed.replaceSubrange(16..<20, with: ZIPFileEncoder.le(UInt64(crc), 4))
        centralFixed.replaceSubrange(20..<24, with: ZIPFileEncoder.le(packed, 4))
        centralFixed.replaceSubrange(24..<28, with: ZIPFileEncoder.le(logical, 4))
        centralFixed.replaceSubrange(42..<46, with: ZIPFileEncoder.le(localOffset, 4))
        var descriptor = entry.descriptor
        if streamed {
            let start: Int
            if descriptor.count == 16 {
                guard ZIPMetadataParser.u32(descriptor, 0) == 0x08074b50 else {
                    throw ZIPMemberRenameFailure.unsupportedArchive
                }
                start = 4
            } else {
                guard descriptor.count == 12 else { throw ZIPMemberRenameFailure.unsupportedArchive }
                start = 0
            }
            descriptor.replaceSubrange(start..<(start + 4), with: ZIPFileEncoder.le(UInt64(crc), 4))
            descriptor.replaceSubrange((start + 4)..<(start + 8), with: ZIPFileEncoder.le(packed, 4))
            descriptor.replaceSubrange((start + 8)..<(start + 12), with: ZIPFileEncoder.le(logical, 4))
        } else {
            guard descriptor.isEmpty else { throw ZIPMemberRenameFailure.unsupportedArchive }
        }
        try writer.write(localFixed, check: check)
        try writer.write(entry.record.rawName, check: check)
        try writer.write(entry.localExtra, check: check)
        try writer.write(packedBytes, check: check)
        try writer.write(descriptor, check: check)
        return .init(localOffset: localOffset, localFixed: localFixed,
            centralFixed: centralFixed, descriptor: descriptor,
            centralEntry: centralFixed + entry.record.rawName + entry.centralExtra + entry.centralComment,
            crc: crc, packed: packed, logical: logical, digest: digest)
    }

    private static func openSource(_ binding: ZIPSourceBinding,
        check: () throws -> Void) throws -> (ZIPSourceFile, Security) {
        try check()
        guard binding.source.pathExtension.lowercased() == "zip" else {
            throw ZIPMemberRenameFailure.unsupportedArchive
        }
        let source: ZIPSourceFile
        do { source = try ZIPSourceFile(binding.source) }
        catch ZIPArchiveFailure.unsupported { throw ZIPMemberRenameFailure.unsupportedSecurity }
        catch { throw ZIPMemberRenameFailure.sourceChanged }
        guard source.observed == binding.stamp else { throw ZIPMemberRenameFailure.sourceChanged }
        guard source.observed.size >= 0, source.observed.size <= 1 << 30 else {
            throw ZIPMemberRenameFailure.limitReached
        }
        var facts = stat()
        guard fstat(source.descriptor, &facts) == 0, facts.st_nlink == 1,
              facts.st_uid == geteuid() else { throw ZIPMemberRenameFailure.unsupportedSecurity }
        let security: Security
        do {
            let quarantine = try ZIPSourceSecurity.extractionWitness(source.descriptor,
                url: source.url, allowingInheritance: true)
            // ZIP entry metadata is copied exactly. For the source file itself,
            // only quarantine and OS provenance have a qualified output rule.
            // Resource forks, other xattrs and extended ACLs stay unsupported.
            let size = flistxattr(source.descriptor, nil, 0, 0)
            guard size >= 0, size <= 4_096 else { throw ZIPMemberRenameFailure.unsupportedSecurity }
            var names = [CChar](repeating: 0, count: max(1, size))
            guard flistxattr(source.descriptor, &names, size, 0) == size else {
                throw ZIPMemberRenameFailure.sourceChanged
            }
            for name in names.prefix(size).split(separator: 0) {
                let bytes = Data(name.map { UInt8(bitPattern: $0) })
                guard let literal = String(data: bytes, encoding: .utf8),
                      literal == "com.apple.quarantine" || literal == "com.apple.provenance" else {
                    throw ZIPMemberRenameFailure.unsupportedSecurity
                }
            }
            let provenance = try attribute(source.descriptor, name: "com.apple.provenance")
            if let acl = acl_get_fd_np(source.descriptor, ACL_TYPE_EXTENDED) {
                acl_free(UnsafeMutableRawPointer(acl))
                throw ZIPMemberRenameFailure.unsupportedSecurity
            }
            guard errno == ENOENT else { throw ZIPMemberRenameFailure.unsupportedSecurity }
            security = .init(quarantine: quarantine, provenance: provenance,
                             rootMode: facts.st_mode & 0o7777, rootOwner: facts.st_uid,
                             rootGroup: facts.st_gid, rootFlags: facts.st_flags)
        } catch let failure as ZIPMemberRenameFailure { throw failure }
          catch { throw ZIPMemberRenameFailure.unsupportedSecurity }
        try source.validate(); try check()
        return (source, security)
    }

    private static func attribute(_ descriptor: Int32, name: String) throws -> Data? {
        let size = fgetxattr(descriptor, name, nil, 0, 0, 0)
        if size < 0, errno == ENOATTR { return nil }
        guard size > 0, size <= 4_096 else { throw ZIPMemberRenameFailure.unsupportedSecurity }
        var data = Data(count: size)
        guard data.withUnsafeMutableBytes({ fgetxattr(descriptor, name, $0.baseAddress, size, 0, 0) }) == size else {
            throw ZIPMemberRenameFailure.sourceChanged
        }
        return data
    }

    private static func outputSecurity(_ descriptor: Int32) throws -> AuthoredZIPSecurityWitness {
        .init(quarantine: try attribute(descriptor, name: "com.apple.quarantine"),
              provenance: try attribute(descriptor, name: "com.apple.provenance"))
    }

    private static func outputProvenance(_ descriptor: Int32, source: Data?,
                                         exactAbsence: Bool) throws -> Bool {
        if !exactAbsence && source == nil { return true }
        return try attribute(descriptor, name: "com.apple.provenance") == source
    }

    private static func validBaseName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && name.utf8.count <= 255
            && !name.contains("/") && !name.contains("\\") && !name.utf8.contains(0)
            && !(name.utf8.count >= 2 && name.utf8.dropFirst().first == 58)
            && !name.unicodeScalars.contains(where: {
                CharacterSet.controlCharacters.contains($0) || [0x061c, 0x200e, 0x200f].contains($0.value)
                    || (0x202a...0x202e).contains($0.value) || (0x2066...0x2069).contains($0.value)
            })
    }

    private static func manifest(length: UInt64, intent: ZIPCopyEditIntent?,
        replacingAdditionFiles: Set<Data> = [], check: () throws -> Void,
        read: (UInt64, Int) throws -> Data) throws -> Manifest {
        try check()
        if !replacingAdditionFiles.isEmpty {
            guard case .some(.add(_, _, _, .replaceFiles)) = intent else {
                throw ZIPMemberAdditionFailure.invalidSelection
            }
        }
        guard length >= 22, length <= 1 << 30 else { throw ZIPMemberRenameFailure.limitReached }
        var limits = ZIPReadLimits()
        limits.members = 20_000; limits.nodes = 20_000; limits.centralBytes = 16 << 20; limits.depth = 63
        var records: [ZIPPayloadRecord] = []
        let storage = try ZIPMetadataParser.parse(length: length, limits: limits,
            capture: { records.append($0) }, cancelled: { (try? check()) == nil }, read: read)
        guard !storage.summary.isZIP64, storage.summary.encryptedMembers == 0,
              storage.summary.symbolicLinks == 0, storage.summary.specialMembers == 0,
              storage.summary.caseConflicts == 0, let centralOffset = storage.centralOffset,
              centralOffset <= length, storage.summary.centralBytes <= 16 << 20,
              UInt64(storage.summary.centralBytes) <= length - centralOffset,
              length - centralOffset - UInt64(storage.summary.centralBytes) >= 22,
              length - centralOffset - UInt64(storage.summary.centralBytes) <= 65_557 else {
            throw ZIPMemberRenameFailure.unsupportedArchive
        }
        // The reader has already bound one unambiguous end record. Keep its
        // opaque archive comment instead of dropping valid user information.
        let trailerStart = centralOffset + UInt64(storage.summary.centralBytes)
        let trailerBytes = Int(length - trailerStart)
        let trailer = try read(trailerStart, trailerBytes)
        guard trailer.count == trailerBytes, ZIPMetadataParser.u32(trailer, 0) == 0x06054b50,
              Int(ZIPMetadataParser.u16(trailer, 20)) == trailerBytes - 22 else {
            throw ZIPMemberRenameFailure.unsupportedArchive
        }
        if case .some(.replace(let document, _)) = intent {
            let witness = document.selection.directoryWitness
            guard witness.offset == centralOffset, witness.bytes == length - centralOffset,
                  witness.digest.count == 32 else { throw ZIPMemberRenameFailure.sourceChanged }
            var digest = SHA256(), offset: UInt64 = 0
            while offset < witness.bytes {
                try check()
                let count = Int(min(UInt64(65_536), witness.bytes - offset))
                digest.update(data: try read(witness.offset + offset, count))
                offset += UInt64(count)
            }
            guard Data(digest.finalize()) == witness.digest else { throw ZIPMemberRenameFailure.sourceChanged }
        }
        let layout = try ZIPContentVerifier.prepare(records, limits: .init(), check: check, read: read)
        guard records.count == layout.extents.count, records.count <= UInt16.max else {
            throw ZIPMemberRenameFailure.limitReached
        }
        var extents: [UInt64: ZIPPayloadExtent] = [:]
        var cursor: UInt64 = 0
        for extent in layout.extents {
            try check()
            guard extent.record.localOffset == cursor, extents[extent.record.localOffset] == nil else {
                throw ZIPMemberRenameFailure.unsupportedArchive
            }
            extents[extent.record.localOffset] = extent
            cursor = extent.end
        }
        guard cursor == centralOffset else { throw ZIPMemberRenameFailure.unsupportedArchive }
        var entries: [Entry] = [], centralCursor = centralOffset
        var names: [String] = [], rawNames: [Data] = [], retained: [Bool] = []
        var selected = 0
        var replacementIndex: Int?
        var directoryByPosition: [UInt64: ZIPCopyBoundRecord] = [:]
        var directoryDestinationPrefix: String?
        if case .some(.rename(let member, let newBaseName)) = intent,
           case .directory(let records) = member.target {
            directoryDestinationPrefix = (member.virtualParent.isEmpty ? "" : member.virtualParent + "/")
                + newBaseName + "/"
            for item in records {
                guard directoryByPosition.updateValue(item, forKey: item.centralPosition) == nil else {
                    throw ZIPMemberRenameFailure.invalidMember
                }
            }
        }
        var groupByPosition: [UInt64: ZIPCopyBoundRecord] = [:]
        var groupRoots: [(path: Data, isDirectory: Bool)] = []
        let duplicateNames: [String]
        let copyParent = intent?.duplicateDestination?.virtualFolder
        let moveParent: String?
        if let selection = intent?.memberSet {
            groupRoots = selection.roots.map { root in
                (Data((root.archivePath + (root.isDirectory ? "/" : "")).utf8), root.isDirectory)
            }
            for item in selection.members {
                guard groupByPosition.updateValue(item, forKey: item.centralPosition) == nil else {
                    throw ZIPMemberRemovalFailure.invalidSelection
                }
            }
            duplicateNames = try intent?.duplicatesMembers == true
                ? Self.duplicateBaseNames(selection, into: copyParent, in: storage, check: check) : []
            if let folder = intent?.moveDestination {
                try Self.validateMove(selection, into: folder.virtualFolder, in: storage, check: check)
                moveParent = folder.virtualFolder
            } else if let folder = intent?.groupingFolder {
                try Self.validateGrouping(selection, into: folder, in: storage, check: check)
                moveParent = folder
            } else { moveParent = nil }
            if let names = intent?.renamedBaseNames {
                try Self.validateBatchRename(selection, to: names, in: storage, check: check)
            }
        } else { duplicateNames = []; moveParent = nil }
        var duplicates: [(source: Int, rawName: Data, name: String)] = []
        for record in records {
            try check()
            guard let extent = extents[record.localOffset],
                  extent.record == record,
                  record.centralOffset == centralOffset, !record.usesZIP64,
                  record.flags & ~UInt16(0x080e) == 0,
                  record.method == 8 || record.flags & 0x0006 == 0,
                  record.kind == .file || record.kind == .directory,
                  record.method == 0 || record.method == 8,
                  record.logical <= UInt32.max, record.packed <= UInt32.max else {
                throw ZIPMemberRenameFailure.unsupportedArchive
            }
            let centralFixed = try read(centralCursor, 46)
            guard centralFixed.count == 46 else { throw ZIPMemberRenameFailure.contentMismatch }
            let nameBytes = Int(ZIPMetadataParser.u16(centralFixed, 28))
            let extraBytes = Int(ZIPMetadataParser.u16(centralFixed, 30))
            let commentBytes = Int(ZIPMetadataParser.u16(centralFixed, 32))
            let creator = ZIPMetadataParser.u16(centralFixed, 4)
            let needed = ZIPMetadataParser.u16(centralFixed, 6)
            let centralFields = 46 + nameBytes + extraBytes
            guard nameBytes == record.rawName.count, extraBytes <= 512,
                  [0, 3, 10].contains(creator >> 8), [10, 20].contains(creator & 0xff),
                  (record.method == 0 && record.flags & 8 == 0 ? [10, 20] : [20]).contains(needed),
                  ZIPMetadataParser.u16(centralFixed, 34) == 0,
                  ZIPMetadataParser.u16(centralFixed, 36) <= 1,
                  centralCursor <= centralOffset + UInt64(storage.summary.centralBytes),
                  UInt64(centralFields + commentBytes) <= centralOffset + UInt64(storage.summary.centralBytes) - centralCursor else {
                throw ZIPMemberRenameFailure.unsupportedArchive
            }
            let central = try read(centralCursor, centralFields)
            let centralComment = commentBytes == 0 ? Data() : try read(centralCursor + UInt64(centralFields), commentBytes)
            guard central.count == centralFields, centralComment.count == commentBytes else {
                throw ZIPMemberRenameFailure.contentMismatch
            }
            guard Data(central[46..<(46 + nameBytes)]) == record.rawName else {
                throw ZIPMemberRenameFailure.unsupportedArchive
            }
            let centralExtra = Data(central.dropFirst(46 + nameBytes))
            let attributes = ZIPMetadataParser.u32(centralFixed, 38)
            let mode = UInt16(attributes >> 16)
            let expectedType = record.kind == .directory ? UInt16(S_IFDIR) : UInt16(S_IFREG)
            let dos = UInt16(truncatingIfNeeded: attributes)
            guard creator >> 8 != 10 || mode == 0,
                  mode & UInt16(S_IFMT) == 0 || mode & UInt16(S_IFMT) == expectedType,
                  mode & ~UInt16(S_IFMT | 0o777) == 0,
                  dos & ~UInt16(0x37) == 0,
                  record.kind == .directory ? record.name.hasSuffix("/") : !record.name.hasSuffix("/"),
                  record.kind == .directory || dos & 0x10 == 0 else {
                throw ZIPMemberRenameFailure.unsupportedArchive
            }
            let localFixed = try read(record.localOffset, 30)
            guard localFixed.count == 30,
                  ZIPMetadataParser.u32(localFixed, 0) == 0x04034b50,
                  ZIPMetadataParser.u16(localFixed, 4) == needed,
                  ZIPMetadataParser.u16(localFixed, 6) == record.flags,
                  ZIPMetadataParser.u16(localFixed, 8) == record.method,
                  ZIPMetadataParser.u16(localFixed, 10) == ZIPMetadataParser.u16(centralFixed, 12),
                  ZIPMetadataParser.u16(localFixed, 12) == ZIPMetadataParser.u16(centralFixed, 14),
                  Int(ZIPMetadataParser.u16(localFixed, 26)) == nameBytes else {
                throw ZIPMemberRenameFailure.unsupportedArchive
            }
            let localExtraBytes = Int(ZIPMetadataParser.u16(localFixed, 28))
            guard localExtraBytes <= 512 else { throw ZIPMemberRenameFailure.unsupportedArchive }
            let localVariable = try read(record.localOffset + 30, nameBytes + localExtraBytes)
            guard localVariable.count == nameBytes + localExtraBytes,
                  Data(localVariable.prefix(nameBytes)) == record.rawName else {
                throw ZIPMemberRenameFailure.unsupportedArchive
            }
            let localExtra = Data(localVariable.dropFirst(nameBytes))
            let localKnown = try knownExtras(localExtra), centralKnown = try knownExtras(centralExtra, central: true)
            for (flag, value) in centralKnown.timestamps {
                if let local = localKnown.timestamps[flag], local != value {
                    throw ZIPMemberRenameFailure.unsupportedArchive
                }
            }
            if let local = localKnown.identity, let central = centralKnown.identity, local != central {
                throw ZIPMemberRenameFailure.unsupportedArchive
            }
            if let local = localKnown.ntfs, let central = centralKnown.ntfs, local != central {
                throw ZIPMemberRenameFailure.unsupportedArchive
            }
            let descriptorLength = extent.end - (extent.payload + record.packed)
            guard descriptorLength == 0 || descriptorLength == 12 || descriptorLength == 16,
                  (record.flags & 8 != 0) == (descriptorLength != 0) else {
                throw ZIPMemberRenameFailure.unsupportedArchive
            }
            let descriptor = try read(extent.payload + record.packed, Int(descriptorLength))
            guard descriptor.count == descriptorLength else { throw ZIPMemberRenameFailure.contentMismatch }
            let entry = Entry(record: record, centralPosition: centralCursor,
                payload: extent.payload, end: extent.end, localFixed: localFixed,
                centralFixed: centralFixed, localExtra: localExtra,
                centralExtra: centralExtra, centralComment: centralComment, descriptor: descriptor)
            entries.append(entry)
            centralCursor += UInt64(centralFields + commentBytes)
            if let destinationPrefix = directoryDestinationPrefix,
               directoryByPosition[entry.centralPosition] == nil,
               (record.name.utf8.starts(with: destinationPrefix.utf8)
                || record.name.utf8.elementsEqual(destinationPrefix.dropLast().utf8)) {
                throw ZIPMemberRenameFailure.ambiguousName
            }
            var rawName = record.rawName, name = record.name, keep = true
            if let intent {
                switch intent {
                case .rename(let member, let newBaseName):
                    switch member.target {
                    case .regular(let position):
                        if record.name.utf8.elementsEqual(member.archivePath.utf8), entry.centralPosition == position,
                           record.kind == .file {
                            selected += 1
                            (rawName, name) = try Self.replacingMemberComponent(record,
                                path: member.archivePath, newBaseName: newBaseName, pathLimit: limits.pathBytes)
                        }
                    case .directory:
                        let prefix = member.archivePath + "/"
                        let belongsToDirectory = record.name.utf8.starts(with: prefix.utf8)
                        let bound = directoryByPosition[entry.centralPosition]
                        guard belongsToDirectory == (bound != nil) else {
                            throw ZIPMemberRenameFailure.sourceChanged
                        }
                        if let bound {
                            guard bound.archivePath.utf8.elementsEqual(record.name.utf8) else {
                                throw ZIPMemberRenameFailure.sourceChanged
                            }
                            selected += 1
                            (rawName, name) = try Self.replacingMemberComponent(record, path: member.archivePath,
                                newBaseName: newBaseName, pathLimit: limits.pathBytes)
                        }
                    }
                case .remove(let selection), .duplicate(let selection, _), .move(let selection, _), .renameMany(let selection, _), .group(let selection, _, _):
                    let root = groupRoots.firstIndex { root in
                        root.isDirectory ? record.name.utf8.starts(with: root.path)
                            : record.name.utf8.elementsEqual(root.path)
                    }
                    let item = groupByPosition[entry.centralPosition]
                    guard (root != nil) == (item != nil) else {
                        throw ZIPMemberRenameFailure.sourceChanged
                    }
                    if let item, let root {
                        guard item.archivePath.utf8.elementsEqual(record.name.utf8) else {
                            throw ZIPMemberRenameFailure.sourceChanged
                        }
                        selected += 1
                        if intent.duplicatesMembers {
                            let path = selection.roots[root].archivePath
                            let unchangedName = path.split(separator: "/").last?.utf8.elementsEqual(duplicateNames[root].utf8) == true
                            var raw = record.rawName, full = record.name
                            if !unchangedName {
                                (raw, full) = try Self.replacingMemberComponent(record, path: path,
                                    newBaseName: duplicateNames[root], pathLimit: limits.pathBytes)
                            }
                            if let copyParent {
                                (raw, full) = try Self.relocatedName(raw, decoded: full, flags: record.flags,
                                    root: path, into: copyParent, pathLimit: limits.pathBytes)
                            }
                            duplicates.append((entries.count - 1, raw, full))
                        } else if let newNames = intent.renamedBaseNames {
                            let path = selection.roots[root].archivePath
                            if path.split(separator: "/").last?.utf8.elementsEqual(newNames[root].utf8) != true {
                                (rawName, name) = try Self.replacingMemberComponent(record, path: path,
                                    newBaseName: newNames[root], pathLimit: limits.pathBytes)
                            }
                        } else if let moveParent {
                            (rawName, name) = try Self.movedRecord(record, root: selection.roots[root].archivePath,
                                into: moveParent, pathLimit: limits.pathBytes)
                        } else { keep = false }
                    }
                case .replace(let document, _):
                    if entry.centralPosition == document.selection.recordOffset,
                       record.name.utf8.elementsEqual(document.archivePath.utf8) {
                        guard record.kind == .file,
                              record.logical <= ZIPTextPreview.maximumUTF8Bytes,
                              record.packed <= ZIPTextPreview.maximumPackedBytes,
                              record.flags & 0x0006 == 0 else {
                            throw ZIPMemberRenameFailure.unsupportedArchive
                        }
                        selected += 1; replacementIndex = entries.count - 1
                    }
                case .add:
                    if replacingAdditionFiles.contains(Data(record.name.utf8)) {
                        guard record.kind == .file else { throw ZIPMemberAdditionFailure.nameConflict }
                        keep = false
                    }
                case .newMember: break
                }
            }
            rawNames.append(rawName); names.append(name); retained.append(keep)
        }
        guard centralCursor == centralOffset + UInt64(storage.summary.centralBytes) else {
            throw ZIPMemberRenameFailure.unsupportedArchive
        }
        if let intent {
            switch intent {
            case .rename(let member, _):
                switch member.target {
                case .regular: guard selected == 1 else { throw ZIPMemberRenameFailure.sourceChanged }
                case .directory(let records):
                    guard selected == records.count else { throw ZIPMemberRenameFailure.sourceChanged }
                }
            case .remove(let selection), .duplicate(let selection, _), .move(let selection, _), .renameMany(let selection, _), .group(let selection, _, _):
                guard selected == selection.members.count else { throw ZIPMemberRenameFailure.sourceChanged }
            case .replace:
                guard selected == 1, replacementIndex != nil else { throw ZIPMemberRenameFailure.sourceChanged }
            case .add(let selection, _, _, _), .newMember(let selection, _, _, _):
                if !selection.virtualFolder.isEmpty {
                    let prefix = Data((selection.virtualFolder + "/").utf8)
                    guard entries.contains(where: { $0.record.name.utf8.starts(with: prefix) }) else {
                        throw ZIPMemberAdditionFailure.invalidSelection
                    }
                }
            }
        }
        guard duplicates.count <= 20_000 - entries.count else { throw ZIPMemberRenameFailure.limitReached }
        for duplicate in duplicates {
            try check()
            entries.append(entries[duplicate.source]); names.append(duplicate.name)
            rawNames.append(duplicate.rawName); retained.append(true)
        }
        var catalog = ZIPCatalogBuilder(limits: limits)
        var retainedLogical: UInt64 = 0, retainedFiles = 0, retainedFolders = 0
        for index in entries.indices where retained[index] {
            try check()
            let entry = entries[index], name = names[index]
            try catalog.add(name: name, kind: entry.record.kind, logical: entry.record.logical,
                packed: entry.record.packed, method: entry.record.method, encrypted: false)
            retainedLogical += entry.record.logical
            if entry.record.kind == .file { retainedFiles += 1 } else { retainedFolders += 1 }
        }
        if case .some(.replace(_, let contents)) = intent, let replacementIndex {
            retainedLogical -= entries[replacementIndex].record.logical
            retainedLogical += UInt64(contents.encoded.count)
        }
        let rebuilt = try catalog.finish(records: retainedFiles + retainedFolders, centralBytes: 0, zip64: false,
            cancelled: { (try? check()) == nil })
        guard rebuilt.summary.caseConflicts == 0 else { throw ZIPMemberRenameFailure.ambiguousName }
        return .init(entries: entries, retained: retained, outputNames: names, rawOutputNames: rawNames,
                     duplicateSources: duplicates.map(\.source),
                     replacementIndex: replacementIndex,
                     trailer: trailer, logical: retainedLogical,
                     files: retainedFiles, folders: retainedFolders)
    }

    /// A combined namespace is checked before any body read. Existing
    /// folders are never silently merged with an added root of the same name.
    private static func combinedPreview(_ manifest: Manifest, additions: ZIPCreationInventory?,
        newMember: NewMember?, check: () throws -> Void) throws -> ArchiveProductionPreview {
        let files = manifest.files + (additions?.files ?? 0) + (newMember?.kind == .file ? 1 : 0)
        let folders = manifest.folders + (additions?.folders ?? 0) + (newMember?.kind == .directory ? 1 : 0)
        let logical = manifest.logical + (additions?.logical ?? 0)
        guard files <= 10_000, files + folders < 20_000, logical <= 1 << 30 else {
            throw ZIPMemberRenameFailure.limitReached
        }
        let retained = manifest.entries.indices.filter { manifest.retained[$0] }
        var longest = retained.map { manifest.outputNames[$0].utf8.count }.max() ?? 0
        if additions != nil || newMember != nil {
            let key = ZIPNameReservations.key
            let roots = Set(additions?.roots.map { key($0.archivePath) } ?? [])
            for index in retained {
                try check()
                var name = key(manifest.outputNames[index])
                if name.hasSuffix("/") { name.removeLast() }
                while !roots.isEmpty {
                    guard !roots.contains(name) else { throw ZIPMemberAdditionFailure.nameConflict }
                    guard let slash = name.lastIndex(of: "/") else { break }
                    name.removeSubrange(slash...)
                }
            }
            if let newMember {
                let path = newMember.kind == .directory ? String(newMember.path.dropLast()) : newMember.path
                let root = key(path)
                for index in retained {
                    try check()
                    let name = key(manifest.outputNames[index])
                    guard name != root, newMember.groupsSelection || !name.hasPrefix(root + "/") else {
                        throw ZIPMemberNewEntryFailure.nameConflict
                    }
                }
            }
            var limits = ZIPReadLimits(); limits.nodes = 20_000; limits.depth = 63
            var catalog = ZIPCatalogBuilder(limits: limits)
            for index in retained {
                try check(); let record = manifest.entries[index].record
                try catalog.add(name: manifest.outputNames[index], kind: record.kind,
                    logical: record.logical, packed: record.packed, method: record.method, encrypted: false)
            }
            if let additions {
                for node in additions.nodes {
                    try check()
                    try catalog.add(name: node.name, kind: node.stamp.directory ? .directory : .file,
                        logical: node.stamp.directory ? 0 : UInt64(node.stamp.size), packed: 0, method: 0, encrypted: false)
                    longest = max(longest, node.name.utf8.count)
                }
            }
            if let newMember {
                try check()
                try catalog.add(name: newMember.path, kind: newMember.kind == .directory ? .directory : .file, logical: 0, packed: 0,
                                method: 0, encrypted: false)
                longest = max(longest, newMember.path.utf8.count)
            }
            let result = try catalog.finish(records: files + folders, centralBytes: 0, zip64: false,
                cancelled: { (try? check()) == nil })
            guard result.summary.caseConflicts == 0 else { throw ZIPMemberAdditionFailure.nameConflict }
        }
        let replaced = Set(manifest.entries.indices.filter { !manifest.retained[$0] }
            .map { Data(manifest.outputNames[$0].utf8) })
        let addedItems = additions?.roots.map {
            ArchiveAddedItemPreview(originalName: $0.originalName, archivePath: $0.archivePath,
                isDirectory: $0.isDirectory, replacesExistingFile: replaced.contains(Data($0.archivePath.utf8)))
        } ?? []
        return .init(files: files, folders: folders, logicalBytes: logical, longestPathBytes: longest,
                     addedItems: addedItems)
    }

    private static func occupiedChildren(of folder: String, manifest: Manifest,
                                         check: () throws -> Void) throws -> Set<String> {
        let prefix = folder.isEmpty ? "" : folder + "/"
        let prefixLength = prefix.count
        var names = Set<String>()
        for index in manifest.outputNames.indices where manifest.retained[index] {
            try check()
            let name = manifest.outputNames[index]
            guard name.utf8.starts(with: prefix.utf8),
                  let leaf = name.dropFirst(prefixLength).split(separator: "/").first else { continue }
            names.insert(String(leaf)) // An implied child folder reserves its name too.
        }
        return names
    }

    /// Sibling roots only. Existing and implied child names are reserved before
    /// decoding or copying member payloads into output, including selected
    /// names that a rule would vacate. Source fingerprints still read input.
    /// This matches local batch Rename's refusal of dependent-name sequences.
    private static func validateBatchRename(_ selection: ZIPMemberSetSelection, to names: [String],
        in storage: ZIPCatalogStorage, check: () throws -> Void) throws {
        guard let first = selection.roots.first else { throw ZIPMemberRenameFailure.invalidMember }
        let parentParts = first.archivePath.split(separator: "/").dropLast()
        let parentPath = parentParts.joined(separator: "/")
        let parent = try folderIndex(parentParts, in: storage, check: check)
        let key = ZIPNameReservations.key
        let occupied = Set(storage.nodes[parent].children.map { key(storage.nodes[$0].name) })
        var targets = Set<String>()
        for (root, name) in zip(selection.roots, names) {
            try check()
            let parts = root.archivePath.split(separator: "/")
            guard parts.dropLast().joined(separator: "/").utf8.elementsEqual(parentPath.utf8),
                  let original = parts.last else { throw ZIPMemberRenameFailure.invalidMember }
            let target = key(name)
            guard targets.insert(target).inserted,
                  target == key(String(original)) || !occupied.contains(target) else {
                throw ZIPMemberRenameFailure.ambiguousName
            }
        }
    }

    /// Use the chosen folder, or each root's own parent for Duplicate. The
    /// catalog includes implied directories and reservations for the group.
    private static func duplicateBaseNames(_ selection: ZIPMemberSetSelection,
        into folder: String?, in storage: ZIPCatalogStorage, check: () throws -> Void) throws -> [String] {
        let target = try folder.map { try folderIndex($0.split(separator: "/")[...], in: storage, check: check) }
        var occupied: [Int: ZIPNameReservations] = [:], result: [String] = []
        for root in selection.roots {
            try check()
            let parts = root.archivePath.split(separator: "/")
            guard let last = parts.last else { throw ZIPMemberRenameFailure.invalidMember }
            if let folder, root.isDirectory,
               folder.utf8.elementsEqual(root.archivePath.utf8) || folder.utf8.starts(with: (root.archivePath + "/").utf8) {
                throw ZIPMemberRenameFailure.invalidMember
            }
            let parent = try target ?? Self.folderIndex(parts.dropLast(), in: storage, check: check)
            if occupied[parent] == nil { occupied[parent] = .init(storage.nodes[parent].children.map { storage.nodes[$0].name }) }
            guard let name = try occupied[parent]?.name(for: String(last), isDirectory: root.isDirectory,
                keepOriginal: folder != nil, check: check) else { throw ZIPMemberRenameFailure.invalidMember }
            result.append(name)
        }
        return result
    }

    private static func folderIndex(_ parts: ArraySlice<Substring>, in storage: ZIPCatalogStorage,
                                    check: () throws -> Void) throws -> Int {
        var parent = 0
        for part in parts {
            try check()
            guard let child = storage.nodes[parent].children.first(where: {
                let node = storage.nodes[$0]
                return node.kind == .directory && node.name.utf8.elementsEqual(part.utf8)
            }) else { throw ZIPMemberRenameFailure.sourceChanged }
            parent = child
        }
        return parent
    }

    /// Moving never merges even implied folders or replaces existing members.
    /// Validate the whole group and its destination from the same catalog.
    private static func validateMove(_ selection: ZIPMemberSetSelection, into folder: String,
                                     in storage: ZIPCatalogStorage, check: () throws -> Void) throws {
        let parts = folder.split(separator: "/")
        let target = try Self.folderIndex(parts[...], in: storage, check: check)
        let locale = Locale(identifier: "en_US_POSIX")
        func key(_ name: String) -> String { name.folding(options: .caseInsensitive, locale: locale) }
        var occupied = Set(storage.nodes[target].children.map { key(storage.nodes[$0].name) })
        for root in selection.roots {
            try check()
            let path = root.archivePath
            let components = path.split(separator: "/")
            guard let name = components.last,
                  !folder.utf8.elementsEqual(components.dropLast().joined(separator: "/").utf8),
                  !root.isDirectory || (!folder.utf8.elementsEqual(path.utf8)
                    && !folder.utf8.starts(with: (path + "/").utf8)) else {
                throw ZIPMemberRenameFailure.invalidMember
            }
            guard occupied.insert(key(String(name))).inserted else {
                throw ZIPMemberRenameFailure.ambiguousName
            }
        }
    }

    /// A new sibling folder is sealed against the original catalog, before
    /// selected roots are relocated. Only those selected records can supply
    /// its children; no existing explicit or implied folder may be merged.
    private static func validateGrouping(_ selection: ZIPMemberSetSelection, into folder: String,
        in storage: ZIPCatalogStorage, check: () throws -> Void) throws {
        let parts = folder.split(separator: "/")
        guard let name = parts.last, selection.coveredSelectionCount == 0 else {
            throw ZIPMemberRemovalFailure.invalidSelection
        }
        let parent = parts.dropLast().joined(separator: "/")
        let target = try Self.folderIndex(parts.dropLast(), in: storage, check: check)
        let key = ZIPNameReservations.key
        guard !storage.nodes[target].children.contains(where: { key(storage.nodes[$0].name) == key(String(name)) }) else {
            throw ZIPMemberNewEntryFailure.nameConflict
        }
        for root in selection.roots {
            try check()
            let actual = root.archivePath.split(separator: "/").dropLast().joined(separator: "/")
            guard actual.utf8.elementsEqual(parent.utf8) else {
                throw ZIPMemberRemovalFailure.invalidSelection
            }
        }
    }

    /// Retain the original root name and descendant raw bytes. A legacy
    /// record can move into an ASCII parent without guessing its encoding.
    private static func movedRecord(_ record: ZIPPayloadRecord, root: String,
                                    into folder: String, pathLimit: Int) throws -> (Data, String) {
        try relocatedName(record.rawName, decoded: record.name, flags: record.flags,
            root: root, into: folder, pathLimit: pathLimit)
    }

    private static func relocatedName(_ rawName: Data, decoded: String, flags: UInt16,
                                      root: String, into folder: String, pathLimit: Int) throws -> (Data, String) {
        let oldDepth = root.utf8.filter { $0 == 47 }.count
        let rawSlashes = rawName.indices.filter { rawName[$0] == 47 }
        let decodedSlashes = decoded.utf8.indices.filter { decoded.utf8[$0] == 47 }
        guard rawSlashes.count == decodedSlashes.count, oldDepth <= rawSlashes.count else {
            throw ZIPMemberRenameFailure.unsupportedArchive
        }
        let rawStart = oldDepth == 0 ? rawName.startIndex : rawSlashes[oldDepth - 1] + 1
        let decodedStart = oldDepth == 0 ? decoded.utf8.startIndex : decoded.utf8.index(after: decodedSlashes[oldDepth - 1])
        let prefix = folder.isEmpty ? "" : folder + "/"
        guard flags & 0x0800 != 0 || prefix.utf8.allSatisfy({ $0 < 128 }) else {
            throw ZIPMemberRenameFailure.unsupportedArchive
        }
        let raw = Data(prefix.utf8) + Data(rawName[rawStart...])
        let name = prefix + String(decoding: decoded.utf8[decodedStart...], as: UTF8.self)
        guard raw.count <= UInt16.max, raw.count <= pathLimit, name.utf8.count <= pathLimit else {
            throw ZIPMemberRenameFailure.limitReached
        }
        return (raw, name)
    }

    /// Replace only the selected component. All other raw name bytes,
    /// including legacy-encoded ancestors and descendants, remain unchanged.
    private static func replacingMemberComponent(_ record: ZIPPayloadRecord,
        path: String, newBaseName: String,
        pathLimit: Int) throws -> (Data, String) {
        let oldParts = path.split(separator: "/")
        guard let oldComponent = oldParts.last,
              record.name.utf8.elementsEqual(path.utf8) || record.name.utf8.starts(with: (path + "/").utf8) else {
            throw ZIPMemberRenameFailure.sourceChanged
        }
        let component = oldParts.count - 1
        let rawSlashes = record.rawName.indices.filter { record.rawName[$0] == 47 }
        let decodedSlashes = record.name.utf8.filter { $0 == 47 }.count
        guard rawSlashes.count == decodedSlashes, component <= rawSlashes.count else {
            throw ZIPMemberRenameFailure.unsupportedArchive
        }
        let start = component == 0 ? 0 : rawSlashes[component - 1] + 1
        let end = component < rawSlashes.count ? rawSlashes[component] : record.rawName.count
        let parts = record.name.split(separator: "/", omittingEmptySubsequences: false)
        guard start < end, parts.indices.contains(component),
              parts[component].utf8.elementsEqual(oldComponent.utf8) else {
            throw ZIPMemberRenameFailure.unsupportedArchive
        }
        if record.flags & 0x0800 != 0 {
            guard let rawComponent = String(data: Data(record.rawName[start..<end]), encoding: .utf8),
                  rawComponent.utf8.elementsEqual(oldComponent.utf8) else {
                throw ZIPMemberRenameFailure.unsupportedArchive
            }
        } else {
            guard newBaseName.unicodeScalars.allSatisfy({ $0.value < 128 }) else {
                throw ZIPMemberRenameFailure.invalidName
            }
        }
        let suffixBytes = Data(record.name.utf8.dropFirst(path.utf8.count))
        guard let suffix = String(data: suffixBytes, encoding: .utf8) else {
            throw ZIPMemberRenameFailure.unsupportedArchive
        }
        let parent = path.utf8.dropLast(oldComponent.utf8.count)
        let name = String(decoding: parent, as: UTF8.self) + newBaseName + suffix
        let raw = Data(record.rawName[..<start]) + Data(newBaseName.utf8) + Data(record.rawName[end...])
        guard raw.count <= UInt16.max, raw.count <= pathLimit, name.utf8.count <= pathLimit else {
            throw ZIPMemberRenameFailure.limitReached
        }
        return (raw, name)
    }

    private struct KnownExtras {
        var timestamps: [UInt8: UInt32] = [:]
        var identity: [UInt64]?
        var ntfs: Data?
    }
    private static func knownExtras(_ bytes: Data, central: Bool = false) throws -> KnownExtras {
        guard bytes.count <= 512 else { throw ZIPMemberRenameFailure.unsupportedArchive }
        var result = KnownExtras(), seen = Set<UInt16>(), cursor = 0
        while cursor < bytes.count {
            guard cursor + 4 <= bytes.count else { throw ZIPMemberRenameFailure.unsupportedArchive }
            let tag = ZIPMetadataParser.u16(bytes, cursor)
            let count = Int(ZIPMetadataParser.u16(bytes, cursor + 2))
            cursor += 4
            guard seen.insert(tag).inserted, cursor + count <= bytes.count else {
                throw ZIPMemberRenameFailure.unsupportedArchive
            }
            let value = Data(bytes[cursor..<(cursor + count)])
            cursor += count
            switch tag {
            case 0x5455:
                guard !value.isEmpty, value[0] & ~UInt8(7) == 0 else {
                    throw ZIPMemberRenameFailure.unsupportedArchive
                }
                // A central UT field may advertise local access/creation bits
                // but carry only modification time. Preserve either encoding.
                let flags = central && value.count == (value[0] & 1 == 1 ? 5 : 1) ? value[0] & 1 : value[0]
                var at = 1
                for flag: UInt8 in [1, 2, 4] where flags & flag != 0 {
                    guard at + 4 <= value.count else { throw ZIPMemberRenameFailure.unsupportedArchive }
                    result.timestamps[flag] = ZIPMetadataParser.u32(value, at)
                    at += 4
                }
                guard at == value.count else { throw ZIPMemberRenameFailure.unsupportedArchive }
            case 0x000a:
                guard value.count == 32, ZIPMetadataParser.u32(value, 0) == 0,
                      ZIPMetadataParser.u16(value, 4) == 1, ZIPMetadataParser.u16(value, 6) == 24 else {
                    throw ZIPMemberRenameFailure.unsupportedArchive
                }
                result.ntfs = value
            case 0x7875:
                guard value.count >= 5, value[0] == 1 else {
                    throw ZIPMemberRenameFailure.unsupportedArchive
                }
                var at = 1, identity: [UInt64] = []
                for _ in 0..<2 {
                    guard at < value.count else { throw ZIPMemberRenameFailure.unsupportedArchive }
                    let width = Int(value[at]); at += 1
                    guard (1...8).contains(width), at + width <= value.count else {
                        throw ZIPMemberRenameFailure.unsupportedArchive
                    }
                    var number: UInt64 = 0
                    for byte in 0..<width { number |= UInt64(value[at + byte]) << (8 * byte) }
                    identity.append(number); at += width
                }
                guard at == value.count else { throw ZIPMemberRenameFailure.unsupportedArchive }
                result.identity = identity
            default: throw ZIPMemberRenameFailure.unsupportedArchive
            }
        }
        return result
    }
    private static func localHeader(_ entry: Entry, name: Data) -> Data {
        patchedLocalFixed(entry.localFixed, name: name) + name + entry.localExtra
    }
    private static func centralHeader(_ entry: Entry, name: Data, localOffset: UInt64) -> Data {
        patchedCentralFixed(entry.centralFixed, name: name, localOffset: localOffset) + name + entry.centralExtra + entry.centralComment
    }
    private static func patchedLocalFixed(_ original: Data, name: Data) -> Data {
        var result = original
        result.replaceSubrange(26..<28, with: ZIPFileEncoder.le(UInt64(name.count), 2))
        return result
    }
    private static func patchedCentralFixed(_ original: Data, name: Data, localOffset: UInt64) -> Data {
        var result = original
        result.replaceSubrange(28..<30, with: ZIPFileEncoder.le(UInt64(name.count), 2))
        result.replaceSubrange(42..<46, with: ZIPFileEncoder.le(localOffset, 4))
        return result
    }
    private static func trailer(_ original: Data, centralBytes: Int,
        centralOffset: UInt64, records: Int) -> Data {
        var result = original
        result.replaceSubrange(8..<10, with: ZIPFileEncoder.le(UInt64(records), 2))
        result.replaceSubrange(10..<12, with: ZIPFileEncoder.le(UInt64(records), 2))
        result.replaceSubrange(12..<16, with: ZIPFileEncoder.le(UInt64(centralBytes), 4))
        result.replaceSubrange(16..<20, with: ZIPFileEncoder.le(centralOffset, 4))
        return result
    }
    private static func readOutput(_ descriptor: Int32, length: UInt64, offset: UInt64,
        count: Int, check: () throws -> Void) throws -> Data {
        try check()
        guard count >= 0, count <= 16 << 20, offset <= length,
              UInt64(count) <= length - offset, offset <= UInt64(Int64.max) else {
            throw ZIPMemberRenameFailure.contentMismatch
        }
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { bytes in
            var done = 0
            while done < count {
                try check()
                let amount = pread(descriptor, bytes.baseAddress!.advanced(by: done),
                    min(65_536, count - done), off_t(offset) + off_t(done))
                if amount < 0 && errno == EINTR { continue }
                guard amount > 0 else { throw ZIPMemberRenameFailure.contentMismatch }
                done += amount
            }
        }
        return data
    }
    private static func preparationFailure(_ error: Error) -> Error {
        if let failure = error as? ZIPMemberRenameFailure { return failure }
        if let failure = error as? ZIPArchiveFailure {
            switch failure {
            case .changed: return ZIPMemberRenameFailure.sourceChanged
            case .ambiguousNames: return ZIPMemberRenameFailure.ambiguousName
            case .limited: return ZIPMemberRenameFailure.limitReached
            default: return ZIPMemberRenameFailure.unsupportedArchive
            }
        }
        if let failure = error as? ZIPContentProblem {
            switch failure.reason {
            case .unsupported: return ZIPMemberRenameFailure.unsupportedArchive
            case .limitReached: return ZIPMemberRenameFailure.limitReached
            default: return ZIPMemberRenameFailure.contentMismatch
            }
        }
        if let failure = error as? ZIPContentFailure {
            switch failure {
            case .unsupported: return ZIPMemberRenameFailure.unsupportedArchive
            case .limitReached: return ZIPMemberRenameFailure.limitReached
            default: return ZIPMemberRenameFailure.contentMismatch
            }
        }
        return error
    }
    private static func operationFailure(_ error: Error) -> Error {
        if let failure = error as? FileOperationFailure { return failure }
        if let failure = error as? ZIPCreationFailure {
            switch failure {
            case .sourceChanged: return FileOperationFailure.sourceChanged
            case .contentMismatch: return FileOperationFailure.copyContentMismatch
            case .unsupportedSource, .limitOrPrivacy, .resourceFork, .codecUnavailable: return FileOperationFailure.unsupported
            }
        }
        if let failure = error as? ZIPMemberRenameFailure {
            switch failure {
            case .sourceChanged: return FileOperationFailure.sourceChanged
            case .contentMismatch: return FileOperationFailure.copyContentMismatch
            case .limitReached, .unsupportedArchive, .unsupportedSecurity,
                 .invalidMember, .invalidName, .ambiguousName: return FileOperationFailure.unsupported
            }
        }
        if let failure = error as? ZIPContentProblem {
            return failure.reason == .limitReached || failure.reason == .unsupported
                ? FileOperationFailure.unsupported : FileOperationFailure.copyContentMismatch
        }
        if error is ZIPContentFailure || error is ZIPArchiveFailure { return FileOperationFailure.copyContentMismatch }
        if error is ZIPExtractionFailure { return FileOperationFailure.copyMetadataMismatch }
        return error
    }
}
