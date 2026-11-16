import Darwin
import Foundation

/// A distinct nonshipping signed role for one generated APFS image. Selection
/// and a spent launch permit grant no mutation without the warm image witness.
enum GeneratedDriveImageReview {
    private static let identifierPrefix = "local.macexplorer.drive-image.qa."

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
        guard info["TraverseDriveImageQualificationOnly"] as? Bool == true,
              Bundle.main.bundleIdentifier == bundleID,
              info["MacExplorerDistributionChannel"] as? String == "qualification",
              info["MacExplorerAccessPolicy"] as? String == "local-user-v1",
              info["MacExplorerStorageMode"] as? String == "portable",
              info["TraverseDriveImageArchitecture"] as? String == "arm64",
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
            fixtureRoot: fixture, stateDirectory: state, phase: phase)
        #else
        return nil
        #endif
    }()

    static var admitted: Bool { selection != nil }
    static var warmAdmitted: Bool { selection?.phase == .warm }
    static var coldAdmitted: Bool { selection?.phase == .cold }

    static func consumePhasePermit(_ selected: Selection) -> Bool {
        #if TRAVERSE_DRIVE_IMAGE_QA && MAC_EXPLORER_DISTRIBUTION && !DEBUG
        return GeneratedSignedReviewAdmission.consume(caseID: selected.caseID,
            bundleID: selected.bundleID, caseRoot: selected.caseRoot,
            phase: selected.phase.rawValue, prefix: "drive-image-",
            packet: "drive-image-phase-permit-v1") { scope in
            guard Set(scope.keys) == Set(["packet", "case", "bundleIdentifier", "caseRoot", "fixtureRoot",
                                          "artifactTreeSHA256", "expiresUTC", "phaseLaunchCeiling",
                                          "imageBytes", "normalAttachMaximum", "normalDetachMaximum",
                                          "forceDetachMaximum", "apfsAddMaximum", "apfsFormatMaximum",
                                          "driveMutationMaximum", "physicalDriveMaximum",
                                          "archiveJobsMaximum", "networkSessionsMaximum", "trashJobsMaximum"]),
                  scope["packet"] as? String == "drive-image-runtime-scope-v1",
                  scope["fixtureRoot"] as? String == selected.fixtureRoot.path,
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
