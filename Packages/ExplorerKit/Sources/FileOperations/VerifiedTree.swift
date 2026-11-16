import CryptoKit
import Darwin
import Foundation

private struct VerifiedTreeLinkIdentity: Hashable {
    let device: dev_t
    let inode: ino_t
}

/// Canonical UTF-8 component-order walk of every produced node, including the
/// root. One bit records each node's public quarantine-property presence;
/// neither paths nor private quarantine bytes enter the journal.
internal struct PublicTreeQuarantineWitnessV16: Codable, Equatable, Sendable {
    let nodeCount: Int
    let pathSetSHA256: String
    let presenceBits: Data
    let requiresEveryNode: Bool

    func validateRepresentation() throws {
        guard (1...20_000).contains(nodeCount), pathSetSHA256.utf8.count == 64,
              pathSetSHA256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              presenceBits.count == (nodeCount + 7) / 8 else { throw FileOperationFailure.recoveryUncertain }
        let used = nodeCount % 8
        if used != 0 {
            guard presenceBits.last! & ~UInt8((1 << used) - 1) == 0 else { throw FileOperationFailure.recoveryUncertain }
        }
        if requiresEveryNode {
            for index in 0..<nodeCount where presenceBits[index / 8] & (UInt8(1) << UInt8(index % 8)) == 0 {
                throw FileOperationFailure.recoveryUncertain
            }
        }
    }
}

internal struct VerifiedTree: Codable, Equatable, Sendable {
    let identity: EntrySnapshot
    let digest: String
    /// V14 Download, v15 one-file ZIP extraction or v16 produced tree only. Legacy fingerprints
    /// include every raw xattr byte; this projection omits the two OS-managed
    /// security attributes entirely.
    let osManagedSecurityV1: Bool?
    /// V16's per-node public-property presence, independent of opaque xattrs.
    let publicTreeQuarantineV16: PublicTreeQuarantineWitnessV16?
    /// Native Trash may grant macOS access metadata while retaining the same object.
    /// Full digest remains authoritative for copy, move and every later Undo guard.
    let nativeTrashDigest: String?
    init(identity: EntrySnapshot, digest: String, nativeTrashDigest: String?, osManagedSecurityV1: Bool? = nil,
         publicTreeQuarantineV16: PublicTreeQuarantineWitnessV16? = nil) {
        self.identity = identity; self.digest = digest; self.nativeTrashDigest = nativeTrashDigest
        self.osManagedSecurityV1 = osManagedSecurityV1
        self.publicTreeQuarantineV16 = publicTreeQuarantineV16
    }
    func matchesNativeTrashTransition(_ other: Self) -> Bool {
        guard identity.sameObject(as: other.identity), osManagedSecurityV1 == other.osManagedSecurityV1,
              publicTreeQuarantineV16 == other.publicTreeQuarantineV16 else { return false }
        if let before = nativeTrashDigest, let after = other.nativeTrashDigest { return before == after }
        return digest == other.digest
    }
    func matches(_ other: Self) -> Bool {
        identity.sameObject(as: other.identity) && osManagedSecurityV1 == other.osManagedSecurityV1
            && publicTreeQuarantineV16 == other.publicTreeQuarantineV16 && digest == other.digest
    }
}

/// Reads only explicitly operated-on objects. Digests are private journal guards, never an index.
/// Unsupported or unrepresentable metadata fails closed before source retirement.
internal func verifiedTree(_ url: URL, cancellation: OperationCancellation, beforeRootValidation: (@Sendable () -> Void)? = nil, budget: TraversalBudget? = nil, copyComparison: CopyComparison? = nil, guarded: GuardedTrashPolicy? = nil, requiresMaterialized: Bool = false, expectedFileContents: [String: Data]? = nil, expectedIdentities: [String: EntrySnapshot]? = nil, expectedQuarantines: [String: Data]? = nil, nativeTrashFamilyCollector: NativeTrashFamilyCollector? = nil, nativeTrashWalkMeter: NativeTrashWalkMeter? = nil, nativeTrashSyntheticRootMetadata: NativeTrashSyntheticRootMetadata? = nil, osManagedSecurityV1: Bool = false, publicTreeRequiresEveryNode: Bool? = nil) throws -> VerifiedTree {
    let parent = try DirectoryAnchor(url.deletingLastPathComponent(), resolve: false)
    return try verifiedTree(parent: parent.fd, name: url.lastPathComponent, cancellation: cancellation, beforeRootValidation: beforeRootValidation, budget: budget, copyComparison: copyComparison, guarded: guarded, rootURL: url, requiresMaterialized: requiresMaterialized, expectedFileContents: expectedFileContents, expectedIdentities: expectedIdentities, expectedQuarantines: expectedQuarantines, nativeTrashFamilyCollector: nativeTrashFamilyCollector, nativeTrashWalkMeter: nativeTrashWalkMeter, nativeTrashSyntheticRootMetadata: nativeTrashSyntheticRootMetadata, osManagedSecurityV1: osManagedSecurityV1, publicTreeRequiresEveryNode: publicTreeRequiresEveryNode)
}

