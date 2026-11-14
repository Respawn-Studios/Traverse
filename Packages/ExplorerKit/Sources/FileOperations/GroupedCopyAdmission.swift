import Darwin
import Foundation

/// Private admission evidence with distinct generated and production routes.
/// Only the generated-root initializer uses the disposable fixture marker.
internal struct GroupedCopyQualification: Sendable {
    static let markerName = ".mac-explorer-grouped-copy-fixture-v1"
    static let marker = Data("Generated MacExplorer grouped Copy fixture v1\n".utf8)
    let root: URL
    let identity: EntrySnapshot
    let groupSize: Int
    internal let production: ProductionCopySession?

    init(root: URL, groupSize: Int = 16) throws {
        guard root.pathComponents.contains(".build"), (1...16).contains(groupSize) else { throw FileOperationFailure.invalidRequest }
        let anchor = try DirectoryAnchor(root, resolve: false)
        var info = stat()
        guard fstat(anchor.fd, &info) == 0, info.st_uid == geteuid(), info.st_mode & 0o077 == 0,
              try OperationJournal.read(name: Self.markerName, anchor: anchor) == Self.marker else { throw FileOperationFailure.invalidRequest }
        self.root = anchor.url; identity = anchor.identity; self.groupSize = groupSize; production = nil
    }

    init(production: ProductionCopySession) {
        root = production.directory; identity = production.receipt.root
        groupSize = 16; self.production = production
    }

    func validate(sources: [URL], destinations: [URL], journal: URL) throws {
        if let production {
            guard journal == production.directory else { throw FileOperationFailure.invalidRequest }
            _ = try production.checkedHistory()
        } else { try validate(locations: sources + destinations + [journal]) }
    }

    func validate(locations: [URL]) throws {
        // App preference admission remains strictly the repository-root route.
        guard production == nil else { throw FileOperationFailure.invalidRequest }
        let anchor = try DirectoryAnchor(root, resolve: false)
        guard anchor.identity.sameObject(as: identity), try OperationJournal.read(name: Self.markerName, anchor: anchor) == Self.marker,
              locations.allSatisfy({ $0.path.hasPrefix(root.path + "/") }) else { throw FileOperationFailure.invalidRequest }
    }
}

internal struct GroupedCopyAdmission: Sendable {
    let qualification: GroupedCopyQualification
    let members: [GroupedCopyManifestMember]
    let itemIDs: [UUID]

    static func prepare(entries: [TransferEntry], move: Bool, conflicts: [TransferConflict],
                        policy: TransferMetadataPolicy, qualification: GroupedCopyQualification,
                        journal: URL, cancellation: OperationCancellation) throws -> Self? {
        try qualification.validate(sources: entries.map(\.source), destinations: entries.map(\.destination), journal: journal)
        guard !move, conflicts.isEmpty, entries.allSatisfy({ $0.sourceIdentity.type == S_IFREG && $0.destinationIdentity == nil && $0.children == nil }) else { return nil }
        var slots: [(GroupedCopySlot, GroupedCopySlot)] = []
        // All non-body eligibility checks finish before hashing the first source.
        for entry in entries {
            try cancellation.check()
            let source = try DirectoryAnchor(entry.source.deletingLastPathComponent(), resolve: false)
            let destination = try DirectoryAnchor(entry.destination.deletingLastPathComponent(), resolve: false)
            guard source.identity.sameObject(as: entry.sourceParent), destination.identity.sameObject(as: entry.destinationParent) else { throw FileOperationFailure.sourceChanged }
            guard let fromVolume = try NativeRenameVolume.qualified(in: source), let toVolume = try NativeRenameVolume.qualified(in: destination) else { return nil }
            if let production = qualification.production,
               (!production.scope.permits(fromVolume) || !production.scope.permits(toVolume)) { return nil }
            do { try requireLocalLocation(source.url); try requireLocalLocation(destination.url) }
            catch FileOperationFailure.unsupported { return nil }
            let native = try NativeRenameEntry.observe(parent: source, name: entry.source.lastPathComponent)
            // Foundation can canonically normalize a URL's last component while
            // the native directory entry retains its original UTF-8 spelling.
            // Bind to the prepared object, then capture the native name as authority
            // for both the immutable source slot and the unused public Copy slot.
            guard native.identity == entry.sourceIdentity else { throw FileOperationFailure.sourceChanged }
            do { try requireResidentRegular(parent: source, name: native.name, expected: entry.sourceIdentity) }
            catch FileOperationFailure.unsupported { return nil }
            try requireAbsent(native.name, in: destination.fd)
            slots.append((GroupedCopySlot(parent: source.url, nameBytes: native.nameBytes, parentIdentity: source.identity, volume: fromVolume),
                GroupedCopySlot(parent: destination.url, nameBytes: native.nameBytes, parentIdentity: destination.identity, volume: toVolume)))
        }
        var members: [GroupedCopyManifestMember] = []
        let budget = TraversalBudget()
        for (index, pair) in slots.enumerated() {
            try cancellation.check()
            let parent = try GroupedCopyFilesystemEvidence.checkedParent(pair.0)
            try requireResidentRegular(parent: parent, name: pair.0.name, expected: entries[index].sourceIdentity)
            let tree = try verifiedTree(parent: parent.fd, name: pair.0.name, cancellation: cancellation, budget: budget)
            guard tree.identity == entries[index].sourceIdentity else { throw FileOperationFailure.sourceChanged }
            members.append(GroupedCopyManifestMember(source: pair.0, destination: pair.1, sourceTree: tree))
        }
        // The store's complete manifest validator runs before any declaration too.
        let id = UUID(), owner = UUID()
        let head = GroupedCopyHead(protocolKind: .groupedCopyV1, protocolVersion: 1, owner: owner, id: id,
            createdAt: Date(), metadataPolicy: policy, groupSize: qualification.groupSize, admittedCount: members.count,
            groupCount: 0, revision: 0, state: .preparing, undoInvalidated: false, reviewIntent: nil)
        try GroupedCopyRecord(head: head, groups: [], members: members.enumerated().map {
            GroupedCopyMember(owner: owner, job: id, ordinal: $0.offset, manifest: $0.element, progress: .notDeclared)
        }).validate()
        return Self(qualification: qualification, members: members, itemIDs: entries.map(\.id))
    }

