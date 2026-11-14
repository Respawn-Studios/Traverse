import Foundation
import Testing
@testable import LocalStorage

@Suite struct ZIPNameSearchTests {
    @Test func globalNameResultsDistinguishEqualNamesWithoutSearchingBodiesOrParentPaths() async throws {
        let storage = try GeneratedZIP.parse(GeneratedZIP.bytes([
            .init("Reports/Notes.txt", bytes: Data("secret needle only in generated body".utf8)),
            .init("Design/Notes.txt"), .init("Reports/Another.md"), .init("Note Templates/", mode: 0x4000, bytes: Data())]))
        let catalog = ZIPArchiveSession(storage)
        let found = try await catalog.searchNames("notes")
        #expect(found.items.map(\.path) == ["Reports/Notes.txt", "Design/Notes.txt"])
        #expect(found.items.map(\.name) == ["Notes.txt", "Notes.txt"])
        #expect(found.total == 2 && found.offset == 0 && !found.hasNext)
        #expect(try await catalog.searchNames("secret needle").total == 0)
        #expect(try await catalog.searchNames("Reports/").total == 0)
        let folderMatch = try await catalog.searchNames("note template")
        #expect(folderMatch.items.count == 1 && folderMatch.items[0].folder != nil)
        let parent = try await catalog.location(of: found.items[1].id)
        #expect(try await catalog.page(in: parent.folder, offset: parent.offset).items.map(\.path) == ["Design/Notes.txt"])
        #expect(try await catalog.page(in: catalog.root, filter: "notes").items.isEmpty)
        await catalog.close()
    }
    @Test func unicodeSeparatorPolicyAndEmptyQueryRemainExplicit() async throws {
        let catalog = ZIPArchiveSession(try GeneratedZIP.parse(GeneratedZIP.bytes([
            .init("日本語/Café_notes-file.txt"), .init("Other/Strasse.txt") ])))
        #expect(try await catalog.searchNames("CAFE NOTES FILE").items.map(\.path) == ["日本語/Café_notes-file.txt"])
        #expect(try await catalog.searchNames("cafe notes file", symbolTolerant: false).total == 0)
        #expect(try await catalog.searchNames("CAFÉ_NOTES-", symbolTolerant: false).total == 1)
        #expect(try await catalog.searchNames("").items.isEmpty)
        #expect(try await catalog.searchNames("   ").total == 0)
        await #expect(throws: ZIPArchiveFailure.invalidFilter) { try await catalog.searchNames(String(repeating: "é", count: 65)) }
        #expect(try await catalog.searchNames(String(repeating: "é", count: 64)).total == 0)
        await catalog.close()
    }
    @Test func globalPagingIsBoundedAndStableAcrossFolderPagingAndCacheChanges() async throws {
        let catalog = ZIPArchiveSession(try GeneratedZIP.parse(GeneratedZIP.bytes((0..<600).map {
            .init("Folder \($0 / 100)/Entry \($0).txt", bytes: Data())
        })))
        let first = try await catalog.searchNames(".txt"), second = try await catalog.searchNames(".txt", offset: 256)
        #expect(first.total == 600 && first.items.count == 256 && first.hasNext)
        #expect(second.offset == 256 && second.items.count == 256 && second.items[0].path == "Folder 2/Entry 256.txt")
        let location = try await catalog.location(of: second.items[0].id)
        #expect(try await catalog.page(in: location.folder, offset: location.offset).items.contains { $0.id == second.items[0].id })
        #expect(try await catalog.searchNames(".txt", offset: 512).items.count == 88)
        #expect(try await catalog.searchNames(".txt", offset: Int.max).offset == 600)
        #expect(try await catalog.searchNames(".txt", offset: Int.max).items.isEmpty)
        await #expect(throws: ZIPArchiveFailure.limited) { try await catalog.searchNames(".txt", offset: -1) }
        #expect(try await catalog.searchNames("Entry 599").items.map(\.path) == ["Folder 5/Entry 599.txt"])
        #expect(try await catalog.searchNames(".txt").items.map(\.id) == first.items.map(\.id))
        await catalog.close()
    }
    @Test func foreignIdentitiesAndClosedSessionsCannotResolveLocations() async throws {
        let storage = try GeneratedZIP.parse(GeneratedZIP.bytes([.init("Folder/One.txt")]))
        let first = ZIPArchiveSession(storage), second = ZIPArchiveSession(storage)
        let item = try #require(try await first.searchNames("one").items.first)
        await #expect(throws: ZIPArchiveFailure.invalidFolder) { try await second.location(of: item.id) }
        await #expect(throws: ZIPArchiveFailure.invalidFolder) { try await first.location(of: .init(owner: item.id.owner, node: 0)) }
        await #expect(throws: ZIPArchiveFailure.invalidFolder) { try await first.location(of: .init(owner: item.id.owner, node: Int.max)) }
        await first.close()
        await #expect(throws: ZIPArchiveFailure.closed) { try await first.searchNames("one") }
        await #expect(throws: ZIPArchiveFailure.closed) { try await first.location(of: item.id) }
        await second.close()
    }
    @Test func cancelledCallerCannotPublishOrPoisonTheNextSearch() async throws {
        let catalog = ZIPArchiveSession(try GeneratedZIP.parse(GeneratedZIP.bytes([.init("One.txt"), .init("Two.txt")])))
        let cancelled = Task { () throws -> ZIPNameSearchPage in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await catalog.searchNames("one")
        }
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(try await catalog.searchNames("two").items.map(\.name) == ["Two.txt"])
        let id = try #require(try await catalog.searchNames("one").items.first?.id)
        let cancelledLocation = Task { () throws -> ZIPItemLocation in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await catalog.location(of: id)
        }
        await #expect(throws: CancellationError.self) { try await cancelledLocation.value }
        #expect(try await catalog.location(of: id).folder == catalog.root)
        await catalog.close()
    }
}
