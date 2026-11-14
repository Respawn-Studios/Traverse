import Darwin
import ExplorerCore
import Foundation
import Testing
@testable import StorageAnalysis

private struct LocationFixture {
    let root: URL
    init() throws {
        var repository = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { repository.deleteLastPathComponent() }
        let base = ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"].map { URL(fileURLWithPath: $0) }
            ?? repository.appendingPathComponent(".build/test-fixtures")
        guard base.standardizedFileURL.path.hasPrefix(repository.path + "/"), base.resolvingSymlinksInPath().path == base.path else {
            throw StorageScanFailure.unsupportedLocation
        }
        try FileManager().createDirectory(at: base, withIntermediateDirectories: true)
        root = base.appendingPathComponent("analysis-location-" + UUID().uuidString)
        try FileManager().createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }
    func path(_ name: String) -> URL { root.appendingPathComponent(name) }
    func scope() throws -> AnalysisLocationSourceScope {
        let fd = open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
        guard fd >= 0 else { throw StorageScanFailure.unavailable }; defer { close(fd) }
        var value = stat(); guard fstat(fd, &value) == 0 else { throw StorageScanFailure.unavailable }
        return try .init(roots: [0: .init(url: root, descriptor: fd,
            identity: .init(device: UInt64(UInt32(bitPattern: value.st_dev)), inode: value.st_ino))], policy: .standard)
    }
    func step(_ relative: String, id: UInt64, parent: UInt64) throws -> StoredAnalysisLocationReference.Step {
        var value = stat(); guard lstat(path(relative).path, &value) == 0 else { throw StorageScanFailure.unavailable }
        return .init(id: id, parent: parent, name: Data(path(relative).lastPathComponent.utf8),
            kind: value.st_mode & S_IFMT == S_IFDIR ? .directory : .regularFile,
            identity: .init(device: UInt64(UInt32(bitPattern: value.st_dev)), inode: value.st_ino), flags: value.st_flags)
    }
}

private func locationFrame() -> [String: Any] {
    ["kind": "location", "location_revision": 1, "classification_revision": 3, "node": "7", "source": 0,
     "chain": [["id": "3", "parent": "0", "name": Data("Folder".utf8).base64EncodedString(), "type": 1,
                 "device": "1", "inode": "10", "flags": "0"],
                ["id": "7", "parent": "3", "name": Data("File.txt".utf8).base64EncodedString(), "type": 0,
                 "device": "1", "inode": "11", "flags": "0"]]]
}

