import Darwin
import Foundation
@_spi(Qualification) @testable import LocalStorage
import Testing

struct APFSVolumeCreationTests {
    private let selected = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let added = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

    @Test func namesRejectInvalidInputAndNormalizeUnicode() throws {
        for name in ["", ".", "..", "-passprompt", " leading", "trailing ", "a/b", "a:b", "a\nb", String(repeating: "é", count: 128)] {
            #expect(throws: APFSVolumeCreationFailure.invalidName) { try APFSVolumeCreation.validatedName(name) }
        }
        #expect(try APFSVolumeCreation.validatedName("Cafe\u{301}") == "Café")
        #expect(try APFSVolumeCreation.validatedName("Data $(echo untouched) `literal`") == "Data $(echo untouched) `literal`")
        #expect(!APFSContainerObservation.validDevice("disk2;echo x"))
        #expect(!APFSContainerObservation.validContainer("disk2s1"))
        #expect(!APFSContainerObservation.validContainer("disk2\n"))
    }

    @Test func reviewRequiresOrdinaryOneStoreContainerAndRealNumericSpace() throws {
        let valid = try APFSContainerObservation.decode(data(), selected: selected)
        #expect(valid.volumes.count == 1 && valid.free == 256 << 20)
        try valid.validateNewName("New Volume")
        #expect(throws: APFSVolumeCreationFailure.nameConflict) { try valid.validateNewName("existing") }
        let low = try APFSContainerObservation.decode(data(free: 1 << 20), selected: selected)
        #expect(throws: APFSVolumeCreationFailure.insufficientSpace) { try low.validateNewName("New Volume") }
        #expect(throws: (any Error).self) { try APFSContainerObservation.decode(data(free: true), selected: selected) }
        #expect(throws: APFSVolumeCreationFailure.unsupported) { try APFSContainerObservation.decode(data(roles: ["Backup"]), selected: selected) }
        #expect(throws: APFSVolumeCreationFailure.unsupported) { try APFSContainerObservation.decode(data(encrypted: true), selected: selected) }
        #expect(throws: APFSVolumeCreationFailure.unsupported) { try APFSContainerObservation.decode(data(stores: 2), selected: selected) }
    }

    @Test func reviewedMembershipAndContainerIdentityAreRevalidated() throws {
        let before = try APFSContainerObservation.decode(data(), selected: selected)
        let changedName = try APFSContainerObservation.decode(data(existingName: "Changed"), selected: selected)
        let changedContainer = try APFSContainerObservation.decode(data(containerID: "00000000-0000-0000-0000-000000000099"), selected: selected)
        let changedSpace = try APFSContainerObservation.decode(data(free: 128 << 20), selected: selected)
        #expect(!before.sameIdentityAndMembers(as: changedName))
        #expect(!before.sameIdentityAndMembers(as: changedContainer))
        #expect(before.sameIdentityAndMembers(as: changedSpace))
        #expect(throws: APFSVolumeCreationFailure.changed) { try APFSContainerObservation.decode(data(), selected: added) }
    }

    @Test func reconciliationRequiresExactlyExpectedAdditionAndPreservedOldVolumes() throws {
        let before = try APFSContainerObservation.decode(data(), selected: selected)
        let after = try APFSContainerObservation.decode(data(additions: [(added, "New Volume")]), selected: selected)
        #expect(before.preservesMembers(in: after))
        #expect(after.singleAddition(comparedWith: before, name: "New Volume")?.uuid == added)
        #expect(before.singleAddition(comparedWith: before, name: "New Volume") == nil)
        #expect(after.singleAddition(comparedWith: before, name: "Wrong Name") == nil)
        let unexpected = try APFSContainerObservation.decode(data(additions: [(added, "New Volume"), (UUID(), "Other")]), selected: selected)
        #expect(unexpected.singleAddition(comparedWith: before, name: "New Volume") == nil)
        let renamedOld = try APFSContainerObservation.decode(data(existingName: "Changed", additions: [(added, "New Volume")]), selected: selected)
        #expect(!before.preservesMembers(in: renamedOld))
    }

