import AppKit
import Darwin
import DiskArbitration
import ExplorerCore
import Foundation
import IOKit
@_spi(Qualification) import LocalStorage

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
        var activity: (any Sendable)?
        do { activity = try ApplicationFileActivity.beginOperation() }
        catch { operations.finish(owner: owner); throw error }
        var addOwnerHeld = true
        defer {
            withExtendedLifetime(activity) {}
            activity = nil
            if addOwnerHeld { operations.finish(owner: owner) }
        }
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
        #if TRAVERSE_DRIVE_IMAGE_QA
        if let selected = GeneratedDriveImageReview.selection, selected.caseMode == .ordinaryV3 {
            // The ordinary model's inspection and barrier reject an active Add
            // owner. The native Add has returned and discovery/markers settled.
            withExtendedLifetime(activity) {}
            activity = nil
            operations.finish(owner: owner)
            addOwnerHeld = false
            try require(operations.activeOwner == nil && ApplicationFileActivity.gate.activeCount == 0,
                        "Generated Add owner or activity remained before ordinary Format review")
            return try await warmOrdinaryV3(operations: operations, drives: drives,
                initial: initial, target: target, receipt: receipt, fixture: fixture,
                evidence: evidence, originalMarker: originalMarker, originalLeaf: originalLeaf,
                formatSeal: formatSeal, targetMarker: markerBefore, mountedBefore: mountedBefore,
                addedName: addedName, addedID: added.id)
        }
        #endif
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
        #if TRAVERSE_DRIVE_IMAGE_QA
        try require(recording.completionPolicy == .sourceQualification,
                    "Signed image review did not select observed-native-v2 recording")
        #else
        try require(recording.completionPolicy == .provisional,
                    "Development image review changed its provisional recording policy")
        #endif
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
                            "nativeCompletionReturned": formatted.nativeCompletion != nil,
                            "submissionReceipt": evidence.submittedRecorded], leaf: "apfs-format-terminal.json")
        await drives.reloadNativeDriveJobAfterRecording()
        #if TRAVERSE_DRIVE_IMAGE_QA
        try require(!formatted.submitted || drives.nativeDriveJobReady
                    && drives.nativeDriveJobIssue.isEmpty
                    && !drives.generatedFormatJobIsAdmissible(owner: generatedOwner),
                    "A completed signed Format job reopened the one-visit recorder gate")
        try require(drives.generatedFormatRecording(owner: generatedOwner,
                    attachmentCurrent: { formatSeal.imageAndOuterCurrent() }) == nil,
                    "A second signed Format recorder was issued in one visit")
        #else
        try require(!formatted.submitted || !drives.generatedFormatJobIsAdmissible(owner: generatedOwner)
                    && !drives.nativeDriveJobIssue.isEmpty,
                    "A submitted unresolved Format job remained clean in its warm coordinator")
        #endif
        try require(!formatted.submitted || evidence.submittedRecorded,
                    "Generated APFS Format submission receipt was not durable")
        guard let newVolume = formatted.formatted else {
            throw GeneratedAPFSFormatFailure(message: "Generated APFS Format ended without an exact reconciled member")
        }
        try require(formatted.submitted && formatted.failure == nil && newVolume.id != added.id
                    && newVolume.name == addedName && formatted.toolExitStatus == 0,
                    "Generated APFS Format postcondition was not established")
        let durable = try await recording.store.load()
        guard let savedJob = durable.record, savedJob.id == recording.jobID,
              savedJob.replacementID == newVolume.id else {
            throw GeneratedAPFSFormatFailure(message: "Generated APFS Format durable job identity changed")
        }
        #if TRAVERSE_DRIVE_IMAGE_QA
        try require(savedJob.version == 2 && savedJob.phase == .observedNativeCompletion
                    && savedJob.isUnresolved == false && savedJob.validate()
                    && formatted.nativeCompletion != nil
                    && savedJob.nativeCompletion == formatted.nativeCompletion
                    && savedJob.nativeCompletion?.validates(savedJob.snapshot) == true,
                    "Signed APFS Format lacks its exact durable native completion")
        #else
        try require(savedJob.version == 1 && savedJob.phase == .compatibleReplacement
                    && savedJob.isUnresolved == true && savedJob.nativeCompletion == nil
                    && formatted.nativeCompletion == nil,
                    "Generated APFS Format result lacks an unresolved durable job")
        #endif
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
        var finalEvidence: [String: Any] = ["passed": true, "submitted": true, "jobID": recording.jobID.uuidString,
                            "siblingUUID": initial.volumeUUID!.uuidString,
                            "siblingDevice": originalLeaf.device, "siblingMarkerInode": originalMarker.inode,
                            "formattedUUID": newVolume.id.uuidString,
                            "formattedName": newVolume.name, "outerDevice": "/dev/" + afterSeal.outer,
                            "siblingMarkerPreserved": true, "targetMarkerRemoved": true,
                            "unrelatedMountsUnchanged": true]
        #if TRAVERSE_DRIVE_IMAGE_QA
        finalEvidence["completionContract"] = GeneratedDriveImageReview.completionContract
        finalEvidence["jobVersion"] = savedJob.version
        finalEvidence["nativeCompletionObserved"] = savedJob.nativeCompletion != nil
        #endif
        try evidence.write(finalEvidence, leaf: "apfs-format-result.json")
        return ["One owned generated APFS image and exact original member passed launch-boundary checks",
                "One Add and one Format drained; exact sibling survived and target marker disappeared",
                "Fresh native target and unrelated mounted identities reconciled without retry"]
    }

    #if TRAVERSE_DRIVE_IMAGE_QA
    /// Exercise the ordinary App model and v3 job slot for only the member
    /// returned by this signed visit's Add. Confirmation is programmatic here;
    /// the role has no browser sheet or physical typing gesture to claim.
    private static func warmOrdinaryV3(operations: ApplicationOperationCoordinator,
                                      drives: ApplicationVolumeCoordinator,
                                      initial: ManagedVolume, target: ManagedVolume,
                                      receipt: GeneratedAPFSReceipt, fixture: URL,
                                      evidence: APFSFormatEvidence,
                                      originalMarker: MarkerIdentity,
                                      originalLeaf: APFSFormatImageSeal.Leaf,
                                      formatSeal: APFSFormatImageSeal,
                                      targetMarker: MarkerIdentity,
                                      mountedBefore: Set<MountID>,
                                      addedName: String, addedID: UUID) async throws -> [String] {
        guard let selected = GeneratedDriveImageReview.selection,
              selected.caseMode == .ordinaryV3, selected.phase == .warm,
              !NativeAPFSFormatFeature.ordinaryEnabled else {
            throw GeneratedAPFSFormatFailure(message: "Ordinary v3 signed case is unavailable")
        }
        try require(operations.activeOwner == nil && ApplicationFileActivity.gate.activeCount == 0,
                    "Add still owns operation activity before Format model review")
        let identity = GeneratedDriveImageReview.FormatReceiptIdentity(
            version: receipt.version, jobID: receipt.jobID,
            fixtureDevice: receipt.fixtureDevice, fixtureInode: receipt.fixtureInode,
            imageDevice: receipt.imageDevice, imageInode: receipt.imageInode,
            originalMediaID: receipt.mediaID, outerMediaID: receipt.outerMediaID,
            outerDevice: formatSeal.outer)
        try require(GeneratedDriveImageReview.armSignedFormatTarget(selection: selected,
            receipt: identity, addedID: addedID, target: target,
            current: { formatSeal.current() }),
            "Signed v3 target was not exactly admitted")
        let model = ApplicationAPFSVolumeFormat()
        model.configure(target: target, operations: operations, changed: {},
                        signedSubmitted: { evidence.recordSubmission() })
        defer { model.dismiss() }
        try require(model.canReview && drives.canReviewOrdinaryFormat(target),
                    "Signed v3 target did not enter the ordinary review gate")
        model.review()
        await model.drain()
        guard let plan = model.plan else {
            throw GeneratedAPFSFormatFailure(message: "Ordinary Format model did not prepare the attached image")
        }
        try require(plan.name == addedName && plan.selected == target
                    && plan.siblingNames == [initial.name],
                    "Ordinary Format model reviewed a different APFS member")
        model.confirmedName = addedName
        try require(model.canSubmit, "Ordinary Format model did not bind exact confirmation")
        try evidence.write(["phase": "intent", "request": "one-apfs-volume-erase",
                            "model": "ordinary-v3", "imageInode": receipt.imageInode,
                            "siblingUUID": initial.volumeUUID!.uuidString,
                            "targetUUID": addedID.uuidString,
                            "targetMarkerInode": targetMarker.inode], leaf: "apfs-format-intent.json")
        model.format()
        await model.drain()
        let completed = model.result
        try evidence.write(["submitted": completed?.submitted ?? false,
                            "formattedUUID": completed?.formatted?.id.uuidString ?? "none",
                            "failure": completed?.failure.map { String(describing: $0) } ?? "none",
                            "status": completed?.toolExitStatus.map { Int($0) } as Any? ?? NSNull(),
                            "diskutilErrorCode": completed?.diskutilErrorCode as Any? ?? NSNull(),
                            "nativeCompletionReturned": completed?.nativeCompletion != nil,
                            "submissionReceipt": evidence.submittedRecorded],
                           leaf: "apfs-format-terminal.json")
        guard let completed, let newVolume = completed.formatted else {
            throw GeneratedAPFSFormatFailure(message: "Ordinary v3 Format model did not reconcile a member")
        }
        try require(completed.submitted && completed.failure == nil && evidence.submittedRecorded
                    && newVolume.id != addedID && newVolume.name == addedName
                    && completed.toolExitStatus == 0 && completed.nativeCompletion != nil,
                    "Ordinary v3 Format postcondition or submitted receipt is missing")
        guard let store = NativeDriveJobStore.applicationStore() else {
            throw GeneratedAPFSFormatFailure(message: "Ordinary v3 durable job store is unavailable")
        }
        let durable = try await store.load()
        guard let saved = durable.record, let owner = saved.ordinaryImageOwner else {
            throw GeneratedAPFSFormatFailure(message: "Ordinary v3 job is not durably saved")
        }
        try require(saved.version == 3 && saved.owner == nil
                    && saved.phase == .observedNativeCompletion && !saved.isUnresolved
                    && saved.validate() && saved.snapshot.targetID == addedID
                    && saved.replacementID == newVolume.id
                    && saved.nativeCompletion == completed.nativeCompletion
                    && saved.nativeCompletion?.validates(saved.snapshot) == true
                    && GeneratedDriveImageReview.signedFormatTargetClaimed(owner: owner)
                    && drives.nativeDriveJobReady && drives.nativeDriveJobIssue.isEmpty
                    && !drives.canReviewOrdinaryFormat(target),
                    "Ordinary v3 Format did not finish in the exact one-use job slot")
        try await until("Ordinary formatted two-member discovery") {
            let members = drives.volumes.filter { $0.group == receipt.outerMediaID && $0.volumeUUID != nil }
            return members.count == 2 && members.contains(where: { $0.volumeUUID == newVolume.id && $0.url != nil })
        }
        let currentSibling = try await observed(drives) {
            $0.volumeUUID == initial.volumeUUID && $0.group == receipt.outerMediaID
        }
        let currentTarget = try await observed(drives) {
            $0.volumeUUID == newVolume.id && $0.group == receipt.outerMediaID
        }
        let siblingMarkerAfter = try await verifyMarker(currentSibling, receipt: receipt)
        try require(currentSibling.mediaID == initial.mediaID
                    && currentSibling.url == initial.url
                    && currentSibling.fileSystemID == initial.fileSystemID
                    && currentSibling.name == initial.name
                    && siblingMarkerAfter == originalMarker,
                    "Ordinary v3 Format changed the original sibling or marker")
        try require(newVolume.mountPoint?.standardizedFileURL == currentTarget.url?.standardizedFileURL
                    && currentTarget.name == addedName && currentTarget.deviceKind == .diskImage,
                    "Ordinary v3 formatted target is not the expected mounted member")
        try await requireFormatTargetMarkerAbsent(currentTarget, fixture: fixture)
        try require(formatSeal.imageAndOuterCurrent(),
                    "Ordinary v3 backing image or outer attachment changed")
        let mountedAfter = try await mountedDeviceIDs(excluding: currentTarget.url)
        try require(mountedBefore == mountedAfter, "Other mounted devices changed during ordinary v3 Format")
        let currentInspection = try await VolumeLifecycle.shared.inspect(currentTarget)
        let currentLeaf = try APFSFormatImageSeal.Leaf(currentTarget, currentInspection)
        let afterSeal = try APFSFormatImageSeal(root: fixture, receipt: receipt,
                                                original: originalLeaf, target: currentLeaf)
        try require(afterSeal.current() && afterSeal.outer == formatSeal.outer,
                    "Ordinary v3 target is not bound to the original generated image")
        try evidence.write(["passed": true, "submitted": true,
                            "model": "ApplicationAPFSVolumeFormat", "typedGestureClaimed": false,
                            "ordinaryEnabled": false, "jobID": saved.id.uuidString,
                            "jobVersion": saved.version,
                            "completionContract": selected.formatCompletionContract,
                            "nativeCompletionObserved": true,
                            "siblingUUID": initial.volumeUUID!.uuidString,
                            "siblingDevice": originalLeaf.device,
                            "siblingMarkerInode": originalMarker.inode,
                            "formattedUUID": newVolume.id.uuidString,
                            "formattedName": newVolume.name,
                            "outerDevice": "/dev/" + afterSeal.outer,
                            "siblingMarkerPreserved": true,
                            "targetMarkerRemoved": true,
                            "unrelatedMountsUnchanged": true],
                           leaf: "apfs-format-result.json")
        return ["Exact generated Add owner released before ordinary App model inspection and barrier",
                "One-use v3 App model Format completed with native result and durable completion",
                "Original sibling, target marker and unrelated mounts reconciled independently"]
    }
    #endif

    /// A second process reads the exact saved job from disk. The signed v2
    /// visit observes completion without gaining any mutation capability;
    /// Development preserves its unresolved v1 recovery comparison.
    static func cold(drives: ApplicationVolumeCoordinator, initial: ManagedVolume,
                                       receipt: GeneratedAPFSReceipt, fixture: URL, output: URL) async throws -> [String] {
        guard !receipt.startsUnmounted, initial.deviceKind == .diskImage, let siblingID = initial.volumeUUID else {
            throw GeneratedAPFSFormatFailure(message: "Cold Format review requires the mounted generated sibling")
        }
        #if TRAVERSE_DRIVE_IMAGE_QA
        if GeneratedDriveImageReview.selection?.caseMode == .ordinaryV3 {
            return try await coldOrdinaryV3(drives: drives, initial: initial,
                                            receipt: receipt, fixture: fixture, output: output)
        }
        #endif
        let owner = formatOwner(receipt: receipt, fixture: fixture)
        guard owner.validate(), let store = NativeDriveJobStore.applicationStore() else {
            throw GeneratedAPFSFormatFailure(message: "Cold Format durable job store is unavailable")
        }
        let before = try await store.load()
        guard let record = before.record, let replacementID = record.replacementID,
              record.owner == owner,
              record.snapshot.targetID != siblingID, replacementID != siblingID,
              record.snapshot.members.count == 2,
              record.snapshot.members.contains(where: { $0.uuid == siblingID && $0.name == initial.name }) else {
            throw GeneratedAPFSFormatFailure(message: "Cold Format job is not the exact generated request")
        }
        #if TRAVERSE_DRIVE_IMAGE_QA
        try require(record.version == 2 && record.phase == .observedNativeCompletion
                    && !record.isUnresolved && record.validate()
                    && record.nativeCompletion?.replacementID == replacementID
                    && record.nativeCompletion?.validates(record.snapshot) == true,
                    "Cold signed Format job lacks its durable native completion")
        #else
        try require(record.version == 1 && record.phase == .compatibleReplacement
                    && record.isUnresolved && record.nativeCompletion == nil,
                    "Cold Development Format job is not the unresolved v1 request")
        #endif
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
        #if TRAVERSE_DRIVE_IMAGE_QA
        try require(drives.nativeDriveJobReady && drives.nativeDriveJobIssue.isEmpty
                    && ProductCapabilities.Feature.allCases.allSatisfy({ !AppFeatureAvailability.allows($0) }),
                    "Cold signed Format visit gained a mutation capability")
        #else
        try require(!drives.nativeDriveJobReady && !drives.nativeDriveJobIssue.isEmpty,
                    "Cold unresolved Format job did not close coordinator admission")
        #endif
        try require(!drives.generatedFormatJobIsAdmissible(owner: owner),
                    "Cold Format visit opened the recorder gate")
        let compatible = try await store.inspectUnresolvedCompatibleReplacement(owner: owner,
            backend: APFSVolumeFormat(), ownerStillCurrent: { seal.current() })
        let after = try await store.load()
        try require(after.bytes == before.bytes && after.record == record && seal.current()
                    && !drives.generatedFormatJobIsAdmissible(owner: owner),
                    "Cold Format inspection changed the job or reopened admission")
        #if TRAVERSE_DRIVE_IMAGE_QA
        let siblingMarkerFinal = try await verifyMarker(initial, receipt: receipt)
        try require(!compatible && ProductCapabilities.Feature.allCases.allSatisfy({ !AppFeatureAvailability.allows($0) })
                    && siblingMarkerFinal == siblingMarkerAfter,
                    "Cold signed Format inspection changed marker or admitted a capability")
        try await requireFormatTargetMarkerAbsent(target, fixture: fixture)
        let result: [String: Any] = ["passed": true, "jobID": record.id.uuidString,
            "completionContract": GeneratedDriveImageReview.completionContract,
            "resolvedNativeCompletion": true, "admissionHeld": true,
            "recordUnchanged": true, "unresolvedPromotion": false,
            "allMutationCapabilitiesHeld": true, "siblingMarkerPreserved": true,
            "targetMarkerAbsent": true]
        try APFSFormatEvidence(output: output).write(result, leaf: "apfs-format-cold-result.json")
        return ["Separate read-only signed visit loaded the exact v2 native completion without mutation authority",
                "Sibling and target markers reconciled independently; cold inspection left the durable record unchanged"]
        #else
        try require(!drives.nativeDriveJobReady, "Cold unresolved Format job became clean")
        let result: [String: Any] = ["passed": true, "jobID": record.id.uuidString,
            "unresolved": true, "admissionHeld": true, "recordUnchanged": true,
            "compatibleInspection": compatible]
        try APFSFormatEvidence(output: output).write(result, leaf: "apfs-format-cold-result.json")
        return ["Separate read-only app launch loaded the exact unresolved generated Format job",
                "Coordinator held the recorder gate and inspection preserved the durable record"]
        #endif
    }

    #if TRAVERSE_DRIVE_IMAGE_QA
    /// Cold v3 reads the exact ordinary image owner and completed slot. It
    /// performs no recovery promotion, recorder creation or native mutation.
    private static func coldOrdinaryV3(drives: ApplicationVolumeCoordinator,
                                       initial: ManagedVolume, receipt: GeneratedAPFSReceipt,
                                       fixture: URL, output: URL) async throws -> [String] {
        guard let selected = GeneratedDriveImageReview.selection,
              selected.caseMode == .ordinaryV3, selected.phase == .cold,
              let siblingID = initial.volumeUUID,
              let store = NativeDriveJobStore.applicationStore(),
              !NativeAPFSFormatFeature.ordinaryEnabled else {
            throw GeneratedAPFSFormatFailure(message: "Cold v3 signed image review is unavailable")
        }
        let before = try await store.load()
        guard let record = before.record, let owner = record.ordinaryImageOwner,
              let replacementID = record.replacementID else {
            throw GeneratedAPFSFormatFailure(message: "Cold v3 ordinary job is absent")
        }
        try require(record.version == 3 && record.owner == nil
                    && record.phase == .observedNativeCompletion && !record.isUnresolved
                    && record.validate() && owner.validate()
                    && owner.imagePath == fixture.appendingPathComponent("fixture.dmg").path
                    && owner.parentDevice == receipt.fixtureDevice
                    && owner.parentInode == receipt.fixtureInode
                    && owner.imageDevice == receipt.imageDevice
                    && owner.imageInode == receipt.imageInode
                    && owner.imageBytes == (1 << 30)
                    && owner.ownerUID == geteuid()
                    && owner.outerMediaID == receipt.outerMediaID
                    && APFSAttachedImageWitness.backingFileCurrent(owner)
                    && record.snapshot.targetID != siblingID
                    && replacementID != siblingID
                    && record.snapshot.members.count == 2
                    && record.snapshot.members.contains(where: {
                        $0.uuid == siblingID && $0.name == initial.name
                    })
                    && record.nativeCompletion?.replacementID == replacementID
                    && record.nativeCompletion?.validates(record.snapshot) == true,
                    "Cold v3 job is not the exact completed generated image request")
        let siblingMarker = try await verifyMarker(initial, receipt: receipt)
        let siblingInspection = try await VolumeLifecycle.shared.inspect(initial)
        let siblingLeaf = try APFSFormatImageSeal.Leaf(initial, siblingInspection)
        let target = try await observed(drives) {
            $0.volumeUUID == replacementID && $0.group == receipt.outerMediaID && $0.url != nil
        }
        let members = drives.volumes.filter { $0.group == receipt.outerMediaID && $0.volumeUUID != nil }
        try require(members.count == 2
                    && Set(members.compactMap(\.volumeUUID)) == Set([siblingID, replacementID]),
                    "Cold v3 image graph is not the exact two-member container")
        let targetInspection = try await VolumeLifecycle.shared.inspect(target)
        let targetLeaf = try APFSFormatImageSeal.Leaf(target, targetInspection)
        let seal = try APFSFormatImageSeal(root: fixture, receipt: receipt,
                                            original: siblingLeaf, target: targetLeaf)
        let siblingMarkerAfter = try await verifyMarker(initial, receipt: receipt)
        try require(seal.current() && seal.outer == owner.outerDevice
                    && siblingMarker == siblingMarkerAfter,
                    "Cold v3 image or sibling marker changed")
        try await requireFormatTargetMarkerAbsent(target, fixture: fixture)
        await drives.waitForNativeDriveJobLoad()
        try require(drives.nativeDriveJobReady && drives.nativeDriveJobIssue.isEmpty
                    && ProductCapabilities.Feature.allCases.allSatisfy({ !AppFeatureAvailability.allows($0) })
                    && !GeneratedDriveImageReview.signedFormatTargetAvailable(target)
                    && !drives.canReviewOrdinaryFormat(target)
                    && !drives.generatedFormatJobIsAdmissible(owner: formatOwner(receipt: receipt,
                                                                                 fixture: fixture)),
                    "Cold v3 visit gained a Format or other mutation admission")
        let after = try await store.load()
        let siblingMarkerFinal = try await verifyMarker(initial, receipt: receipt)
        try require(after.bytes == before.bytes && after.record == record
                    && seal.current() && siblingMarkerFinal == siblingMarkerAfter,
                    "Cold v3 read changed the durable job or image")
        try await requireFormatTargetMarkerAbsent(target, fixture: fixture)
        try APFSFormatEvidence(output: output).write([
            "passed": true, "jobID": record.id.uuidString,
            "completionContract": selected.formatCompletionContract,
            "jobVersion": 3, "resolvedNativeCompletion": true,
            "admissionHeld": true, "recordUnchanged": true,
            "unresolvedPromotion": false, "allMutationCapabilitiesHeld": true,
            "siblingMarkerPreserved": true, "targetMarkerAbsent": true,
            "ordinaryEnabled": false], leaf: "apfs-format-cold-result.json")
        return ["Cold signed visit loaded exact v3 ordinary image completion without mutation authority",
                "Sibling and target markers reconciled; durable job bytes remained unchanged"]
    }
    #endif

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
        guard let attachment = Self.attachment(root: root) else {
            throw GeneratedAPFSFormatFailure(message: "Generated image attachment is unavailable")
        }
        outer = attachment.outer
        guard current() else { throw GeneratedAPFSFormatFailure(message: "Generated image ownership changed before review") }
    }

    /// Called synchronously by the backend on its utility queue immediately
    /// before Process.run, after its own fresh selected-container observation.
    func current() -> Bool {
        guard imageAndOuterCurrent(requireTarget: true), let session = DASessionCreate(kCFAllocatorDefault),
              Self.matches(original, session: session) else { return false }
        return target.map { Self.matches($0, session: session) } ?? true
    }

    func imageAndOuterCurrent(requireTarget: Bool = false) -> Bool {
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
              attachment.outer == outer, attachment.devices.contains(original.device),
              !requireTarget || (target.map { attachment.devices.contains($0.device) } ?? true),
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

    private static func attachment(root: URL) -> (outer: String, devices: Set<String>)? {
        try? APFSAttachedImageWitness.observeSealedFixtureAttachment(root.appendingPathComponent("fixture.dmg"))
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
