/// Mutually exclusive Developer ID updater modes. Presence matters: an empty
/// or null competing marker is invalid rather than silently ignored.
internal enum DirectUpdaterMarker: Equatable {
    case absent, privateBeta, publicRelease, directPublic

    static func resolve(info: [String: Any]) -> Self? {
        let privateKey = "TraversePrivateUpdaterVersion"
        let publicKey = "TraversePublicUpdaterVersion"
        let directKey = "TraverseDirectPublicUpdaterVersion"
        let hasPrivate = info.keys.contains(privateKey)
        let hasPublic = info.keys.contains(publicKey)
        let hasDirect = info.keys.contains(directKey)
        guard [hasPrivate, hasPublic, hasDirect].filter({ $0 }).count <= 1 else { return nil }
        if hasPrivate {
            return info[privateKey] as? String == "2.10.0" ? .privateBeta : nil
        }
        if hasPublic {
            return info[publicKey] as? String == "2.10.0" ? .publicRelease : nil
        }
        if hasDirect {
            return info[directKey] as? String == "2.10.0" ? .directPublic : nil
        }
        return .absent
    }

    var requiresInstallerRights: Bool { self == .privateBeta || self == .publicRelease }
}
