import Darwin
import Foundation
@testable import FileOperations
import Testing

private struct MetadataFixture {
    let root: URL
    let source: URL
    let destination: URL
    let journal: URL
    init(parent: URL? = nil) throws {
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let base = parent ?? package.appendingPathComponent(".build/test-fixtures")
        if parent == nil {
            guard base.resolvingSymlinksInPath().path == base.path else { throw FileOperationFailure.invalidRequest }
            try FileManager().createDirectory(at: base, withIntermediateDirectories: true)
        } else {
            // Explicit /private/tmp spelling is validated by descriptor traversal;
            // Foundation may otherwise rewrite it to the /tmp symlink.
            try DirectoryAnchor(base, resolve: false).validate()
        }
        root = base.appendingPathComponent("copy-metadata-" + UUID().uuidString)
        try FileManager().createDirectory(at: root, withIntermediateDirectories: false)
        source = root.appendingPathComponent("source")
        destination = root.appendingPathComponent("destination")
        journal = root.appendingPathComponent("journal")
        try Data("generated metadata fixture".utf8).write(to: source, options: .withoutOverwriting)
        try FileManager().createDirectory(at: destination, withIntermediateDirectories: false)
    }
    func remove() { try? FileManager().removeItem(at: root) }
    func service(_ hooks: CopyFaultHooks = CopyFaultHooks()) -> RecoverableFileOperations {
        RecoverableFileOperations(journalDirectory: journal, hooks: RecoveryHooks(copyFaults: hooks))
    }
}
private func setMetadataAttribute(_ fd: Int32, _ name: String, _ value: String) throws {
    let data = Data(value.utf8)
    guard data.withUnsafeBytes({ fsetxattr(fd, name, $0.baseAddress, data.count, 0, 0) }) == 0 else { throw posixFailure() }
}
private func setMetadataAttribute(_ url: URL, _ name: String, _ value: String) throws {
    let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { throw posixFailure() }; defer { close(fd) }
    try setMetadataAttribute(fd, name, value)
}
private let fixtureQuarantine = "0083;67000000;MacExplorerGeneratedFixture;00000000-0000-0000-0000-000000000001"

/// This opt-in fixture admits only a fresh image whose exact host-side identity
/// was recorded by the separately reviewed image controller. That controller
/// proves the mounted device belongs to the image. The package test never mounts
/// or detaches a volume.
private struct Fat32CopyFixture {
    private struct Marker: Decodable {
        let version: Int
        let jobID: String
        let imageBytes: Int64
        let imageDev: Int64
        let imageIno: UInt64
        let rootDev: Int64
        let rootIno: UInt64
        let mountDev: Int64
        let mountIno: UInt64
        let filesystem: String
        let format: String
    }
    private let root: DirectoryAnchor
    private let mount: DirectoryAnchor
    private let marker: Marker
    private let markerData: Data
    private static let markerName = ".fat32-copy-owner-v1.json"
    private static let imageBytes: Int64 = 128 * 1024 * 1024

    init() throws {
        guard let raw = ProcessInfo.processInfo.environment["MAC_EXPLORER_FAT32_COPY_TEST_ROOT"] else {
            throw FileOperationFailure.invalidRequest
        }
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let repository = package.deletingLastPathComponent().deletingLastPathComponent()
        let base = repository.appendingPathComponent(".build/integrity-volumes", isDirectory: true)
        let requested = URL(fileURLWithPath: raw, isDirectory: true)
        guard raw == requested.path, requested.deletingLastPathComponent().path == base.path,
              let id = UUID(uuidString: requested.lastPathComponent), id.uuidString == requested.lastPathComponent else {
            throw FileOperationFailure.invalidRequest
        }
        let anchoredRoot = try DirectoryAnchor(requested, resolve: false)
        var rootStat = stat(), markerStat = stat()
        guard fstat(anchoredRoot.fd, &rootStat) == 0, rootStat.st_uid == geteuid(), rootStat.st_mode & 0o077 == 0,
              fstatat(anchoredRoot.fd, Self.markerName, &markerStat, AT_SYMLINK_NOFOLLOW) == 0,
              markerStat.st_mode & S_IFMT == S_IFREG, markerStat.st_uid == geteuid(),
              markerStat.st_nlink == 1, (1...2048).contains(markerStat.st_size) else {
            throw FileOperationFailure.invalidRequest
        }
        let data = try OperationJournal.read(name: Self.markerName, anchor: anchoredRoot)
        guard let shape = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(shape.keys) == Set(["version", "jobID", "imageBytes", "imageDev", "imageIno",
                                      "rootDev", "rootIno", "mountDev", "mountIno", "filesystem", "format"]) else {
            throw FileOperationFailure.invalidRequest
        }
        let decoded = try JSONDecoder().decode(Marker.self, from: data)
        guard decoded.version == 1, decoded.jobID == id.uuidString, decoded.imageBytes == Self.imageBytes,
              decoded.rootDev == Int64(anchoredRoot.identity.device), decoded.rootIno == anchoredRoot.identity.inode,
              decoded.filesystem == "msdos", decoded.format == "FAT32" else {
            throw FileOperationFailure.invalidRequest
        }
        let anchoredMount = try DirectoryAnchor(anchoredRoot.url.appendingPathComponent("mount", isDirectory: true), resolve: false)
        root = anchoredRoot; mount = anchoredMount; marker = decoded; markerData = data
        try validate()
    }

