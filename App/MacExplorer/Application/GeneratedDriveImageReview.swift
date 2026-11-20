import Darwin
import Foundation
import LocalStorage

/// A distinct nonshipping signed role for one generated APFS image. Selection
/// and a spent launch permit grant no mutation without the warm image witness.
enum GeneratedDriveImageReview {
    private static let identifierPrefix = "local.macexplorer.drive-image-v3.qa."
    static let completionContract = "observed-native-v2"
    static let ordinaryCompletionContract = "observed-native-v3"
    @MainActor private static var formatRecorderIssued = false
    @MainActor private static var signedFormatTarget: FormatTarget?
    @MainActor private static var signedFormatClaimedOwner: APFSVolumeFormatImageOwner?

    enum CaseMode: String, Sendable {
        case generatedV2 = "generated-v2"
        case ordinaryV3 = "ordinary-format-v3"

        var completionContract: String {
            switch self {
            case .generatedV2: GeneratedDriveImageReview.completionContract
            case .ordinaryV3: GeneratedDriveImageReview.ordinaryCompletionContract
            }
        }
        var permitPacket: String {
            self == .ordinaryV3 ? "drive-image-phase-permit-v4" : "drive-image-phase-permit-v3"
        }
        var scopePacket: String {
            self == .ordinaryV3 ? "drive-image-runtime-scope-v4" : "drive-image-runtime-scope-v3"
        }
    }

    private struct FormatTarget {
        let caseID: String
        let target: ManagedVolume
        let receipt: FormatReceiptIdentity
        let current: @Sendable () -> Bool
    }

    struct FormatReceiptIdentity: Sendable {
        let version: Int
        let jobID: UUID
        let fixtureDevice: Int64
        let fixtureInode: UInt64
        let imageDevice: Int64
        let imageInode: UInt64
        let originalMediaID: UInt64
        let outerMediaID: UInt64
        let outerDevice: String
    }

    struct SignedFormatGrant: Sendable {
        let current: @Sendable () -> Bool
    }

    enum Phase: String, Sendable {
        case preImage = "pre-image"
        case warm
        case cold
    }

    struct Selection: Sendable {
        let caseID: String
        let bundleID: String
        let caseRoot: URL
        let fixtureRoot: URL
        let stateDirectory: URL
        let phase: Phase
        let caseMode: CaseMode
        let formatCompletionContract: String
    }

    static let requested: Bool = {
        #if TRAVERSE_DRIVE_IMAGE_QA
        return true
        #else
        let info = Bundle.main.infoDictionary ?? [:]
        return info["TraverseDriveImageQualificationOnly"] != nil
            || info["TraverseDriveImageQualificationCase"] != nil
            || info["TraverseDriveImageQualificationRoot"] != nil
            || info["TraverseDriveImageArchitecture"] != nil
            || info["TraverseDriveImageCaseMode"] != nil
            || info["TraverseDriveImageCompletionContract"] != nil
            || Bundle.main.bundleIdentifier?.hasPrefix(identifierPrefix) == true
            || CommandLine.arguments.dropFirst().contains { $0.hasPrefix("--check-drive-image-qa") }
        #endif
    }()

