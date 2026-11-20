import Darwin
import FileOperations
import Foundation

public enum GitIndexEditAction: Equatable, Sendable {
    case stageSavedFile, stageReviewedPath(GitWorkingFolder.StagingSelection)
    case stageReviewedChange(GitWorkingFolder.StagingSelection, GitIndexTextChange)
    case unstage, unstageReviewedChange(head: GitObjectID, GitIndexTextChange)

    public var stagesRemoval: Bool {
        if case .stageReviewedPath(let selection) = self { return selection.isRemoval }
        return false
    }

    var reviewedSelection: GitWorkingFolder.StagingSelection? {
        switch self {
        case .stageReviewedPath(let selection), .stageReviewedChange(let selection, _): selection
        case .stageSavedFile, .unstage, .unstageReviewedChange: nil
        }
    }
}

public enum GitIndexEditFailure: Error, Equatable, Sendable {
    case unsupportedIndex, unsupportedPath, ignoredPath, contentRules
    case unsupportedTextChange
    case indexLocked, objectChanged, editorSourceChanged, writeDenied, uncertain

    public var userMessage: String {
        switch self {
        case .unsupportedIndex: "Use your Git client to edit this index. Its format or additional state needs special handling."
        case .unsupportedPath: "Choose a regular file with an ordinary index entry."
        case .ignoredPath: "Git ignore rules exclude this file."
        case .contentRules: "This file needs Git’s content or line-ending rules. Stage it with your Git client."
        case .unsupportedTextChange: "Choose a single exact change in a tracked UTF-8 file with LF line endings and unchanged file mode."
        case .indexLocked: "Another Git operation holds the index lock. Try again after it finishes."
        case .objectChanged: "The local Git object could not be verified. Refresh the Git view and check the repository."
        case .editorSourceChanged: "The file on disk changed. Reload the editor or review it from the browser before staging."
        case .writeDenied: "The Git index change could not be written. Check folder access and available space."
        case .uncertain: "The index write could not be confirmed. Refresh the staged changes before trying again."
        }
    }
}

/// An exact, single-path review. It carries no editable working bytes and can
/// authorize publication only against the same checkout and index.
public struct GitIndexEditPlan: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let action: GitIndexEditAction
    public let path: GitSnapshotPath
    public let before: GitSnapshotMember?
    public let after: GitSnapshotMember?
    public let head: GitObjectID
    public var hasChange: Bool { before != after }
    public var description: String { "<Git index edit>" }
    public var debugDescription: String { description }

    let location: GitRepositoryLocation
    let headRecord: Data
    let index: GitIndexSnapshot
    let working: GitWorkingFile.Identity?
}

struct GitWorkingFile {
    static let maximumBytes = 8 << 20
    struct Identity: Equatable, Sendable {
        let parent: GitDirectoryIdentity
        let entry: EntrySnapshot
    }

    let parent: DirectoryAnchor
    let name: String
    let identity: Identity
    let executable: Bool
    let bytes: Data
    private let root: DirectoryAnchor
    private let directories: [String]

    init(path: GitSnapshotPath, root: DirectoryAnchor, expecting expected: Identity? = nil, check: () throws -> Void) throws {
        guard let relative = path.literalArgument else { throw GitIndexEditFailure.unsupportedPath }
        let names = relative.split(separator: "/").map(String.init)
        guard let last = names.last, !names.contains(where: { $0.lowercased() == ".git" }) else {
            throw GitIndexEditFailure.unsupportedPath
        }
        self.root = root
        directories = Array(names.dropLast())
        let folder = try Self.parent(in: root, through: directories, check: check)
        let name = last
        let url = folder.url.appendingPathComponent(name)
        guard let info = try folder.gitEntry(name), info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == geteuid(), info.st_flags & UInt32(SF_DATALESS | SF_FIRMLINK) == 0,
              try folder.gitContainsExactName(name, check: check) else {
            throw GitIndexEditFailure.unsupportedPath
        }
        self.name = name
        parent = folder
        let entry = EntrySnapshot(info)
        identity = try .init(parent: GitDirectoryIdentity(folder.fd), entry: entry)
        guard expected == nil || expected == identity else { throw GitInspectionFailure.changed }
        executable = info.st_mode & S_IXUSR != 0
        bytes = try LocalTextComparisonRead.fileBytes(at: url, within: root, maximumBytes: Self.maximumBytes,
            expecting: entry, checkCancellation: check)
        try validate(check: check)
    }

    private static func parent(in root: DirectoryAnchor, through names: [String], check: () throws -> Void) throws -> DirectoryAnchor {
        var folder = root
        for name in names {
            try check()
            guard try folder.gitContainsExactName(name, check: check) else { throw GitInspectionFailure.changed }
            folder = try folder.gitDirectory(name)
            guard try folder.gitEntry(".git") == nil else { throw GitInspectionFailure.unsupportedRepository }
        }
        return folder
    }