    func validate() throws {
        try root.validate(); try mount.validate()
        guard try OperationJournal.read(name: Self.markerName, anchor: root) == markerData,
              Int64(mount.identity.device) == marker.mountDev, mount.identity.inode == marker.mountIno,
              mount.identity.device != root.identity.device else { throw FileOperationFailure.destinationChanged }
        var image = stat(), filesystem = statfs()
        guard fstatat(root.fd, "fixture.dmg", &image, AT_SYMLINK_NOFOLLOW) == 0,
              image.st_mode & S_IFMT == S_IFREG, image.st_uid == geteuid(), image.st_nlink == 1,
              image.st_size == Self.imageBytes, Int64(image.st_dev) == marker.imageDev,
              image.st_ino == marker.imageIno, fstatfs(mount.fd, &filesystem) == 0 else {
            throw FileOperationFailure.destinationChanged
        }
        let kind = withUnsafePointer(to: &filesystem.f_fstypename) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MFSNAMELEN)) { String(cString: $0) }
        }
        guard kind == "msdos", filesystem.f_flags & UInt32(MNT_LOCAL) != 0 else {
            throw FileOperationFailure.destinationChanged
        }
    }

    func createCase(_ label: String, rich: Bool) throws -> (source: URL, destination: URL, journal: URL) {
        try validate()
        guard label == "plain" || label == "rich" else { throw FileOperationFailure.invalidRequest }
        let name = label + "-" + UUID().uuidString
        let sourceDirectory = root.url.appendingPathComponent(name, isDirectory: true)
        let destinationDirectory = mount.url.appendingPathComponent(name, isDirectory: true)
        try FileManager().createDirectory(at: sourceDirectory, withIntermediateDirectories: false)
        try FileManager().createDirectory(at: destinationDirectory, withIntermediateDirectories: false)
        let source = sourceDirectory.appendingPathComponent("generated.bin")
        try Data("Traverse generated FAT32 copy fixture\n".utf8).write(to: source, options: .withoutOverwriting)
        if rich {
            try setMetadataAttribute(source, "com.macexplorer.generated-test", "generated attribute")
            try setMetadataAttribute(source, "com.apple.ResourceFork", "generated fork")
        }
        let fd = open(source.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw posixFailure() }
        defer { close(fd) }
        var times = [timespec(tv_sec: 1_700_000_001, tv_nsec: 123_456_789),
                     timespec(tv_sec: 1_700_000_001, tv_nsec: 123_456_789)]
        guard futimens(fd, &times) == 0 else { throw posixFailure() }
        let observed = try EntrySnapshot(fd: fd)
        guard observed.modifiedSeconds == 1_700_000_001, observed.modifiedNanos == 123_456_789 else {
            throw FileOperationFailure.unsupported
        }
        try validate()
        return (source, destinationDirectory, root.url.appendingPathComponent("journal-" + name))
    }
}

/// Injects only at the generated payload's publish rename, before its native post-walk.
private final class MetadataPublicationMark: @unchecked Sendable {
    private enum Injection { case publication, laterEdit, none }
    private let lock = NSLock()
    private let target: URL
    private let sourceToRetain: URL?
    private var armed = false
    private var retentionArmed = false
    private var injected = false
    private var laterEdited = false
    private var failed = false
    private var retained: URL?
    init(target: URL, laterEditAfterRetaining source: URL? = nil) {
        self.target = target; sourceToRetain = source
    }
    func before(_ source: URL, _ destination: URL) throws {
        if let sourceToRetain, source == sourceToRetain {
            lock.withLock { retentionArmed = true; retained = destination }
            return
        }
        guard destination == target else { return }
        let fd = open(source.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw posixFailure() }
        defer { close(fd) }
        guard try CopySecurity.read(fd).quarantine == nil else { throw FileOperationFailure.copyMetadataMismatch }
        lock.withLock { armed = true }
    }
    func after() {
        let injection = lock.withLock { () -> Injection in
            if armed { armed = false; return .publication }
            if retentionArmed { retentionArmed = false; return .laterEdit }
            return .none
        }
        do {
            switch injection {
            case .publication:
                try setMetadataAttribute(target, CopySecurity.quarantineName, fixtureQuarantine)
                lock.withLock { injected = true }
            case .laterEdit:
                try setMetadataAttribute(target, CopySecurity.quarantineName, "0082;67000099;GeneratedLaterChange;")
                lock.withLock { laterEdited = true }
            case .none: break
            }
        } catch { lock.withLock { failed = true } }
    }
    var succeeded: Bool { lock.withLock { injected && !failed } }
    var changedLater: Bool { lock.withLock { laterEdited && !failed } }
    var retainedURL: URL? { lock.withLock { retained } }
}

