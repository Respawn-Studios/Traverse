import Foundation

/// Pure path layout, not creation/access authority. Development stays at its
/// supplied legacy roots; portable profiles use their own bundle namespace.
public struct ApplicationStorageLayout: Equatable, Sendable {
    public enum Channel: Equatable, Sendable { case development, portable }
    public enum Failure: Error, Sendable { case invalidLocation, invalidIdentifier }
    public let channel: Channel
    public let stateDirectory: URL
    public let cacheDirectory: URL
    public let stateCreationChain: [URL]
    public let cacheCreationChain: [URL]
    private let separatesAnalysis: Bool
    public var analysisDirectory: URL {
        separatesAnalysis ? cacheDirectory.appendingPathComponent("storage-analysis", isDirectory: true) : cacheDirectory
    }
    public var smbDirectory: URL {
        (channel == .development ? stateDirectory : cacheDirectory).appendingPathComponent(
            "smb-browsing", isDirectory: true)
    }
    /// Inert selections only. smbDirectory deliberately retains the earlier
    /// portable Caches/development state path for compatibility accounting.
    public var persistentConnectionWorkspaceDirectory: URL {
        stateDirectory.appendingPathComponent("connection-workspace", isDirectory: true)
    }
    /// Sibling of the persistent connection workspace. This is a path
    /// selection for protection/accounting; only explicit v4 preparation may
    /// create it or grant access to its private SMB recovery bodies.
    public var smbInPlaceRecoveryDirectory: URL {
        Self.smbInPlaceRecoveryDirectory(metadata: persistentConnectionWorkspaceDirectory)
    }
    public static func smbInPlaceRecoveryDirectory(metadata: URL) -> URL {
        metadata.appendingPathExtension("smb-inplace")
    }
    public var connectionWorkspaceRecordDirectory: URL {
        stateDirectory.appendingPathComponent("connection-workspace-location", isDirectory: true)
    }
    /// Ordinary transfer bodies retain their independently qualified path and
    /// budget when connection metadata is activated in Application Support.
    public var ordinaryRemoteDownloadDirectory: URL {
        smbDirectory.deletingLastPathComponent().appendingPathComponent("remote-downloads", isDirectory: true)
    }
    public init(developmentState: URL, legacyAnalysis: URL, separateAnalysis: Bool = false) throws {
        try Self.validate(developmentState)
        try Self.validate(legacyAnalysis)
        channel = .development
        separatesAnalysis = separateAnalysis
        stateDirectory = developmentState
        cacheDirectory = legacyAnalysis
        stateCreationChain = [developmentState]
        cacheCreationChain = [legacyAnalysis]
    }
    public init(applicationSupport: URL, caches: URL, bundleIdentifier: String) throws {
        try Self.validate(applicationSupport)
        try Self.validate(caches)
        guard applicationSupport.path != caches.path,
            !applicationSupport.path.hasPrefix(caches.path + "/"), !caches.path.hasPrefix(applicationSupport.path + "/")
        else {
            throw Failure.invalidLocation
        }
        let parts = bundleIdentifier.split(separator: ".", omittingEmptySubsequences: false)
        guard (3...200).contains(bundleIdentifier.utf8.count), parts.count >= 2,
            parts.allSatisfy({
                !$0.isEmpty && ($0.first?.isLetter == true || $0.first?.isNumber == true)
                    && $0.unicodeScalars.allSatisfy {
                        $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-")
                    }
            })
        else { throw Failure.invalidIdentifier }
        channel = .portable
        separatesAnalysis = true
        stateDirectory = applicationSupport.appendingPathComponent(bundleIdentifier, isDirectory: true)
        cacheDirectory = caches.appendingPathComponent(bundleIdentifier, isDirectory: true)
        stateCreationChain = [applicationSupport, stateDirectory]
        cacheCreationChain = [caches, cacheDirectory]
    }
    /// Inert local-user layout. This never opens a sandbox container or copies
    /// earlier journals, bookmarks, catalogs or credentials into the new mode.
    public static func directUserDomain(homeDirectory: URL) throws -> Self {
        try validate(homeDirectory)
        let parts = homeDirectory.pathComponents
        guard !zip(parts, parts.dropFirst()).contains(where: { $0.0 == "Library" && $0.1 == "Containers" }) else {
            throw Failure.invalidLocation
        }
        let library = homeDirectory.appendingPathComponent("Library", isDirectory: true)
        return try Self(
            applicationSupport: library.appendingPathComponent("Application Support", isDirectory: true),
            caches: library.appendingPathComponent("Caches", isDirectory: true),
            bundleIdentifier: DirectPublicEditionIdentity.storageNamespace)
    }
    private static func validate(_ value: URL) throws {
        let decoded = URLComponents(url: value, resolvingAgainstBaseURL: false)?.percentEncodedPath
            .removingPercentEncoding
        guard value.isFileURL, value.host == nil || value.host == "" || value.host == "localhost",
            value.user == nil, value.password == nil, value.query == nil, value.fragment == nil,
            let decoded, decoded.hasPrefix("/"), decoded != "/", decoded.utf8.count <= 4096,
            !decoded.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
            value.standardizedFileURL.path == value.path
        else { throw Failure.invalidLocation }
    }
}

public enum ApplicationStorageConfiguration {
    public enum Failure: Error, Sendable { case unsupportedMode, unavailable }
    public static func resolve(
        mode: String, forcePortable: Bool, bundleIdentifier: String?,
        developmentPath: String?, applicationSupport: URL?, caches: URL?,
        developmentCachePath: String? = nil
    ) throws -> ApplicationStorageLayout {
        guard ["", "development", "portable"].contains(mode) else { throw Failure.unsupportedMode }
        if forcePortable || mode == "portable" {
            guard let applicationSupport, let caches, let bundleIdentifier else { throw Failure.unavailable }
            return try .init(applicationSupport: applicationSupport, caches: caches, bundleIdentifier: bundleIdentifier)
        }
        guard let developmentPath, developmentPath.hasPrefix("/"), !developmentPath.contains("$("),
            !developmentPath.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { throw Failure.unavailable }
        let state = URL(fileURLWithPath: developmentPath, isDirectory: true)
        if let developmentCachePath {
            let selected = URL(fileURLWithPath: developmentCachePath, isDirectory: true)
            guard developmentCachePath.hasPrefix("/"), !developmentCachePath.contains("$("),
                !developmentCachePath.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                selected.path == developmentCachePath,
                selected.deletingLastPathComponent().path == state.deletingLastPathComponent().path,
                selected.path != state.path
            else { throw Failure.unavailable }
            return try .init(developmentState: state, legacyAnalysis: selected, separateAnalysis: true)
        }
        guard let caches else { throw Failure.unavailable }
        return try .init(
            developmentState: state,
            legacyAnalysis: caches.appendingPathComponent("MacExplorer-Analysis", isDirectory: true))
    }
}
