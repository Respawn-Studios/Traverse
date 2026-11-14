import Foundation
@testable import DirectUpdates
import Testing

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["TRAVERSE_UPDATE_KEYCHAIN_CASE"] != nil))
struct UpdateInvitationStoreTests {
    @Test func exactGeneratedEntriesSaveReopenAndForgetIndependently() async throws {
        let caseID = try #require(ProcessInfo.processInfo.environment["TRAVERSE_UPDATE_KEYCHAIN_CASE"].flatMap(UUID.init(uuidString:)))
        let first = UpdateInvitationStore(qualification:caseID)
        // Second namespace is independently generated and never a personal item.
        let second = UpdateInvitationStore(qualification:UUID())
        let a = try PrivateUpdateInvitation("Generated-update-invitation-one")
        let b = try PrivateUpdateInvitation("Generated-update-invitation-two")
        #expect(try await first.read() == nil)
        do {
            try await first.save(a); try await second.save(b)
            let reopened = UpdateInvitationStore(qualification:caseID)
            #expect(try await reopened.read()?.authorization == a.authorization)
            try await reopened.forget(); try await reopened.forget()
            #expect(try await first.read() == nil)
            #expect(try await second.read()?.authorization == b.authorization)
            try await second.forget()
            #expect(try await second.read() == nil)
        } catch {
            try? await first.forget(); try? await second.forget()
            throw error
        }
    }
}