    func validate(check: () throws -> Void) throws {
        // A case-only move on the same volume can keep both descriptors and
        // file bytes valid while changing the literal path Git would stage.
        let current = try Self.parent(in: root, through: directories, check: check)
        guard try GitDirectoryIdentity(current.fd) == identity.parent,
              try current.gitContainsExactName(name, check: check) else { throw GitInspectionFailure.changed }
        try parent.validate()
        guard try current.gitEntry(name).map(EntrySnapshot.init) == identity.entry else { throw GitInspectionFailure.changed }
    }
}

extension GitReadView {
    func prepareIndexEdit(_ action: GitIndexEditAction, path: GitSnapshotPath, location: GitRepositoryLocation,
                          matchingSavedText: LocalTextReadToken?,
                          check: () throws -> Void) throws -> GitIndexEditPlan {
        guard let argument = path.literalArgument,
              location.filePath(for: location.root.appendingPathComponent(argument)) == path else {
            throw GitIndexEditFailure.unsupportedPath
        }
        guard let head = files.head else { throw GitInspectionFailure.checkoutHasNoCommit }
        let baseline = try GitIndexSnapshot(files.metadata, check: check)
        let index = try installEditableIndex(baseline, check: check)
        let before = try index.entry(at: path)?.member(at: path)
        var expected: GitWorkingFile.Identity?
        if let selection = action.reviewedSelection {
            guard selection.path == path, before == selection.member else { throw GitInspectionFailure.changed }
            try validateIndexSelection(selection, in: location, check: check)
            expected = selection.working
        }
        let working: GitWorkingFile?
        let after: GitSnapshotMember?
        switch action {
        case .unstage:
            working = nil
            after = try committedMember(at: path, head: head)
        case .unstageReviewedChange(let reviewedHead, let change):
            guard reviewedHead == head else { throw GitInspectionFailure.changed }
            working = nil
            after = try prepareUnstagedChange(change, path: path, head: head, indexMember: before, check: check).member
        case .stageReviewedPath(let selection) where selection.isRemoval:
            working = nil
            after = nil
        case .stageSavedFile, .stageReviewedPath, .stageReviewedChange:
            let workingRules = try workingRules(for: [path], includeAttributes: true, check: check)
            let source = try GitWorkingFile(path: path, root: files.root, expecting: expected, check: check)
            if let matchingSavedText, !matchingSavedText.matchesSavedFile(source.bytes,
                at: source.parent.url.appendingPathComponent(source.name), parent: source.parent.identity, entry: source.identity.entry) {
                throw GitIndexEditFailure.editorSourceChanged
            }
            try requireStageRules(path, tracked: before != nil, source: source, rules: workingRules, check: check)
            working = source
            let bytes = try stageBytes(action, from: source, existing: before, check: check)
            after = stagedMember(path: path, bytes: bytes, executable: source.executable, existing: before)
        }
        try validateIndexEditBaseline(location: location, head: head, headRecord: files.headRecord,
            index: baseline, check: check)
        return .init(action: action, path: path, before: before, after: after, head: head, location: location,
            headRecord: files.headRecord, index: baseline, working: working?.identity)
    }

