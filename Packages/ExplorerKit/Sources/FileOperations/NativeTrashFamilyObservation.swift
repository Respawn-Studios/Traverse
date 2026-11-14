import CryptoKit
import Darwin
import Foundation

/// Closed, path-free categories of inputs already used by native Trash verification.
/// The root binding is a separate same-object check, not an appended digest byte.
public enum NativeTrashFingerprintFamily: String, CaseIterable, Hashable, Sendable {
    case rootObject, entryMetadata, linkStructure, content, acl
    case quarantine, provenance, finderInfo, otherXattrs
}

/// Available only after a complete before/after walk and stable parent validation.
/// The OS access attribute is excluded from the native comparison, so it is
/// deliberately separate from families that can explain a native digest refusal.
public enum NativeTrashFamilyFinding: Equatable, Sendable {
    case complete(nativeChanged: [NativeTrashFingerprintFamily], osAccessAttributeChanged: Bool)
    case unavailable
}

/// Ordinary file Trash admits a bounded root metadata transition. A separate
/// versioned directory contract uses the complete family collector below.
internal enum NativeTrashVerificationMode: Equatable, Sendable {
    case strict, ordinaryRegularFilePairCandidate, ordinaryRegularFileNativeMetadata
    case retainedTextDirectoryRootNativeMetadata

    var requiresRegularFilePreflight: Bool {
        switch self {
        case .ordinaryRegularFilePairCandidate, .ordinaryRegularFileNativeMetadata: true
        case .strict, .retainedTextDirectoryRootNativeMetadata: false
        }
    }
}

/// A source-composition choice for future generated qualification. Public app
/// constructors keep ordinary directory Trash strict.
internal enum NativeTrashDirectoryAdmission: Sendable {
    case strict, additiveRootOnlyCandidate, nativeRootMetadata
}

/// Journal witness for one complete directory walk. It contains only bounded
/// hashes and attribute descriptors, never an xattr body or descendant path.
internal struct NativeTrashRootMetadataProofV4: Codable, Equatable, Sendable {
    internal struct Attribute: Codable, Equatable, Sendable {
        let length: Int, digest: Data
        init(_ value: SecurityAttribute) { length = value.length; digest = value.digest }
        var valid: Bool { length > 0 && length <= 16_777_216 && digest.count == 32 }
    }
    let before: VerifiedTree, after: VerifiedTree
    let beforeNative: [String: Data], afterNative: [String: Data]
    let beforeOSAccess: Data, afterOSAccess: Data
    let beforeDescendantQuarantine: Data, afterDescendantQuarantine: Data
    let beforeDescendantOSAccess: Data, afterDescendantOSAccess: Data
    let beforeDescendantIdentity: Data, afterDescendantIdentity: Data
    let beforeRootQuarantine: Attribute?, afterRootQuarantine: Attribute

    func validates(before expectedBefore: VerifiedTree, after expectedAfter: VerifiedTree) -> Bool {
        validatesRootQuarantineChange(before: expectedBefore, after: expectedAfter,
                                      requiresOSAccessChange: true)
    }

    /// Only the v12 native directory contract may accept a root quarantine
    /// addition or rewrite without a simultaneous OS access change.
    func validatesNativeDirectoryV12(before expectedBefore: VerifiedTree,
                                     after expectedAfter: VerifiedTree) -> Bool {
        validatesRootQuarantineChange(before: expectedBefore, after: expectedAfter,
                                      requiresOSAccessChange: false)
    }

