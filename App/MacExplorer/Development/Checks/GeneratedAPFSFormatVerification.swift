import AppKit
import Darwin
import DiskArbitration
import ExplorerCore
import Foundation
import IOKit
import LocalStorage

#if DEBUG || TRAVERSE_DRIVE_IMAGE_QA
struct GeneratedAPFSReceipt: Decodable, Sendable {
        let version: Int
        let jobID: UUID
        let initialMount: String
        let mountDevice: Int64
        let fixtureDevice: Int64
        let fixtureInode: UInt64
        let imageDevice: Int64
        let imageInode: UInt64
        let startsUnmounted: Bool
        let mediaID: UInt64
        let outerMediaID: UInt64
}

struct GeneratedAPFSFormatFailure: Error {
    let message: String
}

@MainActor
enum GeneratedAPFSFormatVerification {
    private nonisolated static func mutationAllowed(fixture: URL, receipt: GeneratedAPFSReceipt) -> Bool {
        if GeneratedDriveImageReview.requested {
            guard let selected = GeneratedDriveImageReview.selection else { return false }
            return selected.phase == .warm && selected.fixtureRoot == fixture
                && selected.caseID == receipt.jobID.uuidString
                && AppFeatureAvailability.allows(.apfsVolumeCreation)
        }
        return AppFeatureAvailability.allows(.apfsVolumeCreation)
    }

    static func readReceipt(_ output: URL) throws -> GeneratedAPFSReceipt {
        let path = output.appendingPathComponent("native-drive-receipt.json")
        let fd = open(path.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw GeneratedAPFSFormatFailure(message: "Native drive receipt unavailable") }
        defer { close(fd) }
        var value = stat()
        guard fstat(fd, &value) == 0, value.st_mode & S_IFMT == S_IFREG, value.st_uid == geteuid(),
              value.st_nlink == 1, (1...4096).contains(value.st_size) else {
            throw GeneratedAPFSFormatFailure(message: "Native drive receipt identity refused")
        }
        var data = Data(count: Int(value.st_size))
        let count = data.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
        guard count == data.count else { throw GeneratedAPFSFormatFailure(message: "Native drive receipt read failed") }
        return try JSONDecoder().decode(GeneratedAPFSReceipt.self, from: data)
    }

    private static func observed(_ drives: ApplicationVolumeCoordinator,
                                 _ predicate: (ManagedVolume) -> Bool) async throws -> ManagedVolume {
        try await until("Native drive observation") { drives.volumes.contains(where: predicate) }
        return drives.volumes.first(where: predicate)!
    }
    private static func until(_ stage: String, _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(120)
        while ContinuousClock.now < deadline {
            if condition() { return }; try await Task.sleep(for: .milliseconds(10))
        }
        throw GeneratedAPFSFormatFailure(message: stage + " did not settle within two minutes")
    }
    private static func require(_ value: Bool, _ message: String) throws {
        if !value { throw GeneratedAPFSFormatFailure(message: message) }
    }