    func applyIndexEdit(_ plan: GitIndexEditPlan, check: () throws -> Void) throws {
        guard plan.hasChange else { return }
        try validateIndexEditBaseline(location: plan.location, head: plan.head, headRecord: plan.headRecord,
            index: plan.index, check: check)
        let index = try installEditableIndex(plan.index, check: check)
        let working: GitWorkingFile?
        let rules: GitWorkingRules?
        let blob: GitLooseBlob?
        switch plan.action {
        case .unstage:
            guard try committedMember(at: plan.path, head: plan.head) == plan.after else { throw GitInspectionFailure.changed }
            working = nil
            rules = nil
            blob = nil
        case .unstageReviewedChange(let reviewedHead, let change):
            guard reviewedHead == plan.head else { throw GitInspectionFailure.changed }
            let output = try prepareUnstagedChange(change, path: plan.path, head: plan.head, indexMember: plan.before, check: check)
            guard output.member == plan.after else { throw GitInspectionFailure.changed }
            working = nil
            rules = nil
            blob = try compressedBlob(output.member.object, bytes: output.bytes, check: check)
        case .stageReviewedPath(let selection) where selection.isRemoval:
            try validateIndexSelection(selection, in: plan.location, check: check)
            working = nil
            rules = nil
            blob = nil
        case .stageSavedFile, .stageReviewedPath, .stageReviewedChange:
            let workingRules = try workingRules(for: [plan.path], includeAttributes: true, check: check)
            guard let expected = plan.working, let after = plan.after else { throw GitInspectionFailure.changed }
            let source = try GitWorkingFile(path: plan.path, root: files.root, expecting: expected, check: check)
            let bytes = try stageBytes(plan.action, from: source, existing: plan.before, check: check)
            guard stagedMember(path: plan.path, bytes: bytes, executable: source.executable, existing: plan.before) == after else {
                throw GitInspectionFailure.changed
            }
            try requireStageRules(plan.path, tracked: plan.before != nil, source: source, rules: workingRules, check: check)
            working = source
            rules = workingRules
            blob = try compressedBlob(after.object, bytes: bytes, check: check)
        }
        let candidate = try editedIndex(plan, from: index, check: check)

        let lock = try GitIndexPublication(in: files.metadata)
        try lock.write(candidate, permissions: plan.index.permissions, check: check)
        try working?.validate(check: check)
        try rules?.validate(check: check)
        // A failed edit can leave an unreachable object, as ordinary Git
        // can. Never remove a blob that another Git client may now use.
        try blob?.publish(in: files.objects, check: check)
        try validateIndexEditBaseline(location: plan.location, head: plan.head, headRecord: plan.headRecord,
            index: plan.index, check: check)
        try rules?.validate(check: check)
        if let blob {
            guard try blob.isPresent(in: files.objects, check: check) else { throw GitIndexEditFailure.objectChanged }
        } else {
            try validateObjectLayout()
        }
        if case .stageReviewedPath(let selection) = plan.action, selection.isRemoval {
            try validateIndexSelection(selection, in: plan.location, check: check)
        }
        try working?.validate(check: check)
        try lock.publish(replacing: plan.index.entry, check: check)
    }

    private func validateIndexEditBaseline(location: GitRepositoryLocation, head: GitObjectID, headRecord: Data,
                                           index: GitIndexSnapshot, check: () throws -> Void) throws {
        let current = try GitRepositoryFiles(location: location, check: check)
        guard current.head == head, current.headRecord == headRecord,
              try GitIndexSnapshot(current.metadata, check: check) == index else { throw GitInspectionFailure.changed }
    }

    private func installEditableIndex(_ snapshot: GitIndexSnapshot, check: () throws -> Void) throws -> GitIndexFormat {
        let index = try GitIndexFormat(snapshot.bytes, hashLength: files.hashLength, check: check)
        if let bytes = snapshot.bytes {
            try bytes.write(to: directory.url.appendingPathComponent("index"), options: .withoutOverwriting)
        }
        return index
    }

    private func committedMember(at path: GitSnapshotPath, head: GitObjectID) throws -> GitSnapshotMember? {
        let value = try member(at: path, commit: head)
        guard value?.isTextCandidate != false else { throw GitIndexEditFailure.unsupportedPath }
        if let value {
            let bytes = try run(["cat-file", "blob", value.object.hex], maximumBytes: GitWorkingFile.maximumBytes)
            guard value.object.matchesBlob(bytes) else { throw GitIndexEditFailure.objectChanged }
        }
        return value
    }

    private func stageBytes(_ action: GitIndexEditAction, from source: GitWorkingFile, existing: GitSnapshotMember?,
                            check: () throws -> Void) throws -> Data {
        guard case .stageReviewedChange(_, let change) = action else { return source.bytes }
        guard let existing, existing.isTextCandidate, source.executable == (existing.kind == .executable) else {
            throw GitIndexEditFailure.unsupportedTextChange
        }
        return try change.applying(to: textBytes(of: existing), comparedWith: source.bytes, check: check)
    }

    private func prepareUnstagedChange(_ change: GitIndexTextChange, path: GitSnapshotPath, head: GitObjectID,
                                       indexMember: GitSnapshotMember?, check: () throws -> Void) throws
        -> (member: GitSnapshotMember, bytes: Data) {
        guard let indexMember, indexMember.isTextCandidate, let committed = try member(at: path, commit: head),
              committed.kind == indexMember.kind else { throw GitIndexEditFailure.unsupportedTextChange }
        let bytes = try change.applying(to: textBytes(of: committed), comparedWith: textBytes(of: indexMember), reversed: true, check: check)
        return (.init(path: path, object: .hashingBlob(bytes, hashLength: files.hashLength), kind: indexMember.kind), bytes)
    }

    private func textBytes(of member: GitSnapshotMember) throws -> Data {
        let data = try run(["cat-file", "blob", member.object.hex], maximumBytes: TextDocumentValue.maximumBytes)
        guard member.object.matchesBlob(data) else { throw GitIndexEditFailure.objectChanged }
        return data
    }

