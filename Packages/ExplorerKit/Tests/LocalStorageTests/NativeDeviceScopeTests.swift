import Testing
@testable import LocalStorage

struct NativeDeviceScopeTests {
    private func node(_ id: UInt64, parent: UInt64? = nil, media: Bool = false, whole: Bool? = nil,
                      apfs: Bool = false, bridge: Bool = false, device: Bool = false) -> NativeDeviceScope.Node {
        .init(id: id, parents: parent.map { [$0] } ?? [], isMedia: media, whole: whole,
              apfsSynthesized: apfs, apfsBridge: bridge, blockStorageDevice: device)
    }
    private var apfs: [NativeDeviceScope.Node] {
        [node(1, parent: 2, media: true, whole: false), node(2, parent: 3),
         node(3, parent: 4, media: true, whole: true, apfs: true), node(4, parent: 5, bridge: true),
         node(5, parent: 6, media: true, whole: false), node(6, parent: 7),
         node(7, parent: 8, media: true, whole: true), node(8, parent: 9), node(9, device: true)]
    }

    @Test func ordinaryMediaAndAPFSResolveDistinctRemovalScopes() throws {
        let ordinary = try NativeDeviceScope(nodes: [node(1, parent: 2, media: true, whole: false),
            node(2, parent: 3, media: true, whole: true), node(3, device: true)], nearestWhole: 2)
        #expect(ordinary.nearestWhole == 2 && ordinary.outerWhole == 2)
        let container = try NativeDeviceScope(nodes: apfs, nearestWhole: 3)
        #expect(container.nearestWhole == 3 && container.outerWhole == 7)
        let bare = try NativeDeviceScope(nodes: [node(7, parent: 9, media: true, whole: true), node(9, device: true)], nearestWhole: 7)
        #expect(bare.outerWhole == 7)
    }

    @Test func ambiguousParentsMissingFlagsUnknownStackAndCyclesRefuse() throws {
        var branched = apfs
        branched[4] = .init(id: 5, parents: [6, 99], isMedia: true, whole: false,
                            apfsSynthesized: false, apfsBridge: false, blockStorageDevice: false)
        var unknown = apfs; unknown[3] = node(4, parent: 5)
        var missing = apfs; missing[4] = node(5, parent: 6, media: true)
        var unknownWhole = apfs; unknownWhole[2] = node(3, parent: 4, media: true, whole: true)
        var terminal = apfs; terminal[8] = node(9)
        var cycle = apfs; cycle[5] = node(5, parent: 7)
        var extraWhole = apfs; extraWhole[4] = node(5, parent: 6, media: true, whole: true)
        for candidate in [branched, unknown, missing, unknownWhole, terminal, cycle, extraWhole,
                          Array(apfs.dropLast()), Array(repeating: apfs[0], count: 65)] {
            #expect(throws: VolumeLifecycleFailure.self) { try NativeDeviceScope(nodes: candidate, nearestWhole: 3) }
        }
        #expect(throws: VolumeLifecycleFailure.self) { try NativeDeviceScope(nodes: apfs, nearestWhole: 7) }
    }

    @Test func aProviderReplacementChangesTheCapturedScope() throws {
        let first = try NativeDeviceScope(nodes: apfs, nearestWhole: 3)
        var replaced = apfs
        replaced[7] = node(8, parent: 99); replaced[8] = node(99, device: true)
        let second = try NativeDeviceScope(nodes: replaced, nearestWhole: 3)
        #expect(first.outerWhole == second.outerWhole && first != second)
        #expect(!NativeDeviceReader.isPresent(UInt64.max))
    }
}