    @Test func unavailablePolicyNeverSubmitsAProcess() async throws {
        let container = try APFSContainerObservation.decode(data(), selected: selected)
        let target = ManagedVolume(id: UUID(), name: "Existing", url: URL(fileURLWithPath: "/generated/only"), isInternal: false,
            canMount: false, canUnmount: true, canEject: true, fileSystemID: 1, group: 2, deviceKind: .diskImage, mediaID: 3, volumeUUID: selected)
        let plan = APFSVolumeCreationPlan(selected: target, name: "New Volume", caseSensitive: false, container: container)
        let result = await APFSVolumeCreation().perform(plan, permitted: { false })
        #expect(!result.submitted && result.created == nil && result.failure == .unavailable)
        #expect(result.failureStage == .revalidation && result.toolExitStatus == nil && result.diagnosticCategory == nil)
        #expect(!String(reflecting: plan).contains("generated"))
    }

    @Test func cancellationWinsUntilMutationLaunchBegins() {
        let cancelled = APFSVolumeTool.MutationAdmission()
        cancelled.cancel()
        #expect(cancelled.beginIfAllowed({ true }) == .cancelled)

        let policyHeld = APFSVolumeTool.MutationAdmission()
        #expect(policyHeld.beginIfAllowed({ false }) == .unavailable)
        policyHeld.cancel()
        #expect(policyHeld.beginIfAllowed({ true }) == .unavailable)

        let launched = APFSVolumeTool.MutationAdmission()
        #expect(launched.beginIfAllowed({ true }) == .launch)
        launched.cancel()
        #expect(launched.beginIfAllowed({ true }) == .unavailable)
    }

    @Test func toolDiagnosticsRetainOnlyFixedNumericErrorSuffix() {
        #expect(APFSVolumeTool.numericErrorCode(Data("Started on disk9\nError starting APFS operation: permission refused (-69501)\n".utf8)) == -69501)
        #expect(APFSVolumeTool.numericErrorCode(Data("Error: -69493: You can't add any more APFS Volumes to its APFS Container\n".utf8)) == -69493)
        #expect(APFSVolumeTool.numericErrorCode(Data("Error: -69493: quoted text (-42)\n".utf8)) == -69493)
        #expect(APFSVolumeTool.numericErrorCode(Data("A volume named Personal(-42) was considered\n".utf8)) == nil)
        #expect(APFSVolumeTool.numericErrorCode(Data("A volume named Error: -69493: personal text\n".utf8)) == nil)
        #expect(APFSVolumeTool.numericErrorCode(Data("Error: -69493:\n".utf8)) == nil)
        #expect(APFSVolumeTool.numericErrorCode(Data("Error: -694931234567: too many digits\n".utf8)) == nil)
        #expect(APFSVolumeTool.numericErrorCode(Data("Error text without a numeric suffix\n".utf8)) == nil)
    }

    @Test func toolDiagnosticCategoriesRequireRecognizedCompleteLines() {
        func classify(_ output: String = "", _ errors: String = "") -> APFSVolumeCreationResult.DiagnosticCategory? {
            APFSVolumeTool.diagnosticCategory(stdout: Data(output.utf8), stderr: Data(errors.utf8))
        }
        #expect(classify("Usage:  diskutil apfs addVolume <container> <filesystem> <name>\n") == .commandUsage)
        #expect(classify("", "Error: The requesting process is not authorized to perform this operation\n") == .authorizationReported)
        #expect(classify("", "Error: Permission denied\n") == .permissionReported)
        #expect(classify("", "Error: Operation not permitted\n") == .permissionReported)
        let volumeLimit = "Error: -69493: You can't add any more APFS Volumes to its APFS Container"
        #expect(classify("", volumeLimit + "\n") == .volumeLimitReported)
        #expect(classify("Volume named " + volumeLimit + "\n") == nil)
        #expect(classify("", volumeLimit + " (name supplied by user)\n") == nil)
        #expect(classify("", volumeLimit.replacingOccurrences(of: "-69493", with: "-69494") + "\n") == nil)
        #expect(classify("Error: Permission ", "denied\n") == nil)
        #expect(classify("Volume named Error: Permission denied was considered\n") == nil)
        #expect(classify("Error creating 'Personal permission denied': unknown failure (-42)\n") == nil)
        #expect(classify("", "Error: unfamiliar refusal\n") == nil)
        #expect(classify() == nil)
        #expect(classify("Usage: diskutil apfs addVolume <container> <filesystem> <name>\n", "Error: Permission denied\n") == nil)
    }

