import AppKit
import Darwin
import ExplorerCore
import LocalStorage

#if TRAVERSE_DRIVE_IMAGE_QA && MAC_EXPLORER_DISTRIBUTION && !DEBUG
/// The signed role has no browser or ordinary file-operation engine. Its warm
/// work calls the existing APFS owners only after an exact generated witness.
@MainActor
enum SignedDriveImageVerification {
    private static func require(_ value: Bool, _ message: String) throws {
        if !value { throw GeneratedAPFSFormatFailure(message: message) }
    }

    private static func write(_ fields: [String: Any], leaf: String,
                              selection: GeneratedDriveImageReview.Selection) throws {
        let evidence = selection.caseRoot.appendingPathComponent("evidence", isDirectory: true)
        guard GeneratedSignedReviewAdmission.ownedDirectory(evidence, privateMode: true),
              let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]),
              data.count <= 4096 else { throw GeneratedAPFSFormatFailure(message: "Drive evidence root refused") }
        let parent = open(evidence.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw GeneratedAPFSFormatFailure(message: "Drive evidence directory unavailable") }
        defer { close(parent) }
        let file = openat(parent, leaf, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard file >= 0 else { throw GeneratedAPFSFormatFailure(message: "Drive evidence leaf refused") }
        defer { close(file) }
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { throw GeneratedAPFSFormatFailure(message: "Drive evidence empty") }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(file, base.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw GeneratedAPFSFormatFailure(message: "Drive evidence write failed") }
                offset += count
            }
        }
        guard fsync(file) == 0, fsync(parent) == 0 else {
            throw GeneratedAPFSFormatFailure(message: "Drive evidence sync failed")
        }
    }

    private static func preImage(_ selected: GeneratedDriveImageReview.Selection) async throws {
        let fixture = selected.fixtureRoot
        try require(selected.formatCompletionContract == selected.caseMode.completionContract,
                    "Pre-image Format completion contract differs")
        guard let jobID = UUID(uuidString: selected.caseID) else {
            throw GeneratedAPFSFormatFailure(message: "Pre-image case identity refused")
        }
        var root = stat(), image = stat()
        try require(lstat(fixture.path, &root) == 0 && root.st_mode & S_IFMT == S_IFDIR
                    && root.st_uid == geteuid()
                    && apfsOwnerMarkerCurrent(root: fixture, jobID: jobID),
                    "Pre-image generated owner refused")
        try require(lstat(fixture.appendingPathComponent("fixture.dmg").path, &image) == -1
                    && errno == ENOENT, "Pre-image fixture already contains an image")
        guard let state = AppStorageLocations.stateDirectory,
              state.standardizedFileURL == selected.stateDirectory.standardizedFileURL,
              let store = NativeDriveJobStore.applicationStore() else {
            throw GeneratedAPFSFormatFailure(message: "Pre-image private job store unavailable")
        }
        let before = try await store.load()
        let operations = ApplicationOperationCoordinator.shared
        let drives = ApplicationVolumeCoordinator(operations: operations, backend: VolumeLifecycle.shared)
        await drives.waitForNativeDriveJobLoad()
        try require(drives.nativeFormatSavedJobIsClean(), "A prior or unreadable drive job blocks image creation")
        let after = try await store.load()
        try require(before.bytes == after.bytes && before.record == after.record,
                    "Pre-image saved job changed during passive admission")
        try require(lstat(fixture.appendingPathComponent("fixture.dmg").path, &image) == -1
                    && errno == ENOENT, "Pre-image fixture changed during saved-job admission")
        try write(["passed": true, "cleanAdmission": true, "imageAbsent": true,
                   "recorderCreated": false, "jobUnchanged": true],
                  leaf: "drive-image-pre-image-review.json", selection: selected)
    }

    private static func observed(_ drives: ApplicationVolumeCoordinator,
                                 receipt: GeneratedAPFSReceipt) async throws -> ManagedVolume {
        let deadline = ContinuousClock.now + .seconds(120)
        while ContinuousClock.now < deadline {
            let matches = drives.volumes.filter {
                $0.mediaID == receipt.mediaID && $0.group == receipt.outerMediaID
                    && $0.url?.path == receipt.initialMount && $0.fileSystemID == receipt.mountDevice
                    && $0.deviceKind == .diskImage && $0.volumeUUID != nil
            }
            if matches.count == 1 { return matches[0] }
            if matches.count > 1 { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw GeneratedAPFSFormatFailure(message: "Exact generated mounted member unavailable")
    }

    private static func imageReceipt(_ selected: GeneratedDriveImageReview.Selection) throws -> GeneratedAPFSReceipt {
        let receipt = try GeneratedAPFSFormatVerification.readReceipt(
            selected.caseRoot.appendingPathComponent("evidence", isDirectory: true))
        var fixture = stat(), image = stat(), mount = stat()
        let imageURL = selected.fixtureRoot.appendingPathComponent("fixture.dmg")
        let mountURL = URL(fileURLWithPath: receipt.initialMount, isDirectory: true)
        try require(receipt.version == 3 && receipt.jobID.uuidString == selected.caseID
                    && !receipt.startsUnmounted && receipt.mediaID != 0 && receipt.outerMediaID != 0
                    && mountURL.standardizedFileURL.path == receipt.initialMount
                    && mountURL.deletingLastPathComponent().path == "/Volumes"
                    && lstat(selected.fixtureRoot.path, &fixture) == 0
                    && fixture.st_mode & S_IFMT == S_IFDIR && fixture.st_uid == geteuid()
                    && Int64(fixture.st_dev) == receipt.fixtureDevice && fixture.st_ino == receipt.fixtureInode
                    && lstat(imageURL.path, &image) == 0 && image.st_mode & S_IFMT == S_IFREG
                    && image.st_uid == geteuid() && image.st_nlink == 1 && image.st_size == off_t(1 << 30)
                    && Int64(image.st_dev) == receipt.imageDevice && image.st_ino == receipt.imageInode
                    && lstat(receipt.initialMount, &mount) == 0 && mount.st_mode & S_IFMT == S_IFDIR
                    && Int64(mount.st_dev) == receipt.mountDevice && mount.st_dev != fixture.st_dev
                    && apfsOwnerMarkerCurrent(root: selected.fixtureRoot, jobID: receipt.jobID),
                    "Signed generated image receipt refused")
        return receipt
    }

    private static func imagePhase(_ selected: GeneratedDriveImageReview.Selection) async throws {
        try require(selected.formatCompletionContract == selected.caseMode.completionContract,
                    "Signed Format completion contract differs")
        let receipt = try imageReceipt(selected)
        let operations = ApplicationOperationCoordinator.shared
        let previous = operations.drives
        let drives = ApplicationVolumeCoordinator(operations: operations, backend: VolumeLifecycle.shared)
        operations.drives = drives
        drives.startDiscovery()
        defer { if !drives.isBusy { operations.drives = previous } }
        let initial = try await observed(drives, receipt: receipt)
        switch selected.phase {
        case .warm:
            try require(GeneratedDriveImageReview.warmAdmitted
                        && AppFeatureAvailability.allows(.apfsVolumeCreation),
                        "Warm generated APFS mutation held")
            _ = try await GeneratedAPFSFormatVerification.warm(operations: operations, drives: drives,
                initial: initial, receipt: receipt, fixture: selected.fixtureRoot,
                output: selected.caseRoot.appendingPathComponent("evidence", isDirectory: true))
        case .cold:
            try require(GeneratedDriveImageReview.coldAdmitted
                        && ProductCapabilities.Feature.allCases.allSatisfy({ !AppFeatureAvailability.allows($0) }),
                        "Cold generated APFS mutation unexpectedly available")
            _ = try await GeneratedAPFSFormatVerification.cold(drives: drives,
                initial: initial, receipt: receipt, fixture: selected.fixtureRoot,
                output: selected.caseRoot.appendingPathComponent("evidence", isDirectory: true))
        case .preImage:
            throw GeneratedAPFSFormatFailure(message: "Pre-image visit cannot enter mounted sequence")
        }
        try require(!drives.isBusy && operations.activeOwner == nil
                    && ApplicationFileActivity.gate.activeCount == 0,
                    "Generated APFS owner did not drain")
    }

    static func run(selection: GeneratedDriveImageReview.Selection) async {
        var stage = "admission"
        do {
            try require(GeneratedDriveImageReview.admitted && !TraverseAccessPolicy.requiresFolderSelection,
                        "Signed drive role unavailable")
            switch selection.phase {
            case .preImage:
                stage = "passive-job-admission"
                try await preImage(selection)
            case .warm, .cold:
                stage = selection.phase == .warm ? "generated-add-and-format" : "native-completion-inspection"
                try await imagePhase(selection)
            }
            stage = "completed"
            try write(["passed": true, "phase": selection.phase.rawValue, "stage": stage,
                       "pid": getpid()],
                      leaf: "drive-image-" + selection.phase.rawValue + "-result.json", selection: selection)
        } catch {
            let code = (error as? GeneratedAPFSFormatFailure)?.message ?? "generated-drive-refused"
            try? write(["passed": false, "phase": selection.phase.rawValue, "stage": stage,
                        "refusal": code, "pid": getpid()],
                       leaf: "drive-image-" + selection.phase.rawValue + "-result.json", selection: selection)
        }
        // A submitted native child cannot be withdrawn by app termination.
        // If an unexpected owner remains, leave this process for inspection.
        let operations = ApplicationOperationCoordinator.shared
        if operations.activeOwner != nil || operations.drives.isBusy
            || ApplicationFileActivity.gate.activeCount != 0 { return }
        NSApp.terminate(nil)
    }
}
#endif
