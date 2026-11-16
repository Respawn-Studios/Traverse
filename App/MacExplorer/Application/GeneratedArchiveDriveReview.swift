import Darwin
import Foundation

/// One nonshipping Release image and one generated case. This selection is
/// inert: it grants no file, archive, or drive operation by itself.
enum GeneratedArchiveDriveReview {
    private static let identifierPrefix = "local.macexplorer.archive-drive.qa."

    enum Phase: String, Sendable {
        case archiveWarm = "archive-warm"
        case archiveCold = "archive-cold"
        case driveReadOnly = "drive-read-only"
    }

    enum Suite: String, Sendable {
        case authored
        case tarMembers = "tar-members"
        var jobsMaximum: Int { self == .authored ? 12 : 42 }
    }

    struct Selection: Sendable {
        let caseID: String
        let bundleID: String
        let caseRoot: URL
        let fixtureRoot: URL
        let journalDirectory: URL
        let phase: Phase
        let suite: Suite
    }

    static let requested: Bool = {
        #if TRAVERSE_ARCHIVE_DRIVE_QA
        return true
        #else
        let info = Bundle.main.infoDictionary ?? [:]
        return info["TraverseArchiveDriveQualificationOnly"] != nil
            || info["TraverseArchiveDriveQualificationCase"] != nil
            || CommandLine.arguments.dropFirst().contains { $0.hasPrefix("--check-archive-drive-qa") }
        #endif
    }()

    /// Parsed once before NSApplication. File operations independently check
    /// the root again at prepare, execution and reverse time.
    static let selection: Selection? = {
        #if TRAVERSE_ARCHIVE_DRIVE_QA && MAC_EXPLORER_DISTRIBUTION && !DEBUG
        let info = Bundle.main.infoDictionary ?? [:]
        guard let caseID = info["TraverseArchiveDriveQualificationCase"] as? String,
              UUID(uuidString: caseID)?.uuidString == caseID else { return nil }
        let suiteValue = info["TraverseArchiveDriveQualificationSuite"]
        guard suiteValue == nil || suiteValue is String,
              let suite = Suite(rawValue: suiteValue as? String ?? "authored") else { return nil }
        let bundleID = identifierPrefix + caseID.lowercased().replacingOccurrences(of: "-", with: "")
        guard info["TraverseArchiveDriveQualificationOnly"] as? Bool == true,
              Bundle.main.bundleIdentifier == bundleID,
              info["MacExplorerDistributionChannel"] as? String == "qualification",
              info["MacExplorerAccessPolicy"] as? String == "local-user-v1",
              info["MacExplorerStorageMode"] as? String == "portable",
              info["TraverseArchiveDriveArchitecture"] as? String == "arm64",
              info["MacExplorerReleasePurpose"] == nil,
              info["TraversePublicUpdaterVersion"] == nil,
              info["TraversePrivateUpdaterVersion"] == nil,
              CommandLine.arguments.count == 5,
              CommandLine.arguments[1] == "--verify-ui",
              CommandLine.arguments[2] == "--check-archive-drive-qa",
              CommandLine.arguments[3] == "--phase",
              let phase = Phase(rawValue: CommandLine.arguments[4]) else { return nil }

        // #filePath binds the app to the ordinary source tree used to compile
        // it. The case path is fixed in Info and repeated in the launch env.
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let build = repository.appendingPathComponent(".build", isDirectory: true)
        let cases = build.appendingPathComponent("traverse-development", isDirectory: true)
        let root = cases.appendingPathComponent(caseID, isDirectory: true)
        let source = root.appendingPathComponent("source", isDirectory: true)
        let fixture = source.appendingPathComponent("Operation Root", isDirectory: true)
        let library = source.appendingPathComponent("Library", isDirectory: true)
        let evidence = root.appendingPathComponent("evidence", isDirectory: true)
        let app = root.appendingPathComponent("Products/Release/Mac Explorer.app", isDirectory: true)
        guard let declaredRoot = info["TraverseArchiveDriveQualificationRoot"] as? String,
              declaredRoot == root.path,
              ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"] == root.path,
              repository.path == repository.standardizedFileURL.path,
              ownedDirectory(build), ownedDirectory(cases),
              ownedDirectory(root, privateMode: true), ownedDirectory(source, privateMode: true),
              ownedDirectory(library, privateMode: true), ownedDirectory(evidence, privateMode: true),
              Bundle.main.bundleURL.standardizedFileURL.path == app.path,
              (phase == .driveReadOnly || ownedDirectory(fixture, privateMode: true)) else { return nil }
        let state = source.appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(bundleID, isDirectory: true)
        return Selection(caseID: caseID, bundleID: bundleID, caseRoot: root, fixtureRoot: fixture,
            journalDirectory: state.appendingPathComponent("operation-recovery", isDirectory: true),
            phase: phase, suite: suite)
        #else
        return nil
        #endif
    }()