    /// Explicitly opted in by the approved driver after it creates/attaches one
    /// fresh512MiB or1GiB image. No arbitrary size, mount, device-name or personal-file input.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TRAVERSE_APFS_OWNED_IMAGE_ROOT"] != nil))
    func ownedImageAddsOneVolumeAndRefusesStaleReview() async throws {
        let raw = try #require(ProcessInfo.processInfo.environment["TRAVERSE_APFS_OWNED_IMAGE_ROOT"])
        let root = URL(fileURLWithPath: raw, isDirectory: true)
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let owner = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("owner.json"))) as? [String: Any])
        let job = try #require(owner["jobID"] as? String)
        try #require(UUID(uuidString: job)?.uuidString == job && root.lastPathComponent == "drive-lifecycle-" + job)
        try #require(root.deletingLastPathComponent() == repo.appendingPathComponent(".build/fixtures") && root.resolvingSymlinksInPath() == root)
        let imageBytes = try #require(owner["bytes"] as? Int)
        try #require(imageBytes == 512 << 20 || imageBytes == 1 << 30)
        let image = root.appendingPathComponent("fixture.dmg")
        var imageStat = stat(), rootStat = stat(), mountStat = stat(), markerBefore = stat()
        try #require(lstat(image.path, &imageStat) == 0 && imageStat.st_mode & S_IFMT == S_IFREG
            && imageStat.st_nlink == 1 && imageStat.st_size == off_t(imageBytes) && imageStat.st_uid == geteuid())
        try #require(lstat(root.path, &rootStat) == 0 && rootStat.st_mode & S_IFMT == S_IFDIR && rootStat.st_uid == geteuid())
        let receiptURL = root.appendingPathComponent("drive-receipt.json")
        var receiptStat = stat()
        try #require(lstat(receiptURL.path, &receiptStat) == 0 && receiptStat.st_mode & S_IFMT == S_IFREG
            && receiptStat.st_uid == geteuid() && receiptStat.st_nlink == 1 && receiptStat.st_size > 0 && receiptStat.st_size <= 4096)
        let receipt = try JSONDecoder().decode(APFSImageDriveReceipt.self, from: Data(contentsOf: receiptURL))
        try #require(receipt.version == 3 && receipt.jobID.uuidString == job && !receipt.startsUnmounted
            && receipt.mediaID != 0 && receipt.outerMediaID != 0
            && receipt.fixtureDevice == Int64(rootStat.st_dev) && receipt.fixtureInode == rootStat.st_ino
            && receipt.imageDevice == Int64(imageStat.st_dev) && receipt.imageInode == imageStat.st_ino
            && !receipt.initialMount.utf8.contains(0) && receipt.initialMount.utf8.count <= 1024)
        let mount = URL(fileURLWithPath: receipt.initialMount, isDirectory: true)
        try #require(mount.deletingLastPathComponent().path == "/Volumes" && mount.standardizedFileURL == mount)
        var target: ManagedVolume?
        for _ in 0..<200 {
            let values = await VolumeLifecycle.shared.observationsForQualification()
            target = values.first { $0.deviceKind == .diskImage && $0.mediaID == receipt.mediaID && $0.group == receipt.outerMediaID
                && $0.fileSystemID == receipt.mountDevice && $0.url?.standardizedFileURL == mount }
            if target != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let selected = try #require(target)
        // A receipt path alone never authorizes a mount/marker read: first match
        // its exact native image media, outer scope and filesystem observation.
        try #require(mount.resolvingSymlinksInPath() == mount
            && lstat(mount.path, &mountStat) == 0 && mountStat.st_mode & S_IFMT == S_IFDIR
            && Int64(mountStat.st_dev) == receipt.mountDevice && rootStat.st_dev != mountStat.st_dev)
        let marker = mount.appendingPathComponent(".mac-explorer-drive-owner")
        try #require(lstat(marker.path, &markerBefore) == 0 && markerBefore.st_mode & S_IFMT == S_IFREG
            && markerBefore.st_dev == mountStat.st_dev && markerBefore.st_uid == geteuid()
            && markerBefore.st_nlink == 1 && markerBefore.st_size == 36)
        let bytes = try Data(contentsOf: marker)
        try #require(bytes == Data(job.utf8))
        // Install the observer only after this exact generated root/image/
        // mount/marker has passed the ownership checks. A retained directory
        // descriptor confines every fixed diagnostic leaf to that root.
        let evidence = try APFSImageTerminalEvidence(root: root, expected: rootStat)
        let backend = APFSVolumeCreation(tool: APFSVolumeTool(terminalObserver: { evidence.capture($0) }))
        let name = "Traverse-Added-" + job
        let plan = try await backend.prepare(selected, name: name)
        let result = await backend.perform(plan, permitted: { true })
        // Persist terminal facts before an assertion can stop the case. Raw
        // bounded streams exist only in this opt-in generated fixture root.
        let terminal: [String: Any] = ["submitted": result.submitted,
            "toolExitStatus": result.toolExitStatus.map { NSNumber(value: $0) } ?? NSNull(),
            "diskutilErrorCode": result.diskutilErrorCode.map { NSNumber(value: $0) } ?? NSNull(),
            "failure": result.failure.map { String(describing: $0) } ?? "none",
            "failureStage": result.failureStage?.rawValue ?? "none",
            "diagnosticCategory": result.diagnosticCategory?.rawValue ?? "unknown",
            "createdVolumeUUID": result.created?.id.uuidString ?? "none"]
        try JSONSerialization.data(withJSONObject: terminal, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("apfs-add-volume-terminal.json"), options: .withoutOverwriting)
        try #require(!result.submitted || evidence.capturedOnce, "The generated mutation terminal evidence could not be retained")
        let added = try #require(result.created, "The single owned-image add-volume did not reconcile: \(String(describing: result.failure))")
        try #require(result.submitted && result.failure == nil && added.name == name)
        // Reusing the review must refuse its stale membership before any new
        // child submission. There is exactly one creation budget for this case.
        let stale = await backend.perform(plan, permitted: { true })
        try #require(!stale.submitted && stale.created == nil && stale.failure == .changed)
        var markerAfter = stat(), imageAfter = stat()
        let markerBytesAfter = try Data(contentsOf: marker)
        try #require(lstat(marker.path, &markerAfter) == 0 && markerAfter.st_ino == markerBefore.st_ino
            && markerAfter.st_dev == markerBefore.st_dev && markerAfter.st_size == markerBefore.st_size
            && markerAfter.st_flags == markerBefore.st_flags && markerBytesAfter == bytes)
        try #require(lstat(image.path, &imageAfter) == 0 && imageAfter.st_ino == imageStat.st_ino
            && imageAfter.st_dev == imageStat.st_dev && imageAfter.st_size == imageStat.st_size)
        let report: [String: Any] = ["passed": true, "submitted": result.submitted, "staleRefused": true,
            "newVolumeName": added.name, "newVolumeUUID": added.id.uuidString, "existingMarkerPreserved": true]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("apfs-add-volume-result.json"), options: .withoutOverwriting)
    }

    private func data(free: Any = 256 << 20, roles: [String] = [], encrypted: Bool = false, stores: Int = 1,
                      containerID: String = "00000000-0000-0000-0000-000000000010", existingName: String = "Existing",
                      additions: [(UUID, String)] = []) throws -> Data {
        func volume(_ id: UUID, _ name: String, _ index: Int) -> [String: Any] {
            ["APFSVolumeUUID": id.uuidString, "DeviceIdentifier": "disk9s\(index)", "Name": name,
             "CapacityQuota": 0, "CapacityReserve": 0, "Roles": roles,
             "Encryption": encrypted, "FileVault": false, "Locked": false, "CryptoMigrationOn": false]
        }
        let volumes = [volume(selected, existingName, 1)] + additions.enumerated().map { volume($0.element.0, $0.element.1, $0.offset + 2) }
        return try PropertyListSerialization.data(fromPropertyList: ["Containers": [[
            "ContainerReference": "disk9", "APFSContainerUUID": containerID, "CapacityCeiling": 512 << 20,
            "CapacityFree": free, "Volumes": volumes,
            "PhysicalStores": (0..<stores).map { ["DeviceIdentifier": "disk8s\($0 + 1)", "DiskUUID": "00000000-0000-0000-0000-00000000002\($0)", "Size": 512 << 20] as [String: Any] }
        ]]], format: .xml, options: 0)
    }
}

