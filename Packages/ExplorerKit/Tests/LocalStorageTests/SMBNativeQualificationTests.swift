import Foundation
import Testing
@_spi(Qualification) @testable import LocalStorage

/// Native qualification only; ordinary tests never mount or probe a server.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["MAC_EXPLORER_B10_NATIVE_CASE"] != nil))
struct SMBNativeQualificationTests {
    @Test func generatedGuestReadOnlyMount() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["MAC_EXPLORER_B10_NATIVE_CASE"])
        let result = try await SMBLoopbackQualification.run(packet: URL(fileURLWithPath: path))
        print("MAC_EXPLORER_SMB_NATIVE " + String(decoding: result, as: UTF8.self))
    }
}