    private func validatesRootQuarantineChange(before expectedBefore: VerifiedTree,
                                               after expectedAfter: VerifiedTree,
                                               requiresOSAccessChange: Bool) -> Bool {
        let keys = Set(NativeTrashFingerprintFamily.allCases.filter { $0 != .rootObject }.map(\.rawValue))
        guard before == expectedBefore, after == expectedAfter,
              before.identity.isDirectory, after.identity.isDirectory,
              before.identity.sameObject(as: after.identity),
              !before.matchesNativeTrashTransition(after),
              Set(beforeNative.keys) == keys, Set(afterNative.keys) == keys,
              beforeNative.values.allSatisfy({ $0.count == 32 }),
              afterNative.values.allSatisfy({ $0.count == 32 }),
              [beforeOSAccess, afterOSAccess, beforeDescendantQuarantine,
               afterDescendantQuarantine, beforeDescendantOSAccess,
               afterDescendantOSAccess, beforeDescendantIdentity,
               afterDescendantIdentity].allSatisfy({ $0.count == 32 }),
              (!requiresOSAccessChange || beforeOSAccess != afterOSAccess),
              beforeDescendantQuarantine == afterDescendantQuarantine,
              beforeDescendantOSAccess == afterDescendantOSAccess,
              beforeDescendantIdentity == afterDescendantIdentity,
              beforeNative[NativeTrashFingerprintFamily.quarantine.rawValue] != afterNative[NativeTrashFingerprintFamily.quarantine.rawValue],
              afterRootQuarantine.valid,
              beforeRootQuarantine.map({ $0.valid && $0 != afterRootQuarantine }) ?? true else { return false }
        return keys.filter { $0 != NativeTrashFingerprintFamily.quarantine.rawValue }.allSatisfy {
            beforeNative[$0] == afterNative[$0]
        }
    }

    /// Literal attribute preservation only. This does not claim that macOS
    /// interprets the new mark as stronger execution protection.
    func validatesAdditiveRoot(before expectedBefore: VerifiedTree, after expectedAfter: VerifiedTree) -> Bool {
        beforeRootQuarantine == nil && validates(before: expectedBefore, after: expectedAfter)
    }
}

internal enum NativeTrashInputFamily: Equatable {
    case entryMetadata, linkStructure, content, acl
    case quarantine, provenance, finderInfo, otherXattrs, osAccessAttribute

    var nativeFamily: NativeTrashFingerprintFamily? {
        switch self {
        case .entryMetadata: .entryMetadata
        case .linkStructure: .linkStructure
        case .content: .content
        case .acl: .acl
        case .quarantine: .quarantine
        case .provenance: .provenance
        case .finderInfo: .finderInfo
        case .otherXattrs: .otherXattrs
        case .osAccessAttribute: nil
        }
    }
}

internal struct NativeTrashFamilySnapshot {
    fileprivate let native: [NativeTrashFingerprintFamily: Data]
    fileprivate let osAccessAttribute: Data
    fileprivate let rootQuarantine: SecurityAttribute?
    fileprivate let rootQuarantineObserved: Bool
    fileprivate let descendantQuarantine: Data
    fileprivate let descendantOSAccess: Data
    fileprivate let descendantIdentity: Data
    /// The complete walk that produced these hashes. Families from another
    /// object or another moment cannot justify a transition for this tree.
    fileprivate let tree: VerifiedTree

    /// Path-free identity binding for a v12 directory's committed descendants.
    var directoryDescendantIdentityWitness: Data { descendantIdentity }

    #if DEBUG
    /// Generated negative control: identical family hashes with the wrong
    /// completed-tree binding must be refused independently of their values.
    func qualificationRebound(to other: VerifiedTree) -> Self {
        .init(native: native, osAccessAttribute: osAccessAttribute,
              rootQuarantine: rootQuarantine, rootQuarantineObserved: rootQuarantineObserved,
              descendantQuarantine: descendantQuarantine, descendantOSAccess: descendantOSAccess,
              descendantIdentity: descendantIdentity, tree: other)
    }
    #endif

    /// A new inode with identical bytes is still a different descendant. The
    /// pre-call gate compares the complete collector as well as the full tree.
    func matchesPreMutationRewalk(_ later: Self, before: VerifiedTree, current: VerifiedTree) -> Bool {
        tree == before && later.tree == current && before.matches(current)
            && rootQuarantineObserved && later.rootQuarantineObserved
            && rootQuarantine == later.rootQuarantine
            && native == later.native && osAccessAttribute == later.osAccessAttribute
            && descendantQuarantine == later.descendantQuarantine
            && descendantOSAccess == later.descendantOSAccess
            && descendantIdentity == later.descendantIdentity
    }

