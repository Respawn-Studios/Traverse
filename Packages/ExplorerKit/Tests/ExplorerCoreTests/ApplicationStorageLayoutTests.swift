import Foundation
import Testing

@testable import ExplorerCore

struct ApplicationStorageLayoutTests {
    @Test func directUserDomainDoesNotReuseScopedOrLegacyNamespace() throws {
        let home = URL(fileURLWithPath: "/Generated/User", isDirectory: true)
        let direct = try ApplicationStorageLayout.directUserDomain(homeDirectory: home)
        let library = home.appendingPathComponent("Library", isDirectory: true)
        #expect(direct.channel == .portable)
        #expect(direct.stateDirectory == library.appendingPathComponent(
            "Application Support/com.respawnstudios.traverse.direct", isDirectory: true))
        #expect(direct.cacheDirectory == library.appendingPathComponent(
            "Caches/com.respawnstudios.traverse.direct", isDirectory: true))
        #expect(direct.stateDirectory != library.appendingPathComponent(
            "Application Support/com.respawnstudios.traverse", isDirectory: true))
        #expect(throws: ApplicationStorageLayout.Failure.invalidLocation) {
            try ApplicationStorageLayout.directUserDomain(homeDirectory: URL(fileURLWithPath:
                "/Generated/User/Library/Containers/com.respawnstudios.traverse/Data", isDirectory: true))
        }
    }
    @Test func portableSeparatesPersistentAndTemporaryMetadataWithoutMigration() throws {
        let support = URL(fileURLWithPath: "/Generated/Library/Application Support", isDirectory: true)
        let caches = URL(fileURLWithPath: "/Generated/Library/Caches", isDirectory: true)
        let value = try ApplicationStorageLayout(
            applicationSupport: support, caches: caches, bundleIdentifier: "com.respawn.ExplorerBeta")
        #expect(value.stateDirectory == support.appendingPathComponent("com.respawn.ExplorerBeta", isDirectory: true))
        #expect(value.cacheDirectory == caches.appendingPathComponent("com.respawn.ExplorerBeta", isDirectory: true))
        #expect(value.stateCreationChain == [support, value.stateDirectory])
        #expect(value.cacheCreationChain == [caches, value.cacheDirectory])
        #expect(value.smbDirectory.path.hasPrefix(value.cacheDirectory.path + "/"))
        #expect(value.analysisDirectory.path.hasPrefix(value.cacheDirectory.path + "/"))
        #expect(value.stateDirectory != value.cacheDirectory)
    }
    @Test func developmentPreservesLegacyLocationsExactly() throws {
        let state = URL(fileURLWithPath: "/Generated/.build/runtime", isDirectory: true)
        let analysis = URL(fileURLWithPath: "/Generated/Caches/MacExplorer-Analysis", isDirectory: true)
        let value = try ApplicationStorageLayout(developmentState: state, legacyAnalysis: analysis)
        #expect(value.stateDirectory == state && value.analysisDirectory == analysis)
        #expect(value.smbDirectory == state.appendingPathComponent("smb-browsing", isDirectory: true))
        #expect(value.stateCreationChain == [state] && value.cacheCreationChain == [analysis])
    }
    @Test func identifiersAndPathsCannotEscapeTheirNamespace() throws {
        let base = URL(fileURLWithPath: "/Generated/Library")
        for id in [
            "", ".hidden", "com..app", "com.app/escape", "com.app\\escape", "com.éxplorer", "com.app\nName", "../app",
            String(repeating: "a", count: 201),
        ] {
            #expect(throws: ApplicationStorageLayout.Failure.invalidIdentifier) {
                try ApplicationStorageLayout(
                    applicationSupport: base, caches: base.appendingPathComponent("../Caches").standardizedFileURL,
                    bundleIdentifier: id)
            }
        }
        for url in [
            URL(string: "smb://host/share")!, URL(string: "file:///Generated/nul%00tail")!,
            URL(fileURLWithPath: "/"), URL(fileURLWithPath: "/Generated/child/../Library"),
        ] {
            #expect(throws: ApplicationStorageLayout.Failure.invalidLocation) {
                try ApplicationStorageLayout(applicationSupport: url, caches: base, bundleIdentifier: "local.generated")
            }
        }
    }
    @Test func configurationKeepsChannelsExplicitAndDistributionIgnoresDevelopmentPath() throws {
        let support = URL(fileURLWithPath: "/Generated/Library/Application Support")
        let caches = URL(fileURLWithPath: "/Generated/Library/Caches")
        let portable = try ApplicationStorageConfiguration.resolve(
            mode: "development", forcePortable: true, bundleIdentifier: "local.Generated",
            developmentPath: "/Other/state", applicationSupport: support, caches: caches,
            developmentCachePath: "/Invalid/other/cache")
        #expect(
            portable.channel == .portable && portable.stateDirectory.deletingLastPathComponent().path == support.path)
        for mode in ["future", "Portable", "portable "] {
            #expect(throws: ApplicationStorageConfiguration.Failure.unsupportedMode) {
                try ApplicationStorageConfiguration.resolve(
                    mode: mode, forcePortable: true, bundleIdentifier: "local.Generated", developmentPath: nil,
                    applicationSupport: support, caches: caches)
            }
        }
        for path in ["relative", "$(SRCROOT)/state", "/Generated/nul\u{0}tail", "/Generated/new\nline"] {
            #expect(throws: ApplicationStorageConfiguration.Failure.unavailable) {
                try ApplicationStorageConfiguration.resolve(
                    mode: "development", forcePortable: false, bundleIdentifier: nil, developmentPath: path,
                    applicationSupport: support, caches: caches)
            }
        }
        #expect(throws: ApplicationStorageLayout.Failure.invalidLocation) {
            try ApplicationStorageLayout(
                applicationSupport: support, caches: support, bundleIdentifier: "local.Generated")
        }
    }
    @Test func explicitDevelopmentCacheIsPrivateAnalysisSelectionWhileLegacyFallbackPersists() throws {
        let caches = URL(fileURLWithPath: "/Generated/Library/Caches", isDirectory: true)
        let state = "/Generated/.build/runtime"
        let selected = try ApplicationStorageConfiguration.resolve(
            mode: "development", forcePortable: false, bundleIdentifier: nil,
            developmentPath: state, applicationSupport: nil, caches: caches,
            developmentCachePath: "/Generated/.build/runtime-cache")
        #expect(selected.channel == .development)
        #expect(selected.stateDirectory.path == state)
        #expect(selected.cacheDirectory.path == "/Generated/.build/runtime-cache")
        #expect(selected.analysisDirectory.path == "/Generated/.build/runtime-cache/storage-analysis")
        let withoutSystemCaches = try ApplicationStorageConfiguration.resolve(
            mode: "development", forcePortable: false, bundleIdentifier: nil,
            developmentPath: state, applicationSupport: nil, caches: nil,
            developmentCachePath: "/Generated/.build/runtime-cache")
        #expect(withoutSystemCaches == selected)
        let legacy = try ApplicationStorageConfiguration.resolve(
            mode: "development", forcePortable: false, bundleIdentifier: nil,
            developmentPath: state, applicationSupport: nil, caches: caches)
        #expect(legacy.analysisDirectory == caches.appendingPathComponent("MacExplorer-Analysis", isDirectory: true))
        for invalid in ["relative/cache", "$(SRCROOT)/.build/runtime-cache", "/Other/runtime-cache", state,
                        "/Generated/.build/runtime/child", "/Generated/.build/new\ncache"] {
            #expect(throws: (any Error).self) {
                try ApplicationStorageConfiguration.resolve(
                    mode: "development", forcePortable: false, bundleIdentifier: nil,
                    developmentPath: state, applicationSupport: nil, caches: caches,
                    developmentCachePath: invalid)
            }
        }
    }
}