internal func verifiedTree(parent: Int32, name: String, cancellation: OperationCancellation, beforeRootValidation: (@Sendable () -> Void)? = nil, budget: TraversalBudget? = nil, copyComparison: CopyComparison? = nil, guarded: GuardedTrashPolicy? = nil, rootURL: URL? = nil, requiresMaterialized: Bool = false, expectedFileContents: [String: Data]? = nil, expectedIdentities: [String: EntrySnapshot]? = nil, expectedQuarantines: [String: Data]? = nil, nativeRename: NativeRenameSecurityProjection? = nil, nativeTrashFamilyCollector: NativeTrashFamilyCollector? = nil, nativeTrashWalkMeter: NativeTrashWalkMeter? = nil, nativeTrashSyntheticRootMetadata: NativeTrashSyntheticRootMetadata? = nil, osManagedSecurityV1: Bool = false, publicTreeRequiresEveryNode: Bool? = nil) throws -> VerifiedTree {
    guard !osManagedSecurityV1 || expectedQuarantines == nil && copyComparison == nil && guarded == nil && nativeTrashFamilyCollector == nil else {
        throw FileOperationFailure.invalidRequest
    }
    let root = try EntrySnapshot(parent: parent, name: name)
    guard publicTreeRequiresEveryNode == nil || osManagedSecurityV1 && root.isDirectory && rootURL != nil else {
        throw FileOperationFailure.invalidRequest
    }
    var hasher = SHA256()
    var nativeTrashHasher = SHA256()
    var publicPathHasher = SHA256(), publicPresenceBits = Data(), publicNodeCount = 0
    let budget = budget ?? TraversalBudget()
    var hardLinkGroups: [VerifiedTreeLinkIdentity: Int] = [:]
    // A traversal visits files sequentially. Reuse one lazily allocated buffer
    // within this call; concurrent traversals retain independent storage.
    var readBuffer: [UInt8] = []
    func append(_ bytes: Data, relative: String, family: NativeTrashInputFamily, nativeRenameIncluded: Bool = true) {
        let length = Data("\(bytes.count):".utf8)
        hasher.update(data: length); hasher.update(data: bytes)
        if family.nativeFamily != nil { nativeTrashHasher.update(data: length); nativeTrashHasher.update(data: bytes) }
        nativeTrashFamilyCollector?.append(bytes, relative: relative, family: family)
        if nativeRenameIncluded { nativeRename?.append(bytes) }
    }
    func visit(_ parent: Int32, _ name: String, _ relative: String, _ depth: Int) throws {
        try cancellation.check()
        let before = try EntrySnapshot(parent: parent, name: name)
        nativeTrashWalkMeter?.visit()
        if let expectedIdentities {
            let path = relative.hasPrefix("/") ? String(relative.dropFirst()) : relative
            guard expectedIdentities[path] == before else { throw FileOperationFailure.sourceChanged }
        }
        try budget.consume(before, depth: depth)
        cancellation.progress?.visit(relative: relative.hasPrefix("/") ? String(relative.dropFirst()) : relative)
        guard before.device == root.device, [S_IFREG, S_IFDIR, S_IFLNK].contains(before.type) else {
            throw FileOperationFailure.unsupported
        }
        if let guarded, let rootURL {
            let url = relative.isEmpty ? rootURL : rootURL.appendingPathComponent(String(relative.dropFirst()))
            try guarded.validateBeforeOpen(parent: parent, name: name, url: url, root: root)
        }
        let flags = before.isDirectory ? O_RDONLY | O_DIRECTORY | O_NOFOLLOW
            : before.type == S_IFLNK ? O_RDONLY | O_SYMLINK : O_RDONLY | O_NOFOLLOW
        let fd = openat(parent, name, flags | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw posixFailure() }
        defer { close(fd) }
        guard try EntrySnapshot(fd: fd) == before else { throw FileOperationFailure.sourceChanged }
        if let requiresEveryNode = publicTreeRequiresEveryNode, let rootURL {
            guard publicNodeCount < 20_000, [S_IFREG, S_IFDIR].contains(before.type) else {
                throw FileOperationFailure.unsupported
            }
            let path = relative.isEmpty ? "" : String(relative.dropFirst())
            let nodeURL = relative.isEmpty ? rootURL : URL(fileURLWithPath: rootURL.path + relative)
            let properties = try nodeURL.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties
            let present = properties?.isEmpty == false
            guard !requiresEveryNode || present,
                  try EntrySnapshot(fd: fd) == before,
                  try EntrySnapshot(parent: parent, name: name) == before else {
                throw FileOperationFailure.copyMetadataMismatch
            }
            publicPathHasher.update(data: Data("\(path.utf8.count):\(before.type):".utf8))
            publicPathHasher.update(data: Data(path.utf8))
            if publicNodeCount % 8 == 0 { publicPresenceBits.append(0) }
            if present { publicPresenceBits[publicNodeCount / 8] |= UInt8(1) << UInt8(publicNodeCount % 8) }
            publicNodeCount += 1
        }
        nativeTrashFamilyCollector?.observeDescendantIdentity(before, relative: relative)
        var value = stat()
        guard fstat(fd, &value) == 0 else { throw posixFailure() }
        if guarded != nil || requiresMaterialized { try GuardedTrashPolicy.requireMaterialized(value) }
        copyComparison?.appendContent(Data(relative.utf8))
        copyComparison?.appendContent(Data("\(before.type)".utf8))
        copyComparison?.beginMetadataNode(relative)
        copyComparison?.appendMetadata(Data("\(before.mode)|\(value.st_flags)|\(before.modifiedSeconds)|\(before.modifiedNanos)".utf8))
        if copyComparison?.diagnoseMetadataFamilies == true {
            copyComparison?.appendMetadata(Data("\(before.mode)".utf8), family: .mode)
            copyComparison?.appendMetadata(Data("\(value.st_flags)".utf8), family: .flags)
            copyComparison?.appendMetadata(Data("\(before.modifiedSeconds)|\(before.modifiedNanos)".utf8), family: .modificationTime)
        }
        copyComparison?.appendOwnership(Data(relative.utf8))
        copyComparison?.appendOwnership(Data("\(value.st_uid)|\(value.st_gid)".utf8))
        var security = CopySecurity()
        append(Data(relative.utf8), relative: relative, family: .entryMetadata)
        append(Data("\(before.mode)|\(value.st_uid)|\(value.st_gid)|\(value.st_flags)|\(before.modifiedSeconds)|\(before.modifiedNanos)".utf8), relative: relative, family: .entryMetadata)
        let size = flistxattr(fd, nil, 0, 0)
        guard size >= 0 else { throw posixFailure() }
        guard size <= 1_048_576 else { throw FileOperationFailure.unsupported }
        var names = [CChar](repeating: 0, count: max(1, size))
        let receivedNames = flistxattr(fd, &names, size, 0)
        guard receivedNames >= 0 else { throw errno == ERANGE ? FileOperationFailure.sourceChanged : posixFailure() }
        guard receivedNames == size else { throw FileOperationFailure.sourceChanged }
        let actualAttributes = names.prefix(size).split(separator: 0).map { Data($0.map { UInt8(bitPattern: $0) }) }.sorted { $0.lexicographicallyPrecedes($1) }
        #if DEBUG
        let actualAttributeSet = Set(actualAttributes)
        let addedNames = relative.isEmpty ? nativeTrashSyntheticRootMetadata?.names ?? [] : []
        let attributes = Array(Set(actualAttributes + addedNames.map { Data($0.utf8) }))
            .sorted { $0.lexicographicallyPrecedes($1) }
        #else
        let attributes = actualAttributes
        #endif
        func readAttribute(_ attribute: String) throws -> Data {
            let length = fgetxattr(fd, attribute, nil, 0, 0, 0)
            guard length >= 0 else { throw errno == ENOATTR ? FileOperationFailure.sourceChanged : posixFailure() }
            guard length <= 16_777_216 else { throw FileOperationFailure.unsupported }
            var data = Data(count: length)
            let actual = data.withUnsafeMutableBytes { fgetxattr(fd, attribute, $0.baseAddress, length, 0, 0) }
            guard actual >= 0 else { throw errno == ERANGE || errno == ENOATTR ? FileOperationFailure.sourceChanged : posixFailure() }
            guard actual == length else { throw FileOperationFailure.sourceChanged }
            return data
        }
        for bytes in attributes {
            guard let attribute = String(data: bytes, encoding: .utf8) else { throw FileOperationFailure.unsupported }
            if osManagedSecurityV1 && (attribute == CopySecurity.quarantineName || attribute == CopySecurity.provenanceName) {
                continue
            }
            #if DEBUG
            var data: Data
            if actualAttributeSet.contains(bytes) { data = try readAttribute(attribute) }
            else { data = Data() }
            if relative.isEmpty, let replacement = nativeTrashSyntheticRootMetadata?.replacement(for: attribute) {
                data = replacement
            }
            #else
            let data = try readAttribute(attribute)
            #endif
            // Native FileManager Trash was observed adding com.apple.macl to an owned
            // fixture. Allow this OS access metadata transition only at that boundary;
            // retain it in the full fingerprint and do not remove or rewrite the attribute.
            if attribute == CopySecurity.quarantineName { security.quarantine = SecurityAttribute(data) }
            else if attribute == CopySecurity.provenanceName { security.provenance = SecurityAttribute(data) }
            else {
                copyComparison?.appendMetadata(bytes); copyComparison?.appendMetadata(data)
                let family: CopyOrdinaryMetadataFamily = attribute == "com.apple.ResourceFork" ? .resourceFork : .otherExtendedAttributes
                copyComparison?.appendMetadata(bytes, family: family)
                copyComparison?.appendMetadata(data, family: family)
            }
            let family: NativeTrashInputFamily
            if attribute == "com.apple.macl" { family = .osAccessAttribute }
            else if attribute == CopySecurity.quarantineName { family = .quarantine }
            else if attribute == CopySecurity.provenanceName { family = .provenance }
            else if attribute == "com.apple.FinderInfo" { family = .finderInfo }
            else { family = .otherXattrs }
            let rootQuarantine = relative.isEmpty && attribute == CopySecurity.quarantineName
            let rootProvenance = relative.isEmpty && attribute == CopySecurity.provenanceName
            if rootQuarantine { nativeRename?.observeRootQuarantine(data) }
            if rootProvenance { nativeRename?.observeRootProvenance(data) }
            append(bytes, relative: relative, family: family, nativeRenameIncluded: !rootQuarantine && !rootProvenance)
            append(data, relative: relative, family: family, nativeRenameIncluded: !rootQuarantine && !rootProvenance)
        }
        if let expected = expectedQuarantines?[relative.hasPrefix("/") ? String(relative.dropFirst()) : relative] {
            guard expected.count == 32, security.quarantine?.digest == expected else {
                throw FileOperationFailure.copyMetadataMismatch
            }
        }
        if relative.isEmpty { nativeTrashFamilyCollector?.observeRootQuarantine(security.quarantine) }
        if let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED) {
            defer { acl_free(UnsafeMutableRawPointer(acl)) }
            var aclLength: ssize_t = 0
            guard let aclText = acl_to_text(acl, &aclLength) else { throw posixFailure() }
            defer { acl_free(UnsafeMutableRawPointer(aclText)) }
            let aclData = Data(bytes: aclText, count: aclLength)
            append(aclData, relative: relative, family: .acl)
            copyComparison?.appendMetadata(aclData)
            copyComparison?.appendMetadata(aclData, family: .acl)
        } else {
            // Darwin returns ENOENT for an existing descriptor with no extended ACL.
            // The descriptor and directory entry are revalidated below; unsupported ACL
            // retrieval remains a refusal, never an assumed empty ACL.
            guard errno == ENOENT else { throw posixFailure() }
            append(Data(), relative: relative, family: .acl)
            copyComparison?.appendMetadata(Data())
            copyComparison?.appendMetadata(Data(), family: .acl)
        }
        if before.type == S_IFREG {
            let linkCount = Data("link-count:\(value.st_nlink)".utf8)
            copyComparison?.appendContent(linkCount)
            append(linkCount, relative: relative, family: .linkStructure)
            let key = VerifiedTreeLinkIdentity(device: before.device, inode: before.inode)
            let group: Int
            if let existing = hardLinkGroups[key] { group = existing }
            else { group = hardLinkGroups.count; hardLinkGroups[key] = group }
            let linkGroup = Data("link-group:\(group)".utf8)
            copyComparison?.appendContent(linkGroup)
            append(linkGroup, relative: relative, family: .linkStructure)
            var content = SHA256()
            if readBuffer.isEmpty { readBuffer = [UInt8](repeating: 0, count: 262_144) }
            var total: Int64 = 0
            while true {
                try cancellation.check()
                let received = readBuffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
                if received < 0, errno == EINTR { continue }
                guard received >= 0 else { throw posixFailure() }
                if received == 0 { break }
                total += Int64(received)
                nativeTrashWalkMeter?.read(received)
                cancellation.progress?.advance(bytes: Int64(received))
                guard total <= before.size else { throw FileOperationFailure.sourceChanged }
                readBuffer.withUnsafeBytes {
                    content.update(bufferPointer: UnsafeRawBufferPointer(rebasing: $0.prefix(received)))
                }
            }
            guard total == before.size else { throw FileOperationFailure.sourceChanged }
            let contentDigest = Data(content.finalize())
            if let expectedFileContents {
                let path = relative.hasPrefix("/") ? String(relative.dropFirst()) : relative
                guard expectedFileContents[path] == contentDigest else { throw FileOperationFailure.copyContentMismatch }
            }
            append(contentDigest, relative: relative, family: .content); copyComparison?.appendContent(contentDigest)
        } else if before.type == S_IFLNK {
            let target = Data(try linkBytes(parent: parent, name: name))
            append(target, relative: relative, family: .linkStructure); copyComparison?.appendContent(target)
        } else {
            for child in try childNames(in: fd, cancellation: cancellation, limit: budget.remaining) {
                try visit(fd, child, relative + "/" + child, depth + 1)
            }
        }
        try copyComparison?.record(relative, identity: before, security: security, ownership: CopyOwnership(uid: value.st_uid, gid: value.st_gid))
        cancellation.progress?.advance(items: 1)
        if relative.isEmpty { beforeRootValidation?() }
        guard try EntrySnapshot(fd: fd) == before,
              try EntrySnapshot(parent: parent, name: name) == before else { throw FileOperationFailure.sourceChanged }
    }
    try visit(parent, name, "", 0)
    let publicWitness: PublicTreeQuarantineWitnessV16?
    if let requiresEveryNode = publicTreeRequiresEveryNode {
        publicWitness = PublicTreeQuarantineWitnessV16(nodeCount: publicNodeCount,
            pathSetSHA256: publicPathHasher.finalize().map { String(format: "%02x", $0) }.joined(),
            presenceBits: publicPresenceBits, requiresEveryNode: requiresEveryNode)
        try publicWitness?.validateRepresentation()
    } else { publicWitness = nil }
    let verified = VerifiedTree(identity: root, digest: hasher.finalize().map { String(format: "%02x", $0) }.joined(),
                                nativeTrashDigest: nativeTrashHasher.finalize().map { String(format: "%02x", $0) }.joined(),
                                osManagedSecurityV1: osManagedSecurityV1 ? true : nil,
                                publicTreeQuarantineV16: publicWitness)
    nativeTrashFamilyCollector?.seal(tree: verified)
    return verified
}
