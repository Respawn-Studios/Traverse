import Foundation
import LocalStorage
import XCTest

final class CrashReportTests: XCTestCase {
    private func report() throws -> CrashReport {
        try .init(capturedAt: Date(timeIntervalSince1970: 1_800_000_000), version: "1.0", build: "90",
            systemVersion: "15.0", systemBuild: "24A123", architecture: .arm64, signal: .abort,
            images: [.init(kind: .application, uuid: "C04291FD-3D73-47AF-9A6A-74F8EB73F734", base: 4096, size: 4096)],
            threads: [.init(number: 0, crashed: true, frames: [.init(address: 4128, image: 0)])])
    }

    func testShareableRoundTripAndReviewedGitHubDraft() throws {
        let source = try report()
        let decoded = try JSONDecoder().decode(CrashReport.self, from: JSONEncoder().encode(source))
        XCTAssertEqual(source, decoded)
        let text = try decoded.text()
        XCTAssertTrue(text.contains("Traverse + 0x20"))
        XCTAssertFalse(text.contains("/Users/"))
        let edited = text + "\nReviewed comment: C++ & labels=admin? # 🔥 秘密 + 100%\n"
        let draft = try GitHubIssueDraft(report: edited, title: decoded.githubIssueTitle())
        let url = draft.url
        XCTAssertTrue(draft.includesFullReport)
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "github.com")
        XCTAssertEqual(url.path, "/Respawn-Studios/Traverse/issues/new")
        XCTAssertNil(url.fragment)
        XCTAssertNil(url.user)
        XCTAssertLessThanOrEqual(url.absoluteString.utf8.count, GitHubIssueDraft.maximumURLBytes)
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(query?.map(\.name), ["title", "body"])
        XCTAssertEqual(query?.first(where: { $0.name == "body" })?.value, edited)
        XCTAssertEqual(query?.first(where: { $0.name == "title" })?.value, "Crash: Traverse 1.0 (90)")
        XCTAssertTrue(url.absoluteString.contains("C%2B%2B"))
    }

    func testMalformedDecodedDataIsRevalidatedBeforeSharing() throws {
        let source = try report()
        let data = try JSONEncoder().encode(source)
        var value = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        value["version"] = "/Users/private-secret"
        let decoded = try JSONDecoder().decode(CrashReport.self, from: JSONSerialization.data(withJSONObject: value))
        XCTAssertThrowsError(try decoded.text())
        XCTAssertThrowsError(try decoded.githubIssueTitle())
        value["version"] = "1.0"
        value["images"] = [["kind": "Traverse", "uuid": String(repeating: "-", count: 1024) + "C04291FD3D7347AF9A6A74F8EB73F734", "base": 4096, "size": 4096]]
        let oversized = try JSONDecoder().decode(CrashReport.self, from: JSONSerialization.data(withJSONObject: value))
        XCTAssertThrowsError(try oversized.validate())
    }

    func testDefaultDraftKeepsReferencedImageIndicesWithoutTheUnusedImageInventory() throws {
        let images = (0..<512).map { index in
            CrashReport.Image(kind: index == 0 ? .application : .system,
                uuid: "C04291FD-3D73-47AF-9A6A-74F8EB73F734", base: UInt64(4096 * (index + 1)), size: 4096)
        }
        let report = try CrashReport(capturedAt: nil, version: "1.0", build: "90", systemVersion: "15",
            systemBuild: nil, architecture: .arm64, signal: .abort, images: images,
            threads: [.init(number: 0, crashed: true, frames: [.init(address: images[511].base + 32, image: 511)]),
                      .init(number: 1, crashed: false, frames: [.init(address: images[256].base + 16, image: 256)])])
        let text = try report.text()
        XCTAssertTrue(text.contains("image[511] System image · UUID"))
        XCTAssertTrue(text.contains("image[0] Traverse · UUID"))
        XCTAssertFalse(text.contains("image[256]"))
        XCTAssertTrue(try GitHubIssueDraft(report: text).includesFullReport)
        let extended = try report.text(includeOtherThreads: true)
        XCTAssertTrue(extended.contains("image[256] System image · UUID"))
        XCTAssertTrue(extended.contains("image[1] System image · UUID"))
        XCTAssertEqual(report.images.count, 512)
    }

    func testEncodedURLBudgetUsesFullTextAtTheBoundaryAndExplicitFallbackBeyondIt() throws {
        let overhead = try GitHubIssueDraft(report: "a").url.absoluteString.utf8.count - 1
        let limit = GitHubIssueDraft.maximumURLBytes - overhead
        let fits = try GitHubIssueDraft(report: String(repeating: "a", count: limit))
        XCTAssertTrue(fits.includesFullReport)
        XCTAssertEqual(fits.url.absoluteString.utf8.count, GitHubIssueDraft.maximumURLBytes)
        let text = String(repeating: "a", count: limit + 1)
        let oversized = try GitHubIssueDraft(report: text)
        XCTAssertFalse(oversized.includesFullReport)
        XCTAssertEqual(oversized, try GitHubIssueDraft(report: text))
        XCTAssertLessThanOrEqual(oversized.url.absoluteString.utf8.count, GitHubIssueDraft.maximumURLBytes)
        let body = URLComponents(url: oversized.url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "body" }?.value
        XCTAssertTrue(body?.hasPrefix(GitHubIssueDraft.abbreviatedHeading) == true)
        XCTAssertTrue(body?.contains("Remaining report omitted") == true)
    }

    func testUnicodeExpansionAndMaximumDocumentAreBoundedWithoutInvalidScalarSuffixes() throws {
        let expanded = String(repeating: "🔥", count: 700)
        XCTAssertLessThan(expanded.utf8.count, GitHubIssueDraft.maximumURLBytes)
        let draft = try GitHubIssueDraft(report: expanded)
        XCTAssertFalse(draft.includesFullReport)
        let body = try XCTUnwrap(URLComponents(url: draft.url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "body" }?.value)
        XCTAssertFalse(body.contains("�"))
        let largest = String(repeating: "a", count: CrashReportRedaction.maximumBytes)
        let bounded = try GitHubIssueDraft(report: largest)
        XCTAssertFalse(bounded.includesFullReport)
        XCTAssertLessThanOrEqual(bounded.url.absoluteString.utf8.count, GitHubIssueDraft.maximumURLBytes)
        XCTAssertThrowsError(try GitHubIssueDraft(report: largest + "a"))
        XCTAssertThrowsError(try GitHubIssueDraft(report: ""))
        XCTAssertThrowsError(try GitHubIssueDraft(report: "Reviewed", title: "Title&labels=admin"))
        XCTAssertThrowsError(try GitHubIssueDraft(report: "Reviewed", title: "Title\nHeader"))
    }

    func testPrivacyHelperHandlesPathsURLsContactDetailsAndUnicode() throws {
        let original = "At /Users/秘密/Documents/Taxes.pdf on /Volumes/Work/secret.txt, email john@example.com or sftp://private.example.com/file at 10.2.3.4."
        let text = try CrashReportRedaction.hidePrivateDetails(in: original)
        for secret in ["秘密", "Taxes.pdf", "secret.txt", "john@example", "private.example", "10.2.3.4"] {
            XCTAssertFalse(text.contains(secret), secret)
        }
        XCTAssertTrue(text.contains("[private path]"))
        XCTAssertThrowsError(try CrashReportRedaction.hidePrivateDetails(in: String(repeating: "a", count: 512 << 10), privatePrefixes: ["a"]))
        XCTAssertThrowsError(try CrashReportRedaction.hidePrivateDetails(in: String(repeating: "/a ", count: 120_000)))
    }

    func testInvalidFramesAndCountsCannotEnterShareableReport() {
        XCTAssertThrowsError(try CrashReport(capturedAt: nil, version: "1", build: "1", systemVersion: "15",
            systemBuild: nil, architecture: .arm64, signal: .abort,
            images: [.init(kind: .application, uuid: nil, base: 4096, size: 16)],
            threads: [.init(number: 0, crashed: true, frames: [.init(address: 5000, image: 0)])]))
    }

    func testExtendedTraceKeepsSymbolIdentitiesWithinTheReportBudget() throws {
        let images = [CrashReport.Image(kind: .application, uuid: "C04291FD-3D73-47AF-9A6A-74F8EB73F734", base: 4096, size: 4096)]
        let threads = (0..<16).map { CrashReport.Thread(number: $0, crashed: $0 == 0,
            frames: Array(repeating: .init(address: 4128, image: 0), count: 512)) }
        let report = try CrashReport(capturedAt: nil, version: "1", build: "1", systemVersion: "15", systemBuild: nil,
            architecture: .arm64, signal: .abort, images: images, threads: threads)
        let text = try report.text(includeOtherThreads: true)
        XCTAssertLessThanOrEqual(text.utf8.count, 256 << 10)
        XCTAssertTrue(text.contains("Additional frames omitted"))
        XCTAssertTrue(text.contains("C04291FD-3D73-47AF-9A6A-74F8EB73F734"))
        XCTAssertTrue(text.contains("## Binary images"))
    }
}
