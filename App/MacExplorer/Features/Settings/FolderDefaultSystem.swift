import AppKit
import CoreServices
import ExplorerCore
import Foundation
import LocalStorage
import UniformTypeIdentifiers

// Shipping remains held. Preview uses the sealed declaration below and the
// existing explicit consent/restore flow; opening Settings changes no default.
enum FolderDefaultFeature {
    static let permitsSystemChanges = false
    static let shippingBundleIdentifier = "com.respawnstudios.traverse"
}

enum FolderDefaultFailure: Error, Sendable {
    case unavailable, invalidApplication, unsafeStorage, corruptStorage, changed, notQualified
}


/// Closed Traverse identities. This parser uses the existing inert profile
/// validator; its computed layout is discarded and grants no storage/access.
/// Actual AppStorageLocations independently selects the private namespace.
enum FolderDefaultIdentityPolicy {
    static let previewIdentifier = DevelopmentReviewProfile.identifier
    static var distributionBuild: Bool {
        #if MAC_EXPLORER_DISTRIBUTION
        true
        #else
        false
        #endif
    }
    static var permitsPreviewBuild: Bool {
        #if !MAC_EXPLORER_DISTRIBUTION
        true
        #else
        false
        #endif
    }
    static func hasPreviewFolderDeclaration(_ info: [String: Any]) -> Bool {
        info["MacExplorerPreviewFolderOpening"] as? String == "public-folder-v1" && hasFolderDeclaration(info)
    }
    static func hasFolderDeclaration(_ info: [String: Any]) -> Bool {
        guard info["CFBundleURLTypes"] == nil,
              let types = info["CFBundleDocumentTypes"] as? [[String: Any]], types.count == 1 else { return false }
        let type = types[0]
        return Set(type.keys) == ["CFBundleTypeName", "CFBundleTypeRole", "LSHandlerRank", "LSItemContentTypes"]
            && type["CFBundleTypeName"] as? String == "Folder"
            && type["CFBundleTypeRole"] as? String == "Viewer"
            && type["LSHandlerRank"] as? String == "Alternate"
            && type["LSItemContentTypes"] as? [String] == ["public.folder"]
    }
    static func acceptsPackageType(_ type: String?, identifier: String, at url: URL) -> Bool {
        if type == "APPL" { return true }
        // Finder is a system application with its own historical package type.
        // Do not broaden this exception to other bundles or Finder copies.
        return type == "FNDR" && identifier == "com.apple.finder"
            && url.path == "/System/Library/CoreServices/Finder.app"
    }
    static func previewCase(identifier: String, info: [String: Any], applicationParent: URL) throws -> String? {
        guard identifier == FolderDefaultFeature.shippingBundleIdentifier || identifier == previewIdentifier else { return nil }
        for key in ["MacExplorerDistributionChannel", "MacExplorerReviewCase", "MacExplorerReviewStorage"] {
            guard info[key] == nil || info[key] is String else { throw FolderDefaultFailure.notQualified }
        }
        let channel = info["MacExplorerDistributionChannel"] as? String
        let caseID = info["MacExplorerReviewCase"] as? String
        let storage = info["MacExplorerReviewStorage"] as? String
        if identifier == FolderDefaultFeature.shippingBundleIdentifier {
            guard channel != DevelopmentReviewProfile.channel, caseID == nil, storage == nil else { throw FolderDefaultFailure.notQualified }
            return nil
        }
        guard identifier == previewIdentifier else { return nil } // A previous external handler is not a running Traverse grant.
        guard storage == nil || DevelopmentReviewProfile.Storage(rawValue: storage!) != nil else { throw FolderDefaultFailure.notQualified }
        // Namespace selection occurs in AppStorageLocations. Repository mode
        // here validates only the sealed id/channel/case, without I/O or use of
        // the returned paths, including when actual storage is private-user-v1.
        let validated = try DevelopmentReviewProfile(identifier: identifier, channel: channel, caseID: caseID,
            checkout: applicationParent, storage: .repository)
        return validated.caseID
    }
    static func acceptsTraverse(_ app: FolderDefaultApplication, distribution: Bool, previewBuild: Bool) -> Bool {
        if app.bundleIdentifier == FolderDefaultFeature.shippingBundleIdentifier { return app.previewCaseID == nil }
        return !distribution && previewBuild && app.bundleIdentifier == previewIdentifier
            && app.previewCaseID.flatMap { UUID(uuidString: $0)?.uuidString } == app.previewCaseID && app.previewCaseID != nil
    }
    static func previewActivationEligible(_ app: FolderDefaultApplication, distribution: Bool, previewBuild: Bool) -> Bool {
        app.bundleIdentifier == previewIdentifier && acceptsTraverse(app, distribution: distribution, previewBuild: previewBuild)
    }
    static func acceptsRunning(_ app: FolderDefaultApplication) -> Bool {
        acceptsTraverse(app, distribution: distributionBuild, previewBuild: permitsPreviewBuild)
    }
}

