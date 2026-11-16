import CoreFoundation
import CryptoKit
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

    struct Selection: Sendable {
        let caseID: String
        let bundleID: String
        let caseRoot: URL
        let fixtureRoot: URL
        let journalDirectory: URL
        let phase: Phase
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
            phase: phase)
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

    /// A host-issued, phase-specific permit is consumed once before AppKit.
    /// Build and inspection cannot create this permit. A failed or interrupted
    /// launch spends its attempt; the host must retain that evidence.
    static func consumePhasePermit(_ selected: Selection) -> Bool {
        #if TRAVERSE_ARCHIVE_DRIVE_QA && MAC_EXPLORER_DISTRIBUTION && !DEBUG
        let evidence = selected.caseRoot.appendingPathComponent("evidence", isDirectory: true)
        guard ownedDirectory(evidence, privateMode: true) else { return false }
        let name = "archive-drive-" + selected.phase.rawValue
        let pending = evidence.appendingPathComponent(name + "-permit.json")
        let consumed = evidence.appendingPathComponent(name + "-consumed.json")
        guard let (fields, before, _) = readPrivateJSON(pending),
              Set(fields.keys) == Set(["packet", "case", "phase", "bundleIdentifier", "caseRoot",
                                       "artifactTreeSHA256", "scopeSHA256", "expiresUTC", "attempt"]),
              fields["packet"] as? String == "archive-drive-phase-permit-v1",
              fields["case"] as? String == selected.caseID,
              fields["phase"] as? String == selected.phase.rawValue,
              fields["bundleIdentifier"] as? String == selected.bundleID,
              fields["caseRoot"] as? String == selected.caseRoot.path,
              fields["attempt"] as? Int == 1,
              let artifactHash = fields["artifactTreeSHA256"] as? String,
              let scopeHash = fields["scopeSHA256"] as? String,
              isLowerHexDigest(artifactHash), isLowerHexDigest(scopeHash),
              let expires = fields["expiresUTC"] as? String,
              let deadline = ISO8601DateFormatter().date(from: expires), Date() <= deadline else { return false }
        let scopePath = evidence.appendingPathComponent("runtime-scope.json")
        guard let (scope, _, scopeData) = readPrivateJSON(scopePath),
              SHA256.hash(data: scopeData).map({ String(format: "%02x", $0) }).joined() == scopeHash,
              Set(scope.keys) == Set(["packet", "case", "bundleIdentifier", "caseRoot", "fixtureRoot",
                                      "artifactTreeSHA256", "expiresUTC", "phaseLaunchCeiling",
                                      "archiveForwardJobsMaximum", "archiveColdUndosMaximum",
                                      "generatedFileMaximumBytes", "generatedTotalMaximumBytes",
                                      "driveMutationMaximum", "networkSessionsMaximum", "trashJobsMaximum"]),
              scope["packet"] as? String == "archive-drive-runtime-scope-v1",
              scope["case"] as? String == selected.caseID,
              scope["bundleIdentifier"] as? String == selected.bundleID,
              scope["caseRoot"] as? String == selected.caseRoot.path,
              scope["fixtureRoot"] as? String == selected.fixtureRoot.path,
              scope["artifactTreeSHA256"] as? String == artifactHash,
              scope["expiresUTC"] as? String == expires,
              let ceilings = scope["phaseLaunchCeiling"] as? [String: Any],
              Set(ceilings.keys) == Set(["archive-warm", "archive-cold", "drive-read-only"]),
              ceilings.values.allSatisfy({ exactJSONInteger($0) == 1 }),
              exactJSONInteger(scope["archiveForwardJobsMaximum"]) == 12,
              exactJSONInteger(scope["archiveColdUndosMaximum"]) == 12,
              let fileMaximum = exactJSONInteger(scope["generatedFileMaximumBytes"]),
              let totalMaximum = exactJSONInteger(scope["generatedTotalMaximumBytes"]),
              0 < fileMaximum, fileMaximum <= (1 << 20),
              fileMaximum <= totalMaximum, totalMaximum <= (4 << 20),
              exactJSONInteger(scope["driveMutationMaximum"]) == 0,
              exactJSONInteger(scope["networkSessionsMaximum"]) == 0,
              exactJSONInteger(scope["trashJobsMaximum"]) == 0,
              link(pending.path, consumed.path) == 0 else { return false }
        var linked = stat()
        guard lstat(consumed.path, &linked) == 0,
              linked.st_dev == before.st_dev, linked.st_ino == before.st_ino,
              linked.st_nlink == 2, unlink(pending.path) == 0 else { return false }
        var final = stat()
        let directory = open(evidence.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        defer { if directory >= 0 { close(directory) } }
        return directory >= 0 && fsync(directory) == 0
            && lstat(consumed.path, &final) == 0
            && final.st_dev == before.st_dev && final.st_ino == before.st_ino
            && final.st_nlink == 1
        #else
        return false
        #endif
    }

    private static func isLowerHexDigest(_ text: String) -> Bool {
        text.utf8.count == 64 && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func exactJSONInteger(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              let integer = Int(number.stringValue), String(integer) == number.stringValue else { return nil }
        return integer
    }

    private static func readPrivateJSON(_ url: URL) -> ([String: Any], stat, Data)? {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0,
              before.st_mode & S_IFMT == S_IFREG,
              before.st_uid == geteuid(), before.st_nlink == 1,
              before.st_mode & 0o7777 == 0o600,
              before.st_size >= 0, before.st_size <= 4096 else { return nil }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 4097)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            guard count >= 0, data.count + count <= 4096 else { return nil }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0,
              after.st_dev == before.st_dev, after.st_ino == before.st_ino,
              after.st_size == before.st_size, after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec,
              after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec,
              let fields = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return (fields, after, data)
    }

    private static func ownedDirectory(_ url: URL, privateMode: Bool = false) -> Bool {
        var facts = stat()
        return lstat(url.path, &facts) == 0 && facts.st_mode & S_IFMT == S_IFDIR
            && facts.st_uid == geteuid() && (!privateMode || facts.st_mode & 0o077 == 0)
    }
}