    static func warm(operations: ApplicationOperationCoordinator, drives: ApplicationVolumeCoordinator,
                                   initial: ManagedVolume, receipt: GeneratedAPFSReceipt, fixture: URL, output: URL) async throws -> [String] {
        try require(!receipt.startsUnmounted && initial.deviceKind == .diskImage && initial.volumeUUID != nil,
                    "APFS Format requires the exact mounted generated image")
        try await until("Generated protection review") { drives.protectionReady && !drives.isEditingProtection }
        let originalMembers = drives.volumes.filter { $0.group == receipt.outerMediaID && $0.volumeUUID != nil }
        try require(originalMembers.count == 1 && originalMembers[0] == initial && drives.permitsRemoval(initial, action: .eject),
                    "APFS Format requires one unprotected original member")
        let protected = operations.protectedStorageLocations
        try require(!protected.contains(where: { $0.pathComponents.starts(with: initial.url?.pathComponents ?? []) }),
                    "Generated APFS image contains protected application storage")
        let originalMarker = try await verifyMarker(initial, receipt: receipt)
        let initialInspection = try await VolumeLifecycle.shared.inspect(initial)
        let originalLeaf = try APFSFormatImageSeal.Leaf(initial, initialInspection)
        let originalSeal = try APFSFormatImageSeal(root: fixture, receipt: receipt, original: originalLeaf)
        await drives.waitForNativeDriveJobLoad()
        try require(drives.nativeDriveJobReady && drives.nativeDriveJobIssue.isEmpty,
                    "A prior or unreadable native Format job blocks generated APFS mutation")
        let owner = UUID()
        try require(operations.begin(owner: owner), "Generated APFS work gate is occupied")
        let activity: any Sendable
        do { activity = try ApplicationFileActivity.beginOperation() }
        catch { operations.finish(owner: owner); throw error }
        defer { withExtendedLifetime(activity) {}; operations.finish(owner: owner) }
        let evidence = try APFSFormatEvidence(output: output)
        let addedName = "Traverse-Format-" + receipt.jobID.uuidString
        try evidence.write(["phase": "intent", "request": "one-apfs-volume-add", "imageInode": receipt.imageInode,
                            "originalUUID": initial.volumeUUID!.uuidString], leaf: "apfs-add-intent.json")
        let addition = APFSVolumeCreation()
        let addPlan = try await addition.prepare(initial, name: addedName)
        let addResult = await addition.perform(addPlan, permitted: {
            mutationAllowed(fixture: fixture, receipt: receipt) && originalSeal.current()
        }, submitted: { evidence.recordAddSubmission() })
        try evidence.write(["submitted": addResult.submitted, "createdUUID": addResult.created?.id.uuidString ?? "none",
                            "failure": addResult.failure.map { String(describing: $0) } ?? "none",
                            "status": addResult.toolExitStatus.map { Int($0) } as Any? ?? NSNull()],
                           leaf: "apfs-add-terminal.json")
        try require(!addResult.submitted || evidence.addRecorded, "Generated APFS Add submission receipt was not durable")
        guard let added = addResult.created else { throw GeneratedAPFSFormatFailure(message: "Generated APFS Add did not reconcile") }
        try require(addResult.submitted && addResult.failure == nil && added.name == addedName && added.id != initial.volumeUUID,
                    "Generated APFS Add exceeded its exact one-member budget")
        try await until("Generated two-member discovery") {
            let members = drives.volumes.filter { $0.group == receipt.outerMediaID && $0.volumeUUID != nil }
            return members.count == 2 && members.contains(where: { $0.volumeUUID == added.id && $0.url != nil })
        }
        let sibling = try await observed(drives) { $0.volumeUUID == initial.volumeUUID && $0.group == receipt.outerMediaID }
        let target = try await observed(drives) { $0.volumeUUID == added.id && $0.group == receipt.outerMediaID && $0.url != nil }
        try require(sibling.mediaID == initial.mediaID && sibling.name == initial.name && sibling.url == initial.url
                    && sibling.fileSystemID == initial.fileSystemID && drives.permitsRemoval(target, action: .eject),
                    "Original generated APFS sibling changed during Add")
        let siblingMarkerBefore = try await verifyMarker(sibling, receipt: receipt)
        try require(siblingMarkerBefore == originalMarker,
                    "Original generated marker changed during Add")
        let targetInspection = try await VolumeLifecycle.shared.inspect(target)
        let targetLeaf = try APFSFormatImageSeal.Leaf(target, targetInspection)
        let formatSeal = try APFSFormatImageSeal(root: fixture, receipt: receipt, original: originalLeaf, target: targetLeaf)
        let markerBefore = try await createFormatTargetMarker(target, receipt: receipt, fixture: fixture)
        let mountedBefore = try await mountedDeviceIDs(excluding: target.url)
        let format = APFSVolumeFormat()
        let plan = try await format.prepare(target)
        try require(plan.name == addedName && plan.selected == target && plan.siblingNames == [sibling.name],
                    "Generated APFS Format review changed the selected member")
        let generatedOwner = formatOwner(receipt: receipt, fixture: fixture)
        guard let recording = drives.generatedFormatRecording(owner: generatedOwner,
            attachmentCurrent: { formatSeal.imageAndOuterCurrent() }) else {
            throw GeneratedAPFSFormatFailure(message: "Generated APFS Format durable recorder was not admitted")
        }
        try require(!drives.generatedFormatJobIsAdmissible(owner: generatedOwner),
                    "An issued Format recorder left a second request admitted")
        try require(recording.ownerStillCurrent(), "Generated APFS Format job owner is stale")
        try evidence.write(["phase": "intent", "request": "one-apfs-volume-erase", "imageInode": receipt.imageInode,
                            "siblingUUID": initial.volumeUUID!.uuidString, "targetUUID": added.id.uuidString,
                            "targetMarkerInode": markerBefore.inode], leaf: "apfs-format-intent.json")
        let formatted = await format.perform(plan, confirmedName: addedName, recording: recording, permitted: {
            mutationAllowed(fixture: fixture, receipt: receipt) && formatSeal.current()
        }, submitted: { evidence.recordSubmission() })
        // This receipt precedes every success assertion. An OS denial, a
        // changed UUID assumption or a failed reconciliation remains visible.
        try evidence.write(["submitted": formatted.submitted,
                            "formattedUUID": formatted.formatted?.id.uuidString ?? "none",
                            "failure": formatted.failure.map { String(describing: $0) } ?? "none",
                            "status": formatted.toolExitStatus.map { Int($0) } as Any? ?? NSNull(),
                            "diskutilErrorCode": formatted.diskutilErrorCode as Any? ?? NSNull(),
                            "submissionReceipt": evidence.submittedRecorded], leaf: "apfs-format-terminal.json")
        await drives.reloadNativeDriveJobAfterRecording()
        try require(!formatted.submitted || !drives.generatedFormatJobIsAdmissible(owner: generatedOwner)
                    && !drives.nativeDriveJobIssue.isEmpty,
                    "A submitted unresolved Format job remained clean in its warm coordinator")
        try require(!formatted.submitted || evidence.submittedRecorded,
                    "Generated APFS Format submission receipt was not durable")
        guard let newVolume = formatted.formatted else {
            throw GeneratedAPFSFormatFailure(message: "Generated APFS Format ended without an exact reconciled member")
        }
        try require(formatted.submitted && formatted.failure == nil && newVolume.id != added.id
                    && newVolume.name == addedName && formatted.toolExitStatus == 0,
                    "Generated APFS Format postcondition was not established")
        let durable = try await recording.store.load()
        try require(durable.record?.id == recording.jobID
                    && durable.record?.phase == .compatibleReplacement
                    && durable.record?.replacementID == newVolume.id
                    && durable.record?.isUnresolved == true,
                    "Generated APFS Format result lacks an unresolved durable job")
        try await until("Formatted two-member discovery") {
            let members = drives.volumes.filter { $0.group == receipt.outerMediaID && $0.volumeUUID != nil }
            return members.count == 2 && members.contains(where: { $0.volumeUUID == newVolume.id && $0.url != nil })
        }
        let currentSibling = try await observed(drives) { $0.volumeUUID == initial.volumeUUID && $0.group == receipt.outerMediaID }
        let currentTarget = try await observed(drives) { $0.volumeUUID == newVolume.id && $0.group == receipt.outerMediaID }
        let siblingMarkerAfter = try await verifyMarker(currentSibling, receipt: receipt)
        try require(currentSibling.mediaID == sibling.mediaID && currentSibling.url == sibling.url
                    && currentSibling.fileSystemID == sibling.fileSystemID && currentSibling.name == sibling.name
                    && siblingMarkerAfter == originalMarker,
                    "Original APFS sibling or marker changed during Format")
        try require(newVolume.mountPoint?.standardizedFileURL == currentTarget.url?.standardizedFileURL
                    && currentTarget.name == addedName && currentTarget.deviceKind == .diskImage,
                    "Formatted APFS target is not the expected mounted generated member")
        try await requireFormatTargetMarkerAbsent(currentTarget, fixture: fixture)
        try require(formatSeal.imageAndOuterCurrent(), "Generated backing image or outer attachment changed after Format")
        let mountedAfter = try await mountedDeviceIDs(excluding: currentTarget.url)
        try require(mountedBefore == mountedAfter, "Other mounted device identities changed during Format")
        let currentInspection = try await VolumeLifecycle.shared.inspect(currentTarget)
        let currentLeaf = try APFSFormatImageSeal.Leaf(currentTarget, currentInspection)
        let afterSeal = try APFSFormatImageSeal(root: fixture, receipt: receipt, original: originalLeaf, target: currentLeaf)
        try require(afterSeal.current() && afterSeal.outer == formatSeal.outer,
                    "Formatted APFS target is not bound to the original image")
        try evidence.write(["passed": true, "submitted": true, "jobID": recording.jobID.uuidString,
                            "siblingUUID": initial.volumeUUID!.uuidString,
                            "siblingDevice": originalLeaf.device, "siblingMarkerInode": originalMarker.inode,
                            "formattedUUID": newVolume.id.uuidString,
                            "formattedName": newVolume.name, "outerDevice": "/dev/" + afterSeal.outer,
                            "siblingMarkerPreserved": true, "targetMarkerRemoved": true,
                            "unrelatedMountsUnchanged": true], leaf: "apfs-format-result.json")
        return ["One owned generated APFS image and exact original member passed launch-boundary checks",
                "One Add and one Format drained; exact sibling survived and target marker disappeared",
                "Fresh native target and unrelated mounted identities reconciled without retry"]
    }