struct FolderDefaultApplication: Codable, Equatable, Sendable {
    let url: URL
    let bundleIdentifier: String
    let name: String
    let previewCaseID: String?
    init(url: URL, bundleIdentifier: String, name: String, previewCaseID: String? = nil) {
        self.url = url; self.bundleIdentifier = bundleIdentifier; self.name = name; self.previewCaseID = previewCaseID
    }

    func validate() throws {
        try Self.validateLocation(url)
        if bundleIdentifier == FolderDefaultIdentityPolicy.previewIdentifier {
            guard let previewCaseID, UUID(uuidString: previewCaseID)?.uuidString == previewCaseID else { throw FolderDefaultFailure.invalidApplication }
        } else if previewCaseID != nil { throw FolderDefaultFailure.invalidApplication }
        guard !bundleIdentifier.isEmpty, bundleIdentifier.utf8.count <= 255,
              bundleIdentifier.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-").contains($0) }),
              !name.isEmpty, name.utf8.count <= 512,
              !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { throw FolderDefaultFailure.invalidApplication }
    }
    static func validateLocation(_ url: URL) throws {
        let decoded = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath.removingPercentEncoding
        guard url.isFileURL, url.baseURL == nil, url.path.hasPrefix("/"),
              url.host == nil || url.host == "" || url.host == "localhost",
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.pathExtension.lowercased() == "app", url.absoluteString.utf8.count <= 8_192,
              let decoded, decoded.hasPrefix("/"),
              !decoded.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !decoded.split(separator: "/").contains("."), !decoded.split(separator: "/").contains(".."),
              !url.pathComponents.contains("."), !url.pathComponents.contains(".."),
              !url.path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { throw FolderDefaultFailure.invalidApplication }
    }

    // Display-name changes are not changes in app identity. No symlink
    // resolution, file-reference coercion or bundle-ID heuristic lookup.
    func identifies(_ other: Self) -> Bool {
        bundleIdentifier == other.bundleIdentifier && url.path == other.url.path && previewCaseID == other.previewCaseID
    }
}

/// Revocation is possible only before native submission. Once submitted, the
/// owner must await the actual callback; Task cancellation is not native drain.
final class FolderDefaultRequestPermit: @unchecked Sendable {
    private enum State { case waiting, submitted, cancelled }
    private let lock = NSLock()
    private var state = State.waiting
    func cancelBeforeSubmission() { lock.withLock { if state == .waiting { state = .cancelled } } }
    func beginSubmission() -> Bool {
        lock.withLock {
            guard state == .waiting else { return false }
            state = .submitted
            return true
        }
    }
    var isSubmitted: Bool { lock.withLock { state == .submitted } }
}

enum FolderDefaultCallback: String, Codable, Equatable, Sendable { case returned, cancelled, failed }
/// Only the existing closed diagnostic projection crosses the callback queue.
/// Native descriptions, domain strings and userInfo never reach app history.
struct FolderDefaultNativeFailure: Sendable {
    let error: DiagnosticErrorCode
    let causes: [DiagnosticErrorCode]
    init(_ error: Error) {
        self.error = DiagnosticErrors.project(error)
        causes = DiagnosticErrors.causes(error)
    }
}
enum FolderDefaultSystemReply: Sendable {
    case notSubmitted
    case completed(FolderDefaultCallback, failure: FolderDefaultNativeFailure? = nil)
}

// A specific qualification seam, limited to the public.folder operation.
protocol FolderDefaultSystem: Sendable {
    func runningApplication() async throws -> FolderDefaultApplication
    func currentApplication() async throws -> FolderDefaultApplication?
    func request(_ destination: FolderDefaultApplication, expecting current: FolderDefaultApplication,
                 permit: FolderDefaultRequestPermit) async -> FolderDefaultSystemReply
}

/// Construction is inert. No launches, registration, Finder scripting, file:
/// scheme changes or personal folder URLs are used by this adapter.
final class NativeFolderDefaultSystem: FolderDefaultSystem, @unchecked Sendable {
    private let queue = DispatchQueue(label: "Traverse.FolderDefault.System", qos: .utility)
    private let runningURL: URL
    private let activity: FileActivityGate
    init(activity: FileActivityGate, runningBundle: Bundle = .main) {
        self.activity = activity; runningURL = runningBundle.bundleURL
    }

