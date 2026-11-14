#if DEBUG
import Darwin
import Foundation

/// An in-repository, two-call diagnostic. Its injected provider can only move
/// exact generated files into this case; it never invokes system Trash.
@_spi(Qualification) public enum GeneratedNativeTrashProvenanceMutation: String, Sendable {
    case notAttempted, moveChanged, removed, denied, ignored
}
@_spi(Qualification) public enum GeneratedNativeTrashProvenanceOfflineFailure: String, Error, Sendable {
    case scopeRefused, sourceMissingProvenance
}
@_spi(Qualification) public struct GeneratedNativeTrashProvenanceOfflineResult: Sendable {
    public let plainSucceededAndUndone: Bool
    public let provenanceMutation: GeneratedNativeTrashProvenanceMutation
    public let osAccessChangedInGeneratedRoute: Bool
    public let exactFamilyObserved: Bool
    public let changedItemNeedsReview: Bool
    public let changedItemReturnedSameObject: Bool
    public let fakeProviderCalls: Int
    public let systemTrashCalls: Int
    public var passed: Bool {
        plainSucceededAndUndone && [.moveChanged, .removed].contains(provenanceMutation)
            && osAccessChangedInGeneratedRoute
            && exactFamilyObserved && changedItemNeedsReview && changedItemReturnedSameObject
            && fakeProviderCalls == 2 && systemTrashCalls == 0
    }
    public var failureClass: String {
        if !plainSucceededAndUndone { return "baselineFailed" }
        if provenanceMutation == .denied { return "provenanceMutationDenied" }
        if provenanceMutation == .ignored { return "provenanceMutationIgnored" }
        if provenanceMutation == .notAttempted { return "provenanceMutationNotAttempted" }
        if !osAccessChangedInGeneratedRoute { return "accessChangeUnavailable" }
        if !exactFamilyObserved { return "familyMismatch" }
        if !changedItemNeedsReview { return "recoveryOutcomeMismatch" }
        if !changedItemReturnedSameObject { return "returnedIdentityMismatch" }
        if fakeProviderCalls != 2 || systemTrashCalls != 0 { return "callBoundMismatch" }
        return "none"
    }
}

@_spi(Qualification) public enum GeneratedNativeTrashProvenanceOfflineControl {
    private static let plain = Data("Traverse generated native Trash provenance plain v1\n".utf8)
    private static let changed = Data("Traverse generated native Trash provenance changed v1\n".utf8)
    private static let provenance = "com.apple.provenance"
    private static let access = "com.apple.macl"