    /// The exact native directory transition may add access metadata to the
    /// root. Its native inputs and every descendant observation stay exact.
    func permitsExactNativeDirectoryTransition(comparedWith later: Self,
                                               before: VerifiedTree, returned: VerifiedTree) -> Bool {
        tree == before && later.tree == returned
            && before.identity.isDirectory && returned.identity.isDirectory
            && before.matchesNativeTrashTransition(returned)
            && rootQuarantineObserved && later.rootQuarantineObserved
            && rootQuarantine == later.rootQuarantine
            && native == later.native
            && descendantQuarantine == later.descendantQuarantine
            && descendantOSAccess == later.descendantOSAccess
            && descendantIdentity == later.descendantIdentity
    }

    func permitsBoundedRootQuarantineChange(comparedWith after: Self, before: VerifiedTree,
                                            returned: VerifiedTree) -> Bool {
        guard tree == before, after.tree == returned,
              before.identity.sameObject(as: returned.identity),
              rootQuarantineObserved, after.rootQuarantineObserved else { return false }
        switch (rootQuarantine, after.rootQuarantine) {
        case (nil, .some(let later)): return later.length > 0
        case (.some(let original), .some(let later)):
            return original.length > 0 && later.length > 0 && original != later
        default: return false
        }
    }

    /// Presence only; raw marks and their digests stay out of history and UI.
    func rootQuarantineChanged(comparedWith after: Self, before: VerifiedTree,
                               returned: VerifiedTree) -> Bool? {
        guard tree == before, after.tree == returned,
              rootQuarantineObserved, after.rootQuarantineObserved else { return nil }
        return rootQuarantine != after.rootQuarantine
    }

    /// A native reverse rename from Trash may rewrite an existing root mark.
    /// Admit only an observed nonempty-to-nonempty quarantine change; every
    /// other native family and OS access metadata must remain exact.
    func permitsOrdinaryTrashUndoRootQuarantineRewrite(comparedWith after: Self,
                                                       before: VerifiedTree, restored: VerifiedTree) -> Bool {
        guard tree == before, after.tree == restored,
              before.identity.type == S_IFREG, restored.identity.type == S_IFREG,
              before.identity.sameObject(as: restored.identity),
              rootQuarantineObserved, after.rootQuarantineObserved,
              let original = rootQuarantine, let rewritten = after.rootQuarantine,
              original.length > 0, rewritten.length > 0, original != rewritten else { return false }
        return finding(comparedWith: after, before: before, returned: restored)
            == .complete(nativeChanged: [.quarantine], osAccessAttributeChanged: false)
    }

    /// Only a root security rewrite is allowed after a native directory rename.
    /// Every descendant identity and input family remains exact.
    func permitsDirectoryRootSecurityRewrite(comparedWith after: Self,
                                             before: VerifiedTree, renamed: VerifiedTree) -> Bool {
        guard tree == before, after.tree == renamed,
              before.identity.isDirectory, renamed.identity.isDirectory,
              before.identity.sameObject(as: renamed.identity),
              rootQuarantineObserved, after.rootQuarantineObserved,
              descendantIdentity == after.descendantIdentity,
              descendantQuarantine == after.descendantQuarantine,
              descendantOSAccess == after.descendantOSAccess else { return false }
        let markChanged = rootQuarantine != after.rootQuarantine
        let changed: [NativeTrashFingerprintFamily]
        let osAccessChanged: Bool
        switch finding(comparedWith: after, before: before, returned: renamed) {
        case .complete(let families, let osChanged): changed = families; osAccessChanged = osChanged
        case .unavailable: return false
        }
        guard (markChanged || osAccessChanged),
              changed == (markChanged ? [.quarantine] : []) else { return false }
        if markChanged {
            guard let original = rootQuarantine, let rewritten = after.rootQuarantine,
                  original.length > 0, rewritten.length > 0 else { return false }
        }
        return true
    }

