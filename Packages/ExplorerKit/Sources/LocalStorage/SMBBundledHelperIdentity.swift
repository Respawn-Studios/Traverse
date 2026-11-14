import CryptoKit
import Darwin
import ExplorerCore
import Foundation
import Security

/// Declared edition policy, never a grant or proof that a path is readable.
/// Kept with concrete signed-helper admission so standalone qualification uses
/// the same implementation as the installed app, without a new dependency.
public enum FileAccessPolicy: String, Sendable, Equatable {
    case selectedFolders = "sandbox-selected-v1"
    case localUser = "local-user-v1"
    public enum Failure: Error { case incompatibleEdition }
    public var requiresFolderSelection: Bool { self == .selectedFolders }
    public static func distribution(channel: String, identifier: String, value: String?) throws -> Self {
        guard identifier == "com.respawnstudios.traverse", let value, let policy = Self(rawValue: value),
              channel == "developer-id" || channel == "app-store" && policy == .selectedFolders else {
            throw Failure.incompatibleEdition
        }
        return policy
    }
}

/// An explicit local-build policy for named network helpers. The legacy internal
/// type/file name stays stable for existing standalone SMB qualification tools.
/// Provisioned/TestFlight identity remains a separate fail-closed configuration.
enum SMBBundledHelperIdentity {
    enum Failure: Error, Sendable { case policy, parent, helper, changed, child }
    static let storeParent = "com.respawnstudios.traverse"
    static let storeTeam = "CDLNJRG82U"
    private static let remoteEditorQAPrefix = "local.macexplorer.sandbox.remote-editor."
    /// Runtime channel admission is explicit too: app-target compiler flags do
    /// not necessarily propagate into a separately compiled package target.
    static func permitsLocalChannel(_ value: Any?, qualificationAllowed: Bool) -> Bool {
        guard let value else { return true } // Existing development bundles.
        guard let channel = value as? String else { return false }
        return channel == "development" || channel == "development-preview"
            || channel == "qualification" && qualificationAllowed
    }
    /// Both exact local parents still require their own enclosing seal, signer,
    /// role manifest and freshly bound child identity. Preview is never a
    /// fallback for distribution or a generic alternate bundle identifier.
    static func permitsDevelopmentParent(_ identifier: String, channel: Any?, reviewCase: Any?) -> Bool {
        if identifier == "local.macexplorer.development" {
            return channel == nil || channel as? String == "development"
        }
        guard identifier == "local.macexplorer.preview", channel as? String == "development-preview",
              let tag = reviewCase as? String, UUID(uuidString: tag)?.uuidString == tag else { return false }
        return true
    }
    enum Role: String, Sendable {
        case browser, resolver, sftp
        var basename: String { self == .sftp ? "sftp-metadata-worker" : "smb-\(rawValue)-worker" }
        var identifier: String { self == .sftp ? "local.macexplorer.sftp.metadata" : "local.macexplorer.smb.\(rawValue)" }
        var manifestResource: String { self == .sftp ? "SFTPHelperManifest.plist" : "SMBHelperManifest.plist" }
        var maximumBytes: Int { switch self { case .browser: 4 << 20; case .resolver: 2 << 20; case .sftp: 8 << 20 } }
        var isSFTP: Bool { self == .sftp }
        var storeIdentifier: String { self == .sftp ? "com.respawnstudios.traverse.sftp.metadata" : "com.respawnstudios.traverse.smb.\(rawValue)" }
    }
    struct Manifest: Sendable {
        let parent: String, team: String, digest: String
        let qualification: Bool
        init(_ fields: [String: Any], role: Role, qualificationAllowed: Bool) throws {
            guard Set(fields.keys).isSubset(of: ["version", "channel", "parentIdentifier", "teamIdentifier", "roles", "case"]),
                  let version = fields["version"] as? NSNumber, CFGetTypeID(version) != CFBooleanGetTypeID(), version.doubleValue == 1,
                  let channel = fields["channel"] as? String,
                  channel == "development" || channel == "qualification" && qualificationAllowed,
                  let parent = fields["parentIdentifier"] as? String, !parent.isEmpty, parent.utf8.count <= 255,
                  let team = fields["teamIdentifier"] as? String, team == "adhoc" || team.count == 10 && team.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) }),
                  let roles = fields["roles"] as? [String: [String: String]],
                  roles.allSatisfy({ name, details in Role(rawValue: name)?.isSFTP == role.isSFTP && Set(details.keys) == ["identifier", "sha256"] }),
                  let details = roles[role.rawValue], details["identifier"] == role.identifier,
                  let digest = details["sha256"], digest.count == 64,
                  digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw Failure.policy }
            if channel == "qualification" {
                guard let value = fields["case"] as? String, UUID(uuidString: value)?.uuidString == value else { throw Failure.policy }
            } else { guard fields["case"] == nil else { throw Failure.policy } }
            self.parent = parent; self.team = team; self.digest = digest; qualification = channel == "qualification"
        }
    }
    struct FileObservation: Equatable, Sendable {
        let device: dev_t, inode: ino_t, size: off_t, modified: timespec, changed: timespec
        init(_ facts: stat) {
            device = facts.st_dev; inode = facts.st_ino; size = facts.st_size
            modified = facts.st_mtimespec; changed = facts.st_ctimespec
        }
        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.device == rhs.device && lhs.inode == rhs.inode && lhs.size == rhs.size
                && lhs.modified.tv_sec == rhs.modified.tv_sec && lhs.modified.tv_nsec == rhs.modified.tv_nsec
                && lhs.changed.tv_sec == rhs.changed.tv_sec && lhs.changed.tv_nsec == rhs.changed.tv_nsec
        }
    }
    /// Immutable Security handles are used only on the admitted preparation/
    /// session executors. No secret or access grant is stored in this token.
    final class Prepared: @unchecked Sendable {
        let helper: URL
        private let observation: FileObservation, unique: Data, requirement: SecRequirement
        private let expires: TimeInterval
        fileprivate init(helper: URL, observation: FileObservation, unique: Data, requirement: SecRequirement) {
            self.helper = helper; self.observation = observation; self.unique = unique; self.requirement = requirement
            expires = ProcessInfo.processInfo.systemUptime + 30
        }
        func validateInstallation() throws {
            guard ProcessInfo.processInfo.systemUptime < expires else { throw Failure.changed }
            let opened = Darwin.open(helper.path, O_RDONLY | O_NOFOLLOW_ANY | O_CLOEXEC | O_NONBLOCK)
            guard opened >= 0 else { throw Failure.changed }; defer { Darwin.close(opened) }
            var facts = stat()
            guard fstat(opened, &facts) == 0, FileObservation(facts) == observation else { throw Failure.changed }
        }
        /// Caller retains this exact direct child unreaped until the check
        /// returns. A stopped/exited/substituted process receives no input.
        func validateChild(_ pid: pid_t) throws {
            guard pid > 0, ProcessInfo.processInfo.systemUptime < expires else { throw Failure.child }
            var child: SecCode?
            guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid as String: NSNumber(value: pid)] as CFDictionary, [], &child) == errSecSuccess,
                  let child, SecCodeCheckValidity(child, [], requirement) == errSecSuccess,
                  let info = try? SMBBundledHelperIdentity.information(child), info.unique == unique else { throw Failure.child }
        }
    }

    static func prepare(_ role: Role, bundle: URL) throws -> Prepared {
        if let channel = Bundle.main.object(forInfoDictionaryKey: "MacExplorerDistributionChannel") as? String,
           channel == "app-store" || channel == "developer-id" {
            return try prepareStore(role, bundle: bundle, channel: channel)
        }
        if Bundle.main.object(forInfoDictionaryKey: "MacExplorerDistributionChannel") as? String == "qualification",
           Bundle.main.bundleIdentifier?.hasPrefix(remoteEditorQAPrefix) == true {
            return try prepareRemoteEditorQA(role, bundle: bundle)
        }
        #if MAC_EXPLORER_DISTRIBUTION
        // Unknown distribution channels never fall back to the local policy.
        throw Failure.policy
        #else
        #if DEBUG || SMB_HELPER_IDENTITY_QUALIFICATION || SFTP_HELPER_IDENTITY_QUALIFICATION
        let qualificationAllowed = true
        #else
        let qualificationAllowed = false
        #endif
        guard permitsLocalChannel(Bundle.main.object(forInfoDictionaryKey: "MacExplorerDistributionChannel"),
                                  qualificationAllowed: qualificationAllowed) else { throw Failure.policy }
        let runningBundle = Bundle.main.bundleURL.standardizedFileURL
        guard bundle.standardizedFileURL == runningBundle, bundle.resolvingSymlinksInPath() == bundle else { throw Failure.parent }
        var running: SecCode?, enclosing: SecStaticCode?
        guard SecCodeCopySelf([], &running) == errSecSuccess, let running,
              SecCodeCheckValidity(running, [], nil) == errSecSuccess,
              SecStaticCodeCreateWithPath(bundle as CFURL, [], &enclosing) == errSecSuccess, let enclosing,
              SecStaticCodeCheckValidity(enclosing, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckNestedCode | kSecCSCheckAllArchitectures), nil) == errSecSuccess else { throw Failure.parent }
        let current = try information(running), parent = try information(enclosing)
        guard current.unique == parent.unique, current.executable == parent.executable,
              parent.executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() == bundle else { throw Failure.parent }
        let resource = bundle.appendingPathComponent("Contents/Resources/\(role.manifestResource)")
        let bytes = try read(resource, maximum: 16384).0
        guard let fields = try PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any] else { throw Failure.policy }
        let manifest = try Manifest(fields, role: role, qualificationAllowed: qualificationAllowed)
        if Bundle.main.object(forInfoDictionaryKey: "MacExplorerDistributionChannel") as? String == "qualification" {
            guard manifest.qualification,
                  Bundle.main.object(forInfoDictionaryKey: "MacExplorerSandboxQualificationCase") as? String == fields["case"] as? String else {
                throw Failure.policy
            }
        }
        guard manifest.parent == parent.identifier, Bundle.main.bundleIdentifier == parent.identifier,
              matchesSigner(parent, expected: manifest.team) else { throw Failure.parent }
        if manifest.qualification {
            let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            guard manifest.team == "adhoc", let value = fields["case"] as? String, UUID(uuidString: value)?.uuidString == value,
                  bundle.pathComponents.contains(value), bundle.path.hasPrefix(repo.appendingPathComponent(".build").path + "/") else { throw Failure.policy }
        } else {
            guard permitsDevelopmentParent(parent.identifier,
                channel: Bundle.main.object(forInfoDictionaryKey: "MacExplorerDistributionChannel"),
                reviewCase: Bundle.main.object(forInfoDictionaryKey: "MacExplorerReviewCase")) else { throw Failure.policy }
        }
        let helper = bundle.appendingPathComponent("Contents/Helpers/\(role.basename)")
        let (source, observation) = try read(helper, maximum: role.maximumBytes)
        guard SHA256.hash(data: source).map({ String(format: "%02x", $0) }).joined() == manifest.digest else { throw Failure.helper }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(helper as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures), nil) == errSecSuccess else { throw Failure.helper }
        let identity = try information(code)
        guard identity.identifier == role.identifier, identity.executable == helper, matchesSigner(identity, expected: manifest.team) else { throw Failure.helper }
        let hex = identity.unique.map { String(format: "%02x", $0) }.joined()
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString("cdhash H\"\(hex)\"" as CFString, [], &requirement) == errSecSuccess,
              let requirement else { throw Failure.helper }
        let prepared = Prepared(helper: helper, observation: observation, unique: identity.unique, requirement: requirement)
        try prepared.validateInstallation(); return prepared
        #endif
    }
    /// This exact generated Release identity may exercise the ordinary worker
    /// while the shipping store signer/manifest path remains unchanged. Its
    /// enclosing case-selected seal binds the role map and inherited children.
    private static func prepareRemoteEditorQA(_ role: Role, bundle: URL) throws -> Prepared {
        guard let tag = Bundle.main.object(forInfoDictionaryKey: "MacExplorerSandboxQualificationCase") as? String,
              UUID(uuidString: tag)?.uuidString == tag,
              Bundle.main.bundleIdentifier == remoteEditorQAPrefix + tag.lowercased().replacingOccurrences(of: "-", with: ""),
              Bundle.main.object(forInfoDictionaryKey: "MacExplorerAccessPolicy") as? String == FileAccessPolicy.selectedFolders.rawValue,
              Bundle.main.object(forInfoDictionaryKey: "MacExplorerStorageMode") as? String == "portable" else { throw Failure.policy }
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let expected = repo.appendingPathComponent(".build/traverse-development/\(tag)/Products/Release/Mac Explorer.app")
        guard bundle == expected, bundle == Bundle.main.bundleURL.standardizedFileURL,
              bundle.resolvingSymlinksInPath() == bundle else { throw Failure.parent }
        func rights(_ code: SecStaticCode) throws -> [String: Any] {
            var raw: CFDictionary?
            guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &raw) == errSecSuccess,
                  let fields = raw as? [String: Any] else { throw Failure.policy }
            if let values = fields[kSecCodeInfoEntitlementsDict as String] as? [String: Any] { return values }
            guard fields[kSecCodeInfoEntitlementsDict as String] == nil else { throw Failure.policy }
            return [:]
        }
        var running: SecCode?, enclosing: SecStaticCode?
        guard SecCodeCopySelf([], &running) == errSecSuccess, let running,
              SecCodeCheckValidity(running, [], nil) == errSecSuccess,
              SecStaticCodeCreateWithPath(bundle as CFURL, [], &enclosing) == errSecSuccess, let enclosing,
              SecStaticCodeCheckValidity(enclosing, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckNestedCode | kSecCSCheckAllArchitectures), nil) == errSecSuccess else { throw Failure.parent }
        let current = try information(running), parent = try information(enclosing)
        let parentRights = try rights(enclosing)
        let exactParentRights: Set<String> = ["com.apple.security.app-sandbox", "com.apple.security.files.user-selected.read-write",
            "com.apple.security.files.bookmarks.app-scope", "com.apple.security.network.client"]
        guard current.unique == parent.unique, current.executable == parent.executable,
              parent.executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() == bundle,
              parent.identifier == Bundle.main.bundleIdentifier, parent.hardened,
              Set(parentRights.keys) == exactParentRights,
              storeRightsAdmitted(parentRights, helper: false) else { throw Failure.parent }
        let resource = bundle.appendingPathComponent("Contents/Resources/\(role.manifestResource)")
        let bytes = try read(resource, maximum: 16384).0
        guard let fields = try PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any],
              Set(fields.keys) == ["version", "channel", "parentIdentifier", "teamIdentifier", "roles", "case"],
              let version = fields["version"] as? NSNumber, CFGetTypeID(version) != CFBooleanGetTypeID(), version.doubleValue == 1,
              fields["channel"] as? String == "qualification", fields["case"] as? String == tag,
              fields["parentIdentifier"] as? String == parent.identifier,
              let qaTeam = fields["teamIdentifier"] as? String,
              qaTeam == "adhoc" || qaTeam == storeTeam,
              let roles = fields["roles"] as? [String: [String: String]],
              Set(roles.keys) == (role.isSFTP ? Set(["sftp"]) : Set(["browser", "resolver"])),
              roles.allSatisfy({ name, details in
                  guard let expectedRole = Role(rawValue: name), let digest = details["sha256"] else { return false }
                  return Set(details.keys) == ["identifier", "sha256"] && details["identifier"] == expectedRole.storeIdentifier
                      && digest.count == 64 && digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
              }), let digest = roles[role.rawValue]?["sha256"] else { throw Failure.policy }
        guard matchesSigner(parent, expected: qaTeam) else { throw Failure.parent }
        func appleRequirement(_ identifier: String) throws -> SecRequirement {
            var result: SecRequirement?
            guard SecRequirementCreateWithString(("anchor apple generic and identifier \"" + identifier + "\"") as CFString,
                                                 [], &result) == errSecSuccess, let result else { throw Failure.policy }
            return result
        }
        if qaTeam != "adhoc" {
            let requirement = try appleRequirement(parent.identifier)
            guard SecCodeCheckValidity(running, [], requirement) == errSecSuccess,
                  SecStaticCodeCheckValidity(enclosing,
                    SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckNestedCode | kSecCSCheckAllArchitectures),
                    requirement) == errSecSuccess else { throw Failure.parent }
        }
        let helper = bundle.appendingPathComponent("Contents/Helpers/\(role.basename)")
        let (source, observation) = try read(helper, maximum: role.maximumBytes)
        guard SHA256.hash(data: source).map({ String(format: "%02x", $0) }).joined() == digest else { throw Failure.helper }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(helper as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures), nil) == errSecSuccess else { throw Failure.helper }
        let identity = try information(code)
        guard identity.identifier == role.storeIdentifier, identity.executable == helper,
              matchesSigner(identity, expected: qaTeam), identity.hardened,
              storeRightsAdmitted(try rights(code), helper: true) else { throw Failure.helper }
        if qaTeam != "adhoc" {
            guard SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures),
                                             try appleRequirement(role.storeIdentifier)) == errSecSuccess else {
                throw Failure.helper
            }
        }
        let hex = identity.unique.map { String(format: "%02x", $0) }.joined()
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString("cdhash H\"\(hex)\"" as CFString, [], &requirement) == errSecSuccess,
              let requirement else { throw Failure.helper }
        let prepared = Prepared(helper: helper, observation: observation, unique: identity.unique, requirement: requirement)
        try prepared.validateInstallation(); return prepared
    }
    /// The enclosing seal protects this role map. Apple may re-sign code during
    /// processing, so the distribution contract binds identifiers/signers, then
    /// freshly binds the installed child CDHash. It never reuses a build hash.
    struct StoreManifest {
        init(_ fields: [String: Any], role: Role, channel: String = "app-store", policy: FileAccessPolicy = .selectedFolders) throws {
            let expected = role.isSFTP ? Set(["sftp"]) : Set(["browser", "resolver"])
            guard channel == "app-store" || channel == "developer-id",
                  Set(fields.keys) == ["version", "channel", "accessPolicy", "parentIdentifier", "teamIdentifier", "roles"],
                  let version = fields["version"] as? NSNumber, CFGetTypeID(version) != CFBooleanGetTypeID(), version.doubleValue == 3,
                  fields["accessPolicy"] as? String == policy.rawValue,
                  (try? FileAccessPolicy.distribution(channel: channel, identifier: storeParent, value: policy.rawValue)) == policy,
                  fields["channel"] as? String == channel, fields["parentIdentifier"] as? String == storeParent,
                  fields["teamIdentifier"] as? String == storeTeam,
                  let roles = fields["roles"] as? [String: [String: String]], Set(roles.keys) == expected,
                  roles.allSatisfy({ name, details in
                      guard let value = Role(rawValue: name) else { return false }
                      return details == ["identifier": value.storeIdentifier]
                  }) else { throw Failure.policy }
        }
    }
    static func storeRightsAdmitted(_ rights: [String: Any], helper: Bool, policy: FileAccessPolicy = .selectedFolders,
                                    channel: String = "app-store", updaterSelected: Bool = false) -> Bool {
        func boolean(_ name: String, _ expected: Bool) -> Bool {
            guard let value = rights[name] as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { return false }
            return value.boolValue == expected
        }
        guard channel == "app-store" || channel == "developer-id" else { return false }
        let updaterRight = "com.apple.security.temporary-exception.mach-lookup.global-name"
        if updaterSelected {
            guard !helper, channel == "developer-id", policy == .selectedFolders,
                  let names = rights[updaterRight] as? [String],
                  names == [storeParent + "-spks", storeParent + "-spki"] else { return false }
        } else if rights[updaterRight] != nil { return false }
        if helper && policy == .localUser { return rights.isEmpty }
        if helper { return Set(rights.keys) == ["com.apple.security.app-sandbox", "com.apple.security.inherit"]
            && boolean("com.apple.security.app-sandbox", true) && boolean("com.apple.security.inherit", true) }
        let required: Set<String> = policy == .selectedFolders ? ["com.apple.security.app-sandbox", "com.apple.security.files.user-selected.read-write",
            "com.apple.security.files.bookmarks.app-scope", "com.apple.security.network.client"] : []
        let identity: Set<String> = ["com.apple.application-identifier", "application-identifier", "com.apple.developer.team-identifier",
            "keychain-access-groups", "beta-reports-active", "com.apple.security.get-task-allow"]
        let admitted = required.union(identity).union(updaterSelected ? [updaterRight] : [])
        guard Set(rights.keys).isSubset(of: admitted), required.allSatisfy({ boolean($0, true) }) else { return false }
        for name in ["com.apple.application-identifier", "application-identifier"] where rights[name] != nil {
            guard rights[name] as? String == storeTeam + "." + storeParent else { return false }
        }
        if let team = rights["com.apple.developer.team-identifier"] { guard team as? String == storeTeam else { return false } }
        if let groups = rights["keychain-access-groups"] {
            guard let groups = groups as? [String], groups.count <= 1,
                  groups.allSatisfy({ $0 == storeTeam + "." + storeParent }) else { return false }
        }
        if rights["com.apple.security.get-task-allow"] != nil && !boolean("com.apple.security.get-task-allow", false) { return false }
        if rights["beta-reports-active"] != nil && !boolean("beta-reports-active", true) { return false }
        return true
    }
    private static func prepareStore(_ role: Role, bundle: URL, channel: String) throws -> Prepared {
        let policy = try FileAccessPolicy.distribution(channel: channel, identifier: storeParent,
            value: Bundle.main.object(forInfoDictionaryKey: "MacExplorerAccessPolicy") as? String)
        guard let updater = DirectUpdaterMarker.resolve(info: Bundle.main.infoDictionary ?? [:]),
              channel == "developer-id" || updater == .absent else { throw Failure.policy }
        if policy == .localUser {
            guard updater == .absent || updater == .directPublic else { throw Failure.policy }
            if updater == .directPublic && !DirectPublicEditionIdentity.matches(
                identifier: Bundle.main.bundleIdentifier, info: Bundle.main.infoDictionary ?? [:]) {
                throw Failure.policy
            }
        } else if updater == .directPublic { throw Failure.policy }
        guard bundle == Bundle.main.bundleURL.standardizedFileURL, bundle.resolvingSymlinksInPath() == bundle,
              Bundle.main.bundleIdentifier == storeParent else { throw Failure.parent }
        func requirement(_ identifier: String) throws -> SecRequirement {
            var result: SecRequirement?
            guard SecRequirementCreateWithString(("anchor apple generic and identifier \"" + identifier + "\"") as CFString, [], &result) == errSecSuccess,
                  let result else { throw Failure.policy }; return result
        }
        func rights(_ code: SecStaticCode) throws -> [String: Any] {
            var raw: CFDictionary?
            guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &raw) == errSecSuccess,
                  let fields = raw as? [String: Any] else { throw Failure.policy }
            if let values = fields[kSecCodeInfoEntitlementsDict as String] as? [String: Any] { return values }
            guard fields[kSecCodeInfoEntitlementsDict as String] == nil else { throw Failure.policy }
            return [:]
        }
        var running: SecCode?, enclosing: SecStaticCode?
        let parentRequirement = try requirement(storeParent)
        guard SecCodeCopySelf([], &running) == errSecSuccess, let running,
              SecCodeCheckValidity(running, [], parentRequirement) == errSecSuccess,
              SecStaticCodeCreateWithPath(bundle as CFURL, [], &enclosing) == errSecSuccess, let enclosing,
              SecStaticCodeCheckValidity(enclosing, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckNestedCode | kSecCSCheckAllArchitectures), parentRequirement) == errSecSuccess else { throw Failure.parent }
        let current = try information(running), parent = try information(enclosing)
        guard current.unique == parent.unique, current.executable == parent.executable,
              parent.executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() == bundle,
              parent.identifier == storeParent, matchesSigner(parent, expected: storeTeam), parent.hardened,
              storeRightsAdmitted(try rights(enclosing), helper: false, policy: policy,
                                  channel: channel, updaterSelected: updater.requiresInstallerRights) else { throw Failure.parent }
        let resource = bundle.appendingPathComponent("Contents/Resources/\(role.manifestResource)")
        let bytes = try read(resource, maximum: 16384).0
        guard let fields = try PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any] else { throw Failure.policy }
        _ = try StoreManifest(fields, role: role, channel: channel, policy: policy)
        let helper = bundle.appendingPathComponent("Contents/Helpers/\(role.basename)")
        let observation = try read(helper, maximum: role.maximumBytes).1
        var code: SecStaticCode?
        let helperRequirement = try requirement(role.storeIdentifier)
        guard SecStaticCodeCreateWithPath(helper as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures), helperRequirement) == errSecSuccess else { throw Failure.helper }
        let identity = try information(code)
        guard identity.identifier == role.storeIdentifier, identity.executable == helper, matchesSigner(identity, expected: storeTeam), identity.hardened,
              storeRightsAdmitted(try rights(code), helper: true, policy: policy, channel: channel) else { throw Failure.helper }
        var exact: SecRequirement?
        let hash = identity.unique.map { String(format: "%02x", $0) }.joined()
        guard SecRequirementCreateWithString("cdhash H\"\(hash)\"" as CFString, [], &exact) == errSecSuccess, let exact else { throw Failure.helper }
        let value = Prepared(helper: helper, observation: observation, unique: identity.unique, requirement: exact)
        try value.validateInstallation(); return value
    }
    private struct Identity {
        let identifier: String, team: String?, unique: Data, executable: URL, adhoc: Bool, hardened: Bool
    }
    private static func matchesSigner(_ identity: Identity, expected: String) -> Bool {
        expected == "adhoc" ? identity.adhoc && identity.team == nil : !identity.adhoc && identity.team == expected
    }
    private static func information(_ code: SecCode) throws -> Identity {
        var representation: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &representation) == errSecSuccess, let representation else { throw Failure.helper }
        return try information(representation)
    }
    private static func information(_ code: SecStaticCode) throws -> Identity {
        var raw: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &raw) == errSecSuccess,
              let fields = raw as? [String: Any], let identifier = fields[kSecCodeInfoIdentifier as String] as? String,
              let unique = fields[kSecCodeInfoUnique as String] as? Data, (20...32).contains(unique.count),
              let executable = fields[kSecCodeInfoMainExecutable as String] as? URL,
              let flags = fields[kSecCodeInfoFlags as String] as? NSNumber else { throw Failure.helper }
        return Identity(identifier: identifier, team: fields[kSecCodeInfoTeamIdentifier as String] as? String,
            unique: unique, executable: executable.standardizedFileURL, adhoc: flags.uint32Value & SecCodeSignatureFlags.adhoc.rawValue != 0,
            hardened: flags.uint32Value & 0x10000 != 0)
    }
    private static func read(_ path: URL, maximum: Int) throws -> (Data, FileObservation) {
        let opened = Darwin.open(path.path, O_RDONLY | O_NOFOLLOW_ANY | O_CLOEXEC | O_NONBLOCK)
        guard opened >= 0 else { throw Failure.helper }; defer { Darwin.close(opened) }
        var initial = stat(), final = stat()
        guard fstat(opened, &initial) == 0, initial.st_mode & S_IFMT == S_IFREG,
              initial.st_nlink == 1, initial.st_size > 0, initial.st_size <= maximum else { throw Failure.helper }
        var result = Data(), buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = Darwin.read(opened, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw Failure.helper }; if count == 0 { break }
            result.append(contentsOf: buffer.prefix(count)); guard result.count <= maximum else { throw Failure.helper }
        }
        guard fstat(opened, &final) == 0, FileObservation(initial) == FileObservation(final), result.count == initial.st_size else { throw Failure.changed }
        return (result, FileObservation(final))
    }
}
