import CryptoKit
import Darwin
import ExplorerCore
import Foundation
import Security

/// Known signed compositions share the same read-only worker. Declaring a
/// composition does not establish device access or hardware qualification.
internal enum DriveHealthHelperIdentity {
    fileprivate static let team = "CDLNJRG82U"

    enum Failure: Error { case policy, changed, signature }
    struct Profile: Sendable, Equatable {
        let parentIdentifier: String
        let helperIdentifier: String
        let channel: String
        let reviewCase: String?
        let inherited: Bool
        let updaterSelected: Bool

        static func resolve(identifier: String?, info: [String: Any]) throws -> Self {
            // A requested service role can never fall through to the child.
            guard info["TraverseDriveHealthServiceVersion"] == nil,
                  let updater = DirectUpdaterMarker.resolve(info: info) else { throw Failure.policy }
            let channel = info["MacExplorerDistributionChannel"] as? String
            if identifier == "local.macexplorer.preview", channel == "development-preview",
               updater == .absent,
               info["TraverseDriveHealthHelperVersion"] == nil,
               info["MacExplorerSandboxQualificationCase"] == nil,
               let tag = info["MacExplorerReviewCase"] as? String, UUID(uuidString: tag)?.uuidString == tag {
                return .init(parentIdentifier: "local.macexplorer.preview", helperIdentifier: "local.macexplorer.drive.health",
                    channel: "development-preview", reviewCase: tag, inherited: false, updaterSelected: false)
            }
            guard info["TraverseDriveHealthHelperVersion"] as? Int == 2 else { throw Failure.policy }
            if identifier == "com.respawnstudios.traverse", channel == "developer-id",
               info["MacExplorerReviewCase"] == nil, info["MacExplorerSandboxQualificationCase"] == nil,
               info["MacExplorerAccessPolicy"] as? String == "sandbox-selected-v1" {
                return .init(parentIdentifier: "com.respawnstudios.traverse",
                    helperIdentifier: "com.respawnstudios.traverse.drive.health", channel: "developer-id",
                    reviewCase: nil, inherited: true, updaterSelected: updater.requiresInstallerRights)
            }
            let tag = "9309F6A1-E7A3-45C2-A864-0CBF02880D63"
            let parent = "local.macexplorer.sandbox.remote-editor." + tag.replacingOccurrences(of: "-", with: "").lowercased()
            guard identifier == parent, channel == "qualification",
                  updater == .absent,
                  info["MacExplorerSandboxQualificationCase"] as? String == tag,
                  info["MacExplorerAccessPolicy"] as? String == "sandbox-selected-v1", info["MacExplorerReviewCase"] == nil,
                  info["MacExplorerStorageMode"] as? String == "portable" else { throw Failure.policy }
            return .init(parentIdentifier: parent, helperIdentifier: parent + ".drive.health",
                channel: "qualification", reviewCase: tag, inherited: true, updaterSelected: false)
        }

        func acceptsManifest(_ fields: [String: Any]) -> Bool {
            let keys: Set<String> = inherited
                ? Set(["format", "parentIdentifier", "helperIdentifier", "teamIdentifier", "channel", "accessPolicy", "sha256"])
                    .union(reviewCase == nil ? [] : ["reviewCase"])
                : ["format", "parentIdentifier", "helperIdentifier", "teamIdentifier", "reviewCase", "sha256"]
            guard Set(fields.keys) == keys,
                  fields["format"] as? String == (inherited ? "drive-health-inherited-v2" : "drive-health-preview-v1"),
                  fields["parentIdentifier"] as? String == parentIdentifier,
                  fields["helperIdentifier"] as? String == helperIdentifier,
                  fields["teamIdentifier"] as? String == team,
                  fields["reviewCase"] as? String == reviewCase,
                  let digest = fields["sha256"] as? String, digest.utf8.count == 64,
                  digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return false }
            return !inherited || fields["channel"] as? String == channel
                && fields["accessPolicy"] as? String == "sandbox-selected-v1"
        }