/// Same v3 shape as the existing native lifecycle receipt. Required typed fields
/// reject absent/null/string-valued startsUnmounted and unbound legacy receipts.
private struct APFSImageDriveReceipt: Decodable {
    let version: Int
    let jobID: UUID
    let initialMount: String
    let mountDevice, fixtureDevice, imageDevice: Int64
    let fixtureInode, imageInode, mediaID, outerMediaID: UInt64
    let startsUnmounted: Bool
}

/// Opt-in image evidence only, not a product logger. The pinned directory is
/// owner-validated once; fixed exclusive leaves never follow links or replace
/// old failure receipts. The lock protects status and the single callback.
private final class APFSImageTerminalEvidence: @unchecked Sendable {
    private enum Failure: Error { case directory, write }
    private let descriptor: Int32
    private let lock = NSLock()
    private var attempts = 0, succeeded = false
    var capturedOnce: Bool { lock.withLock { attempts == 1 && succeeded } }

    init(root: URL, expected: stat) throws {
        let fd = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Failure.directory }
        var facts = stat()
        guard fstat(fd, &facts) == 0, facts.st_mode & S_IFMT == S_IFDIR,
              facts.st_uid == geteuid(), facts.st_dev == expected.st_dev, facts.st_ino == expected.st_ino else {
            Darwin.close(fd); throw Failure.directory
        }
        descriptor = fd
    }
    deinit { Darwin.close(descriptor) }

    func capture(_ terminal: APFSVolumeTool.MutationTerminal) {
        lock.withLock {
            attempts += 1
            guard attempts == 1 else { succeeded = false; return }
            do {
                guard terminal.stdout.count <= 8192, terminal.stderr.count <= 8192 else { throw Failure.write }
                try write(terminal.stdout, leaf: "apfs-add-volume-stdout.txt")
                try write(terminal.stderr, leaf: "apfs-add-volume-stderr.txt")
                let receipt: [String: Any] = ["format": "apfs-owned-image-tool-terminal-v1", "childReaped": true,
                    "toolExitStatus": terminal.status, "stdoutPrefixBytes": terminal.stdout.count,
                    "stderrPrefixBytes": terminal.stderr.count, "stdoutTruncated": terminal.stdoutTruncated,
                    "stderrTruncated": terminal.stderrTruncated, "readIncomplete": terminal.readIncomplete]
                let data = try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
                guard data.count <= 1024 else { throw Failure.write }
                try write(data, leaf: "apfs-add-volume-tool-diagnostic.json")
                succeeded = true
            } catch { succeeded = false } // Never log raw streams or dynamic errors.
        }
    }
    private func write(_ data: Data, leaf: String) throws {
        let fd = openat(descriptor, leaf, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard fd >= 0 else { throw Failure.write }
        defer { Darwin.close(fd) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                guard let base = bytes.baseAddress else { throw Failure.write }
                let count = Darwin.write(fd, base.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw Failure.write }
                offset += count
            }
        }
    }
}