    /// Retained private v10 Delete staging keeps the same bounded rule.
    func permitsOwnedTrashStagingRootSecurityRewrite(comparedWith after: Self,
                                                    before: VerifiedTree, staged: VerifiedTree) -> Bool {
        permitsDirectoryRootSecurityRewrite(comparedWith: after, before: before, renamed: staged)
    }

    func finding(comparedWith after: Self, before: VerifiedTree, returned: VerifiedTree) -> NativeTrashFamilyFinding {
        guard tree == before, after.tree == returned else { return .unavailable }
        var changed: [NativeTrashFingerprintFamily] = []
        if !before.identity.sameObject(as: returned.identity) { changed.append(.rootObject) }
        for family in NativeTrashFingerprintFamily.allCases where family != .rootObject {
            guard let before = native[family], let later = after.native[family] else { return .unavailable }
            if before != later { changed.append(family) }
        }
        // An inverse rename can change only the separate OS access attribute.
        // An unchanged complete pair has no transition to explain.
        let osAccessChanged = osAccessAttribute != after.osAccessAttribute
        guard !changed.isEmpty || osAccessChanged else { return .unavailable }
        return .complete(nativeChanged: changed,
                         osAccessAttributeChanged: osAccessChanged)
    }

    func rootMetadataProof(comparedWith after: Self, before: VerifiedTree,
                           returned: VerifiedTree,
                           nativeDirectoryV12: Bool = false) -> NativeTrashRootMetadataProofV4? {
        let observed = finding(comparedWith: after, before: before, returned: returned)
        guard before.identity.isDirectory, returned.identity.isDirectory,
              (observed == .complete(nativeChanged: [.quarantine], osAccessAttributeChanged: true)
               || nativeDirectoryV12 && observed == .complete(
                    nativeChanged: [.quarantine], osAccessAttributeChanged: false)),
              permitsBoundedRootQuarantineChange(comparedWith: after, before: before, returned: returned),
              descendantQuarantine == after.descendantQuarantine,
              descendantOSAccess == after.descendantOSAccess,
              descendantIdentity == after.descendantIdentity,
              let root = after.rootQuarantine else { return nil }
        let proof = NativeTrashRootMetadataProofV4(
            before: before, after: returned,
            beforeNative: Dictionary(uniqueKeysWithValues: native.map { ($0.key.rawValue, $0.value) }),
            afterNative: Dictionary(uniqueKeysWithValues: after.native.map { ($0.key.rawValue, $0.value) }),
            beforeOSAccess: osAccessAttribute, afterOSAccess: after.osAccessAttribute,
            beforeDescendantQuarantine: descendantQuarantine,
            afterDescendantQuarantine: after.descendantQuarantine,
            beforeDescendantOSAccess: descendantOSAccess,
            afterDescendantOSAccess: after.descendantOSAccess,
            beforeDescendantIdentity: descendantIdentity,
            afterDescendantIdentity: after.descendantIdentity,
            beforeRootQuarantine: rootQuarantine.map(NativeTrashRootMetadataProofV4.Attribute.init),
            afterRootQuarantine: .init(root))
        return (nativeDirectoryV12
            ? proof.validatesNativeDirectoryV12(before: before, after: returned)
            : proof.validates(before: before, after: returned)) ? proof : nil
    }
}

/// Ephemeral sidecar for one verifiedTree walk. It receives bytes from the
/// existing append sites and never retains an attribute, path, or file body.
internal final class NativeTrashFamilyCollector {
    private var native: [NativeTrashFingerprintFamily: SHA256] = [:]
    private var osAccessAttribute = SHA256()
    private var descendantQuarantine = SHA256()
    private var descendantOSAccess = SHA256()
    private var descendantIdentity = SHA256()
    private var rootQuarantine: SecurityAttribute?
    private var rootQuarantineObserved = false
    private var completed = false
    private var invalid = false
    private var sealedTree: VerifiedTree?
    #if DEBUG
    private var qualificationRemap: ((NativeTrashInputFamily) -> NativeTrashInputFamily)?
    /// An internal negative-control seam. It cannot change canonical digests.
    func setQualificationRemap(_ value: @escaping (NativeTrashInputFamily) -> NativeTrashInputFamily) {
        qualificationRemap = value
    }
    #endif