        func acceptsHelperRights(_ rights: [String: Any]) -> Bool {
            inherited ? SMBBundledHelperIdentity.storeRightsAdmitted(rights, helper: true,
                channel: "developer-id") : rights.isEmpty
        }
        func acceptsParentRights(_ rights: [String: Any]) -> Bool {
            !inherited || SMBBundledHelperIdentity.storeRightsAdmitted(rights, helper: false,
                channel: "developer-id", updaterSelected: updaterSelected)
        }
    }

    static var compositionDeclared: Bool {
        (try? Profile.resolve(identifier: Bundle.main.bundleIdentifier, info: Bundle.main.infoDictionary ?? [:])) != nil
    }
    struct FileState: Equatable, Sendable {
        let device: dev_t, inode: ino_t, size: off_t, modified: timespec, changed: timespec
        init(_ value: stat) {
            device = value.st_dev; inode = value.st_ino; size = value.st_size
            modified = value.st_mtimespec; changed = value.st_ctimespec
        }
        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.device == rhs.device && lhs.inode == rhs.inode && lhs.size == rhs.size &&
            lhs.modified.tv_sec == rhs.modified.tv_sec && lhs.modified.tv_nsec == rhs.modified.tv_nsec &&
            lhs.changed.tv_sec == rhs.changed.tv_sec && lhs.changed.tv_nsec == rhs.changed.tv_nsec
        }
    }
    struct Prepared {
        let helper: URL
        private let state: FileState
        private let manifest: URL
        private let manifestState: FileState
        private let unique: Data
        private let requirement: SecRequirement
        private let profile: Profile
        private let expires: TimeInterval
        fileprivate init(helper: URL, state: FileState, manifest: URL, manifestState: FileState,
                         unique: Data, requirement: SecRequirement, profile: Profile) {
            self.helper = helper; self.state = state; self.manifest = manifest
            self.manifestState = manifestState; self.unique = unique; self.requirement = requirement
            self.profile = profile
            expires = ProcessInfo.processInfo.systemUptime + 30
        }
        func validateInstallation() throws {
            guard ProcessInfo.processInfo.systemUptime < expires else { throw Failure.changed }
            let fd = Darwin.open(helper.path, O_RDONLY | O_NOFOLLOW_ANY | O_CLOEXEC | O_NONBLOCK)
            guard fd >= 0 else { throw Failure.changed }
            defer { Darwin.close(fd) }
            var facts = stat()
            guard fstat(fd, &facts) == 0, FileState(facts) == state else { throw Failure.changed }
            let manifestFD = Darwin.open(manifest.path, O_RDONLY | O_NOFOLLOW_ANY | O_CLOEXEC | O_NONBLOCK)
            guard manifestFD >= 0 else { throw Failure.changed }
            defer { Darwin.close(manifestFD) }
            guard fstat(manifestFD, &facts) == 0, FileState(facts) == manifestState else { throw Failure.changed }
        }
        func validateChild(_ pid: pid_t) throws {
            guard pid > 0, ProcessInfo.processInfo.systemUptime < expires else { throw Failure.changed }
            var running: SecCode?
            guard SecCodeCopyGuestWithAttributes(nil,
                [kSecGuestAttributePid as String: NSNumber(value: pid)] as CFDictionary, [], &running) == errSecSuccess,
                let running, SecCodeCheckValidity(running, [], requirement) == errSecSuccess,
                let fields = try? DriveHealthHelperIdentity.identity(running), fields.unique == unique,
                fields.identifier == profile.helperIdentifier, fields.team == team,
                fields.hardened, profile.acceptsHelperRights(fields.rights) else { throw Failure.signature }
        }
    }
    fileprivate struct Identity {
        let identifier: String, team: String?, unique: Data
        let hardened: Bool
        let rights: [String: Any]
    }
    fileprivate static func identity(_ code: SecCode) throws -> Identity {
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
              let staticCode else { throw Failure.signature }
        return try identity(staticCode)
    }
    fileprivate static func identity(_ code: SecStaticCode) throws -> Identity {
        var result: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &result) == errSecSuccess,
            let fields = result as? [String: Any],
            let identifier = fields[kSecCodeInfoIdentifier as String] as? String,
            let unique = fields[kSecCodeInfoUnique as String] as? Data,
            let flags = fields[kSecCodeInfoFlags as String] as? NSNumber,
            (20...32).contains(unique.count) else { throw Failure.signature }
        let rights: [String: Any]
        if let raw = fields[kSecCodeInfoEntitlementsDict as String] {
            guard let values = raw as? [String: Any] else { throw Failure.signature }
            rights = values
        } else { rights = [:] }
        return Identity(identifier: identifier,
            team: fields[kSecCodeInfoTeamIdentifier as String] as? String, unique: unique,
            hardened: flags.uint32Value & 0x10000 != 0, rights: rights)
    }
    fileprivate static func read(_ url: URL, maximum: Int) throws -> (Data, FileState) {
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW_ANY | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw Failure.changed }
        defer { Darwin.close(fd) }
        var before = stat(), after = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_nlink == 1, before.st_size > 0, before.st_size <= maximum else { throw Failure.changed }
        var bytes = Data(), buffer = [UInt8](repeating: 0, count: 16384)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw Failure.changed }
            if count == 0 { break }
            bytes.append(contentsOf: buffer.prefix(count))
            guard bytes.count <= maximum else { throw Failure.changed }
        }
        guard fstat(fd, &after) == 0, FileState(before) == FileState(after),
              bytes.count == before.st_size else { throw Failure.changed }
        return (bytes, FileState(after))
    }
    private static func appleRequirement(identifier: String, required: Bool) throws -> SecRequirement? {
        guard required else { return nil } // Preserve the local Preview v1 policy.
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString("anchor apple generic and identifier \"\(identifier)\"" as CFString,
            [], &requirement) == errSecSuccess, let requirement else { throw Failure.signature }
        return requirement
    }
    static func prepare() throws -> Prepared {
        let profile = try Profile.resolve(identifier: Bundle.main.bundleIdentifier, info: Bundle.main.infoDictionary ?? [:])
        let bundle = Bundle.main.bundleURL.standardizedFileURL
        guard bundle.resolvingSymlinksInPath() == bundle else { throw Failure.policy }
        if profile.channel == "qualification", let tag = profile.reviewCase {
            let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            guard bundle == repo.appendingPathComponent(".build/traverse-development/\(tag)/Products/Release/Mac Explorer.app") else {
                throw Failure.policy
            }
        }
        let parentRequirement = try appleRequirement(identifier: profile.parentIdentifier, required: profile.inherited)
        var selfCode: SecCode?
        guard SecCodeCopySelf([], &selfCode) == errSecSuccess, let selfCode,
              SecCodeCheckValidity(selfCode, [], parentRequirement) == errSecSuccess,
              let parent = try? identity(selfCode), parent.identifier == profile.parentIdentifier,
              parent.team == team, !profile.inherited || parent.hardened,
              profile.acceptsParentRights(parent.rights) else { throw Failure.signature }
        var enclosing: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &enclosing) == errSecSuccess,
              let enclosing,
              SecStaticCodeCheckValidity(enclosing,
                SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckNestedCode | kSecCSCheckAllArchitectures), parentRequirement) == errSecSuccess,
              let installed = try? identity(enclosing), installed.identifier == profile.parentIdentifier,
              installed.team == team, installed.unique == parent.unique,
              profile.acceptsParentRights(installed.rights) else { throw Failure.signature }
        let manifest = bundle.appendingPathComponent("Contents/Resources/DriveHealthHelperManifest.plist")
        let (manifestData, manifestState) = try read(manifest, maximum: 4096)
        guard let fields = try PropertyListSerialization.propertyList(from: manifestData, format: nil) as? [String: Any],
              profile.acceptsManifest(fields), let digest = fields["sha256"] as? String else { throw Failure.policy }
        let helper = bundle.appendingPathComponent("Contents/Helpers/drive-health-worker")
        let (image, state) = try read(helper, maximum: 4 << 20)
        let observed = SHA256.hash(data: image).map { String(format: "%02x", $0) }.joined()
        guard observed == digest else { throw Failure.changed }
        let helperRequirement = try appleRequirement(identifier: profile.helperIdentifier, required: profile.inherited)
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(helper as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode,
              SecStaticCodeCheckValidity(staticCode, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures), helperRequirement) == errSecSuccess else {
            throw Failure.signature
        }
        let helperIdentity = try identity(staticCode)
        guard helperIdentity.identifier == profile.helperIdentifier,
              helperIdentity.team == team, helperIdentity.hardened,
              profile.acceptsHelperRights(helperIdentity.rights) else {
            throw Failure.signature
        }
        let unique = helperIdentity.unique
        let hash = unique.map { String(format: "%02x", $0) }.joined()
        let childRequirement = "cdhash H\"\(hash)\"" + (profile.inherited
            ? " and anchor apple generic and identifier \"\(profile.helperIdentifier)\"" : "")
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(childRequirement as CFString, [], &requirement) == errSecSuccess,
              let requirement else { throw Failure.signature }
        let prepared = Prepared(helper: helper, state: state, manifest: manifest,
            manifestState: manifestState, unique: unique, requirement: requirement, profile: profile)
        try prepared.validateInstallation()
        return prepared
    }
}

