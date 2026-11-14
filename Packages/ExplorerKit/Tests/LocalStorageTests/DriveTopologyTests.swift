import Foundation
import Testing
@testable import LocalStorage

struct DriveTopologyTests {
    private func node(_ id: UInt64, parent: UInt64? = nil, kind: DriveTopologyNode.Kind = .device,
                      path: String? = nil, verified: Bool = true, capacity: UInt64? = 512 << 30) -> DriveTopologyNode {
        let volume = ManagedVolume(id: UUID(), name: "Private generated \(id)", url: path.map { URL(fileURLWithPath: $0) },
            isInternal: true, canMount: false, canUnmount: false, canEject: false,
            fileSystemID: nil, group: nil, mediaID: id)
        return .init(id: id, parentID: parent, kind: kind, name: volume.name, deviceName: "generated-\(id)",
            capacity: capacity, fields: .init(fileSystem: kind == .volume ? "apfs" : nil),
            volume: volume, relationshipVerified: verified)
    }
    @Test func apfsRelationshipsKeepSharedVolumesDistinctFromPartitions() throws {
        let snapshot = try DriveTopologySnapshot(nodes: [
            node(1), node(2, parent: 1, kind: .partition), node(3, parent: 2, kind: .apfsContainer),
            node(4, parent: 3, kind: .volume, path: "/"), node(5, parent: 3, kind: .volume, path: "/System/Volumes/Data")
        ])
        #expect(snapshot.roots.map(\.id) == [1])
        #expect(snapshot.children(of: 1).map(\.kind) == [.partition])
        #expect(snapshot.path(to: 5).map(\.id) == [1, 2, 3, 5])
        #expect(snapshot.node(4)?.sharesContainerSpace == true && snapshot.node(5)?.sharesContainerSpace == true)
        #expect(snapshot.node(3)?.sharesContainerSpace == false && !snapshot.hasUnresolvedRelationships)
        #expect(snapshot.containsSystemStorage(1) && snapshot.containsSystemStorage(3) && snapshot.containsSystemStorage(5))
        #expect(!snapshot.containsSystemStorage(900))
    }
    @Test func missingAndUnsupportedRelationshipsStayVisible() throws {
        let snapshot = try DriveTopologySnapshot(nodes: [node(1), node(2, parent: 999, kind: .unresolved, verified: false)])
        #expect(snapshot.roots.map(\.id) == [1, 2] && snapshot.hasUnresolvedRelationships)
        #expect(snapshot.path(to: 2).map(\.id) == [2] && snapshot.node(999) == nil)
        #expect(try DriveTopologySnapshot(nodes: [], discoveryTruncated: true).hasUnresolvedRelationships)
    }
    @Test func malformedGraphsRejectRatherThanGuessOrRecurseWithoutLimit() throws {
        var invalid: [[DriveTopologyNode]] = [
            [node(1), node(1)], [node(0)], [node(1, parent: 1)],
            [node(1, parent: 2), node(2, parent: 1)], [node(1, capacity: UInt64.max)]
        ]
        let deep: [DriveTopologyNode] = (1...65).map { value in
            let parent: UInt64? = value == 1 ? nil : UInt64(value - 1)
            return node(UInt64(value), parent: parent)
        }
        invalid.append(deep)
        invalid.append((1...513).map { node(UInt64($0)) })
        for nodes in invalid {
            #expect(throws: VolumeLifecycleFailure.self) { try DriveTopologySnapshot(nodes: nodes) }
        }
    }
    @Test func boundedScaleAndRedactedDescriptionsDoNotNeedFilesystemWork() throws {
        let snapshot = try DriveTopologySnapshot(nodes: [node(1)] +
            (2...512).map { node(UInt64($0), parent: 1, kind: .volume) })
        #expect(snapshot.children(of: 1).count == 511 && snapshot.roots.count == 1)
        #expect(!String(describing: snapshot).contains("Private"))
        #expect(String(describing: snapshot.node(1)!) == "Drive topology observation")
        #expect(try DriveTopologySnapshot(nodes: []).roots.isEmpty)
    }
}