    private final class Observation: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [NativeTrashFamilyFinding] = []
        func accept(_ stage: OperationDiagnosticStage) {
            guard stage.checkpoint == .nativeTrashFingerprint, let finding = stage.nativeTrashFinding else { return }
            lock.withLock { values.append(finding) }
        }
        var findings: [NativeTrashFamilyFinding] { lock.withLock { values } }
    }

    private final class Provider: @unchecked Sendable {
        private typealias Control = GeneratedNativeTrashProvenanceOfflineControl
        private let root: URL, name: String, body: Data, mutate: Bool
        private let lock = NSLock()
        private var calls = 0
        private var provenanceMutation: GeneratedNativeTrashProvenanceMutation = .notAttempted
        private var accessChanged = false
        init(root: URL, name: String, body: Data, mutate: Bool) {
            self.root = root; self.name = name; self.body = body; self.mutate = mutate
        }
        var snapshot: (calls: Int, provenance: GeneratedNativeTrashProvenanceMutation, access: Bool) {
            lock.withLock { (calls, provenanceMutation, accessChanged) }
        }
        func move(_ supplied: URL) throws -> URL {
            let source = root.appendingPathComponent("Input/" + name)
            let target = root.appendingPathComponent("Returned/" + name)
            guard supplied == source else { throw FileOperationFailure.invalidRequest }
            try Control.validateMarker(root)
            let first = try Control.checkedSource(source, body: body)
            let sourceProvenance = try Control.attributeAt(source, Control.provenance, matching: first)
            let sourceAccess = try Control.attributeAt(source, Control.access, matching: first)
            let permitted = lock.withLock { () -> Bool in
                guard calls == 0 else { return false }
                calls += 1; return true
            }
            guard permitted else { throw FileOperationFailure.invalidRequest }
            let from = try DirectoryAnchor(source.deletingLastPathComponent(), resolve: false)
            let to = try DirectoryAnchor(target.deletingLastPathComponent(), resolve: false)
            guard from.identity.device == to.identity.device,
                  try EntrySnapshot(parent: from.fd, name: source.lastPathComponent).sameObject(as: first) else {
                throw FileOperationFailure.invalidRequest
            }
            try requireAbsent(target.lastPathComponent, in: to.fd)
            try exclusiveRename(from: from.fd, name: source.lastPathComponent,
                                to: to.fd, name: target.lastPathComponent)
            guard try EntrySnapshot(parent: to.fd, name: target.lastPathComponent).sameObject(as: first) else {
                throw FileOperationFailure.recoveryUncertain
            }
            if mutate {
                let fd = openat(to.fd, target.lastPathComponent,
                                O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
                guard fd >= 0 else { throw FileOperationFailure.unavailable }
                defer { close(fd) }
                guard try EntrySnapshot(fd: fd).sameObject(as: first), sourceProvenance != nil else {
                    throw FileOperationFailure.unavailable
                }
                let afterMove = try Control.attribute(fd, Control.provenance)
                let mutation: GeneratedNativeTrashProvenanceMutation
                if afterMove != sourceProvenance { mutation = .moveChanged }
                else {
                    let removed = fremovexattr(fd, Control.provenance, 0) == 0
                    let later = try Control.attribute(fd, Control.provenance)
                    mutation = !removed ? .denied : later != sourceProvenance ? .removed : .ignored
                }
                var accessChanged = try Control.attribute(fd, Control.access) != sourceAccess
                if [.moveChanged, .removed].contains(mutation) {
                    if !accessChanged {
                        let mark = Data(repeating: 0, count: 72)
                        let wrote = mark.withUnsafeBytes {
                            fsetxattr(fd, Control.access, $0.baseAddress, mark.count, 0, 0)
                        } == 0
                        let later = try Control.attribute(fd, Control.access)
                        accessChanged = wrote && later != sourceAccess
                    }
                }
                lock.withLock {
                    provenanceMutation = mutation
                    self.accessChanged = accessChanged
                }
            }
            try from.validate(); try to.validate()
            return target
        }
    }

    private static func facts(_ url: URL, directory: Bool) throws -> stat {
        guard url.isFileURL, url == url.standardizedFileURL,
              url.resolvingSymlinksInPath() == url else { throw FileOperationFailure.invalidRequest }
        var value = stat()
        guard lstat(url.path, &value) == 0,
              value.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG),
              value.st_uid == geteuid(), value.st_mode & 0o077 == 0,
              (directory || value.st_nlink == 1) else { throw FileOperationFailure.invalidRequest }
        return value
    }

    private static func snapshot(_ url: URL) throws -> EntrySnapshot {
        let parent = try DirectoryAnchor(url.deletingLastPathComponent(), resolve: false)
        return try EntrySnapshot(parent: parent.fd, name: url.lastPathComponent)
    }

    private static func validateMarker(_ root: URL) throws {
        let marker = root.appendingPathComponent("reservation.json")
        let value = try facts(marker, directory: false)
        guard value.st_size <= 4096 else { throw FileOperationFailure.invalidRequest }
        let parent = try DirectoryAnchor(root, resolve: false)
        let fd = openat(parent.fd, marker.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw FileOperationFailure.invalidRequest }
        defer { close(fd) }
        var opened = stat()
        guard fstat(fd, &opened) == 0, opened.st_dev == value.st_dev,
              opened.st_ino == value.st_ino, opened.st_mode & S_IFMT == S_IFREG,
              opened.st_uid == geteuid(), opened.st_mode & 0o077 == 0,
              opened.st_nlink == 1, opened.st_size <= 4096 else {
            throw FileOperationFailure.invalidRequest
        }
        let data = try FileHandle(fileDescriptor: fd, closeOnDealloc: false).read(upToCount: 4097)
        guard let data, data.count <= 4096,
              let fields = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              fields["packet"] as? String == "traverse-development-v1",
              fields["action"] as? String == "native-trash-provenance-offline-v1",
              fields["maximumFakeCalls"] as? Int == 2,
              fields["maximumSystemTrashCalls"] as? Int == 0 else {
            throw FileOperationFailure.invalidRequest
        }
        try parent.validate()
    }

    @discardableResult
    private static func checkedSource(_ source: URL, body: Data) throws -> EntrySnapshot {
        let value = try facts(source, directory: false)
        guard value.st_size == off_t(body.count), value.st_size <= 64 << 10 else { throw FileOperationFailure.invalidRequest }
        let parent = try DirectoryAnchor(source.deletingLastPathComponent(), resolve: false)
        let before = try EntrySnapshot(parent: parent.fd, name: source.lastPathComponent)
        let fd = openat(parent.fd, source.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw FileOperationFailure.invalidRequest }
        defer { close(fd) }
        var opened = stat()
        guard fstat(fd, &opened) == 0, opened.st_mode & S_IFMT == S_IFREG,
              opened.st_uid == geteuid(), opened.st_mode & 0o077 == 0,
              opened.st_nlink == 1, opened.st_size == off_t(body.count) else {
            throw FileOperationFailure.invalidRequest
        }
        guard let actual = try FileHandle(fileDescriptor: fd, closeOnDealloc: false).read(upToCount: body.count + 1)
        else { throw FileOperationFailure.invalidRequest }
        guard try EntrySnapshot(fd: fd) == before,
              actual == body else {
            throw FileOperationFailure.invalidRequest
        }
        guard try attribute(fd, provenance) != nil else {
            throw GeneratedNativeTrashProvenanceOfflineFailure.sourceMissingProvenance
        }
        try parent.validate()
        return before
    }

    private static func attribute(_ fd: Int32, _ name: String) throws -> Data? {
        errno = 0
        let count = fgetxattr(fd, name, nil, 0, 0, 0)
        if count < 0 {
            if errno == ENOATTR { return nil }
            throw FileOperationFailure.unavailable
        }
        guard count <= 4096 else { throw FileOperationFailure.unsupported }
        var value = Data(count: count)
        let read = value.withUnsafeMutableBytes { fgetxattr(fd, name, $0.baseAddress, count, 0, 0) }
        guard read == count else { throw FileOperationFailure.sourceChanged }
        return value
    }

    private static func attributeAt(_ url: URL, _ name: String, matching identity: EntrySnapshot) throws -> Data? {
        let parent = try DirectoryAnchor(url.deletingLastPathComponent(), resolve: false)
        let fd = openat(parent.fd, url.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw FileOperationFailure.unavailable }
        defer { close(fd) }
        guard try EntrySnapshot(fd: fd).sameObject(as: identity) else {
            throw FileOperationFailure.sourceChanged
        }
        let result = try attribute(fd, name)
        try parent.validate()
        return result
    }

    /// Requires an exact, pre-created private case. The method opens no user
    /// location and writes only its two generated files' in-case destinations.
    @_spi(Qualification) public static func run(root: URL) async throws -> GeneratedNativeTrashProvenanceOfflineResult {
        var repo = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { repo.deleteLastPathComponent() }
        guard root.isFileURL, root == root.standardizedFileURL,
              root.resolvingSymlinksInPath() == root,
              root.deletingLastPathComponent() == repo.appendingPathComponent(".build/traverse-development"),
              UUID(uuidString: root.lastPathComponent)?.uuidString == root.lastPathComponent else {
            throw GeneratedNativeTrashProvenanceOfflineFailure.scopeRefused
        }
        let rootFacts = try facts(root, directory: true)
        for name in ["Input", "Returned", "State"] {
            let directory = try facts(root.appendingPathComponent(name), directory: true)
            guard directory.st_dev == rootFacts.st_dev else { throw FileOperationFailure.invalidRequest }
        }
        try validateMarker(root)
        let inputNames = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Input").path)
        let returnedNames = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Returned").path)
        let stateNames = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("State").path)
        guard Set(inputNames) == Set(["Generated-Plain.bin", "Generated-Changed.bin"]),
              returnedNames.isEmpty, stateNames.isEmpty,
              !FileManager.default.fileExists(atPath: root.appendingPathComponent("result.json").path) else {
            throw FileOperationFailure.invalidRequest
        }
        let plainSource = root.appendingPathComponent("Input/Generated-Plain.bin")
        let changedSource = root.appendingPathComponent("Input/Generated-Changed.bin")
        try checkedSource(plainSource, body: plain)
        try checkedSource(changedSource, body: changed)
        let plainBefore = try verifiedTree(plainSource, cancellation: OperationCancellation())
        let plainProvider = Provider(root: root, name: "Generated-Plain.bin", body: plain, mutate: false)
        let changedProvider = Provider(root: root, name: "Generated-Changed.bin", body: changed, mutate: true)
        let observation = Observation()
        FileOperationDiagnostics.install { [observation] stage in observation.accept(stage) }
        defer { FileOperationDiagnostics.install(nil) }
        let plainState = root.appendingPathComponent("State/plain")
        let plainEngine = RecoverableFileOperations(journalDirectory: plainState,
            hooks: RecoveryHooks(), legacy: LocalFileOperations(trash: { [plainProvider] in try plainProvider.move($0) }),
            protecting: [root.appendingPathComponent("State")])
        let first = await plainEngine.perform(.trash(sources: [plainSource]), progress: { _ in })
        var plainSuccess = false
        if first.result.disposition == .succeeded, let recordID = first.recordID {
            let undo = await plainEngine.undo(recordID: recordID)
            if undo.result.disposition == .succeeded {
                do {
                    try checkedSource(plainSource, body: plain)
                    let plainAfter = try verifiedTree(plainSource, cancellation: OperationCancellation())
                    plainSuccess = plainBefore.matches(plainAfter)
                }
                catch { plainSuccess = false }
            }
        }
        guard plainSuccess else {
            return .init(plainSucceededAndUndone: false, provenanceMutation: .notAttempted,
                osAccessChangedInGeneratedRoute: false, exactFamilyObserved: false,
                changedItemNeedsReview: false, changedItemReturnedSameObject: false,
                fakeProviderCalls: plainProvider.snapshot.calls, systemTrashCalls: 0)
        }
        let changedIdentity = try snapshot(changedSource)
        let changedState = root.appendingPathComponent("State/changed")
        let changedEngine = RecoverableFileOperations(journalDirectory: changedState,
            hooks: RecoveryHooks(), legacy: LocalFileOperations(trash: { [changedProvider] in try changedProvider.move($0) }),
            protecting: [root.appendingPathComponent("State")])
        let second = await changedEngine.perform(.trash(sources: [changedSource]), progress: { _ in })
        let target = root.appendingPathComponent("Returned/Generated-Changed.bin")
        let same = (try? snapshot(target).sameObject(as: changedIdentity)) == true
        let history = try await changedEngine.inspectExistingHistory()
        let state = history.records.first
        let retained = state?.state == "needsReview" && state?.canUndo == false
            && state?.locations.contains(target) == true
        let injected = changedProvider.snapshot
        let exactFinding = observation.findings == [
            .complete(nativeChanged: [.provenance], osAccessAttributeChanged: true)]
        return .init(plainSucceededAndUndone: plainSuccess,
            provenanceMutation: injected.provenance,
            osAccessChangedInGeneratedRoute: injected.access,
            exactFamilyObserved: exactFinding,
            changedItemNeedsReview: retained && second.result.disposition == .partial,
            changedItemReturnedSameObject: same,
            fakeProviderCalls: plainProvider.snapshot.calls + injected.calls,
            systemTrashCalls: 0)
    }
}
#endif
