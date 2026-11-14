import Foundation
import Testing
@testable import LocalStorage

@Suite struct ZIPArchiveSortingTests {
    private struct Entry {
        let name: String, logical: UInt64, packed: UInt64, method: UInt16
        let kind: ZIPMemberKind
        init(_ name: String,_ logical: UInt64 = 0,_ packed: UInt64 = 0,_ method: UInt16 = 0,kind: ZIPMemberKind = .file) {
            self.name = name; self.logical = logical; self.packed = packed; self.method = method; self.kind = kind
        }
    }
    private func storage(_ entries: [Entry]) throws -> ZIPCatalogStorage {
        var builder = ZIPCatalogBuilder(limits:.init())
        for e in entries { try builder.add(name:e.name,kind:e.kind,logical:e.logical,packed:e.packed,method:e.method,encrypted:false) }
        return try builder.finish(records:entries.count,centralBytes:0,zip64:false,cancelled:{false})
    }
    private func catalog(_ entries: [Entry]) throws -> ZIPArchiveSession { ZIPArchiveSession(try storage(entries)) }
    private func many() -> [Entry] {
        (0..<600).map { (index: Int) -> Entry in
            let logical = UInt64(index), packed = UInt64(599-index)
            let method: UInt16 = index%3 == 0 ? 8 : 0
            return Entry("Folder/Entry \(index).txt",logical,packed,method)
        }
    }

