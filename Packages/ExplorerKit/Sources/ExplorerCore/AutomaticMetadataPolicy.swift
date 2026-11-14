import Foundation

/// A shared boundary for automatic search/completion. This does not change
/// explicit ordinary browsing or grant access to any filesystem location.
public enum AutomaticMetadataPolicy {
    private static let credentialComponents: Set<String> = [
        ".ssh", ".gnupg", ".aws", ".azure", ".kube", ".netrc", ".npmrc", ".pypirc",
        "keychains", "credentials", "secrets"
    ]
    public static func excludes(_ url: URL) -> Bool {
        url.standardizedFileURL.pathComponents.contains(where: excludesComponent)
    }
    public static func excludesComponent(_ component: String) -> Bool {
        credentialComponents.contains(component.lowercased(with: Locale(identifier: "en_US_POSIX")))
    }
}