    static let selection: Selection? = {
        #if TRAVERSE_DRIVE_IMAGE_QA && MAC_EXPLORER_DISTRIBUTION && !DEBUG
        let info = Bundle.main.infoDictionary ?? [:]
        guard let caseID = info["TraverseDriveImageQualificationCase"] as? String,
              UUID(uuidString: caseID)?.uuidString == caseID else { return nil }
        let bundleID = identifierPrefix + caseID.lowercased().replacingOccurrences(of: "-", with: "")
        let caseMode: CaseMode
        switch info["TraverseDriveImageCaseMode"] {
        case nil: caseMode = .generatedV2
        case let raw as String where raw == CaseMode.ordinaryV3.rawValue: caseMode = .ordinaryV3
        default: return nil
        }
        guard info["TraverseDriveImageQualificationOnly"] as? Bool == true,
              Bundle.main.bundleIdentifier == bundleID,
              info["MacExplorerDistributionChannel"] as? String == "qualification",
              info["MacExplorerAccessPolicy"] as? String == "local-user-v1",
              info["MacExplorerStorageMode"] as? String == "portable",
              info["TraverseDriveImageArchitecture"] as? String == "arm64",
              info["TraverseDriveImageCompletionContract"] as? String == caseMode.completionContract,
              info["MacExplorerReleasePurpose"] == nil,
              info["TraversePublicUpdaterVersion"] == nil,
              info["TraversePrivateUpdaterVersion"] == nil,
              CommandLine.arguments.count == 5,
              CommandLine.arguments[1] == "--verify-ui",
              CommandLine.arguments[2] == "--check-drive-image-qa",
              CommandLine.arguments[3] == "--phase",
              let phase = Phase(rawValue: CommandLine.arguments[4]) else { return nil }

        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let build = repository.appendingPathComponent(".build", isDirectory: true)
        let cases = build.appendingPathComponent("traverse-development", isDirectory: true)
        let fixtures = build.appendingPathComponent("fixtures", isDirectory: true)
        let root = cases.appendingPathComponent(caseID, isDirectory: true)
        let source = root.appendingPathComponent("source", isDirectory: true)
        let library = source.appendingPathComponent("Library", isDirectory: true)
        let evidence = root.appendingPathComponent("evidence", isDirectory: true)
        let fixture = fixtures.appendingPathComponent("drive-lifecycle-" + caseID, isDirectory: true)
        let app = root.appendingPathComponent("Products/Release/Mac Explorer.app", isDirectory: true)
        guard info["TraverseDriveImageQualificationRoot"] as? String == root.path,
              ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"] == root.path,
              repository.path == repository.standardizedFileURL.path,
              GeneratedSignedReviewAdmission.ownedDirectory(build),
              GeneratedSignedReviewAdmission.ownedDirectory(cases),
              GeneratedSignedReviewAdmission.ownedDirectory(fixtures),
              GeneratedSignedReviewAdmission.ownedDirectory(root, privateMode: true),
              GeneratedSignedReviewAdmission.ownedDirectory(source, privateMode: true),
              GeneratedSignedReviewAdmission.ownedDirectory(library, privateMode: true),
              GeneratedSignedReviewAdmission.ownedDirectory(evidence, privateMode: true),
              GeneratedSignedReviewAdmission.ownedDirectory(fixture, privateMode: true),
              Bundle.main.bundleURL.standardizedFileURL.path == app.path,
              Bundle.main.bundleURL.resolvingSymlinksInPath().path == app.path else { return nil }
        let state = library.appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent(bundleID, isDirectory: true)
        return Selection(caseID: caseID, bundleID: bundleID, caseRoot: root,
            fixtureRoot: fixture, stateDirectory: state, phase: phase,
            caseMode: caseMode, formatCompletionContract: caseMode.completionContract)
        #else
        return nil
        #endif
    }()

    static var admitted: Bool { selection != nil }
    static var warmAdmitted: Bool { selection?.phase == .warm }
    static var coldAdmitted: Bool { selection?.phase == .cold }
    @MainActor static var formatRecorderAvailable: Bool {
        warmAdmitted && selection?.caseMode == .generatedV2 && !formatRecorderIssued
    }
    @MainActor static func claimFormatRecorder() -> Bool {
        guard formatRecorderAvailable else { return false }
        formatRecorderIssued = true
        return true
    }

    /// The signed v4 route arms only the member returned by its one native Add.
    /// This is an App model admission, not a product feature switch or a grant
    /// to format another image. Its final predicate still checks the live seal.
    @MainActor static func armSignedFormatTarget(selection selected: Selection,
                                                 receipt: FormatReceiptIdentity,
                                                 addedID: UUID, target: ManagedVolume,
                                                 current: @escaping @Sendable () -> Bool) -> Bool {
        guard self.selection?.caseID == selected.caseID, selected.caseMode == .ordinaryV3,
              selected.phase == .warm, signedFormatTarget == nil,
              signedFormatClaimedOwner == nil,
              receipt.version == 3, receipt.jobID.uuidString == selected.caseID,
              target.deviceKind == .diskImage, target.isInternal == false,
              target.volumeUUID == addedID,
              target.volumeUUID != nil, target.mediaID != nil,
              target.mediaID != receipt.originalMediaID, target.group == receipt.outerMediaID,
              target.url != nil, target.fileSystemID != nil else { return false }
        signedFormatTarget = FormatTarget(caseID: selected.caseID, target: target,
                                          receipt: receipt, current: current)
        return true
    }

    @MainActor static func signedFormatTargetAvailable(_ target: ManagedVolume) -> Bool {
        guard let selected = selection, selected.caseMode == .ordinaryV3,
              selected.phase == .warm, signedFormatClaimedOwner == nil,
              let armed = signedFormatTarget else { return false }
        return armed.caseID == selected.caseID && armed.target == target
    }

    @MainActor static func claimSignedFormatTarget(_ target: ManagedVolume,
                                                   owner: APFSVolumeFormatImageOwner) -> SignedFormatGrant? {
        guard let expected = signedFormatReviewOwner(target), owner == expected,
              let armed = signedFormatTarget else { return nil }
        signedFormatClaimedOwner = owner
        return SignedFormatGrant(current: armed.current)
    }