    /// A second process must read the unresolved job from disk. This route has
    /// no Add/Format call and cannot obtain a recorder while that job remains.
    static func cold(drives: ApplicationVolumeCoordinator, initial: ManagedVolume,
                                       receipt: GeneratedAPFSReceipt, fixture: URL, output: URL) async throws -> [String] {
        guard !receipt.startsUnmounted, initial.deviceKind == .diskImage, let siblingID = initial.volumeUUID else {
            throw GeneratedAPFSFormatFailure(message: "Cold Format review requires the mounted generated sibling")
        }
        let owner = formatOwner(receipt: receipt, fixture: fixture)
        guard owner.validate(), let store = NativeDriveJobStore.applicationStore() else {
            throw GeneratedAPFSFormatFailure(message: "Cold Format durable job store is unavailable")
        }
        let before = try await store.load()
        guard let record = before.record, let replacementID = record.replacementID,
              record.owner == owner, record.phase == .compatibleReplacement, record.isUnresolved,
              record.snapshot.targetID != siblingID, replacementID != siblingID,
              record.snapshot.members.count == 2,
              record.snapshot.members.contains(where: { $0.uuid == siblingID && $0.name == initial.name }) else {
            throw GeneratedAPFSFormatFailure(message: "Cold Format job is not the exact unresolved generated request")
        }
        let siblingMarker = try await verifyMarker(initial, receipt: receipt)
        let siblingInspection = try await VolumeLifecycle.shared.inspect(initial)
        let siblingLeaf = try APFSFormatImageSeal.Leaf(initial, siblingInspection)
        let target = try await observed(drives) {
            $0.volumeUUID == replacementID && $0.group == receipt.outerMediaID && $0.url != nil
        }
        let members = drives.volumes.filter { $0.group == receipt.outerMediaID && $0.volumeUUID != nil }
        try require(members.count == 2 && Set(members.compactMap(\.volumeUUID)) == Set([siblingID, replacementID]),
                    "Cold Format graph is not the exact two-member image")
        let targetInspection = try await VolumeLifecycle.shared.inspect(target)
        let targetLeaf = try APFSFormatImageSeal.Leaf(target, targetInspection)
        let seal = try APFSFormatImageSeal(root: fixture, receipt: receipt, original: siblingLeaf, target: targetLeaf)
        let siblingMarkerAfter = try await verifyMarker(initial, receipt: receipt)
        try require(seal.current() && siblingMarker == siblingMarkerAfter,
                    "Cold Format image or sibling marker changed")
        try await requireFormatTargetMarkerAbsent(target, fixture: fixture)

        await drives.waitForNativeDriveJobLoad()
        try require(!drives.nativeDriveJobReady && !drives.nativeDriveJobIssue.isEmpty,
                    "Cold unresolved Format job did not close coordinator admission")
        try require(!drives.generatedFormatJobIsAdmissible(owner: owner),
                    "Cold unresolved Format job reopened the recorder gate")
        let compatible = try await store.inspectUnresolvedCompatibleReplacement(owner: owner,
            backend: APFSVolumeFormat(), ownerStillCurrent: { seal.current() })
        let after = try await store.load()
        try require(after.bytes == before.bytes && after.record == record && seal.current()
                    && !drives.nativeDriveJobReady && !drives.generatedFormatJobIsAdmissible(owner: owner),
                    "Cold Format inspection changed the job or reopened admission")
        let result: [String: Any] = ["passed": true, "jobID": record.id.uuidString,
            "unresolved": true, "admissionHeld": true, "recordUnchanged": true,
            "compatibleInspection": compatible]
        try APFSFormatEvidence(output: output).write(result, leaf: "apfs-format-cold-result.json")
        return ["Separate read-only app launch loaded the exact unresolved generated Format job",
                "Coordinator held the recorder gate and inspection preserved the durable record"]
    }