    @Test func naturalNamesAndFolderPartitionRemainExplicitInBothDirections() async throws {
        let s = try catalog([.init("File 10.txt"),.init("File 2.txt"),.init("Z Folder/Child"),.init("A Folder/Child")])
        #expect(try await s.page(in:s.root,sorting:.init(.name)).items.map(\.name) == ["A Folder","Z Folder","File 2.txt","File 10.txt"])
        #expect(try await s.page(in:s.root,sorting:.init(.name,descending:true)).items.map(\.name) == ["Z Folder","A Folder","File 10.txt","File 2.txt"])
        await s.close()
    }
    @Test func recordedSizesUseUnsignedComparisonWithoutSubtractionOrBodies() async throws {
        let s = try catalog([.init("Small",7),.init("Large",UInt64(Int64.max)+1),.init("Zero",0)])
        #expect(try await s.page(in:s.root,sorting:.init(.logical,descending:true)).items.map(\.name) == ["Large","Small","Zero"])
        #expect(try await s.page(in:s.root,sorting:.init(.logical)).items.map(\.name) == ["Zero","Small","Large"])
        await s.close()
    }
    @Test func packedSizeIsIndependentOfLogicalSizeAndFoldersKeepTotals() async throws {
        let s = try catalog([.init("First",1,70,8),.init("Second",2,20,8),.init("Third",3,50,8),.init("Folder/Inside",4,9,8)])
        let rows = try await s.page(in:s.root,sorting:.init(.packed,descending:true)).items
        #expect(rows.map(\.name) == ["Folder","First","Third","Second"])
        #expect(rows[0].logicalBytes == 4 && rows[0].packedBytes == 9)
        await s.close()
    }
    @Test func methodOrderKeepsUnknownFactsAndDeterministicNameTies() async throws {
        let s = try catalog([.init("Unknown",0,0,99),.init("Stored 10",0,0,0),.init("Deflate",0,0,8),
            .init("Stored 2",0,0,0),.init("Folder/Child",0,0,12)])
        #expect(try await s.page(in:s.root,sorting:.init(.method)).items.map(\.name) == ["Folder","Deflate","Unknown","Stored 2","Stored 10"])
        #expect(try await s.page(in:s.root,sorting:.init(.method,descending:true)).items.map(\.name) == ["Folder","Stored 2","Stored 10","Unknown","Deflate"])
        await s.close()
    }
    @Test func equalBasenamesRemainDistinctAcrossGlobalOrdering() async throws {
        let s = try catalog([.init("B/Report.txt",3),.init("A/Report.txt",9),.init("C/Report.txt",9)])
        let rows = try await s.searchNames("report",sorting:.init(.logical,descending:true)).items
        #expect(rows.map(\.path) == ["A/Report.txt","C/Report.txt","B/Report.txt"] && Set(rows.map(\.id)).count == 3)
        #expect(try await s.searchNames("report",sorting:.init(.logical)).items.map(\.path) == ["B/Report.txt","A/Report.txt","C/Report.txt"])
        #expect(try await s.searchNames("report",sorting:.init(.name)).items.map(\.path) == ["B/Report.txt","A/Report.txt","C/Report.txt"])
        await s.close()
    }
    @Test func completeFolderIsOrderedBeforeEveryPageBoundary() async throws {
        let s = try catalog(many()), folder = try #require(try await s.page(in:s.root).items.first?.folder)
        let first = try await s.page(in:folder,sorting:.init(.logical,descending:true))
        let second = try await s.page(in:folder,offset:256,sorting:.init(.logical,descending:true))
        let last = try await s.page(in:folder,offset:512,sorting:.init(.logical,descending:true))
        #expect(first.total == 600 && first.items.count == 256 && first.items.first?.logicalBytes == 599 && first.items.last?.logicalBytes == 344)
        #expect(second.items.first?.logicalBytes == 343 && second.items.last?.logicalBytes == 88)
        #expect(last.items.count == 88 && last.items.first?.logicalBytes == 87 && last.items.last?.logicalBytes == 0 && !last.hasNext)
        #expect(Set((first.items+second.items+last.items).map(\.id)).count == 600)
        await s.close()
    }
    @Test func completeSearchIsOrderedBeforePagingAndDoesNotMatchParentNames() async throws {
        let s = try catalog(many())
        let first = try await s.searchNames("Entry",sorting:.init(.packed,descending:true))
        let second = try await s.searchNames("Entry",offset:256,sorting:.init(.packed,descending:true))
        let last = try await s.searchNames("Entry",offset:512,sorting:.init(.packed,descending:true))
        #expect(first.items.first?.name == "Entry 0.txt" && second.items.first?.name == "Entry 256.txt" && last.items.last?.name == "Entry 599.txt")
        #expect(first.total == 600 && first.items.count == 256 && last.items.count == 88)
        #expect(try await s.searchNames("Folder/",sorting:.init(.logical)).total == 0)
        await s.close()
    }
    @Test func cacheIncludesOrderFieldDirectionCriteriaAndSymbolPolicy() async throws {
        let s = try catalog([.init("Café_notes-file.txt",2,8),.init("Alpha.txt",9,1),.init("Zeta.txt",3,5)])
        #expect(try await s.page(in:s.root,sorting:.init(.logical,descending:true)).items.first?.name == "Alpha.txt")
        #expect(try await s.page(in:s.root,sorting:.init(.packed,descending:true)).items.first?.name == "Café_notes-file.txt")
        #expect(try await s.page(in:s.root,filter:"CAFE NOTES",sorting:.init(.logical)).total == 1)
        #expect(try await s.page(in:s.root,filter:"CAFE NOTES",symbolTolerant:false,sorting:.init(.logical)).total == 0)
        #expect(try await s.searchNames(".txt",sorting:.init(.logical)).items.first?.name == "Café_notes-file.txt")
        #expect(try await s.searchNames(".TXT",sorting:.init(.logical,descending:true)).items.first?.name == "Alpha.txt")
        #expect(try await s.searchNames("cafe notes",symbolTolerant:false,sorting:.init(.logical)).total == 0)
        #expect(try await s.searchNames("cafe notes",sorting:.init(.logical)).total == 1)
        await s.close()
    }
    @Test func containingLocationUsesCompleteChosenFolderOrder() async throws {
        let s = try catalog(many())
        let selected = try #require(try await s.searchNames("Entry 17.txt").items.first)
        let position = try await s.location(of:selected.id,sorting:.init(.logical,descending:true))
        #expect(position.offset == 512)
        let page = try await s.page(in:position.folder,offset:position.offset,sorting:.init(.logical,descending:true))
        #expect(page.items.contains {$0.id == selected.id})
        #expect(try await s.location(of:selected.id).offset == 0)
        await s.close()
    }
    @Test func cancellationDuringComparisonsCannotPublishOrPoisonLaterQuery() async throws {
        let data = try storage(many()), s = ZIPArchiveSession(data)
        var calls = 0
        #expect(throws:CancellationError.self) {
            try ZIPCatalogOrdering.ids(Array(data.nodes.indices.dropFirst()),nodes:data.nodes,order:.init(.logical,descending:true)) {
                calls += 1; if calls == 10 { throw CancellationError() }
            }
        }
        #expect(calls == 10)
        let cancelled = Task { () throws -> ZIPNameSearchPage in
            withUnsafeCurrentTask {$0?.cancel()}
            return try await s.searchNames("Entry",sorting:.init(.logical,descending:true))
        }
        await #expect(throws:CancellationError.self) { try await cancelled.value }
        #expect(try await s.searchNames("Entry",sorting:.init(.logical,descending:true)).items.first?.logicalBytes == 599)
        await s.close()
    }
    @Test func foreignClosedAndInvalidRequestsKeepExistingRefusals() async throws {
        let data = try storage([.init("One")]), s = ZIPArchiveSession(data), other = ZIPArchiveSession(data)
        let item = try #require(try await s.page(in:s.root).items.first)
        await #expect(throws:ZIPArchiveFailure.invalidFolder) { try await other.location(of:item.id,sorting:.init(.logical)) }
        await #expect(throws:ZIPArchiveFailure.invalidFolder) { try await other.page(in:s.root,sorting:.init(.packed)) }
        await #expect(throws:ZIPArchiveFailure.limited) { try await s.page(in:s.root,offset:-1,sorting:.init(.name)) }
        await #expect(throws:ZIPArchiveFailure.invalidFilter) { try await s.searchNames(String(repeating:"é",count:65),sorting:.init(.name)) }
        #expect(try await s.page(in:s.root,offset:Int.max,sorting:.init(.logical)).items.isEmpty)
        await s.close()
        await #expect(throws:ZIPArchiveFailure.closed) { try await s.searchNames("One",sorting:.init(.logical)) }
        await #expect(throws:ZIPArchiveFailure.closed) { try await s.location(of:item.id,sorting:.init(.logical)) }
        await other.close()
    }
    @Test func legacyCallsKeepTheirCatalogOrderAfterSortedQueries() async throws {
        let s = try catalog([.init("Z/Entry.txt",1),.init("A/Entry.txt",9),.init("Root",3)])
        let legacy = try await s.searchNames("Entry")
        #expect(legacy.items.map(\.path) == ["Z/Entry.txt","A/Entry.txt"])
        #expect(try await s.searchNames("Entry",sorting:.init(.logical,descending:true)).items.map(\.path) == ["A/Entry.txt","Z/Entry.txt"])
        #expect(try await s.searchNames("Entry").items.map(\.id) == legacy.items.map(\.id))
        #expect(try await s.page(in:s.root).items.map(\.name) == ["A","Z","Root"])
        #expect(try await s.searchNames("",sorting:.init(.name)).items.isEmpty)
        await s.close()
        let flat = try catalog([.init("File 10.txt"),.init("File 2.txt"),.init("Another.txt")])
        #expect(try await flat.searchNames(".txt",sorting:.init(.name)).items.map(\.name) == ["Another.txt","File 2.txt","File 10.txt"])
        #expect(try await flat.searchNames(".txt").items.map(\.name) == ["File 10.txt","File 2.txt","Another.txt"])
        #expect(try await flat.searchNames("File",sorting:.init(.name)).items.map(\.name) == ["File 2.txt","File 10.txt"])
        await flat.close()
    }
}