/// An independently signed, application-scoped service has closed QA and
/// Developer ID product compositions. An invalid declaration stays requested
/// so the caller never tries the inherited child as a fallback.
internal enum DriveHealthServiceIdentity {
    private static let versionKey = "TraverseDriveHealthServiceVersion"
    private static let qaCase = "9309F6A1-E7A3-45C2-A864-0CBF02880D63"
    private static let serviceLeaf = "drive-health-service.xpc"
    private static let executableLeaf = "drive-health-service"

    typealias Failure = DriveHealthHelperIdentity.Failure

    struct Profile {
        let parentIdentifier: String
        let serviceIdentifier: String
        let reviewCase: String?
        let channel: String
        let accessPolicy: FileAccessPolicy
        let updaterSelected: Bool

        static func resolve(identifier: String?, info: [String: Any]) throws -> Self {
            guard let updater = DirectUpdaterMarker.resolve(info: info) else { throw Failure.policy }
            guard let version = info[versionKey] as? NSNumber,
                  CFGetTypeID(version) != CFBooleanGetTypeID(),
                  version.intValue == 1, version.doubleValue == 1,
                  info["TraverseDriveHealthHelperVersion"] == nil,
                  info["MacExplorerReviewCase"] == nil,
                  info["MacExplorerStorageMode"] as? String == "portable",
                  let accessPolicy = FileAccessPolicy(rawValue: info["MacExplorerAccessPolicy"] as? String ?? "") else {
                throw Failure.policy
            }
            if identifier == "com.respawnstudios.traverse" {
                guard info["CFBundleIdentifier"] as? String == identifier,
                      info["MacExplorerDistributionChannel"] as? String == "developer-id",
                      info["MacExplorerSandboxQualificationCase"] == nil else {
                    throw Failure.policy
                }
                if accessPolicy == .localUser {
                    guard updater == .directPublic,
                          DirectPublicEditionIdentity.matches(identifier: identifier, info: info) else {
                        throw Failure.policy
                    }
                } else {
                    guard updater != .directPublic,
                          info["TraverseDirectStorageNamespace"] == nil else { throw Failure.policy }
                }
                return .init(parentIdentifier: "com.respawnstudios.traverse",
                    serviceIdentifier: "com.respawnstudios.traverse.drive.health.xpc",
                    reviewCase: nil, channel: "developer-id",
                    accessPolicy: accessPolicy,
                    updaterSelected: updater.requiresInstallerRights)
            }
            let parent = "local.macexplorer.sandbox.remote-editor."
                + qaCase.replacingOccurrences(of: "-", with: "").lowercased()
            guard updater == .absent, accessPolicy == .selectedFolders,
                  info["TraverseDirectStorageNamespace"] == nil,
                  identifier == parent,
                  info["CFBundleIdentifier"] as? String == parent,
                  info["MacExplorerDistributionChannel"] as? String == "qualification",
                  info["MacExplorerSandboxQualificationCase"] as? String == qaCase else {
                throw Failure.policy
            }
            return .init(parentIdentifier: parent, serviceIdentifier: parent + ".drive.health.xpc",
                reviewCase: qaCase, channel: "qualification", accessPolicy: .selectedFolders,
                updaterSelected: false)
        }