    private static func formatOwner(receipt: GeneratedAPFSReceipt, fixture: URL) -> APFSVolumeFormatGeneratedOwner {
        APFSVolumeFormatGeneratedOwner(fixtureID: receipt.jobID,
            imagePath: fixture.appendingPathComponent("fixture.dmg").path,
            rootDevice: receipt.fixtureDevice, rootInode: receipt.fixtureInode,
            imageDevice: receipt.imageDevice, imageInode: receipt.imageInode,
            ownerUID: UInt32(geteuid()), outerMediaID: receipt.outerMediaID)
    }

    private static func createFormatTargetMarker(_ volume: ManagedVolume, receipt: GeneratedAPFSReceipt, fixture: URL) async throws -> MarkerIdentity {
        guard let mount = volume.url else { throw GeneratedAPFSFormatFailure(message: "Generated Format target is unmounted") }
        return try await Task.detached {
            var root = stat(), directory = stat(), marker = stat()
            guard lstat(fixture.path, &root) == 0, lstat(mount.path, &directory) == 0,
                  directory.st_mode & S_IFMT == S_IFDIR, directory.st_dev != root.st_dev,
                  Int64(directory.st_dev) == volume.fileSystemID else {
                throw GeneratedAPFSFormatFailure(message: "Generated Format target mount changed")
            }
            let parent = open(mount.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard parent >= 0 else { throw GeneratedAPFSFormatFailure(message: "Generated Format target mount refused") }
            defer { close(parent) }
            guard fstat(parent, &directory) == 0, Int64(directory.st_dev) == volume.fileSystemID else {
                throw GeneratedAPFSFormatFailure(message: "Generated Format target directory changed")
            }
            let fd = openat(parent, ".mac-explorer-format-target", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw GeneratedAPFSFormatFailure(message: "Generated Format target marker refused") }
            defer { close(fd) }
            let bytes = Array(receipt.jobID.uuidString.utf8)
            let written = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            guard written == bytes.count, fsync(fd) == 0, fsync(parent) == 0,
                  fstat(fd, &marker) == 0, marker.st_dev == directory.st_dev,
                  marker.st_uid == geteuid(), marker.st_nlink == 1, marker.st_size == 36 else {
                throw GeneratedAPFSFormatFailure(message: "Generated Format target marker was not sealed")
            }
            return MarkerIdentity(device: Int64(marker.st_dev), size: marker.st_size, inode: marker.st_ino, flags: marker.st_flags)
        }.value
    }

    private static func requireFormatTargetMarkerAbsent(_ volume: ManagedVolume, fixture: URL) async throws {
        guard let mount = volume.url else { throw GeneratedAPFSFormatFailure(message: "Formatted target is unmounted") }
        try await Task.detached {
            var root = stat(), directory = stat()
            guard lstat(fixture.path, &root) == 0, lstat(mount.path, &directory) == 0,
                  directory.st_mode & S_IFMT == S_IFDIR, directory.st_dev != root.st_dev,
                  Int64(directory.st_dev) == volume.fileSystemID else {
                throw GeneratedAPFSFormatFailure(message: "Formatted target mount changed")
            }
            let parent = open(mount.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard parent >= 0 else { throw GeneratedAPFSFormatFailure(message: "Formatted target mount refused") }
            defer { close(parent) }
            guard fstat(parent, &directory) == 0, Int64(directory.st_dev) == volume.fileSystemID else {
                throw GeneratedAPFSFormatFailure(message: "Formatted target directory changed")
            }
            let fd = openat(parent, ".mac-explorer-format-target", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            if fd >= 0 { close(fd); throw GeneratedAPFSFormatFailure(message: "Formatted target retained old marker") }
            guard errno == ENOENT else { throw GeneratedAPFSFormatFailure(message: "Formatted target marker state is uncertain") }
        }.value
    }

    private struct MountID: Hashable, Sendable { let first, second: Int32 }
    private static func mountedDeviceIDs(excluding target: URL?) async throws -> Set<MountID> {
        try await Task.detached {
            guard let target else { throw GeneratedAPFSFormatFailure(message: "Generated target mount is unavailable") }
            let capacity = getfsstat(nil, 0, MNT_NOWAIT)
            guard capacity > 0, capacity <= 4096 else { throw GeneratedAPFSFormatFailure(message: "Mounted identity table is unavailable") }
            var rows = Array(repeating: statfs(), count: Int(capacity))
            let count = rows.withUnsafeMutableBufferPointer {
                getfsstat($0.baseAddress, Int32($0.count * MemoryLayout<statfs>.stride), MNT_NOWAIT)
            }
            guard count > 0, count <= capacity else { throw GeneratedAPFSFormatFailure(message: "Mounted identity table changed") }
            func path(_ row: statfs) -> Data? {
                withUnsafeBytes(of: row.f_mntonname) { raw in raw.firstIndex(of: 0).map { Data(raw[..<$0]) } }
            }
            let current = Array(rows.prefix(Int(count)))
            let targetRows = current.filter { path($0) == Data(target.path.utf8) }
            guard targetRows.count == 1 else { throw GeneratedAPFSFormatFailure(message: "Generated target is not an exact mounted member") }
            return Set(current.filter { path($0) != Data(target.path.utf8) }
                .map { MountID(first: $0.f_fsid.val.0, second: $0.f_fsid.val.1) })
        }.value
    }

    struct MarkerIdentity: Sendable, Equatable {
        let device: Int64, size: Int64
        let inode: UInt64
        let flags: UInt32
    }
    @discardableResult static func verifyMarker(_ volume: ManagedVolume, receipt: GeneratedAPFSReceipt) async throws -> MarkerIdentity {
        guard let root = volume.url else { throw GeneratedAPFSFormatFailure(message: "Generated volume not mounted") }
        return try await Task.detached {
            var identity = stat()
            guard lstat(root.path, &identity) == 0, Int64(identity.st_dev) == volume.fileSystemID,
                  identity.st_mode & S_IFMT == S_IFDIR else { throw GeneratedAPFSFormatFailure(message: "Generated mount identity changed") }
            let marker = root.appendingPathComponent(".mac-explorer-drive-owner")
            let fd = open(marker.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw GeneratedAPFSFormatFailure(message: "Generated mount owner marker unavailable") }
            defer { close(fd) }
            var value = stat()
            guard fstat(fd, &value) == 0, value.st_dev == identity.st_dev, value.st_mode & S_IFMT == S_IFREG,
                  value.st_size == 36, value.st_nlink == 1, value.st_uid == geteuid() else { throw GeneratedAPFSFormatFailure(message: "Generated mount owner marker refused") }
            var bytes = [UInt8](repeating: 0, count: 36)
            guard read(fd, &bytes, bytes.count) == 36, String(decoding: bytes, as: UTF8.self) == receipt.jobID.uuidString else {
                throw GeneratedAPFSFormatFailure(message: "Generated mount ownership changed")
            }
            return MarkerIdentity(device: Int64(value.st_dev), size: value.st_size, inode: value.st_ino, flags: value.st_flags)
        }.value
    }
}

/// Debug-only launch gate for the one generated image. It never accepts a
/// user-supplied device name as ownership and never retains another image's
/// metadata. The backend independently reobserves APFS membership.
private struct APFSFormatImageSeal: Sendable {
    struct Leaf: Sendable {
        let device: String
        let mediaID: UInt64
        let volumeUUID: UUID
        let name: String
        let mount: URL
        init(_ volume: ManagedVolume, _ inspection: VolumeInspection) throws {
            guard inspection.volume == volume, let mediaID = volume.mediaID, let volumeUUID = volume.volumeUUID,
                  let mount = volume.url, volume.deviceKind == .diskImage,
                  inspection.deviceName.range(of: #"\Adisk[0-9]+s[0-9]+\z"#, options: .regularExpression) != nil else {
                throw GeneratedAPFSFormatFailure(message: "Generated APFS leaf is not natively bound")
            }
            device = inspection.deviceName; self.mediaID = mediaID; self.volumeUUID = volumeUUID
            name = volume.name; self.mount = mount.standardizedFileURL
        }
    }

    let root: URL
    let receipt: GeneratedAPFSReceipt
    let outer: String
    let original: Leaf
    let target: Leaf?

    init(root: URL, receipt: GeneratedAPFSReceipt, original: Leaf, target: Leaf? = nil) throws {
        self.root = root; self.receipt = receipt; self.original = original; self.target = target
        guard let attachment = Self.attachment(root: root),
              let entities = attachment["system-entities"] as? [[String: Any]],
              let first = entities.first?["dev-entry"] as? String,
              first.range(of: #"\A/dev/disk[0-9]+\z"#, options: .regularExpression) != nil else {
            throw GeneratedAPFSFormatFailure(message: "Generated image attachment is unavailable")
        }
        outer = String(first.dropFirst(5))
        guard current() else { throw GeneratedAPFSFormatFailure(message: "Generated image ownership changed before review") }
    }

    /// Called synchronously by the backend on its utility queue immediately
    /// before Process.run, after its own fresh selected-container observation.
    func current() -> Bool {
        guard imageAndOuterCurrent(), let session = DASessionCreate(kCFAllocatorDefault),
              Self.matches(original, session: session) else { return false }
        return target.map { Self.matches($0, session: session) } ?? true
    }

    func imageAndOuterCurrent() -> Bool {
        var fixture = stat(), image = stat()
        let file = root.appendingPathComponent("fixture.dmg")
        guard apfsOwnerMarkerCurrent(root: root, jobID: receipt.jobID),
              lstat(root.path, &fixture) == 0, fixture.st_mode & S_IFMT == S_IFDIR,
              fixture.st_uid == geteuid(), Int64(fixture.st_dev) == receipt.fixtureDevice,
              fixture.st_ino == receipt.fixtureInode,
              lstat(file.path, &image) == 0, image.st_mode & S_IFMT == S_IFREG,
              image.st_uid == geteuid(), image.st_nlink == 1, image.st_size == (1 << 30),
              Int64(image.st_dev) == receipt.imageDevice, image.st_ino == receipt.imageInode,
              let attachment = Self.attachment(root: root),
              let entities = attachment["system-entities"] as? [[String: Any]],
              entities.first?["dev-entry"] as? String == "/dev/" + outer,
              entities.contains(where: { $0["dev-entry"] as? String == "/dev/" + original.device }),
              let session = DASessionCreate(kCFAllocatorDefault),
              let disk = outer.withCString({ DADiskCreateFromBSDName(kCFAllocatorDefault, session, $0) }),
              Self.mediaID(disk) == receipt.outerMediaID else { return false }
        var finalFixture = stat(), finalImage = stat()
        return lstat(root.path, &finalFixture) == 0 && lstat(file.path, &finalImage) == 0
            && finalFixture.st_dev == fixture.st_dev && finalFixture.st_ino == fixture.st_ino
            && finalImage.st_dev == image.st_dev && finalImage.st_ino == image.st_ino
            && finalImage.st_size == image.st_size && finalImage.st_nlink == image.st_nlink
    }

    private static func matches(_ leaf: Leaf, session: DASession) -> Bool {
        guard let disk = leaf.device.withCString({ DADiskCreateFromBSDName(kCFAllocatorDefault, session, $0) }),
              mediaID(disk) == leaf.mediaID,
              let description = DADiskCopyDescription(disk) as NSDictionary?,
              let rawUUID = description[kDADiskDescriptionVolumeUUIDKey],
              CFGetTypeID(rawUUID as CFTypeRef) == CFUUIDGetTypeID() else { return false }
        let checkedUUID = rawUUID as! CFUUID // Native type checked above.
        guard let uuid = UUID(uuidString: CFUUIDCreateString(nil, checkedUUID) as String),
              uuid == leaf.volumeUUID,
              description[kDADiskDescriptionVolumeNameKey] as? String == leaf.name,
              (description[kDADiskDescriptionVolumePathKey] as? URL)?.standardizedFileURL == leaf.mount
        else { return false }
        return true
    }

    private static func mediaID(_ disk: DADisk) -> UInt64? {
        let media = DADiskCopyIOMedia(disk)
        guard media != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(media) }
        var value: UInt64 = 0
        return IORegistryEntryGetRegistryEntryID(media, &value) == KERN_SUCCESS ? value : nil
    }

    private static func attachment(root: URL) -> [String: Any]? {
        guard let data = readOnlyPlist("/usr/bin/hdiutil", ["info", "-plist"]),
              let value = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let images = value["images"] as? [[String: Any]] else { return nil }
        let matches = images.filter { $0["image-path"] as? String == root.appendingPathComponent("fixture.dmg").path }
        guard matches.count == 1, matches[0]["owner-uid"] as? Int == Int(geteuid()) else { return nil }
        return matches[0]
    }

    /// Read-only hdiutil output stays in memory and is bounded. A hung inquiry
    /// can be signalled; mutation children are never sent through this path.
    private static func readOnlyPlist(_ executable: String, _ arguments: [String]) -> Data? {
        let child = Process(), pipe = Pipe()
        child.executableURL = URL(fileURLWithPath: executable)
        child.arguments = arguments
        child.environment = ["LANG": "C", "LC_ALL": "C"]
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = pipe
        child.standardError = FileHandle.nullDevice
        do { try child.run() } catch { return nil }
        let descriptor = pipe.fileHandleForReading.fileDescriptor
        var bytes = Data(), eof = false
        let deadline = ProcessInfo.processInfo.systemUptime + 20
        while !eof && ProcessInfo.processInfo.systemUptime < deadline {
            var request = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let ready = Darwin.poll(&request, 1, 100)
            if ready < 0 { if errno == EINTR { continue }; break }
            if ready == 0 { continue }
            guard request.revents & Int16(POLLIN | POLLHUP | POLLERR | POLLNVAL) != 0 else { continue }
            var buffer = [UInt8](repeating: 0, count: 16_384)
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
            if count < 0 { break }
            if count == 0 { eof = true; break }
            if bytes.count + count > (2 << 20) { break }
            bytes.append(contentsOf: buffer.prefix(count))
        }
        if !eof && child.isRunning {
            child.terminate()
            let stopDeadline = ProcessInfo.processInfo.systemUptime + 2
            while child.isRunning && ProcessInfo.processInfo.systemUptime < stopDeadline { usleep(10_000) }
            if child.isRunning { Darwin.kill(child.processIdentifier, SIGKILL) }
        }
        try? pipe.fileHandleForReading.close()
        child.waitUntilExit()
        return eof && child.terminationReason == .exit && child.terminationStatus == 0 ? bytes : nil
    }
}

func apfsOwnerMarkerCurrent(root: URL, jobID: UUID) -> Bool {
    let fd = open(root.appendingPathComponent("owner.json").path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    var before = stat(), after = stat()
    guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
          before.st_uid == geteuid(), before.st_nlink == 1, (1...512).contains(before.st_size) else { return false }
    var bytes = Data(count: Int(before.st_size))
    let count = bytes.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
    guard count == bytes.count, fstat(fd, &after) == 0,
          before.st_dev == after.st_dev, before.st_ino == after.st_ino,
          before.st_size == after.st_size,
          let value = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
          Set(value.keys) == Set(["jobID", "bytes"]),
          value["jobID"] as? String == jobID.uuidString,
          value["bytes"] as? Int == (1 << 30) else { return false }
    return true
}

/// Fixed, exclusive, fsynced generated-image receipts. Intent is written
/// before the destructive request; submitted is written inside its callback.
private final class APFSFormatEvidence: @unchecked Sendable {
    private let descriptor: Int32
    private let lock = NSLock()
    private var addAttempts = 0, addWritten = false
    private var submitAttempts = 0, submittedWritten = false
    var addRecorded: Bool { lock.withLock { addAttempts == 1 && addWritten } }
    var submittedRecorded: Bool { lock.withLock { submitAttempts == 1 && submittedWritten } }

    init(output: URL) throws {
        let fd = open(output.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw GeneratedAPFSFormatFailure(message: "Generated Format evidence root unavailable") }
        descriptor = fd
    }
    deinit { close(descriptor) }

    func recordAddSubmission() {
        lock.withLock {
            addAttempts += 1
            guard addAttempts == 1 else { addWritten = false; return }
            addWritten = (try? write(["phase": "submitted", "request": "one-apfs-volume-add"],
                                     leaf: "apfs-add-submitted.json")) != nil
        }
    }

    func recordSubmission() {
        lock.withLock {
            submitAttempts += 1
            guard submitAttempts == 1 else { submittedWritten = false; return }
            submittedWritten = (try? write(["phase": "submitted", "request": "one-apfs-volume-erase"],
                                           leaf: "apfs-format-submitted.json")) != nil
        }
    }

    func write(_ object: [String: Any], leaf: String) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard data.count <= 4096 else { throw GeneratedAPFSFormatFailure(message: "Generated Format evidence exceeds its limit") }
        let file = openat(descriptor, leaf, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard file >= 0 else { throw GeneratedAPFSFormatFailure(message: "Generated Format evidence leaf refused") }
        defer { close(file) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                guard let base = bytes.baseAddress else { throw GeneratedAPFSFormatFailure(message: "Generated Format evidence write refused") }
                let count = Darwin.write(file, base.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw GeneratedAPFSFormatFailure(message: "Generated Format evidence write failed") }
                offset += count
            }
        }
        guard fsync(file) == 0, fsync(descriptor) == 0 else {
            throw GeneratedAPFSFormatFailure(message: "Generated Format evidence sync failed")
        }
    }
}
#endif