    /// A read-only review of the exact armed member can bind the sealed file.
    /// Only the later claim spends the arm and permits the native launch gate.
    @MainActor static func signedFormatReviewOwner(_ target: ManagedVolume) -> APFSVolumeFormatImageOwner? {
        guard signedFormatTargetAvailable(target), let selected = selection, let receipt = signedFormatTarget?.receipt else { return nil }
        let owner = APFSVolumeFormatImageOwner(imagePath: selected.fixtureRoot.appendingPathComponent("fixture.dmg").path,
            parentDevice: receipt.fixtureDevice, parentInode: receipt.fixtureInode,
            imageDevice: receipt.imageDevice, imageInode: receipt.imageInode, imageBytes: 1 << 30,
            ownerUID: geteuid(), outerDevice: receipt.outerDevice, outerMediaID: receipt.outerMediaID)
        return owner.validate() ? owner : nil
    }

    @MainActor static func signedFormatTargetClaimed(owner: APFSVolumeFormatImageOwner) -> Bool {
        selection?.caseMode == .ordinaryV3 && selection?.phase == .warm
            && signedFormatClaimedOwner == owner
    }

    static func consumePhasePermit(_ selected: Selection) -> Bool {
        #if TRAVERSE_DRIVE_IMAGE_QA && MAC_EXPLORER_DISTRIBUTION && !DEBUG
        return GeneratedSignedReviewAdmission.consume(caseID: selected.caseID,
            bundleID: selected.bundleID, caseRoot: selected.caseRoot,
            phase: selected.phase.rawValue, prefix: "drive-image-",
            packet: selected.caseMode.permitPacket,
            pinnedDigests: ["buildInputsSHA256", "buildResultSHA256", "controllerInputsSHA256"]) { scope in
            let keys = Set(["packet", "case", "bundleIdentifier", "caseRoot", "fixtureRoot",
                                          "artifactTreeSHA256", "buildInputsSHA256", "buildResultSHA256",
                                          "controllerInputsSHA256", "controllerInputsCount",
                                          "expiresUTC", "phaseLaunchCeiling", "formatCompletionContract",
                                          "imageBytes", "normalAttachMaximum", "normalDetachMaximum",
                                          "forceDetachMaximum", "apfsAddMaximum", "apfsFormatMaximum",
                                          "driveMutationMaximum", "physicalDriveMaximum",
                                          "archiveJobsMaximum", "networkSessionsMaximum", "trashJobsMaximum"])
            let expected = selected.caseMode == .ordinaryV3 ? keys.union(["caseMode"]) : keys
            guard Set(scope.keys) == expected,
                  scope["packet"] as? String == selected.caseMode.scopePacket,
                  selected.caseMode == .generatedV2
                    || scope["caseMode"] as? String == selected.caseMode.rawValue,
                  scope["formatCompletionContract"] as? String == selected.formatCompletionContract,
                  scope["fixtureRoot"] as? String == selected.fixtureRoot.path,
                  let buildInputsDigest = scope["buildInputsSHA256"] as? String,
                  let buildResultDigest = scope["buildResultSHA256"] as? String,
                  let controllerInputsDigest = scope["controllerInputsSHA256"] as? String,
                  GeneratedSignedReviewAdmission.exactDigest(buildInputsDigest),
                  GeneratedSignedReviewAdmission.exactDigest(buildResultDigest),
                  GeneratedSignedReviewAdmission.exactDigest(controllerInputsDigest),
                  let controllerCount = GeneratedSignedReviewAdmission.exactInteger(scope["controllerInputsCount"]),
                  (1...512).contains(controllerCount),
                  let ceilings = scope["phaseLaunchCeiling"] as? [String: Any],
                  Set(ceilings.keys) == Set(["pre-image", "warm", "cold"]),
                  ceilings.values.allSatisfy({ GeneratedSignedReviewAdmission.exactInteger($0) == 1 }),
                  GeneratedSignedReviewAdmission.exactInteger(scope["imageBytes"]) == (1 << 30),
                  GeneratedSignedReviewAdmission.exactInteger(scope["normalAttachMaximum"]) == 1,
                  GeneratedSignedReviewAdmission.exactInteger(scope["normalDetachMaximum"]) == 1,
                  GeneratedSignedReviewAdmission.exactInteger(scope["forceDetachMaximum"]) == 0,
                  GeneratedSignedReviewAdmission.exactInteger(scope["apfsAddMaximum"]) == 1,
                  GeneratedSignedReviewAdmission.exactInteger(scope["apfsFormatMaximum"]) == 1,
                  GeneratedSignedReviewAdmission.exactInteger(scope["driveMutationMaximum"]) == 2,
                  GeneratedSignedReviewAdmission.exactInteger(scope["physicalDriveMaximum"]) == 0,
                  GeneratedSignedReviewAdmission.exactInteger(scope["archiveJobsMaximum"]) == 0,
                  GeneratedSignedReviewAdmission.exactInteger(scope["networkSessionsMaximum"]) == 0,
                  GeneratedSignedReviewAdmission.exactInteger(scope["trashJobsMaximum"]) == 0 else { return false }
            return true
        }
        #else
        return false
        #endif
    }
}
