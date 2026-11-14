#if DEBUG
import AppKit
import ExplorerCore
import Search

/// Explicit owner-approved generated fixtures only. This check never requests
/// indexing, reads file bodies, or records unrelated indexed candidates.
@MainActor
enum SearchIndexLiveVerification {
    private struct Fixture: Decodable, Sendable {
        let kind: String
        let root: String
        let filename: String
    }
    private struct Receipt: Decodable, Sendable {
        let schema: Int
        let id: String
        let query: String
        let fixtures: [Fixture]
        let indexSettingsChanged: Bool
        let advancedFilenameFixtures: Bool?
    }

    static func run(receiptURL: URL, output: URL) async throws -> [String] {
        let receipt = try await Task.detached {
            let file = receiptURL.standardizedFileURL
            guard file.path == receiptURL.path,
                  file.pathComponents.contains(".build"), file.pathComponents.contains("fixtures"),
                  file == file.resolvingSymlinksInPath(),
                  let bytes = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize, bytes <= 16_384 else {
                throw UIVerification.Failure(message: "Index check requires its owned bounded receipt")
            }
            let receipt = try JSONDecoder().decode(Receipt.self, from: Data(contentsOf: file))
            guard receipt.schema == 1, receipt.id.count == 12,
                  receipt.id.allSatisfy({ $0.isHexDigit }),
                  receipt.query == "MacExplorerReview-" + receipt.id,
                  !receipt.indexSettingsChanged,
                  Set(receipt.fixtures.map(\.kind)) == ["Internal", "External"], receipt.fixtures.count == 2 else {
                throw UIVerification.Failure(message: "Index fixture receipt is invalid")
            }
            for fixture in receipt.fixtures {
                let base = fixture.kind == "Internal" ? FileManager().homeDirectoryForCurrentUser.appendingPathComponent("Downloads").path : "/Volumes/Workspace/Downloads"
                let folder = URL(fileURLWithPath: fixture.root, isDirectory: true)
                guard folder.path == base + "/Mac Explorer Search Review " + receipt.id,
                      folder == folder.resolvingSymlinksInPath(),
                      fixture.filename == receipt.query + "-" + fixture.kind + ".txt" else {
                    throw UIVerification.Failure(message: "Refused an unrelated search fixture")
                }
                let markerURL = folder.appendingPathComponent(".mac-explorer-fixture.json")
                let marker = try JSONSerialization.jsonObject(with: Data(contentsOf: markerURL)) as? [String: Any]
                guard marker?["generator"] as? String == "mac-explorer-live-index-review",
                      marker?["id"] as? String == receipt.id,
                      marker?["ownerApprovedLocations"] as? Bool == true,
                      FileManager().fileExists(atPath: folder.appendingPathComponent(fixture.filename).path) else {
                    throw UIVerification.Failure(message: "Index fixture ownership marker is missing")
                }
            }
            return receipt
        }.value
        let adapter = SpotlightMetadataSearch()
        // Keep every live query tied to the generated ID, including exact,
        // Unicode and literal-wildcard cases. No broad personal-file query runs.
        struct Case {
            let label: String
            let request: SearchRequest
            let includeExternal: Bool
            let expectedName: (Fixture) -> String?
        }
        var cases: [Case] = try [false, true].map { includeExternal in
            Case(label: "contains", request: try SearchRequest(filename: receipt.query), includeExternal: includeExternal,
                 expectedName: { $0.filename })
        }
        if receipt.advancedFilenameFixtures == true {
            guard let internalFixture = receipt.fixtures.first(where: { $0.kind == "Internal" }) else {
                throw UIVerification.Failure(message: "Missing internal search fixture")
            }
            cases.append(Case(label: "case-insensitive-exact", request: try SearchRequest(filename: internalFixture.filename.lowercased(), filenameMatch: .exact),
                              includeExternal: true, expectedName: { $0.kind == "Internal" ? $0.filename : nil }))
            for includeExternal in [false, true] {
                cases.append(Case(label: "case-and-diacritic-contains",
                                  request: try SearchRequest(filename: "macexplorerunicodereview-" + receipt.id + "-cafe"),
                                  includeExternal: includeExternal,
                                  expectedName: { "MacExplorerUnicodeReview-" + receipt.id + "-Café-" + $0.kind + ".txt" }))
                cases.append(Case(label: "literal-wildcard-with-indexed-decoy",
                                  request: try SearchRequest(filename: "MacExplorerLiteralReview-" + receipt.id + "-literal*?"),
                                  includeExternal: includeExternal,
                                  expectedName: { "MacExplorerLiteralReview-" + receipt.id + "-literal*?-" + $0.kind + ".txt" }))
            }
        }
        var samples: [[String: Any]] = []
        var failures: [String] = []
        for test in cases {
            let includeExternal = test.includeExternal
            let started = ProcessInfo.processInfo.systemUptime
            let session = adapter.start(request: test.request, includeExternalVolumes: includeExternal,
                                        policy: SearchPolicy(maximumResults: 16, maximumDuration: 10))
            var matches: [SearchMatch] = []
            var coverage: SearchCoverage?
            for await event in session.events {
                switch event.payload {
                case .batch(let batch): matches += batch
                case .progress: break
                case .finished(let final): coverage = final
                }
            }
            let expected = Set(receipt.fixtures.filter { includeExternal || $0.kind == "Internal" }.compactMap { fixture in
                test.expectedName(fixture).map { URL(fileURLWithPath: fixture.root, isDirectory: true).appendingPathComponent($0) }
            })
            let actual = Set(matches.map(\.entry.url))
            if actual != expected { failures.append("\(test.label), external \(includeExternal): query did not match only its expected owned fixtures") }
            if coverage?.completion != .completed || coverage?.indexedCoverageUnverified != true {
                failures.append("Indexed coverage/terminal state was inaccurate")
            }
            samples.append([
                "case": test.label,
                "includeExternalVolumes": includeExternal,
                "milliseconds": (ProcessInfo.processInfo.systemUptime - started) * 1000,
                "expectedFixtureCount": expected.count,
                "actualFixtureCount": actual.intersection(expected).count,
                "unexpectedCandidateCount": actual.subtracting(expected).count,
                "requestedVolumeRoots": coverage?.requestedRoots.map(\.path) ?? [],
                "visitedCandidates": coverage?.visitedEntries ?? 0,
                "completion": coverage?.completion.rawValue ?? "missing",
                "boundaries": Dictionary(uniqueKeysWithValues: (coverage?.boundaryCounts ?? [:]).map { ($0.key.rawValue, $0.value) }),
                "indexedCoverageUnverified": coverage?.indexedCoverageUnverified ?? false
            ])
        }
        let report: [String: Any] = [
            "schema": 1, "passed": failures.isEmpty, "fixtureID": receipt.id,
            "source": "Actual bounded filename-only MDQuery with owner-approved generated Downloads fixtures",
            "samples": samples, "failures": failures,
            "indexSettingsChanged": false, "fileBodiesRead": false,
            "notEstablished": ["Complete disk/index coverage", "Other filesystems/providers or permission states"]
        ]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("live-search-index.json"), options: .withoutOverwriting)
        guard failures.isEmpty else { throw UIVerification.Failure(message: failures.joined(separator: "; ")) }
        return ["Actual internal-only index query returns only its owned internal fixture", "Explicit external-inclusive index query returns both owned fixtures while coverage remains unverified", "When provisioned, exact case-insensitive, diacritic and literal-wildcard queries match only their owned fixtures"]
    }
}
#endif
