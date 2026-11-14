#if DEBUG
import Darwin
import Foundation

/// Virtual metadata exercises the real native verifier without writing a
/// protected xattr or calling FileManager/system Trash. Generated case only.
@_spi(Qualification) public struct GeneratedNativeTrashMetadataPairResult: Sendable {
    public let strictPairRefused: Bool
    public let candidatePairAccepted: Bool
    public let exactPairFamilyObserved: Bool
    public let accessOnlyAcceptedByStrict: Bool
    public let provenanceOnlyRefused: Bool
    public let pairWithOtherRefused: Bool
    public let contentDriftRefused: Bool
    public let replacementRefused: Bool
    public let missingFamilyRefused: Bool
    public let staleFamilyRefused: Bool
    public let strictDefaultRefused: Bool
    public let ordinaryCandidateCommitted: Bool
    public let ordinaryUndoGuardRefused: Bool
    public let sourceDriftRefusedBeforeProvider: Bool
    public let preflightEntries: Int
    public let preflightBodyBytes: Int64
    public let expectedBodyBytes: Int64
    public let preflightElapsedNanoseconds: UInt64
    public let fakeProviderCalls: Int
    public let systemTrashCalls: Int
    public var passed: Bool {
        strictPairRefused && candidatePairAccepted && exactPairFamilyObserved
            && accessOnlyAcceptedByStrict && provenanceOnlyRefused && pairWithOtherRefused
            && contentDriftRefused && replacementRefused && missingFamilyRefused
            && staleFamilyRefused && strictDefaultRefused && ordinaryCandidateCommitted
            && ordinaryUndoGuardRefused
            && sourceDriftRefusedBeforeProvider && preflightEntries == 1
            && preflightBodyBytes == expectedBodyBytes && preflightElapsedNanoseconds > 0
            && fakeProviderCalls == 1 && systemTrashCalls == 0
    }
}

@_spi(Qualification) public enum GeneratedNativeTrashMetadataPairOfflineControl {
    private static let caseAction = "native-trash-verifier-pair-offline-v1"