    func revalidate(journal: URL, cancellation: OperationCancellation) throws {
        try qualification.validate(sources: members.map { $0.source.url }, destinations: members.map { $0.destination.url }, journal: journal)
        for member in members {
            try cancellation.check()
            let source = try GroupedCopyFilesystemEvidence.checkedParent(member.source)
            let destination = try GroupedCopyFilesystemEvidence.checkedParent(member.destination)
            try Self.requireLocalLocation(source.url); try Self.requireLocalLocation(destination.url)
            let native = try NativeRenameEntry.observe(parent: source, name: member.source.name)
            guard native.nameBytes == member.source.nameBytes, native.identity == member.sourceTree.identity else { throw FileOperationFailure.sourceChanged }
            try Self.requireResidentRegular(parent: source, name: member.source.name, expected: member.sourceTree.identity)
            guard member.sourceTree.matches(try verifiedTree(parent: source.fd, name: member.source.name, cancellation: cancellation)) else { throw FileOperationFailure.sourceChanged }
            try requireAbsent(member.destination.name, in: destination.fd)
            try source.validate(); try destination.validate()
        }
    }

    /// Conservative known-cloud exclusions, not a universal FileProvider detector.
    /// Production additionally binds reviewed volume IDs; generated routes keep
    /// their existing disposable-root checks.
    static func requireLocalLocation(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isUbiquitousItemKey, .volumeIsLocalKey])
        // Foundation returns nil for isUbiquitousItem on qualified local fixtures.
        // Positive local-volume evidence is mandatory; nil is not cloud evidence.
        guard values.volumeIsLocal == true, values.isUbiquitousItem != true,
              !url.pathComponents.contains("CloudStorage"), !url.pathComponents.contains("Mobile Documents") else { throw FileOperationFailure.unsupported }
    }

    /// No body reads: refuse dataless/known-cloud/alias/hard-link inputs first.
    static func requireResidentRegular(parent: DirectoryAnchor, name: String, expected: EntrySnapshot) throws {
        var info = stat()
        guard fstatat(parent.fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw posixFailure() }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1, info.st_flags & UInt32(SF_DATALESS) == 0 else { throw FileOperationFailure.unsupported }
        let url = parent.url.appendingPathComponent(name)
        let values = try url.resourceValues(forKeys: [.isAliasFileKey])
        guard values.isAliasFile == false else { throw FileOperationFailure.unsupported }
        try requireLocalLocation(url)
        guard try EntrySnapshot(parent: parent.fd, name: name) == expected else { throw FileOperationFailure.sourceChanged }
    }
}