@Suite struct StoredLocationTests {
    @Test func storedLocationCapabilityIsExplicitAndStrict() throws {
        let header: [String: Any] = ["schema": 11, "policy_revision": "local-metadata-v1", "classification_revision": 3,
            "profile": "full-result-classification-v3"]
        #expect(try AnalysisPolicyBinding(header: header, startup: false, policy: .standard, classificationRevision: .v3).storedLocationRevision == nil)
        var capable = header; capable["stored_location_revision"] = 1
        #expect(try AnalysisPolicyBinding(header: capable, startup: false, policy: .standard, classificationRevision: .v3).storedLocationRevision == 1)
        for wrong: Any in [true, "1", 2, -1] {
            capable["stored_location_revision"] = wrong
            #expect(throws: StorageScanFailure.self) { try AnalysisPolicyBinding(header: capable, startup: false, policy: .standard, classificationRevision: .v3) }
        }
    }
    @Test(.enabled(if: ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 27))
    func verifiedStartupSourcesResolveUsingPhysicalAndNamespaceFacts() async throws {
        let gate = FileActivityGate()
        let discovery = StartupVolumeDiscovery(activityGate: gate)
        let plan = try await discovery.discover()
        let scope = try AnalysisLocationSourceScope(roots: [
            1: .init(url: plan.dataRoot, descriptor: plan.data.descriptor, identity: plan.data.identity.object, physical: plan.data.identity),
            2: .init(url: plan.systemRoot, descriptor: plan.system.descriptor, identity: plan.system.identity.object, physical: plan.system.identity)
        ], policy: .standard)
        for (source, root, child) in [(UInt64(1), plan.data, "Users"), (UInt64(2), plan.system, "System")] {
            let empty = StoredAnalysisLocationReference(node: source, source: source, chain: [])
            let resolved = try scope.resolve(empty, cancelled: { !plan.isTopologyUnchanged })
            #expect(resolved.url == root.url && resolved.isSourceRoot)
            let fd = openat(root.descriptor, child, O_EVTONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
            guard fd >= 0 else { throw StorageScanFailure.unavailable }; defer { close(fd) }
            var value = stat(), attributes = attrlist()
            #expect(fstat(fd, &value) == 0)
            attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
            attributes.commonattr = UInt32(ATTR_CMN_RETURNED_ATTRS) | UInt32(ATTR_CMN_DEVID) | UInt32(ATTR_CMN_FILEID)
            attributes.forkattr = UInt32(ATTR_CMNEXT_REALDEVID | ATTR_CMNEXT_REALFSID)
            var bytes = [UInt8](repeating: 0, count: 48)
            #expect(fgetattrlist(fd, &attributes, &bytes, bytes.count, UInt32(FSOPT_ATTR_CMN_EXTENDED | FSOPT_RETURN_REALDEV)) == 0)
            let fields = try StartupNativeRoot.decode(Data(bytes))
            let step = StoredAnalysisLocationReference.Step(id: 3, parent: source, name: Data(child.utf8), kind: .directory,
                identity: .init(device: UInt64(fields.device), inode: fields.inode), flags: value.st_flags)
            let reference = StoredAnalysisLocationReference(node: 3, source: source, chain: [step])
            let target = try scope.resolve(reference, cancelled: { !plan.isTopologyUnchanged })
            #expect(target.url == root.url.appendingPathComponent(child) && !target.isSourceRoot)
        }
        try plan.revalidateNative()
        #expect(gate.activeCount == 0)
    }
    @Test func decoderBindsEveryParentSourceIdentityAndLeaf() throws {
        let value = try StoredAnalysisLocationReference.decode([locationFrame()], node: 7)
        #expect(value.source == 0 && value.chain.count == 2 && value.chain.last?.kind == .regularFile)
        for (key, wrong) in [("node", "8" as Any), ("source", true as Any), ("source", 3 as Any),
                             ("location_revision", 2 as Any), ("classification_revision", 2 as Any)] {
            var frame = locationFrame(); frame[key] = wrong
            #expect(throws: StorageScanFailure.self) { try StoredAnalysisLocationReference.decode([frame], node: 7) }
        }
        for (key, wrong) in [("parent", "1" as Any), ("id", "0" as Any), ("type", true as Any),
                             ("type", 2 as Any), ("device", "0" as Any), ("inode", "0" as Any),
                             ("flags", String(UInt64.max) as Any), ("name", Data("..".utf8).base64EncodedString() as Any),
                             ("name", Data("a/b".utf8).base64EncodedString() as Any)] {
            var frame = locationFrame(), rows = try #require(frame["chain"] as? [[String: Any]])
            rows[0][key] = wrong; frame["chain"] = rows
            #expect(throws: StorageScanFailure.self) { try StoredAnalysisLocationReference.decode([frame], node: 7) }
        }
        var startup = locationFrame(); startup["source"] = 1
        #expect(throws: StorageScanFailure.self) { try StoredAnalysisLocationReference.decode([startup], node: 7) }
    }
    @Test func sourceRootTagsRemainExplicitRatherThanNameBased() throws {
        let normal: [String: Any] = ["kind": "location", "location_revision": 1, "classification_revision": 3, "node": "0", "source": 0, "chain": [[String: Any]]()]
        #expect(try StoredAnalysisLocationReference.decode([normal], node: 0).chain.isEmpty)
        var data = normal; data["node"] = "1"; data["source"] = 1
        #expect(try StoredAnalysisLocationReference.decode([data], node: 1).source == 1)
        #expect(throws: StorageScanFailure.self) { try StoredAnalysisLocationReference.decode([data], node: 0) }
        var deep = locationFrame(); deep["chain"] = Array(repeating: (locationFrame()["chain"] as! [[String: Any]])[0], count: 65)
        #expect(throws: StorageScanFailure.self) { try StoredAnalysisLocationReference.decode([deep], node: 7) }
    }
    @Test func nativeMetadataResolutionPreservesExactPathAndReadsNoBody() throws {
        let fixture = try LocationFixture()
        try FileManager().createDirectory(at: fixture.path("Folder"), withIntermediateDirectories: false)
        try Data("generated".utf8).write(to: fixture.path("Folder/Café.txt"))
        let scope = try fixture.scope(), steps = try [fixture.step("Folder", id: 1, parent: 0), fixture.step("Folder/Café.txt", id: 2, parent: 1)]
        let result = try scope.resolve(.init(node: 2, source: 0, chain: steps), cancelled: { false })
        #expect(result.url == fixture.path("Folder/Café.txt") && result.kind == .regularFile && !result.isSourceRoot)
        #expect(try Data(contentsOf: result.url) == Data("generated".utf8))
        #expect(try scope.resolve(.init(node: 0, source: 0, chain: []), cancelled: { false }).isSourceRoot)
    }
    @Test func rootParentAndLeafSubstitutionRefuseWithoutRetargeting() throws {
        let fixture = try LocationFixture()
        try FileManager().createDirectory(at: fixture.path("Folder"), withIntermediateDirectories: false)
        try Data("generated".utf8).write(to: fixture.path("Folder/File.txt"))
        let scope = try fixture.scope(), steps = try [fixture.step("Folder", id: 1, parent: 0), fixture.step("Folder/File.txt", id: 2, parent: 1)]
        try FileManager().moveItem(at: fixture.path("Folder"), to: fixture.path("Original Folder"))
        try FileManager().createDirectory(at: fixture.path("Folder"), withIntermediateDirectories: false)
        try FileManager().linkItem(at: fixture.path("Original Folder/File.txt"), to: fixture.path("Folder/File.txt"))
        #expect(throws: StorageScanFailure.changed) { try scope.resolve(.init(node: 2, source: 0, chain: steps), cancelled: { false }) }
        let current = try [fixture.step("Folder", id: 1, parent: 0), fixture.step("Folder/File.txt", id: 2, parent: 1)]
        try FileManager().moveItem(at: fixture.path("Folder/File.txt"), to: fixture.path("Retained.txt"))
        try Data("new occupant".utf8).write(to: fixture.path("Folder/File.txt"))
        #expect(throws: StorageScanFailure.changed) { try scope.resolve(.init(node: 2, source: 0, chain: current), cancelled: { false }) }
        let oldRoot = fixture.root.deletingLastPathComponent().appendingPathComponent(fixture.root.lastPathComponent + "-original")
        try FileManager().moveItem(at: fixture.root, to: oldRoot)
        try FileManager().createDirectory(at: fixture.root, withIntermediateDirectories: false)
        #expect(throws: StorageScanFailure.changed) { try scope.resolve(.init(node: 0, source: 0, chain: []), cancelled: { false }) }
    }
    @Test func secondMetadataPassRejectsRaceAndCancellation() throws {
        let fixture = try LocationFixture()
        try Data("generated".utf8).write(to: fixture.path("File.txt"))
        let scope = try fixture.scope(), step = try fixture.step("File.txt", id: 1, parent: 0)
        #expect(throws: StorageScanFailure.changed) {
            try scope.resolve(.init(node: 1, source: 0, chain: [step]), cancelled: { false }, betweenChecks: {
                try FileManager().moveItem(at: fixture.path("File.txt"), to: fixture.path("Original.txt"))
                try Data("replacement".utf8).write(to: fixture.path("File.txt"))
            })
        }
        #expect(throws: CancellationError.self) { try scope.resolve(.init(node: 1, source: 0, chain: [step]), cancelled: { true }) }
    }
    @Test func linkPrivateDatalessAndUnrepresentableReferencesRefuse() throws {
        let fixture = try LocationFixture()
        try FileManager().createDirectory(at: fixture.path("Folder"), withIntermediateDirectories: false)
        try FileManager().createSymbolicLink(at: fixture.path("Link"), withDestinationURL: fixture.path("Folder"))
        let scope = try fixture.scope(), real = try fixture.step("Folder", id: 1, parent: 0)
        let symbolic = StoredAnalysisLocationReference.Step(id: 1, parent: 0, name: Data("Link".utf8), kind: .directory, identity: real.identity, flags: 0)
        #expect(throws: (any Error).self) { try scope.resolve(.init(node: 1, source: 0, chain: [symbolic]), cancelled: { false }) }
        for (name, flags) in [(Data(".ssh".utf8), UInt32(0)), (Data([255]), 0), (Data("Folder".utf8), UInt32(SF_DATALESS))] {
            let denied = StoredAnalysisLocationReference.Step(id: 1, parent: 0, name: name, kind: .directory, identity: real.identity, flags: flags)
            #expect(throws: StorageScanFailure.unsupportedLocation) { try scope.resolve(.init(node: 1, source: 0, chain: [denied]), cancelled: { false }) }
        }
    }
}