@Suite(.serialized) struct CopyMetadataTests {
    @Test func generatedCopyDifferenceReportsOnlyFixedMetadataFamilies() async throws {
        let f = try MetadataFixture(); defer { f.remove() }
        let result = await f.service().perform(.copy(sources: [f.source], destinationDirectory: f.destination))
        #expect(result.result.disposition == .succeeded)
        let copied = f.destination.appendingPathComponent("source")

        func differences() throws -> (CopyComparison, CopyComparison) {
            let source = CopyComparison(diagnoseMetadataFamilies: true),
                destination = CopyComparison(diagnoseMetadataFamilies: true)
            _ = try verifiedTree(f.source, cancellation: .init(), copyComparison: source)
            _ = try verifiedTree(copied, cancellation: .init(), copyComparison: destination)
            #expect(source.contentDigest == destination.contentDigest)
            return (source, destination)
        }

        let baseline = try differences()
        #expect(baseline.0.metadataDigest == baseline.1.metadataDigest)
        #expect(try baseline.0.differingMetadataFamilies(from: baseline.1).isEmpty)

        try FileManager().setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_001)], ofItemAtPath: copied.path)
        let timeChanged = try differences()
        #expect(timeChanged.0.metadataDigest != timeChanged.1.metadataDigest)
        #expect(try timeChanged.0.differingMetadataFamilies(from: timeChanged.1) == [.modificationTime])

        try setMetadataAttribute(copied, "com.macexplorer.generated-test", "generated attribute")
        let attributeChanged = try differences()
        #expect(try attributeChanged.0.differingMetadataFamilies(from: attributeChanged.1) == [.modificationTime, .otherExtendedAttributes])

        try setMetadataAttribute(copied, "com.apple.ResourceFork", "generated fork")
        let forkChanged = try differences()
        #expect(try forkChanged.0.differingMetadataFamilies(from: forkChanged.1) == [.modificationTime, .resourceFork, .otherExtendedAttributes])
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MAC_EXPLORER_RUN_FAT32_COPY_TESTS"] == "1",
                   "Requires one separately admitted owned 128 MiB FAT32 image and fixed fixture marker."))
    func generatedFAT32CopyDiagnosesMetadataWithoutTouchingOtherVolumes() async throws {
        let fixture = try Fat32CopyFixture()
        // Two fresh, tiny, generated sources. A third copy and one Undo belong
        // only to a later reviewed portable-policy candidate.
        for (label, rich) in [("plain", false), ("rich", true)] {
            let item = try fixture.createCase(label, rich: rich)
            let sourceComparison = CopyComparison(diagnoseMetadataFamilies: true)
            let before = try verifiedTree(item.source, cancellation: .init(), copyComparison: sourceComparison)
            let operation = RecoverableFileOperations(journalDirectory: item.journal)
            let result = await operation.perform(.copy(sources: [item.source], destinationDirectory: item.destination), metadataPolicy: .strict)
            try fixture.validate()
            let status = try #require(result.result.items.first { $0.role == .transfer }?.status)
            let recordID = try #require(result.recordID)
            let record = try #require(try OperationJournal(item.journal).inspectRecord(recordID))
            let publicCopy = item.destination.appendingPathComponent(item.source.lastPathComponent)
            #expect(before.matches(try verifiedTree(item.source, cancellation: .init())))

            var families: [CopyOrdinaryMetadataFamily] = []
            var contentEqual = false, staged = false, sidecar = false
            let area = try #require(record.areas.count == 1 ? record.areas[0] : nil)
            let prefix = ".mac-explorer-recovery-"
            guard area.url.deletingLastPathComponent() == item.destination,
                  area.url.lastPathComponent.hasPrefix(prefix),
                  UUID(uuidString: String(area.url.lastPathComponent.dropFirst(prefix.count))) != nil else {
                throw FileOperationFailure.invalidRequest
            }
            if let anchor = try? DirectoryAnchor(area.url, resolve: false) {
                var sibling = stat()
                if fstatat(anchor.fd, "._payload", &sibling, AT_SYMLINK_NOFOLLOW) == 0 { sidecar = true }
                else { #expect(errno == ENOENT) }
                let destinationComparison = CopyComparison(diagnoseMetadataFamilies: true)
                if let stagedTree = try? verifiedTree(parent: anchor.fd, name: "payload", cancellation: .init(),
                                                        copyComparison: destinationComparison) {
                    staged = true
                    contentEqual = sourceComparison.contentDigest == destinationComparison.contentDigest
                    families = try sourceComparison.differingMetadataFamilies(from: destinationComparison)
                    #expect(stagedTree.identity.device == anchor.identity.device)
                }
            }
            let statusName: String
            switch status {
            case .failed(let failure): statusName = failure.rawValue
            case .succeeded: statusName = "succeeded"
            case .skipped: statusName = "skipped"
            case .cancelled: statusName = "cancelled"
            case .notStarted: statusName = "notStarted"
            }
            print("FAT32_COPY_FAMILY variant=\(label) status=\(statusName) staged=\(staged) contentEqual=\(contentEqual) families=\(families.map(\.rawValue).joined(separator: ",")) appleDouble=\(sidecar)")

            if label == "plain" {
                #expect(status == .failed(.copyMetadataMismatch))
                #expect(record.state == "needsReview" && staged && contentEqual)
                #expect(families.contains(.modificationTime))
                #expect(!FileManager().fileExists(atPath: publicCopy.path))
            } else if case .failed = status {
                #expect(record.state == "needsReview")
                #expect(!FileManager().fileExists(atPath: publicCopy.path))
            } else {
                #expect(status == .succeeded)
                #expect(FileManager().fileExists(atPath: publicCopy.path))
            }
        }
    }

    @Test func realNativeQuarantineCopiesWithActualFingerprintAndUndo() async throws {
        let f = try MetadataFixture(); defer { f.remove() }
        try setMetadataAttribute(f.source, CopySecurity.quarantineName, fixtureQuarantine)
        let original = try verifiedTree(f.source, cancellation: OperationCancellation())
        let service = f.service()
        let plan = try await service.prepareTransfer(sources: [f.source], destinationDirectory: f.destination, move: false)
        #expect(plan.metadataPolicy == .strict)
        let result = await service.perform(plan)
        #expect(result.result.disposition == .succeeded)
        #expect(original.matches(try verifiedTree(f.source, cancellation: OperationCancellation())))
        let copied = f.destination.appendingPathComponent("source")
        let copy = try verifiedTree(copied, cancellation: OperationCancellation())
        // Native propagation may legitimately preserve these attributes on another
        // OS. Record transformed-output coverage without requiring the OS to change
        // metadata. When true, the historical digest-equality guard rejects this copy.
        print("NATIVE_SECURITY_TRANSITION_JSON {\"schema\":1,\"transformedNativeOutputExercised\":\(original.digest != copy.digest)}")
        let recordID = try #require(result.recordID)
        let record = try #require(try OperationJournal(f.journal).inspectRecord(recordID))
        #expect(record.steps.last?.after?.matches(copy) == true)
        let undone = await f.service().undo(recordID: record.id)
        #expect(undone.result.disposition == .succeeded)
        #expect(!FileManager().fileExists(atPath: copied.path))
    }

    @Test(arguments: [TransferMetadataPolicy.strict, .destinationOwnership])
    func postReceiptSecurityEditIsRefusedInBothModes(policy: TransferMetadataPolicy) async throws {
        let f = try MetadataFixture(); defer { f.remove() }
        try setMetadataAttribute(f.source, CopySecurity.quarantineName, fixtureQuarantine)
        let original = try verifiedTree(f.source, cancellation: OperationCancellation())
        let service = f.service(CopyFaultHooks(afterSecurityReceipt: { _, destination in
            try setMetadataAttribute(destination, CopySecurity.quarantineName, "0083;67000001;EditedFixture;")
        }))
        let result = await service.perform(.copy(sources: [f.source], destinationDirectory: f.destination), metadataPolicy: policy)
        #expect(result.result.items.contains { $0.status == .failed(.copyMetadataMismatch) })
        #expect(original.matches(try verifiedTree(f.source, cancellation: OperationCancellation())))
        #expect(!FileManager().fileExists(atPath: f.destination.appendingPathComponent("source").path))
    }

    @Test func unknownAttributeAdditionIsMetadataMismatchAndSourceEditIsSourceChanged() async throws {
        for mutateSource in [false, true] {
            let f = try MetadataFixture(); defer { f.remove() }
            let service = f.service(CopyFaultHooks(afterNativeCopy: { source, destination in
                try setMetadataAttribute(mutateSource ? source : destination, "com.macexplorer.generated-test", "changed")
            }))
            let result = await service.perform(.copy(sources: [f.source], destinationDirectory: f.destination))
            #expect(result.result.items.contains { $0.status == .failed(mutateSource ? .sourceChanged : .copyMetadataMismatch) })
        }
    }

    @Test func changedCopyBytesGetContentMismatch() async throws {
        let f = try MetadataFixture(); defer { f.remove() }
        let service = f.service(CopyFaultHooks(afterNativeCopy: { _, destination in
            var byte: UInt8 = 88
            guard pwrite(destination, &byte, 1, 0) == 1 else { throw posixFailure() }
        }))
        let result = await service.perform(.copy(sources: [f.source], destinationDirectory: f.destination))
        #expect(result.result.items.contains { $0.status == .failed(.copyContentMismatch) })
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MAC_EXPLORER_RUN_CROSS_VOLUME_TESTS"] == "1", "Requires marked private temporary ownership fixtures."))
    func destinationOwnershipAllowsOnlyNativeOwnershipDifferenceAndUndoRemainsExact() async throws {
        var groups = [gid_t](repeating: 0, count: Int(getgroups(0, nil)))
        let groupCount = getgroups(Int32(groups.count), &groups)
        #expect(groupCount >= 0)
        let alternate = try #require(groups.first { $0 != getegid() })
        let temporary = try MetadataTemporaryRoot()
        defer { do { try temporary.remove() } catch { Issue.record("Owned metadata fixture cleanup refused.") } }
        for policy in [TransferMetadataPolicy.strict, .destinationOwnership] {
            let f = try MetadataFixture(parent: temporary.url); defer { f.remove() }
            let original = try verifiedTree(f.source, cancellation: OperationCancellation())
            let service = f.service(CopyFaultHooks(afterNativeCopy: { _, destination in
                guard fchown(destination, uid_t.max, alternate) == 0 else { throw posixFailure() }
            }))
            let result = await service.perform(.copy(sources: [f.source], destinationDirectory: f.destination), metadataPolicy: policy)
            if policy == .strict {
                #expect(result.result.items.contains { $0.status == .failed(.copyOwnershipMismatch) }, "Statuses: \(result.result.items.map(\.status))")
            } else {
                #expect(result.result.disposition == .succeeded)
                let copied = f.destination.appendingPathComponent("source")
                try setMetadataAttribute(copied, "com.macexplorer.later-edit", "protect")
                let inverse = await f.service().undo(recordID: try #require(result.recordID))
                #expect(inverse.result.items.contains { $0.status == .failed(.sourceChanged) })
                #expect(FileManager().fileExists(atPath: copied.path))
            }
            #expect(original.matches(try verifiedTree(f.source, cancellation: OperationCancellation())))
        }
    }

    @Test func securityPredicatesRefuseRemovalChangesAndUnprovedAdditions() throws {
        let f = try MetadataFixture(); defer { f.remove() }
        let identity = try verifiedTree(f.source, cancellation: OperationCancellation()).identity
        let q = SecurityAttribute(Data("quarantine".utf8)), p = SecurityAttribute(Data("provenance".utf8))
        let changed = SecurityAttribute(Data("changed".utf8)), empty = SecurityAttribute(Data())
        func allowed(_ before: CopySecurity, _ after: CopySecurity, baseline: CopySecurity = CopySecurity(), sourceAfter: CopySecurity? = nil) -> Bool {
            NativeCopyReceipt(relative: "", source: identity, destination: identity, destinationBeforeIdentity: identity, destinationOwnership: CopyOwnership(uid: geteuid(), gid: getegid()),
                sourceBefore: before, destinationBefore: baseline, sourceAfter: sourceAfter ?? before, destinationAfter: after).permitsSecurityTransition()
        }
        #expect(allowed(CopySecurity(quarantine: q), CopySecurity(quarantine: changed)))
        #expect(!allowed(CopySecurity(quarantine: q), CopySecurity()))
        #expect(!allowed(CopySecurity(quarantine: q), CopySecurity(quarantine: empty)))
        #expect(!allowed(CopySecurity(), CopySecurity(quarantine: q)))
        #expect(!allowed(CopySecurity(provenance: p), CopySecurity(provenance: changed)))
        #expect(!allowed(CopySecurity(provenance: p), CopySecurity()))
        #expect(allowed(CopySecurity(), CopySecurity(provenance: p)))
        #expect(allowed(CopySecurity(), CopySecurity(provenance: p), baseline: CopySecurity(provenance: p)))
        #expect(!allowed(CopySecurity(), CopySecurity(provenance: changed), baseline: CopySecurity(provenance: p)))
        #expect(!allowed(CopySecurity(quarantine: q), CopySecurity(quarantine: q), sourceAfter: CopySecurity(quarantine: changed)))
    }

    @Test func missingDuplicateOrWrongReceiptCannotValidateArbitraryPayload() throws {
        let f = try MetadataFixture(); defer { f.remove() }
        let source = CopyComparison(), destination = CopyComparison()
        let tree = try verifiedTree(f.source, cancellation: OperationCancellation(), copyComparison: source)
        _ = try verifiedTree(f.source, cancellation: OperationCancellation(), copyComparison: destination)
        let receipts = NativeCopyReceipts()
        #expect(throws: FileOperationFailure.copyMetadataMismatch) { try receipts.validate(source: source, destination: destination, policy: .strict) }
        let security = try #require(source.nodes[""]).security
        let receipt = NativeCopyReceipt(relative: "wrong", source: tree.identity, destination: tree.identity, destinationBeforeIdentity: tree.identity, destinationOwnership: CopyOwnership(uid: geteuid(), gid: getegid()),
            sourceBefore: security, destinationBefore: security, sourceAfter: security, destinationAfter: security)
        try receipts.append(receipt)
        #expect(throws: FileOperationFailure.copyMetadataMismatch) { try receipts.append(receipt) }
        #expect(throws: FileOperationFailure.copyMetadataMismatch) { try receipts.validate(source: source, destination: destination, policy: .strict) }
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MAC_EXPLORER_RUN_CROSS_VOLUME_TESTS"] == "1", "Requires marked private temporary ownership fixtures."))
    func laterOwnershipChangeIsRefusedEvenInDestinationOwnershipMode() async throws {
        let temporary = try MetadataTemporaryRoot()
        defer { do { try temporary.remove() } catch { Issue.record("Owned metadata fixture cleanup refused.") } }
        let f = try MetadataFixture(parent: temporary.url); defer { f.remove() }
        var groups = [gid_t](repeating: 0, count: Int(getgroups(0, nil)))
        _ = getgroups(Int32(groups.count), &groups)
        let alternate = try #require(groups.first { $0 != getegid() })
        let service = f.service(CopyFaultHooks(afterSecurityReceipt: { _, destination in
            guard fchown(destination, uid_t.max, alternate) == 0 else { throw posixFailure() }
        }))
        let result = await service.perform(.copy(sources: [f.source], destinationDirectory: f.destination), metadataPolicy: .destinationOwnership)
        #expect(result.result.items.contains { $0.status == .failed(.copyMetadataMismatch) }, "Statuses: \(result.result.items.map(\.status))")
    }

    @Test(arguments: [TransferMetadataPolicy.strict, .destinationOwnership])
    func mergeAndReplaceKeepSecurityAndRestoreDisplacedOriginal(policy: TransferMetadataPolicy) async throws {
        let f = try MetadataFixture(); defer { f.remove() }
        let directory = f.root.appendingPathComponent("tree")
        let target = f.destination.appendingPathComponent("tree")
        try FileManager().createDirectory(at: directory, withIntermediateDirectories: false)
        try FileManager().createDirectory(at: target, withIntermediateDirectories: false)
        let child = directory.appendingPathComponent("child")
        try Data("generated new".utf8).write(to: child, options: .withoutOverwriting)
        try setMetadataAttribute(child, CopySecurity.quarantineName, fixtureQuarantine)
        let displaced = target.appendingPathComponent("child")
        let sibling = target.appendingPathComponent("untouched")
        try Data("generated old".utf8).write(to: displaced, options: .withoutOverwriting)
        try Data("generated sibling".utf8).write(to: sibling, options: .withoutOverwriting)
        let original = try verifiedTree(displaced, cancellation: OperationCancellation())
        let untouched = try verifiedTree(sibling, cancellation: OperationCancellation())
        let service = f.service()
        let plan = try await service.prepareTransfer(sources: [directory], destinationDirectory: f.destination, move: false, metadataPolicy: policy)
        let resolutions = Dictionary(uniqueKeysWithValues: plan.conflicts.map { ($0.id, $0.canMerge ? TransferConflictResolution.merge : .replace) })
        let result = await service.perform(plan, resolutions: resolutions)
        #expect(result.result.disposition == .succeeded)
        #expect(untouched.matches(try verifiedTree(sibling, cancellation: OperationCancellation())))
        let undone = await f.service().undo(recordID: try #require(result.recordID))
        #expect(undone.result.disposition == .succeeded)
        #expect(original.matches(try verifiedTree(displaced, cancellation: OperationCancellation())))
        #expect(untouched.matches(try verifiedTree(sibling, cancellation: OperationCancellation())))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MAC_EXPLORER_RUN_CROSS_VOLUME_TESTS"] == "1", "Requires marked private temporary ownership fixtures."))
    func actualInheritedGroupDifferenceRequiresExplicitOwnershipPolicy() async throws {
        let temporary = try MetadataTemporaryRoot()
        defer { do { try temporary.remove() } catch { Issue.record("Owned metadata fixture cleanup refused.") } }
        let sourceFixture = try MetadataFixture(parent: temporary.url)
        defer { sourceFixture.remove() }
        let original = try verifiedTree(sourceFixture.source, cancellation: OperationCancellation())
        for policy in [TransferMetadataPolicy.strict, .destinationOwnership] {
            let destinationFixture = try MetadataFixture(); defer { destinationFixture.remove() }
            let service = destinationFixture.service()
            let result = await service.perform(.copy(sources: [sourceFixture.source], destinationDirectory: destinationFixture.destination), metadataPolicy: policy)
            if policy == .strict {
                #expect(result.result.items.contains { $0.status == .failed(.copyOwnershipMismatch) }, "Statuses: \(result.result.items.map(\.status))")
            } else {
                #expect(result.result.disposition == .succeeded)
                let inverse = await service.undo(recordID: try #require(result.recordID))
                #expect(inverse.result.disposition == .succeeded)
            }
            #expect(original.matches(try verifiedTree(sourceFixture.source, cancellation: OperationCancellation())))
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MAC_EXPLORER_RUN_CROSS_VOLUME_TESTS"] == "1",
                   "Requires explicit generated private temporary fixtures."))
    func crossVolumeQuarantineMoveRetainsOriginalAndUndoUsesActualFingerprint() async throws {
        let f = try MetadataFixture(); defer { f.remove() }
        let temporary = try MetadataTemporaryRoot()
        defer { do { try temporary.remove() } catch { Issue.record("Owned metadata fixture cleanup refused; retained for review.") } }
        #expect(try DirectoryAnchor(f.root).identity.device != temporary.identity.device)
        try setMetadataAttribute(f.source, CopySecurity.quarantineName, fixtureQuarantine)
        let before = try verifiedTree(f.source, cancellation: OperationCancellation())
        let result = await f.service().perform(.move(sources: [f.source], destinationDirectory: temporary.url))
        #expect(result.result.disposition == .succeeded)
        #expect(!FileManager().fileExists(atPath: f.source.path))
        let recordID = try #require(result.recordID)
        let record = try #require(try OperationJournal(f.journal).inspectRecord(recordID))
        let retained = try #require(record.steps.last).destination
        #expect(before.matches(try verifiedTree(retained, cancellation: OperationCancellation())))
        let inverse = await f.service().undo(recordID: record.id)
        #expect(inverse.result.disposition == .succeeded)
        #expect(before.matches(try verifiedTree(f.source, cancellation: OperationCancellation())))
        #expect(!FileManager().fileExists(atPath: temporary.url.appendingPathComponent("source").path))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MAC_EXPLORER_RUN_CROSS_VOLUME_TESTS"] == "1",
                   "Requires owned generated fixtures with genuinely different device identities."))
    func crossVolumeMoveUsesPublishedNativeMarkForBothLaterChecksAndColdUndo() async throws {
        let f = try MetadataFixture()
        var complete = false
        defer { if complete { do { try FileManager().removeItem(at: f.root) } catch { Issue.record("Owned host fixture cleanup refused.") } } }
        let temporary = try MetadataTemporaryRoot()
        defer { if complete { do { try temporary.remove() } catch { Issue.record("Owned destination fixture cleanup refused.") } } }
        try #require(try DirectoryAnchor(f.root).identity.device != temporary.identity.device)
        let original = try verifiedTree(f.source, cancellation: .init())
        let target = temporary.url.appendingPathComponent("source")
        let mark = MetadataPublicationMark(target: target)
        var hooks = RecoveryHooks()
        hooks.beforeExclusiveRename = { from, to in try mark.before(from, to) }
        hooks.afterRename = { mark.after() }
        let service = RecoverableFileOperations(journalDirectory: f.journal, hooks: hooks)
        let moved = await service.perform(.move(sources: [f.source], destinationDirectory: temporary.url))
        try #require(moved.result.disposition == .succeeded && mark.succeeded)
        let id = try #require(moved.recordID)
        let record = try #require(try OperationJournal(f.journal).inspectRecord(id))
        try #require(record.steps.count == 2)
        let publication = record.steps[0], retention = record.steps[1]
        let after = try #require(publication.after)
        let observedPublished = try verifiedTree(target, cancellation: .init())
        try #require(publication.source.lastPathComponent == "payload" && publication.destination == target
            && !publication.before.matches(after) && after.matches(observedPublished))
        let retainedImage = try verifiedTree(retention.destination, cancellation: .init())
        try #require(!FileManager().fileExists(atPath: f.source.path)
            && original.matches(retainedImage))
        let undone = await RecoverableFileOperations(journalDirectory: f.journal).undo(recordID: id)
        let restored = try verifiedTree(f.source, cancellation: .init())
        try #require(undone.result.disposition == .succeeded
            && original.matches(restored)
            && !FileManager().fileExists(atPath: target.path))
        complete = true
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MAC_EXPLORER_RUN_CROSS_VOLUME_TESTS"] == "1",
                   "Requires owned generated fixtures with genuinely different device identities."))
    func laterCrossVolumePublishedMarkEditRefusesSecondRewalk() async throws {
        let f = try MetadataFixture()
        var complete = false
        defer { if complete { do { try FileManager().removeItem(at: f.root) } catch { Issue.record("Owned host fixture cleanup refused.") } } }
        let temporary = try MetadataTemporaryRoot()
        defer { if complete { do { try temporary.remove() } catch { Issue.record("Owned destination fixture cleanup refused.") } } }
        try #require(try DirectoryAnchor(f.root).identity.device != temporary.identity.device)
        let original = try verifiedTree(f.source, cancellation: .init())
        let target = temporary.url.appendingPathComponent("source")
        let mark = MetadataPublicationMark(target: target, laterEditAfterRetaining: f.source)
        var hooks = RecoveryHooks()
        hooks.beforeExclusiveRename = { from, to in try mark.before(from, to) }
        hooks.afterRename = { mark.after() }
        let moved = await RecoverableFileOperations(journalDirectory: f.journal, hooks: hooks)
            .perform(.move(sources: [f.source], destinationDirectory: temporary.url))
        let refusedLaterChange = moved.result.items.contains { $0.status == .failed(.recoveryUncertain) }
        try #require(mark.succeeded && mark.changedLater && refusedLaterChange)
        let id = try #require(moved.recordID)
        let review = try #require(try OperationJournal(f.journal).inspectRecord(id))
        try #require(review.state == "needsReview" && review.steps.count == 2
            && review.steps[0].after != nil && review.steps[1].after != nil)
        let retained = try #require(mark.retainedURL)
        let changedPublished = try verifiedTree(target, cancellation: .init())
        try #require(review.steps[1].destination == retained
            && review.steps[0].after?.matches(changedPublished) == false)
        let retainedImage = try verifiedTree(retained, cancellation: .init())
        try #require(!FileManager().fileExists(atPath: f.source.path)
            && FileManager().fileExists(atPath: target.path)
            && original.matches(retainedImage))
        complete = true
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MAC_EXPLORER_RUN_CROSS_VOLUME_TESTS"] == "1",
                   "Requires owned generated fixtures with genuinely different device identities."))
    func interruptedCrossVolumePublicationKeepsOriginalAndUnacknowledgedImage() async throws {
        let f = try MetadataFixture()
        var complete = false
        defer { if complete { do { try FileManager().removeItem(at: f.root) } catch { Issue.record("Owned host fixture cleanup refused.") } } }
        let temporary = try MetadataTemporaryRoot()
        defer { if complete { do { try temporary.remove() } catch { Issue.record("Owned destination fixture cleanup refused.") } } }
        try #require(try DirectoryAnchor(f.root).identity.device != temporary.identity.device)
        let original = try verifiedTree(f.source, cancellation: .init())
        let target = temporary.url.appendingPathComponent("source")
        let mark = MetadataPublicationMark(target: target)
        var hooks = RecoveryHooks()
        hooks.beforeExclusiveRename = { from, to in try mark.before(from, to) }
        hooks.afterRename = { mark.after() }
        hooks.beforeSync = { url in if url == target { throw FileOperationFailure.ioFailure } }
        let moved = await RecoverableFileOperations(journalDirectory: f.journal, hooks: hooks)
            .perform(.move(sources: [f.source], destinationDirectory: temporary.url))
        let interrupted = moved.result.items.contains { $0.status == .failed(.ioFailure) }
        try #require(mark.succeeded && interrupted)
        let id = try #require(moved.recordID)
        let record = try #require(try OperationJournal(f.journal).inspectRecord(id))
        try #require(record.state == "needsReview" && record.steps.count == 1
            && record.steps[0].destination == target && record.steps[0].after == nil)
        let unchangedOriginal = try verifiedTree(f.source, cancellation: .init())
        try #require(original.matches(unchangedOriginal)
            && FileManager().fileExists(atPath: target.path))
        complete = true
    }

}