    private final class Count: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        var calls: Int { lock.withLock { value } }
        func increment() throws {
            try lock.withLock {
                guard value == 0 else { throw FileOperationFailure.invalidRequest }
                value += 1
            }
        }
    }

    private final class Walk: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [(Int, Int64, UInt64)] = []
        func accept(_ entries: Int, _ bytes: Int64, _ elapsed: UInt64) {
            lock.withLock { values.append((entries, bytes, elapsed)) }
        }
        var single: (Int, Int64, UInt64)? { lock.withLock { values.count == 1 ? values[0] : nil } }
    }

    private final class Provider: @unchecked Sendable {
        private let root: URL, name: String, body: Data
        let count = Count()
        init(root: URL, name: String, body: Data) { self.root = root; self.name = name; self.body = body }
        func move(_ supplied: URL) throws -> URL {
            let source = root.appendingPathComponent("Input/" + name)
            let target = root.appendingPathComponent("Returned/" + name)
            guard supplied == source else { throw FileOperationFailure.invalidRequest }
            try GeneratedNativeTrashMetadataPairOfflineControl.validateMarker(root)
            let before = try GeneratedNativeTrashMetadataPairOfflineControl.checkedBody(source, body: body)
            try count.increment()
            let from = try DirectoryAnchor(source.deletingLastPathComponent(), resolve: false)
            let to = try DirectoryAnchor(target.deletingLastPathComponent(), resolve: false)
            guard from.identity.device == to.identity.device,
                  try EntrySnapshot(parent: from.fd, name: name).sameObject(as: before) else {
                throw FileOperationFailure.sourceChanged
            }
            try requireAbsent(name, in: to.fd)
            try exclusiveRename(from: from.fd, name: name, to: to.fd, name: name)
            guard try EntrySnapshot(parent: to.fd, name: name).sameObject(as: before) else {
                throw FileOperationFailure.recoveryUncertain
            }
            try from.validate(); try to.validate()
            return target
        }
    }

    private static func facts(_ url: URL, directory: Bool) throws -> stat {
        guard url.isFileURL, url == url.standardizedFileURL,
              rootUnredirected(url) else { throw FileOperationFailure.invalidRequest }
        var value = stat()
        guard lstat(url.path, &value) == 0,
              value.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG),
              value.st_uid == geteuid(), value.st_mode & 0o077 == 0,
              (directory || value.st_nlink == 1) else { throw FileOperationFailure.invalidRequest }
        return value
    }

    private static func rootUnredirected(_ url: URL) -> Bool { url.resolvingSymlinksInPath() == url }

    private static func validateMarker(_ root: URL) throws {
        let marker = root.appendingPathComponent("reservation.json")
        let before = try facts(marker, directory: false)
        guard before.st_size <= 4096 else { throw FileOperationFailure.invalidRequest }
        let parent = try DirectoryAnchor(root, resolve: false)
        let fd = openat(parent.fd, "reservation.json", O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw FileOperationFailure.invalidRequest }
        defer { close(fd) }
        var opened = stat()
        guard fstat(fd, &opened) == 0, opened.st_dev == before.st_dev,
              opened.st_ino == before.st_ino, opened.st_mode & S_IFMT == S_IFREG,
              opened.st_uid == geteuid(), opened.st_mode & 0o077 == 0,
              opened.st_nlink == 1, opened.st_size == before.st_size else {
            throw FileOperationFailure.invalidRequest
        }
        let data = try FileHandle(fileDescriptor: fd, closeOnDealloc: false).read(upToCount: 4097)
        guard let data, data.count <= 4096,
              let fields = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              fields["packet"] as? String == "traverse-development-v1",
              fields["action"] as? String == caseAction,
              fields["maximumFakeCalls"] as? Int == 1,
              fields["maximumSystemTrashCalls"] as? Int == 0 else {
            throw FileOperationFailure.invalidRequest
        }
        try parent.validate()
    }

    private static func body(_ name: String) -> Data {
        Data("Traverse generated native Trash verifier pair \(name) v1\n".utf8)
    }

    @discardableResult
    private static func create(_ root: URL, name: String) throws -> URL {
        let allowed = Set(["Direct.bin", "Stale.bin", "Content.bin", "Replacement.bin",
                           "Ordinary.bin", "SourceDrift.bin"])
        guard allowed.contains(name) else {
            throw FileOperationFailure.invalidRequest
        }
        let parent = try DirectoryAnchor(root.appendingPathComponent("Input"), resolve: false)
        let value = body(name)
        let fd = openat(parent.fd, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw FileOperationFailure.invalidRequest }
        defer { close(fd) }
        try value.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw FileOperationFailure.ioFailure }
                offset += count
            }
        }
        guard fsync(fd) == 0 else { throw FileOperationFailure.ioFailure }
        try syncDirectory(parent)
        try parent.validate()
        return root.appendingPathComponent("Input/" + name)
    }

    private static func checkedBody(_ source: URL, body expected: Data) throws -> EntrySnapshot {
        let value = try facts(source, directory: false)
        guard value.st_size == off_t(expected.count), expected.count <= 4096 else {
            throw FileOperationFailure.invalidRequest
        }
        let parent = try DirectoryAnchor(source.deletingLastPathComponent(), resolve: false)
        let before = try EntrySnapshot(parent: parent.fd, name: source.lastPathComponent)
        let fd = openat(parent.fd, source.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw FileOperationFailure.invalidRequest }
        defer { close(fd) }
        let actual = try FileHandle(fileDescriptor: fd, closeOnDealloc: false).read(upToCount: expected.count + 1)
        guard actual == expected, try EntrySnapshot(fd: fd) == before else {
            throw FileOperationFailure.sourceChanged
        }
        try parent.validate()
        return before
    }

    private static func observed(_ url: URL) throws -> (VerifiedTree, NativeTrashFamilySnapshot) {
        let families = NativeTrashFamilyCollector()
        let tree = try verifiedTree(url, cancellation: OperationCancellation(), nativeTrashFamilyCollector: families)
        guard let snapshot = families.snapshot() else { throw FileOperationFailure.recoveryUncertain }
        return (tree, snapshot)
    }

    private static func verifies(_ root: URL, url: URL, before: VerifiedTree,
                                 families: NativeTrashFamilySnapshot?, synthetic: NativeTrashSyntheticRootMetadata,
                                 mode: NativeTrashVerificationMode?) throws -> Bool {
        var hooks = RecoveryHooks()
        // A strict caller remains strict even when this generated engine has
        // the ordinary Trash qualification hook installed.
        hooks.nativeTrashQualificationMode = .ordinaryRegularFilePairCandidate
        hooks.nativeTrashSyntheticRootMetadata = synthetic
        let engine = RecoverableFileOperations(journalDirectory: root.appendingPathComponent("State/direct"), hooks: hooks)
        do {
            if let mode {
                _ = try engine.verifyNativeTrashResult(url, before: before, cancellation: OperationCancellation(),
                    beforeFamilies: families, ordinaryMode: mode)
            } else {
                _ = try engine.verifyNativeTrashResult(url, before: before, cancellation: OperationCancellation(),
                    beforeFamilies: families)
            }
            return true
        } catch FileOperationFailure.recoveryUncertain { return false }
    }

    private static func rewriteFirstByte(_ url: URL) throws {
        let parent = try DirectoryAnchor(url.deletingLastPathComponent(), resolve: false)
        let fd = openat(parent.fd, url.lastPathComponent, O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw FileOperationFailure.invalidRequest }
        defer { close(fd) }
        let byte = Data([0x58])
        let written = byte.withUnsafeBytes { pwrite(fd, $0.baseAddress, $0.count, 0) }
        guard written == 1, fsync(fd) == 0 else { throw FileOperationFailure.ioFailure }
        try parent.validate()
    }

    /// Only a newly reserved private generated case under the compiled source
    /// repository is accepted. All created files and journals stay in that case.
    @_spi(Qualification) public static func run(root: URL) async throws -> GeneratedNativeTrashMetadataPairResult {
        var repo = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { repo.deleteLastPathComponent() }
        guard root.isFileURL, root == root.standardizedFileURL, rootUnredirected(root),
              root.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-development"),
              UUID(uuidString: root.lastPathComponent)?.uuidString == root.lastPathComponent else {
            throw FileOperationFailure.invalidRequest
        }
        let rootFacts = try facts(root, directory: true)
        for name in ["Input", "Returned", "State", "cache", "evidence", "source"] {
            let child = try facts(root.appendingPathComponent(name), directory: true)
            guard child.st_dev == rootFacts.st_dev else { throw FileOperationFailure.invalidRequest }
        }
        try validateMarker(root)
        for name in ["Input", "Returned", "State"] {
            guard try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(name).path).isEmpty else {
                throw FileOperationFailure.invalidRequest
            }
        }
        let pair = try NativeTrashSyntheticRootMetadata(
            provenance: Data("Traverse-generated-provenance-pair-v1".utf8),
            osAccess: Data(repeating: 0x5A, count: 72))
        let accessOnly = try NativeTrashSyntheticRootMetadata(osAccess: Data(repeating: 0x5A, count: 72))
        let provenanceOnly = try NativeTrashSyntheticRootMetadata(provenance: Data("Traverse-generated-provenance-pair-v1".utf8))
        let pairOther = try NativeTrashSyntheticRootMetadata(
            provenance: Data("Traverse-generated-provenance-pair-v1".utf8),
            osAccess: Data(repeating: 0x5A, count: 72), other: Data("other-generated-v1".utf8))

        let direct = try create(root, name: "Direct.bin")
        let (directBefore, directFamilies) = try observed(direct)
        let strictPairRefused = try !verifies(root, url: direct, before: directBefore,
            families: directFamilies, synthetic: pair, mode: .strict)
        let candidatePairAccepted = try verifies(root, url: direct, before: directBefore,
            families: directFamilies, synthetic: pair, mode: .ordinaryRegularFilePairCandidate)
        let afterFamilies = NativeTrashFamilyCollector()
        let after = try verifiedTree(direct, cancellation: OperationCancellation(),
            nativeTrashFamilyCollector: afterFamilies, nativeTrashSyntheticRootMetadata: pair)
        guard let afterSnapshot = afterFamilies.snapshot() else { throw FileOperationFailure.recoveryUncertain }
        let exactPairFamilyObserved = directFamilies.finding(comparedWith: afterSnapshot,
            before: directBefore, returned: after)
            == .complete(nativeChanged: [.provenance], osAccessAttributeChanged: true)
        let accessOnlyAcceptedByStrict = try verifies(root, url: direct, before: directBefore,
            families: directFamilies, synthetic: accessOnly, mode: .strict)
        let provenanceOnlyRefused = try !verifies(root, url: direct, before: directBefore,
            families: directFamilies, synthetic: provenanceOnly, mode: .ordinaryRegularFilePairCandidate)
        let pairWithOtherRefused = try !verifies(root, url: direct, before: directBefore,
            families: directFamilies, synthetic: pairOther, mode: .ordinaryRegularFilePairCandidate)
        let missingFamilyRefused = try !verifies(root, url: direct, before: directBefore,
            families: nil, synthetic: pair, mode: .ordinaryRegularFilePairCandidate)
        let strictDefaultRefused = try !verifies(root, url: direct, before: directBefore,
            families: directFamilies, synthetic: pair, mode: nil)

        let stale = try create(root, name: "Stale.bin")
        let (staleTree, _) = try observed(stale)
        guard !staleTree.identity.sameObject(as: directBefore.identity) else {
            throw FileOperationFailure.invalidRequest
        }
        // Keep every family byte from the valid Direct snapshot. Only its
        // completed-tree binding changes, so this tests stale authority alone.
        let staleFamilies = directFamilies.qualificationRebound(to: staleTree)
        let staleFamilyRefused = try !verifies(root, url: direct, before: directBefore,
            families: staleFamilies, synthetic: pair, mode: .ordinaryRegularFilePairCandidate)

        let content = try create(root, name: "Content.bin")
        let (contentBefore, contentFamilies) = try observed(content)
        try rewriteFirstByte(content)
        let contentDriftRefused = try !verifies(root, url: content, before: contentBefore,
            families: contentFamilies, synthetic: pair, mode: .ordinaryRegularFilePairCandidate)

        let replacement = try create(root, name: "Replacement.bin")
        let (replacementBefore, replacementFamilies) = try observed(replacement)
        let input = try DirectoryAnchor(root.appendingPathComponent("Input"), resolve: false)
        try requireAbsent("ReplacementOld.bin", in: input.fd)
        try exclusiveRename(from: input.fd, name: "Replacement.bin", to: input.fd, name: "ReplacementOld.bin")
        _ = try create(root, name: "Replacement.bin")
        let replacementRefused = try !verifies(root, url: replacement, before: replacementBefore,
            families: replacementFamilies, synthetic: pair, mode: .ordinaryRegularFilePairCandidate)

        let ordinary = try create(root, name: "Ordinary.bin")
        let provider = Provider(root: root, name: "Ordinary.bin", body: body("Ordinary.bin"))
        let walk = Walk()
        var hooks = RecoveryHooks()
        hooks.nativeTrashQualificationMode = .ordinaryRegularFilePairCandidate
        hooks.nativeTrashSyntheticRootMetadata = pair
        hooks.nativeTrashPreflightMeasured = { [walk] entries, bytes, elapsed in walk.accept(entries, bytes, elapsed) }
        let engine = RecoverableFileOperations(journalDirectory: root.appendingPathComponent("State/ordinary"),
            hooks: hooks, legacy: LocalFileOperations(trash: { [provider] in try provider.move($0) }),
            protecting: [root.appendingPathComponent("State")])
        let ordinaryResult = await engine.perform(.trash(sources: [ordinary]), progress: { _ in })
        let returned = root.appendingPathComponent("Returned/Ordinary.bin")
        let ordinaryCandidateCommitted = ordinaryResult.result.disposition == .succeeded
            && ordinaryResult.recordID != nil
            && provider.count.calls == 1
            && !FileManager.default.fileExists(atPath: ordinary.path)
            && (try? checkedBody(returned, body: body("Ordinary.bin"))) != nil
        // Undo must compare the saved full after-image with an actual fresh
        // walk. The virtual after metadata is absent, so it must preserve the
        // generated returned item and require review before any reverse move.
        var ordinaryUndoGuardRefused = false
        if let id = ordinaryResult.recordID, ordinaryCandidateCommitted {
            let undo = await engine.undo(recordID: id)
            ordinaryUndoGuardRefused = undo.result.items.contains { $0.status == .failed(.sourceChanged) }
                && FileManager.default.fileExists(atPath: returned.path)
                && !FileManager.default.fileExists(atPath: ordinary.path)
        }

        let changed = try create(root, name: "SourceDrift.bin")
        let neverProvider = Provider(root: root, name: "SourceDrift.bin", body: body("SourceDrift.bin"))
        var driftHooks = RecoveryHooks()
        driftHooks.nativeTrashQualificationMode = .ordinaryRegularFilePairCandidate
        driftHooks.nativeTrashSyntheticRootMetadata = pair
        driftHooks.nativeTrashBeforeSourceRecheck = {
            try GeneratedNativeTrashMetadataPairOfflineControl.rewriteFirstByte(changed)
        }
        let driftEngine = RecoverableFileOperations(journalDirectory: root.appendingPathComponent("State/source-drift"),
            hooks: driftHooks, legacy: LocalFileOperations(trash: { [neverProvider] in try neverProvider.move($0) }),
            protecting: [root.appendingPathComponent("State")])
        let driftResult = await driftEngine.perform(.trash(sources: [changed]), progress: { _ in })
        let sourceDriftRefusedBeforeProvider = driftResult.result.items.contains { $0.status == .failed(.sourceChanged) }
            && neverProvider.count.calls == 0 && FileManager.default.fileExists(atPath: changed.path)
        let measured = walk.single
        return .init(strictPairRefused: strictPairRefused,
            candidatePairAccepted: candidatePairAccepted, exactPairFamilyObserved: exactPairFamilyObserved,
            accessOnlyAcceptedByStrict: accessOnlyAcceptedByStrict,
            provenanceOnlyRefused: provenanceOnlyRefused,
            pairWithOtherRefused: pairWithOtherRefused,
            contentDriftRefused: contentDriftRefused,
            replacementRefused: replacementRefused,
            missingFamilyRefused: missingFamilyRefused,
            staleFamilyRefused: staleFamilyRefused,
            strictDefaultRefused: strictDefaultRefused,
            ordinaryCandidateCommitted: ordinaryCandidateCommitted,
            ordinaryUndoGuardRefused: ordinaryUndoGuardRefused,
            sourceDriftRefusedBeforeProvider: sourceDriftRefusedBeforeProvider,
            preflightEntries: measured?.0 ?? -1,
            preflightBodyBytes: measured?.1 ?? -1,
            expectedBodyBytes: Int64(body("Ordinary.bin").count),
            preflightElapsedNanoseconds: measured?.2 ?? 0,
            fakeProviderCalls: provider.count.calls + neverProvider.count.calls,
            systemTrashCalls: 0)
    }
}
#endif
