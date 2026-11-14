import ExplorerCore
import Foundation
@_spi(Qualification) import LocalStorage
import XCTest

@MainActor final class SMBHostnameResolverTests: XCTestCase {
    let unusedBundle = URL(fileURLWithPath: "/not-admitted-resolver.bundle")

    func testInvalidOrNumericInputIsRejectedBeforeIOAndAdmission() async {
        let activity = FileActivityGate(maximumActivities: 1)
        for host in ["", "smb://server/share", "127.0.0.1", "127.001.0.1", "::1", "[::1]", "user@server",
            "bad..name", "bad/name", "bad\\name", "server\n", "-server", "server-", "server.", "ß.example", String(repeating: "a", count: 254)] {
            do {
                _ = try await SMBHostnameResolver.resolve(host, bundleURL: unusedBundle, activity: activity)
                XCTFail("Invalid input was admitted")
            } catch SMBResolutionFailure.invalidInput { }
            catch { XCTFail("Input reached another stage: \(error)") }
            XCTAssertEqual(activity.activeCount, 0)
        }
        for deadline in [0.0, -1.0, 11.0, Double.infinity, Double.nan] {
            do {
                _ = try await SMBHostnameResolver.resolve("localhost", bundleURL: unusedBundle, activity: activity, lookupDeadline: deadline)
                XCTFail("Invalid deadline was admitted")
            } catch SMBResolutionFailure.invalidInput { }
            catch { XCTFail("Deadline reached another stage") }
        }
        do {
            _ = try await SMBHostnameResolver.resolve("unrequested.invalid", bundleURL: unusedBundle, activity: activity, mode: .empty)
            XCTFail("Generated mode used a nonfixture hostname")
        } catch SMBResolutionFailure.invalidInput { }
        catch { XCTFail("Generated-mode input reached another stage") }
    }

    func testClosedActivityAdmissionStartsNoChildOrBundleRead() async throws {
        let activity = FileActivityGate(maximumActivities: 1)
        let token = try XCTUnwrap(activity.closeAdmission())
        let result = try await SMBHostnameResolver.resolve("localhost", bundleURL: unusedBundle, activity: activity)
        XCTAssertEqual(result.failure, .unavailable); XCTAssertTrue(result.addresses.isEmpty)
        XCTAssertFalse(result.lifetime.childStarted); XCTAssertTrue(result.lifetime.ownerReleased)
        XCTAssertEqual(activity.activeCount, 0); XCTAssertTrue(activity.ownsDrainedAdmission(token))
        XCTAssertTrue(activity.reopen(token))
    }
}
