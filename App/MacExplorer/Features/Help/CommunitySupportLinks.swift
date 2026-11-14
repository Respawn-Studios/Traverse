import Foundation

/// Release-owned links. Never substitute a paid pass for voluntary support.
enum CommunitySupportLinks {
    static var funding: URL? {
        url("TraverseVoluntarySupportURL", hosts: ["respawn-studios.com", "buymeacoffee.com"])
            ?? URL(string: "https://buymeacoffee.com/respawnstudios")
    }
    static var source: URL? {
        url("TraversePublicSourceURL", hosts: ["github.com", "respawn-studios.com"])
            ?? URL(string: "https://github.com/Respawn-Studios/Traverse")
    }
    static let discord = URL(string: "https://discord.gg/UdKp2uQBQy")
    static var isPublicLaunch: Bool {
        Bundle.main.bundleIdentifier == "com.respawnstudios.traverse"
            && [.publicRelease, .directPublic].contains(AppFeatureAvailability.policy.edition)
            && Bundle.main.object(forInfoDictionaryKey: "TraverseCommunityRelease") as? Bool == true
            && funding != nil && source != nil
    }

    private static func url(_ key: String, hosts: Set<String>) -> URL? {
        guard let text = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              let parts = URLComponents(string: text), parts.scheme == "https",
              let host = parts.host, hosts.contains(host), parts.user == nil, parts.password == nil,
              parts.port == nil, parts.query == nil, parts.fragment == nil else { return nil }
        let path = "/" + parts.path.split(separator: "/").joined(separator: "/")
        guard !["/support-the-studio", "/supporter-pass"].contains(path) else { return nil }
        return parts.url
    }
}