        var parentRequirement: String { DriveHealthServiceIdentity.roleRequirement(parentIdentifier) }
        var serviceRequirement: String { DriveHealthServiceIdentity.roleRequirement(serviceIdentifier) }

        func acceptsManifest(_ fields: [String: Any]) -> Bool {
            var keys: Set<String> = ["format", "parentIdentifier", "serviceIdentifier", "teamIdentifier",
                "channel", "accessPolicy", "parentRequirement", "sha256", "serviceCDHash"]
            if reviewCase != nil { keys.insert("reviewCase") }
            guard Set(fields.keys) == keys,
                  fields["format"] as? String == (reviewCase == nil
                    ? "drive-health-xpc-developer-id-v1" : "drive-health-xpc-qa-v1"),
                  fields["parentIdentifier"] as? String == parentIdentifier,
                  fields["serviceIdentifier"] as? String == serviceIdentifier,
                  fields["teamIdentifier"] as? String == DriveHealthHelperIdentity.team,
                  fields["channel"] as? String == channel,
                  fields["accessPolicy"] as? String == accessPolicy.rawValue,
                  fields["reviewCase"] as? String == reviewCase,
                  fields["parentRequirement"] as? String == parentRequirement,
                  let digest = fields["sha256"] as? String, digest.utf8.count == 64,
                  digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                  let hash = fields["serviceCDHash"] as? String,
                  [40, 64].contains(hash.utf8.count),
                  hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                return false
            }
            return true
        }