private struct MetadataTemporaryRoot {
    let url: URL
    let identity: EntrySnapshot
    let parentIdentity: EntrySnapshot
    let parentURL: URL
    let marker: Data
    let name: String
    private static func selectedParentURL() throws -> URL {
        guard let raw = ProcessInfo.processInfo.environment["MAC_EXPLORER_CROSS_VOLUME_TEST_ROOT"] else {
            return URL(fileURLWithPath: "/private/tmp", isDirectory: true)
        }
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let repository = package.deletingLastPathComponent().deletingLastPathComponent()
        let base = repository.appendingPathComponent(".build/integrity-volumes", isDirectory: true)
        let prefix = base.path + "/"
        guard raw.hasPrefix(prefix) else { throw FileOperationFailure.invalidRequest }
        let components = raw.dropFirst(prefix.count).split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 2, components[1] == "mount",
              let jobID = UUID(uuidString: String(components[0]))?.uuidString,
              jobID == String(components[0]) else { throw FileOperationFailure.invalidRequest }
        let root = try DirectoryAnchor(base.appendingPathComponent(jobID, isDirectory: true), resolve: false)
        var rootStat = stat(), markerStat = stat()
        guard fstat(root.fd, &rootStat) == 0, rootStat.st_uid == geteuid(), rootStat.st_mode & 0o077 == 0,
              fstatat(root.fd, ".integrity-volume-owner-v1.json", &markerStat, AT_SYMLINK_NOFOLLOW) == 0,
              markerStat.st_mode & S_IFMT == S_IFREG, markerStat.st_uid == geteuid(),
              markerStat.st_nlink == 1, (1...1024).contains(markerStat.st_size),
              let owner = try JSONSerialization.jsonObject(with: OperationJournal.read(
                  name: ".integrity-volume-owner-v1.json", anchor: root)) as? [String: Any],
              owner.count == 3, owner["version"] as? Int == 1,
              owner["jobID"] as? String == jobID,
              owner["imageBytes"] as? Int == 512 * 1024 * 1024 else {
            throw FileOperationFailure.invalidRequest
        }
        let mount = try DirectoryAnchor(root.url.appendingPathComponent("mount", isDirectory: true), resolve: false)
        guard mount.identity.device != root.identity.device else { throw FileOperationFailure.invalidRequest }
        try root.validate(); try mount.validate()
        return mount.url
    }
    init() throws {
        let parent = try DirectoryAnchor(Self.selectedParentURL(), resolve: false)
        parentURL = parent.url
        parentIdentity = parent.identity
        name = "mac-explorer-metadata-" + UUID().uuidString
        url = parent.url.appendingPathComponent(name, isDirectory: true)
        marker = Data(("MacExplorer metadata fixture v1\n" + name).utf8)
        guard mkdirat(parent.fd, name, 0o700) == 0 else { throw posixFailure() }
        let root = try DirectoryAnchor(url, resolve: false)
        identity = root.identity
        let fd = openat(root.fd, ".owned-fixture", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw posixFailure() }; defer { close(fd) }
        guard marker.withUnsafeBytes({ write(fd, $0.baseAddress, $0.count) }) == marker.count, fsync(fd) == 0 else { throw posixFailure() }
        try syncDirectory(root); try syncDirectory(parent)
    }
    func remove() throws {
        guard url.deletingLastPathComponent() == parentURL,
              url.lastPathComponent == name else { throw FileOperationFailure.invalidRequest }
        let parent = try DirectoryAnchor(parentURL, resolve: false)
        let root = try DirectoryAnchor(url, resolve: false)
        guard root.identity.sameObject(as: identity), parent.identity.sameObject(as: parentIdentity),
              try OperationJournal.read(name: ".owned-fixture", anchor: root) == marker else { throw FileOperationFailure.sourceChanged }
        try root.validate(); try parent.validate()
        try FileManager().removeItem(at: url)
    }
}