    static var admitted: Bool { selection != nil }
    static var archiveAdmitted: Bool {
        guard let phase = selection?.phase else { return false }
        return phase == .archiveWarm || phase == .archiveCold
    }
    static var archiveForwardAdmitted: Bool { selection?.phase == .archiveWarm }
    static var archiveColdAdmitted: Bool { selection?.phase == .archiveCold }
    static var driveAdmitted: Bool { selection?.phase == .driveReadOnly }

    /// Keep the native review's access/available-name preparation inside its
    /// generated source before it asks the operation engine for a plan.
    static func permitsFixtureLocations(_ urls: [URL]) -> Bool {
        guard archiveAdmitted, let selected = selection else { return false }
        let root = selected.fixtureRoot
        guard ownedDirectory(selected.caseRoot, privateMode: true),
              ownedDirectory(selected.caseRoot.appendingPathComponent("source", isDirectory: true), privateMode: true),
              ownedDirectory(root, privateMode: true) else { return false }
        let base = root.path
        for url in urls {
            guard url.isFileURL, url.path == url.standardizedFileURL.path,
                  url.path == base || url.path.hasPrefix(base + "/") else { return false }
            var current = url.path == base ? root : url.deletingLastPathComponent()
            while true {
                var facts = stat()
                guard lstat(current.path, &facts) == 0,
                      facts.st_mode & S_IFMT == S_IFDIR,
                      facts.st_uid == geteuid() else { return false }
                if current.path == base { break }
                guard current.path.hasPrefix(base + "/") else { return false }
                current.deleteLastPathComponent()
            }
            var item = stat()
            if lstat(url.path, &item) == 0 {
                guard item.st_uid == geteuid(),
                      item.st_mode & S_IFMT == S_IFDIR
                        || item.st_mode & S_IFMT == S_IFREG && item.st_nlink == 1 else { return false }
            } else if errno != ENOENT { return false }
        }
        return true
    }

    /// This role keeps its own exact archive and zero-drive scope; the shared
    /// helper handles only private-file and one-use permit mechanics.
    static func consumePhasePermit(_ selected: Selection) -> Bool {
        #if TRAVERSE_ARCHIVE_DRIVE_QA && MAC_EXPLORER_DISTRIBUTION && !DEBUG
        return GeneratedSignedReviewAdmission.consume(caseID: selected.caseID,
            bundleID: selected.bundleID, caseRoot: selected.caseRoot,
            phase: selected.phase.rawValue, prefix: "archive-drive-",
            packet: "archive-drive-phase-permit-v1") { scope in
            var keys = Set(["packet", "case", "bundleIdentifier", "caseRoot", "fixtureRoot",
                                          "artifactTreeSHA256", "expiresUTC", "phaseLaunchCeiling",
                                          "archiveForwardJobsMaximum", "archiveColdUndosMaximum",
                                          "generatedFileMaximumBytes", "generatedTotalMaximumBytes",
                                          "driveMutationMaximum", "networkSessionsMaximum", "trashJobsMaximum"])
            if selected.suite == .tarMembers {
                keys.insert("archiveSuite")
                keys.insert("generatedFixtureEntriesMaximum")
                guard scope["archiveSuite"] as? String == selected.suite.rawValue,
                      GeneratedSignedReviewAdmission.exactInteger(scope["generatedFixtureEntriesMaximum"]) == 192 else { return false }
            }
            guard Set(scope.keys) == keys,
                  scope["packet"] as? String == "archive-drive-runtime-scope-v1",
                  scope["fixtureRoot"] as? String == selected.fixtureRoot.path,
                  let ceilings = scope["phaseLaunchCeiling"] as? [String: Any],
                  Set(ceilings.keys) == Set(["archive-warm", "archive-cold", "drive-read-only"]),
                  ceilings.values.allSatisfy({ GeneratedSignedReviewAdmission.exactInteger($0) == 1 }),
                  GeneratedSignedReviewAdmission.exactInteger(scope["archiveForwardJobsMaximum"]) == selected.suite.jobsMaximum,
                  GeneratedSignedReviewAdmission.exactInteger(scope["archiveColdUndosMaximum"]) == selected.suite.jobsMaximum,
                  let fileMaximum = GeneratedSignedReviewAdmission.exactInteger(scope["generatedFileMaximumBytes"]),
                  let totalMaximum = GeneratedSignedReviewAdmission.exactInteger(scope["generatedTotalMaximumBytes"]),
                  0 < fileMaximum, fileMaximum <= (1 << 20),
                  fileMaximum <= totalMaximum, totalMaximum <= (4 << 20),
                  GeneratedSignedReviewAdmission.exactInteger(scope["driveMutationMaximum"]) == 0,
                  GeneratedSignedReviewAdmission.exactInteger(scope["networkSessionsMaximum"]) == 0,
                  GeneratedSignedReviewAdmission.exactInteger(scope["trashJobsMaximum"]) == 0 else { return false }
            return true
        }
        #else
        return false
        #endif
    }

    private static func ownedDirectory(_ url: URL, privateMode: Bool = false) -> Bool {
        GeneratedSignedReviewAdmission.ownedDirectory(url, privateMode: privateMode)
    }
}