        func acceptsServiceInfo(_ fields: [String: Any]) -> Bool {
            let keys: Set<String> = ["CFBundleIdentifier", "CFBundleExecutable", "CFBundlePackageType",
                "CFBundleShortVersionString", "CFBundleVersion", "LSMinimumSystemVersion", "XPCService"]
            guard Set(fields.keys) == keys,
                  fields["CFBundleIdentifier"] as? String == serviceIdentifier,
                  fields["CFBundleExecutable"] as? String == executableLeaf,
                  fields["CFBundlePackageType"] as? String == "XPC!",
                  fields["CFBundleShortVersionString"] as? String == "1.0",
                  fields["CFBundleVersion"] as? String == "1",
                  fields["LSMinimumSystemVersion"] as? String == "15.0",
                  let service = fields["XPCService"] as? [String: Any],
                  Set(service.keys) == Set(["ServiceType", "RunLoopType"]),
                  service["ServiceType"] as? String == "Application",
                  service["RunLoopType"] as? String == "dispatch_main" else { return false }
            return true
        }
    }

    static var compositionRequested: Bool {
        Bundle.main.infoDictionary?[versionKey] != nil
    }
    static var compositionDeclared: Bool {
        (try? Profile.resolve(identifier: Bundle.main.bundleIdentifier, info: Bundle.main.infoDictionary ?? [:])) != nil
    }

    /// Apple-issued Developer ID Application role, exact team and identifier.
    /// Team IDs are quoted because an initial digit otherwise breaks parsing.
    static func roleRequirement(_ identifier: String) -> String {
        "anchor apple generic and identifier \"\(identifier)\""
            + " and certificate 1[field.1.2.840.113635.100.6.2.6] exists"
            + " and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
            + " and certificate leaf[subject.OU] = \"\(DriveHealthHelperIdentity.team)\""
    }

    struct Prepared: Sendable {
        let serviceIdentifier: String
        let peerRequirement: String
        private let binary: URL, info: URL, manifest: URL
        private let binaryState: DriveHealthHelperIdentity.FileState
        private let infoState: DriveHealthHelperIdentity.FileState
        private let manifestState: DriveHealthHelperIdentity.FileState
        private let expires: TimeInterval

        fileprivate init(profile: Profile, binary: URL, binaryState: DriveHealthHelperIdentity.FileState,
                         info: URL, infoState: DriveHealthHelperIdentity.FileState,
                         manifest: URL, manifestState: DriveHealthHelperIdentity.FileState,
                         serviceCDHash: String) {
            serviceIdentifier = profile.serviceIdentifier
            peerRequirement = "cdhash H\"\(serviceCDHash)\" and " + profile.serviceRequirement
            self.binary = binary; self.binaryState = binaryState
            self.info = info; self.infoState = infoState
            self.manifest = manifest; self.manifestState = manifestState
            expires = ProcessInfo.processInfo.systemUptime + 30
        }

        func validateInstallation() throws {
            guard ProcessInfo.processInfo.systemUptime < expires else { throw Failure.changed }
            for (url, expected) in [(binary, binaryState), (info, infoState), (manifest, manifestState)] {
                let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW_ANY | O_CLOEXEC | O_NONBLOCK)
                guard fd >= 0 else { throw Failure.changed }
                defer { Darwin.close(fd) }
                var facts = stat()
                guard fstat(fd, &facts) == 0, facts.st_nlink == 1,
                      DriveHealthHelperIdentity.FileState(facts) == expected else { throw Failure.changed }
            }
        }
    }

    /// Synchronous metadata/signature work. The client must call this off the
    /// main actor and validate again immediately before connection activation.
    static func prepare() throws -> Prepared {
        let profile = try Profile.resolve(identifier: Bundle.main.bundleIdentifier, info: Bundle.main.infoDictionary ?? [:])
        let bundle = Bundle.main.bundleURL.standardizedFileURL
        guard bundle.resolvingSymlinksInPath() == bundle else { throw Failure.policy }
        if let reviewCase = profile.reviewCase {
            let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            guard bundle == repo.appendingPathComponent(".build/traverse-development/\(reviewCase)/Products/Release/Mac Explorer.app") else {
                throw Failure.policy
            }
        }
        var role: SecRequirement?
        guard SecRequirementCreateWithString(profile.parentRequirement as CFString, [], &role) == errSecSuccess,
              let role else { throw Failure.signature }
        var selfCode: SecCode?
        guard SecCodeCopySelf([], &selfCode) == errSecSuccess, let selfCode,
              SecCodeCheckValidity(selfCode, [], role) == errSecSuccess,
              let running = try? DriveHealthHelperIdentity.identity(selfCode),
              running.identifier == profile.parentIdentifier,
              running.team == DriveHealthHelperIdentity.team, running.hardened,
              SMBBundledHelperIdentity.storeRightsAdmitted(running.rights, helper: false,
                  policy: profile.accessPolicy, channel: "developer-id",
                  updaterSelected: profile.updaterSelected) else { throw Failure.signature }
        var outer: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundle as CFURL, [], &outer) == errSecSuccess, let outer,
              SecStaticCodeCheckValidity(outer,
                  SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckNestedCode | kSecCSCheckAllArchitectures), role) == errSecSuccess,
              let installed = try? DriveHealthHelperIdentity.identity(outer),
              installed.identifier == profile.parentIdentifier,
              installed.team == DriveHealthHelperIdentity.team,
              installed.unique == running.unique, installed.hardened,
              SMBBundledHelperIdentity.storeRightsAdmitted(installed.rights, helper: false,
                  policy: profile.accessPolicy, channel: "developer-id",
                  updaterSelected: profile.updaterSelected) else { throw Failure.signature }

        let services = bundle.appendingPathComponent("Contents/XPCServices", isDirectory: true)
        guard services.resolvingSymlinksInPath() == services,
              Set(try FileManager.default.contentsOfDirectory(atPath: services.path)) == [serviceLeaf] else {
            throw Failure.policy
        }
        let service = services.appendingPathComponent(serviceLeaf, isDirectory: true)
        let info = service.appendingPathComponent("Contents/Info.plist")
        let binary = service.appendingPathComponent("Contents/MacOS/\(executableLeaf)")
        let manifest = bundle.appendingPathComponent("Contents/Resources/DriveHealthServiceManifest.plist")
        let (manifestData, manifestState) = try DriveHealthHelperIdentity.read(manifest, maximum: 4096)
        guard let fields = try PropertyListSerialization.propertyList(from: manifestData, format: nil) as? [String: Any],
              profile.acceptsManifest(fields),
              let digest = fields["sha256"] as? String,
              let cdhash = fields["serviceCDHash"] as? String else { throw Failure.policy }
        let (infoData, infoState) = try DriveHealthHelperIdentity.read(info, maximum: 4096)
        guard let serviceInfo = try PropertyListSerialization.propertyList(from: infoData, format: nil) as? [String: Any],
              profile.acceptsServiceInfo(serviceInfo) else { throw Failure.policy }
        let (image, binaryState) = try DriveHealthHelperIdentity.read(binary, maximum: 4 << 20)
        guard SHA256.hash(data: image).map({ String(format: "%02x", $0) }).joined() == digest else {
            throw Failure.changed
        }
        var serviceRole: SecRequirement?
        guard SecRequirementCreateWithString(profile.serviceRequirement as CFString, [], &serviceRole) == errSecSuccess,
              let serviceRole else { throw Failure.signature }
        var staticService: SecStaticCode?
        guard SecStaticCodeCreateWithPath(service as CFURL, [], &staticService) == errSecSuccess,
              let staticService,
              SecStaticCodeCheckValidity(staticService,
                  SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures), serviceRole) == errSecSuccess,
              let signed = try? DriveHealthHelperIdentity.identity(staticService),
              signed.identifier == profile.serviceIdentifier,
              signed.team == DriveHealthHelperIdentity.team, signed.hardened,
              signed.rights.isEmpty,
              signed.unique.map({ String(format: "%02x", $0) }).joined() == cdhash else {
            throw Failure.signature
        }
        let prepared = Prepared(profile: profile, binary: binary, binaryState: binaryState,
            info: info, infoState: infoState, manifest: manifest, manifestState: manifestState,
            serviceCDHash: cdhash)
        try prepared.validateInstallation()
        return prepared
    }
}
