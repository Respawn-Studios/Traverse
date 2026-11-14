import Foundation
@testable import LocalStorage
import XCTest

@MainActor final class UserAccountHomeTests: XCTestCase {
    func testAccountHomeAcceptsConfiguredUnicodeAndNetworkLocationsWithoutProbing() throws {
        for path in ["/Users/Generated", "/Volumes/Generated Home/Zoë", "/Network/Servers/example/Users/Generated"] {
            XCTAssertEqual(try UserAccountHome.validated(path: path).path, path)
        }
        for path in ["", "/", "relative", "/Users/../Elsewhere", "/Users/Bad\nName", "/Users/Bad\0Name", "/" + String(repeating: "x", count: 4097)] {
            XCTAssertThrowsError(try UserAccountHome.validated(path: path))
        }
    }
    func testCancelledLookupDoesNotAdmitWork() async {
        let task = Task { () throws -> URL in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await UserAccountHome.resolve()
        }
        do { _ = try await task.value; XCTFail("Cancelled account lookup returned a location") }
        catch is CancellationError {} catch { XCTFail("Cancellation lost its meaning") }
    }
}