    func runningApplication() async throws -> FolderDefaultApplication {
        try await onQueue { [self] in
            let app = try Self.inspectRunning(runningURL)
            guard FolderDefaultIdentityPolicy.acceptsRunning(app) else {
                throw FolderDefaultFailure.notQualified
            }
            return app
        }
    }
    func currentApplication() async throws -> FolderDefaultApplication? {
        try await onQueue { try Self.current() }
    }
    func request(_ destination: FolderDefaultApplication, expecting current: FolderDefaultApplication,
                 permit: FolderDefaultRequestPermit) async -> FolderDefaultSystemReply {
        // Separately promoted Preview-only activation. Metadata and exact
        // running identity are revalidated on the worker before native entry.
        guard FolderDefaultIdentityPolicy.permitsPreviewBuild else { return .notSubmitted }
        return await withCheckedContinuation { continuation in
            queue.async { [self] in
                do {
                    // The coordinator retains its activity lease through the
                    // callback and readback. This worker does not own UI state.
                    let running = try Self.inspectRunning(runningURL)
                    // Both modern type-wide entry points were refused by the
                    // current macOS. The Preview compatibility request uses
                    // Apple's public role-handler API, never preference-file
                    // editing or an automatic second attempt. That API names a
                    // bundle ID rather than a URL, so require its currently
                    // resolved application to be the exact reviewed copy.
                    let reference = runningURL.appendingPathComponent("Contents/Resources", isDirectory: true)
                    let keys: Set<URLResourceKey> = [.contentTypeKey, .isDirectoryKey, .isSymbolicLinkKey, .fileResourceIdentifierKey]
                    let facts = try reference.resourceValues(forKeys: keys)
                    guard FolderDefaultIdentityPolicy.previewActivationEligible(running,
                        distribution: FolderDefaultIdentityPolicy.distributionBuild,
                        previewBuild: FolderDefaultIdentityPolicy.permitsPreviewBuild),
                          facts.contentType == .folder, facts.isDirectory == true, facts.isSymbolicLink != true,
                          try Self.inspectApplication(destination.url).identifies(destination),
                          let registered = NSWorkspace.shared.urlForApplication(withBundleIdentifier: destination.bundleIdentifier),
                          try Self.inspectApplication(registered).identifies(destination),
                          try Self.current()?.identifies(current) == true,
                          let referenceID = facts.fileResourceIdentifier as? NSObject else {
                        continuation.resume(returning: .notSubmitted)
                        return
                    }
                    var freshReference = reference
                    freshReference.removeAllCachedResourceValues()
                    let finalFacts = try freshReference.resourceValues(forKeys: keys)
                    guard finalFacts.contentType == .folder, finalFacts.isDirectory == true, finalFacts.isSymbolicLink != true,
                          (finalFacts.fileResourceIdentifier as? NSObject)?.isEqual(referenceID) == true,
                          permit.beginSubmission() else {
                        continuation.resume(returning: .notSubmitted); return
                    }
                    // This public API is deprecated in favor of the two
                    // observed-refused NSWorkspace overloads. Keep it confined
                    // to explicit Preview qualification and use the same API
                    // for Restore. Readback remains the coordinator's verdict;
                    // neither registration nor a noErr return proves routing.
                    // The current-handler comparison and this call are not CAS.
                    let status = LSSetDefaultRoleHandlerForContentType(UTType.folder.identifier as CFString,
                        .all, destination.bundleIdentifier as CFString)
                    let error = status == noErr ? nil : NSError(domain: NSOSStatusErrorDomain, code: Int(status))
                    let reply: FolderDefaultCallback = status == noErr ? .returned : status == userCanceledErr ? .cancelled : .failed
                    continuation.resume(returning: .completed(reply, failure: error.map(FolderDefaultNativeFailure.init)))
                } catch { continuation.resume(returning: .notSubmitted) }
            }
        }
    }
    private func onQueue<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                let result = Result {
                    let lease = try activity.begin()
                    defer { withExtendedLifetime(lease) {} }
                    return try body()
                }
                continuation.resume(with: result)
            }
        }
    }
    private static func current() throws -> FolderDefaultApplication? {
        try NSWorkspace.shared.urlForApplication(toOpen: .folder).map(inspectApplication)
    }
    private static func inspectRunning(_ url: URL) throws -> FolderDefaultApplication {
        let app = try inspectApplication(url)
        if app.bundleIdentifier == FolderDefaultIdentityPolicy.previewIdentifier {
            guard let info = Bundle(url: url)?.infoDictionary,
                  FolderDefaultIdentityPolicy.hasPreviewFolderDeclaration(info) else { throw FolderDefaultFailure.notQualified }
        }
        return app
    }
    private static func inspectApplication(_ url: URL) throws -> FolderDefaultApplication {
        // App-bundle metadata only, on the utility worker; no directory listing.
        try FolderDefaultApplication.validateLocation(url)
        guard let bundle = Bundle(url: url), let identifier = bundle.bundleIdentifier,
              FolderDefaultIdentityPolicy.acceptsPackageType(bundle.object(forInfoDictionaryKey: "CFBundlePackageType") as? String,
                  identifier: identifier, at: url) else { throw FolderDefaultFailure.invalidApplication }
        let info = bundle.infoDictionary ?? [:]
        let preview = try FolderDefaultIdentityPolicy.previewCase(identifier: identifier, info: info,
            applicationParent: url.deletingLastPathComponent())
        let app = FolderDefaultApplication(url: url, bundleIdentifier: identifier,
            name: url.deletingPathExtension().lastPathComponent, previewCaseID: preview)
        try app.validate()
        return app
    }
}