    init() {
        for family in NativeTrashFingerprintFamily.allCases where family != .rootObject {
            native[family] = Self.seed(family.rawValue)
        }
        osAccessAttribute = Self.seed("osAccessAttribute")
        descendantQuarantine = Self.seed("descendantQuarantine")
        descendantOSAccess = Self.seed("descendantOSAccess")
        descendantIdentity = Self.seed("descendantIdentity")
    }

    private static func seed(_ name: String) -> SHA256 {
        var value = SHA256()
        value.update(data: Data("traverse.native-trash-family.v1:".utf8))
        value.update(data: Data(name.utf8))
        return value
    }

    private static func update(_ value: inout SHA256, relative: String, bytes: Data) {
        let path = Data(relative.utf8)
        for input in [path, bytes] {
            value.update(data: Data("\(input.count):".utf8))
            value.update(data: input)
        }
    }

    func append(_ bytes: Data, relative: String, family: NativeTrashInputFamily) {
        if completed { invalid = true; return }
        #if DEBUG
        let effective = qualificationRemap?(family) ?? family
        #else
        let effective = family
        #endif
        if let label = effective.nativeFamily {
            guard var value = native[label] else { return }
            Self.update(&value, relative: relative, bytes: bytes)
            native[label] = value
        } else {
            Self.update(&osAccessAttribute, relative: relative, bytes: bytes)
        }
        if !relative.isEmpty {
            if effective == .quarantine {
                Self.update(&descendantQuarantine, relative: relative, bytes: bytes)
            } else if effective == .osAccessAttribute {
                Self.update(&descendantOSAccess, relative: relative, bytes: bytes)
            }
        }
    }

    /// The canonical tree remains copy-compatible; this sidecar additionally
    /// proves a native directory move retained every descendant object.
    func observeDescendantIdentity(_ entry: EntrySnapshot, relative: String) {
        if completed { invalid = true; return }
        guard !relative.isEmpty else { return }
        let value = "\(entry.device)|\(entry.inode)|\(entry.type)|\(entry.birthSeconds)|\(entry.birthNanos)"
        Self.update(&descendantIdentity, relative: relative, bytes: Data(value.utf8))
    }

    /// Called once after the root xattr enumeration, including absence.
    func observeRootQuarantine(_ attribute: SecurityAttribute?) {
        if completed || rootQuarantineObserved { invalid = true; return }
        rootQuarantine = attribute
        rootQuarantineObserved = true
    }

    /// The caller seals only after the entire tree and final object checks pass.
    func seal(tree: VerifiedTree) { completed = true; sealedTree = tree }

    func snapshot() -> NativeTrashFamilySnapshot? {
        guard completed && !invalid && rootQuarantineObserved, let sealedTree else { return nil }
        var result: [NativeTrashFingerprintFamily: Data] = [:]
        for (family, original) in native {
            let value = original
            result[family] = Data(value.finalize())
        }
        let access = osAccessAttribute
        let childQuarantine = descendantQuarantine
        let childAccess = descendantOSAccess
        let childIdentity = descendantIdentity
        return NativeTrashFamilySnapshot(native: result, osAccessAttribute: Data(access.finalize()),
                                         rootQuarantine: rootQuarantine,
                                         rootQuarantineObserved: rootQuarantineObserved,
                                         descendantQuarantine: Data(childQuarantine.finalize()),
                                         descendantOSAccess: Data(childAccess.finalize()),
                                         descendantIdentity: Data(childIdentity.finalize()), tree: sealedTree)
    }
}
