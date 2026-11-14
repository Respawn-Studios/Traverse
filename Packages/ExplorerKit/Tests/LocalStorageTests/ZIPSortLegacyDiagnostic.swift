import Foundation
import Testing
@testable import LocalStorage

@Test func archiveSortLegacyDiagnostic() async throws {
    guard let path = ProcessInfo.processInfo.environment["MAC_EXPLORER_ARCHIVE_SORT_TEST_ROOT"],
          ProcessInfo.processInfo.environment["MAC_EXPLORER_ARCHIVE_SORT_BASELINE"] == "1" else { return }
    var builder = ZIPCatalogBuilder(limits: .init())
    try builder.add(name: "First.txt",kind: .file,logical: 1,packed: 1,method: 0,encrypted: false)
    try builder.add(name: "Last.txt",kind: .file,logical: 4_096,packed: 2_048,method: 8,encrypted: false)
    let catalog = ZIPArchiveSession(try builder.finish(records: 2,centralBytes: 0,zip64: false,cancelled: { false }))
    let first = try await catalog.page(in: catalog.root)
    #expect(first.items.map(\.name) == ["First.txt","Last.txt"])
    #expect(first.items[0].logicalBytes < first.items[1].logicalBytes)
    try JSONSerialization.data(withJSONObject: ["fixedOrderIsNotLargestFirst":true,"metadataOnly":true,
        "legacyFirst":"First.txt","largest":"Last.txt","payloadReads":0],options:[.sortedKeys])
        .write(to:URL(fileURLWithPath:path).appendingPathComponent("evidence/legacy-order.json"),options:.withoutOverwriting)
    await catalog.close()
}
