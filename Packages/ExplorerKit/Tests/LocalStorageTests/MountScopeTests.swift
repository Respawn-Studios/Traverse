import Darwin
import Foundation
import Testing
@testable import LocalStorage

struct MountScopeTests {
    private func entry(_ path: String, type: String = "apfs", source: String = "/dev/generated", native: MountScopeObservation.Native = .block(leaf: 11, whole: 10),
                       device: Int64 = 20, inode: UInt64 = 1, local: Bool = true, network: Bool? = false) -> MountScopeObservation {
        let url = URL(fileURLWithPath: path)
        return MountScopeObservation(requested: url, mount: url, source: source, fileSystem: type,
            fileSystemID: 20, fileSystemIDExtra: 0, flags: local ? UInt32(MNT_LOCAL) : 0,
            object: .init(device: device, inode: inode), parent: .init(device: device, inode: 1), native: native,
            nativeNetwork: network, nativeProtocol: nil)
    }
    @Test func ordinaryAndKnownSyntheticFactsStayDistinguishable() throws {
        let direct = entry("/generated/disk")
        let device = entry("/generated/provider", type: "devicefs", source: "Generated namespace", native: .noMedia)
        let lower = entry("/generated/lower", native: .block(leaf: 101, whole: 100))
        let layer = entry("/generated/layer", type: "nullfs", source: lower.requested.path, native: .noMedia)
        let values = Dictionary(uniqueKeysWithValues: [direct, device, lower, layer].map { ($0.requested, $0) })
        let resolver = MountScopeResolver { try #require(values[$0]) }
        #expect(try resolver.resolve(direct.requested) == .block(group: 10, device: 20))
        #expect(try resolver.resolve(device.requested) == .knownDeviceNamespace)
        // An observed lower path is deliberately returned as currentLayer,
        // rather than silently promoted to proven native block membership.
        #expect(try resolver.resolve(layer.requested) == .currentLayer(group: 100))
        #expect(resolver.proof.observations.count == 4)
        try resolver.revalidate()
    }
    @Test func unknownIncompleteOrUnresolvableCannotAcquireMembership() throws {
        for value in [entry("/generated/a", native: .unresolved),
                      entry("/generated/a", type: "unknown", native: .noMedia),
                      entry("/generated/a", type: "devicefs", native: .noMedia),
                      entry("/generated/a", type: "devicefs", source: "Namespace", native: .noMedia, local: false),
                      entry("/generated/a", type: "devicefs", source: "Namespace", native: .noMedia, network: nil),
                      entry("/generated/a", type: "nullfs", source: "relative", native: .noMedia),
                      entry("/generated/a", type: "nullfs", source: "/missing", native: .noMedia)] {
            let resolver = MountScopeResolver { url in
                guard url == value.requested else { throw VolumeLifecycleFailure.unavailable }; return value
            }
            #expect(throws: (any Error).self) { try resolver.resolve(value.requested) }
        }
    }
    @Test func cyclesDepthAndNativeSubstitutionRefuse() throws {
        let a = entry("/generated/a", type: "nullfs", source: "/generated/b", native: .noMedia)
        let b = entry("/generated/b", type: "nullfs", source: "/generated/a", native: .noMedia)
        let cycle = MountScopeResolver { $0 == a.requested ? a : b }
        #expect(throws: (any Error).self) { try cycle.resolve(a.requested) }
        let deep = MountScopeResolver { url in
            let index = Int(url.lastPathComponent) ?? 0
            return entry(url.path, type: "nullfs", source: "/generated/\(index + 1)", native: .noMedia)
        }
        #expect(throws: (any Error).self) { try deep.resolve(URL(fileURLWithPath: "/generated/0")) }
        var values = [a.requested: a, b.requested: entry(b.requested.path)]
        let resolver = MountScopeResolver { try #require(values[$0]) }
        _ = try resolver.resolve(a.requested)
        values[b.requested] = entry(b.requested.path, native: .block(leaf: 201, whole: 200))
        #expect(throws: (any Error).self) { try resolver.revalidate() }
    }
    @Test func sourceObjectReplacementIsNotHiddenByUnchangedSourceSpelling() throws {
        let layer = entry("/generated/layer", type: "nullfs", source: "/generated/source", native: .noMedia)
        var source = entry("/generated/source", inode: 123)
        let resolver = MountScopeResolver { $0 == layer.requested ? layer : source }
        _ = try resolver.resolve(layer.requested)
        source = entry(source.requested.path, inode: 456)
        #expect(throws: (any Error).self) { try resolver.revalidate() }
    }

    @Test func normalRequestsAllowKnownUnrelatedLayersButRefuseTargetBackedLayers() throws {
        let target = entry("/generated/target", device: 20)
        let sibling = entry("/generated/sibling", native: .block(leaf: 12, whole: 10), device: 21)
        let other = entry("/generated/other", native: .block(leaf: 101, whole: 100), device: 200)
        let layer = entry("/generated/layer", type: "nullfs", source: other.requested.path, native: .noMedia)
        let namespace = entry("/generated/namespace", type: "devicefs", source: "Namespace", native: .noMedia)
        var values = Dictionary(uniqueKeysWithValues: [target, sibling, other, layer, namespace].map { ($0.requested, $0) })
        let resolver = MountScopeResolver { try #require(values[$0]) }
        #expect(try resolver.normalDiskMembers(in: [target, sibling, other, layer, namespace].map(\.requested), group: 10) == [20, 21])
        try resolver.revalidate()
        values[layer.requested] = entry(layer.requested.path, type: "nullfs", source: target.requested.path, native: .noMedia)
        #expect(throws: (any Error).self) { try resolver.revalidate() }
        let targetBacked = MountScopeResolver { try #require(values[$0]) }
        #expect(throws: VolumeLifecycleFailure.self) { try targetBacked.normalDiskMembers(in: [target.requested, layer.requested], group: 10) }
        let unknown = entry("/generated/unknown", type: "unknown", native: .noMedia)
        let unsupported = MountScopeResolver { _ in unknown }
        #expect(throws: (any Error).self) { try unsupported.normalDiskMembers(in: [unknown.requested], group: 10) }
        #expect(throws: (any Error).self) { try resolver.normalDiskMembers(in: Array(repeating: target.requested, count: 513), group: 10) }
    }

    @Test func protectedStorageRequiresDirectNativeMembership() throws {
        let native = entry("/generated/native", device: 20)
        let layer = entry("/generated/layer", type: "nullfs", source: native.requested.path, native: .noMedia)
        let namespace = entry("/generated/namespace", type: "devicefs", source: "Namespace", native: .noMedia)
        let values = Dictionary(uniqueKeysWithValues: [native, layer, namespace].map { ($0.requested, $0) })
        let resolver = MountScopeResolver { try #require(values[$0]) }
        try resolver.validateProtectedLocation(native.requested, devices: [200], wholeGroup: 100)
        #expect(throws: VolumeLifecycleFailure.self) { try resolver.validateProtectedLocation(native.requested, devices: [20], wholeGroup: nil) }
        #expect(throws: VolumeLifecycleFailure.self) { try resolver.validateProtectedLocation(native.requested, devices: [], wholeGroup: 10) }
        for url in [layer.requested, namespace.requested] {
            #expect(throws: VolumeLifecycleFailure.self) { try resolver.validateProtectedLocation(url, devices: [], wholeGroup: 100) }
        }
    }

    @Test func directoryChildWritesDoNotInvalidateItsIdentityButReplacementDoes() throws {
        // No real device action: this is an owned package-test directory only.
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let repository = package.deletingLastPathComponent().deletingLastPathComponent()
        let base = ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"].map { URL(fileURLWithPath: $0).standardizedFileURL }
            ?? package.appendingPathComponent(".build/test-fixtures", isDirectory: true)
        guard base.path.hasPrefix(repository.path + "/"), base.pathComponents.contains(".build"),
              base.resolvingSymlinksInPath().path == base.path else { throw LocalStorageError.unavailable }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let root = base.appendingPathComponent("mount-scope-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        var before = stat(), changed = stat(), replacement = stat()
        #expect(lstat(root.path, &before) == 0)
        try Data("generated".utf8).write(to: root.appendingPathComponent("child"), options: .withoutOverwriting)
        #expect(lstat(root.path, &changed) == 0)
        #expect(MountScopeObservation.Object(before) == MountScopeObservation.Object(changed))
        let retained = root.appendingPathComponent("original")
        let original = root.appendingPathComponent("directory")
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: false)
        #expect(lstat(original.path, &before) == 0)
        try FileManager.default.moveItem(at: original, to: retained)
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: false)
        #expect(lstat(original.path, &replacement) == 0)
        #expect(MountScopeObservation.Object(before) != MountScopeObservation.Object(replacement))
    }
}