    private func stagedMember(path: GitSnapshotPath, bytes: Data, executable: Bool, existing: GitSnapshotMember?) -> GitSnapshotMember {
        .init(path: path, object: .hashingBlob(bytes, hashLength: files.hashLength),
              kind: existing?.kind ?? (executable ? .executable : .file))
    }

    private func requireStageRules(_ path: GitSnapshotPath, tracked: Bool, source: GitWorkingFile, rules: GitWorkingRules,
                                   check: () throws -> Void) throws {
        if !tracked, try ignoredPaths([path], using: rules, check: check).contains(path) {
            throw GitIndexEditFailure.ignoredPath
        }
        guard source.bytes.range(of: Data([13, 10])) == nil else { throw GitIndexEditFailure.contentRules }
        // Targeted queries report Git's special states as the same strings
        // as literal values like filter=unset. Listing defined attributes
        // lets an absent transformation rule be distinguished reliably.
        let transformations: Set<String> = ["filter", "working-tree-encoding", "ident"]
        let data = try withInput(path.bytes + Data([0]), named: "attribute-query") { input in
            try run(["check-attr", "--stdin", "-z", "--all"], maximumBytes: 64 << 10, rulesTree: rules.mirror, input: input)
        }
        let records = try records(data)
        guard records.count.isMultiple(of: 3) else { throw GitInspectionFailure.invalidOutput }
        var found = Set<String>()
        for offset in stride(from: 0, to: records.count, by: 3) {
            guard records[offset] == path.bytes, let key = String(data: records[offset + 1], encoding: .utf8),
                  found.insert(key).inserted else { throw GitInspectionFailure.invalidOutput }
            if transformations.contains(key) { throw GitIndexEditFailure.contentRules }
        }
        try rules.validate(check: check)
    }

    private func editedIndex(_ plan: GitIndexEditPlan, from index: GitIndexFormat, check: () throws -> Void) throws -> Data {
        let mode = plan.after.map { $0.kind == .executable ? "100755" : "100644" } ?? "0"
        let object = plan.after?.object.hex ?? String(repeating: "0", count: files.hashLength)
        let row = Data("\(mode) \(object)\t".utf8) + plan.path.bytes + Data([0])
        _ = try withInput(row, named: "index-edit") { input in
            try run(["update-index", "--info-only", "-z", "--index-info"], maximumBytes: 4_096, input: input)
        }
        guard let result = try directory.gitReadOptional("index", maximum: GitIndexSnapshot.maximumBytes, check: check) else {
            throw GitIndexEditFailure.unsupportedIndex
        }
        let updated = try GitIndexFormat(result, hashLength: files.hashLength, check: check)
        try updated.verifiesEdit(from: index, path: plan.path, to: plan.after)
        return result
    }

    private func compressedBlob(_ oid: GitObjectID, bytes: Data, check: () throws -> Void) throws -> GitLooseBlob {
        let folderName = "new-object"
        try createFolder(folderName, in: directory)
        let output = try directory.gitDirectory(folderName)
        let result = try withInput(bytes, named: "blob-input") { input in
            try run(["hash-object", "-w", "--no-filters", "--stdin"], maximumBytes: 256, input: input, privateObjects: output)
        }
        guard result == Data((oid.hex + "\n").utf8) else { throw GitIndexEditFailure.objectChanged }
        let prefix = String(oid.hex.prefix(2)), objectName = String(oid.hex.dropFirst(2))
        let fan = try output.gitDirectory(prefix)
        guard let compressed = try fan.gitReadOptional(objectName, maximum: GitLooseBlob.maximumBytes, check: check),
              try run(["cat-file", "blob", oid.hex], maximumBytes: GitWorkingFile.maximumBytes,
                      privateObjects: output) == bytes else { throw GitIndexEditFailure.objectChanged }
        var verifiedExisting: Data?
        if try files.objects.gitEntry(prefix) != nil,
           let existing = try files.objects.gitDirectory(prefix).gitReadOptional(objectName,
               maximum: GitLooseBlob.maximumBytes, check: check), existing != compressed {
            // A different zlib stream can encode the same Git blob. Check
            // those exact bytes in an otherwise empty owned object store.
            let isolated = "existing-object"
            try createFolder(isolated, in: directory)
            let existingObjects = try directory.gitDirectory(isolated)
            try createFolder(prefix, in: existingObjects)
            let exact = try existingObjects.gitDirectory(prefix)
            try existing.write(to: exact.url.appendingPathComponent(objectName), options: .withoutOverwriting)
            guard try run(["cat-file", "blob", oid.hex], maximumBytes: GitWorkingFile.maximumBytes,
                          privateObjects: existingObjects) == bytes else { throw GitIndexEditFailure.objectChanged }
            verifiedExisting = existing
        }
        return .init(object: oid, compressed: compressed, verifiedExisting: verifiedExisting)
    }
}
