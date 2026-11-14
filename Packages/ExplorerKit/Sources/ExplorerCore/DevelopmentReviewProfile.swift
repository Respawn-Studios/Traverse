import Foundation

/// A local review installation has one sealed, independent profile. This
/// describes paths only; it grants no file access and never migrates beta data.
public struct DevelopmentReviewProfile: Sendable {
    public static let identifier = "local.macexplorer.preview"
    public static let channel = "development-preview"
    public enum Failure: Error { case invalidIdentity, invalidCase, invalidCheckout }
    public enum Storage: String, Sendable { case repository = "repository-v1", privateUser = "private-user-v1" }
    public let caseID: String
    public let layout: ApplicationStorageLayout

    public init(identifier: String?, channel: String?, caseID: String?, checkout: URL,
                storage: Storage = .repository, applicationSupport: URL? = nil, caches: URL? = nil) throws {
        guard identifier == Self.identifier, channel == Self.channel else { throw Failure.invalidIdentity }
        guard let caseID, UUID(uuidString: caseID)?.uuidString == caseID else { throw Failure.invalidCase }
        guard checkout.isFileURL, checkout.host == nil || checkout.host == "" || checkout.host == "localhost",
              checkout.user == nil, checkout.password == nil, checkout.query == nil, checkout.fragment == nil,
              checkout.path != "/", checkout.standardizedFileURL == checkout,
              !checkout.path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { throw Failure.invalidCheckout }
        self.caseID = caseID
        if storage == .privateUser {
            guard let applicationSupport, let caches else { throw ApplicationStorageLayout.Failure.invalidLocation }
            layout = try .init(applicationSupport: applicationSupport, caches: caches,
                               bundleIdentifier: Self.identifier + "." + caseID.lowercased())
            return
        }
        let root = checkout.appendingPathComponent(".build/traverse-development", isDirectory: true)
            .appendingPathComponent(caseID, isDirectory: true)
        layout = try .init(developmentState: root.appendingPathComponent("state", isDirectory: true),
                           legacyAnalysis: root.appendingPathComponent("cache", isDirectory: true), separateAnalysis: true)
    }
}
