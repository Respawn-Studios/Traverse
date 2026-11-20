import CoreServices
import Darwin
import ExplorerCore
import Foundation
@testable import Search
import Testing

private struct SearchFixture {
    let root: URL
    init() throws {
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let repository = package.deletingLastPathComponent().deletingLastPathComponent()
        let retained = ProcessInfo.processInfo.environment["MAC_EXPLORER_SEARCH_FIXTURE_ROOT"]
        let configured = retained ?? ProcessInfo.processInfo.environment["MAC_EXPLORER_TEST_ROOT"]
        let base = configured.map { URL(fileURLWithPath: $0).standardizedFileURL }
            ?? package.appendingPathComponent(".build/search-fixtures", isDirectory: true)
        guard base.path.hasPrefix(repository.path + "/"), base.pathComponents.contains(".build"),
              base.resolvingSymlinksInPath().path == base.path else { throw FixtureFailure.unsafeRoot }
        if retained != nil {
            let owner = base.deletingLastPathComponent()
            guard base.lastPathComponent == "source",
                  owner.deletingLastPathComponent().path == repository.appendingPathComponent(".build/traverse-release").path,
                  UUID(uuidString: owner.lastPathComponent)?.uuidString == owner.lastPathComponent,
                  let marker = try JSONSerialization.jsonObject(with: Data(contentsOf: owner.appendingPathComponent("reservation.json"))) as? [String: Any],
                  marker["action"] as? String == "traverse-search-focused" else { throw FixtureFailure.unsafeRoot }
        }
        root = base.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager().createDirectory(at: root, withIntermediateDirectories: true)
    }
    func file(_ relative: String, body: String = "generated fixture") throws -> URL {
        let url = root.appendingPathComponent(relative)
        try FileManager().createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(body.utf8).write(to: url, options: .withoutOverwriting)
        return url
    }
    func directory(_ relative: String) throws -> URL {
        let url = root.appendingPathComponent(relative, isDirectory: true)
        try FileManager().createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    func remove() {
        // Qualification keeps generated failures/fixtures for inspection. The
        // exact retained root was admitted before any fixture was created.
        guard ProcessInfo.processInfo.environment["MAC_EXPLORER_SEARCH_FIXTURE_ROOT"] == nil else { return }
        try? FileManager().removeItem(at: root)
    }
    enum FixtureFailure: Error { case unsafeRoot }
}

private func collect(_ session: SearchSession) async -> ([SearchMatch], SearchCoverage?) {
    var results: [SearchMatch] = []
    var coverage: SearchCoverage?
    for await event in session.events {
        #expect(session.generation.accepts(event))
        switch event.payload {
        case .batch(let matches): results += matches
        case .progress(let value):
            #expect(value.finishedAt == nil && !value.isComplete)
        case .finished(let value):
            #expect(coverage == nil)
            coverage = value
        }
    }
    return (results, coverage)
}

@Test func literalGrammarAndUnknownMetadataFilters() throws {
    let url = URL(fileURLWithPath: "/generated/报告 Café *?.TXT")
    let entry = FileEntry(url: url, name: url.lastPathComponent, kind: .file, byteCount: 42,
                          modifiedAt: Date(timeIntervalSince1970: 100), accessedAt: Date(timeIntervalSince1970: 200))
    #expect(try SearchRequest(filename: "cafe").matches(entry))
    #expect(try SearchRequest(filename: "*").matches(entry))
    #expect(try !SearchRequest(filename: "' OR kMDItemTextContent == '*").matches(entry))
    #expect(try SearchRequest(filename: "报告 Café *?.txt", filenameMatch: .exact).matches(entry))
    #expect(try !SearchRequest(filename: "Café", filenameMatch: .exact).matches(entry))
    #expect(try SearchRequest(filename: "", filenameExtension: "txt", byteRange: 40...45,
                              dateRange: Date(timeIntervalSince1970: 99)...Date(timeIntervalSince1970: 101)).matches(entry))
    #expect(try !SearchRequest(filename: "", dateField: .created,
                               dateRange: .distantPast...Date()).matches(entry))
    #expect(throws: SearchValidationError.self) { try SearchRequest(filename: "../escape") }
    #expect(throws: SearchValidationError.self) { try SearchRequest(filename: "a\0b") }
    #expect(throws: SearchValidationError.self) { try SearchRequest(filename: "x", filenameExtension: ".txt") }
}

@Test func localNavigationInitialsStayInsideTheExplicitSearchGrammar() async throws {
    let fixture = try SearchFixture()
    defer { fixture.remove() }
    let exact = try fixture.file("EHT.swift")
    let abbreviated = try fixture.file("Nested/EditorHTTPTrace.swift")
    _ = try fixture.file("ContainsOnlyBody.txt", body: "EditorHTTPTrace")
    _ = try fixture.file(".git/EditorHTTPTrace.swift")
    let scope = try SearchScope(root: fixture.root, showHidden: true, excludesGitMetadata: true)
    let request = try SearchRequest(filename: "eht", filenameMatch: .navigation, kind: .file)
    let (matches, coverage) = await collect(LocalMetadataSearch().start(request: request, scope: scope))
    #expect(Set(matches.map(\.entry.url)) == [exact, abbreviated])
    #expect(coverage?.completion == .completed && coverage?.boundaryCounts[.excluded] == 1)
    #expect(request.filenameNavigationRank(for: exact.lastPathComponent) == .stem)
    #expect(request.filenameNavigationRank(for: abbreviated.lastPathComponent) == .initials)
    let (indexed, indexedCoverage) = await collect(SpotlightMetadataSearch().start(request: request, scope: scope))
    #expect(indexed.isEmpty && indexedCoverage?.completion == .failed)
}

@Test func scopeRejectsGlobalRootsAndLexicalEscapes() throws {
    let root = URL(fileURLWithPath: "/generated/folder")
    let scope = try SearchScope(root: root, excludedSubroots: [root.appendingPathComponent("excluded")])
    #expect(scope.permits(root.appendingPathComponent("item")))
    #expect(!scope.permits(URL(fileURLWithPath: "/generated/folder-neighbor/item")))
    #expect(!scope.permits(root.appendingPathComponent("../escape")))
    #expect(!scope.permits(root.appendingPathComponent("excluded/deep/item")))
    #expect(!scope.permits(root.appendingPathComponent("EXCLUDED/deep/item")))
    #expect(throws: SearchValidationError.self) { try SearchScope(root: URL(fileURLWithPath: "/")) }
    #expect(throws: SearchValidationError.self) { try SearchScope(root: URL(fileURLWithPath: "/Volumes")) }
    #expect(throws: SearchValidationError.self) { try SearchScope(root: URL(string: "https://example.invalid")!) }
    #expect(throws: SearchValidationError.self) { try SearchScope(root: root, excludedSubroots: [URL(fileURLWithPath: "/outside")]) }
    #expect(MetadataObservation.isCredentialLocation(URL(fileURLWithPath: "/generated/.SSH/id")))
    #expect(MetadataObservation.isCredentialLocation(URL(fileURLWithPath: "/generated/KEYCHAINS/item")))
}

@Test func confinedTextScopeRetainsAllExclusions() throws {
    let root = URL(fileURLWithPath: "/generated/Project", isDirectory: true)
    let scope = try SearchScope(root: root, excludedSubroots: [root.appendingPathComponent("Sources/Private Output")],
        excludesGitMetadata: true, excludesSensitiveText: true, excludedDescendantNames: ["node_modules"])
    #expect(try scope.confined(toRelativeFolder: "") == scope)
    let narrower = try scope.confined(toRelativeFolder: "sources/")
    #expect(narrower.root.path == root.appendingPathComponent("sources").path)
    #expect(narrower.permits(narrower.root.appendingPathComponent("Allowed.swift")))
    #expect(!narrower.permits(narrower.root.appendingPathComponent("PRIVATE OUTPUT/Generated.swift")))
    #expect(!narrower.permits(narrower.root.appendingPathComponent("node_modules/Source.swift")))
    for rejected in ["/Outside", "../Outside", "Sources//Nested", "Sources/./Nested", ".git/objects", "NODE_MODULES/.cache", ".hidden"] {
        #expect(throws: SearchValidationError.invalidScope) { try scope.confined(toRelativeFolder: rejected) }
    }
    let visibleHidden = try SearchScope(root: root, showHidden: true, excludesSensitiveText: true)
    #expect(throws: SearchValidationError.invalidScope) { try visibleHidden.confined(toRelativeFolder: ".env/Inside") }
}

@Test func recursiveSearchMatchesFilenameWithoutReadingBodyOrChangingFileDates() async throws {
    let fixture = try SearchFixture()
    defer { fixture.remove() }
    let bodyOnly = try fixture.file("ordinary.txt", body: "BODY_SENTINEL_947168")
    let named = try fixture.file("deep/FILE_SENTINEL_713842.txt", body: "ordinary body")
    var times = [timespec(tv_sec: 100, tv_nsec: 0), timespec(tv_sec: 200, tv_nsec: 0)]
    #expect(utimensat(AT_FDCWD, bodyOnly.path, &times, 0) == 0)
    var before = stat()
    #expect(lstat(bodyOnly.path, &before) == 0)
    let service = LocalMetadataSearch()
    let scope = try SearchScope(root: fixture.root)
    let body = await collect(service.start(request: try SearchRequest(filename: "BODY_SENTINEL_947168"), scope: scope))
    #expect(body.0.isEmpty)
    #expect(body.1?.isComplete == true)
    let filename = await collect(service.start(request: try SearchRequest(filename: "FILE_SENTINEL_713842"), scope: scope))
    #expect(filename.0.map(\.entry.url) == [named])
    #expect(filename.0.first?.source == .recursiveMetadata)
    var after = stat()
    #expect(lstat(bodyOnly.path, &after) == 0)
    #expect(before.st_atimespec.tv_sec == after.st_atimespec.tv_sec)
    #expect(before.st_atimespec.tv_nsec == after.st_atimespec.tv_nsec)
    #expect(before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec)
    #expect(before.st_size == after.st_size)
}

@Test func recursiveScopeStopsPackagesLinksHiddenCredentialsAndExplicitExclusions() async throws {
    let fixture = try SearchFixture()
    defer { fixture.remove() }
    _ = try fixture.file("visible/match.txt")
    _ = try fixture.file("Excluded/match.txt")
    _ = try fixture.file("Example.app/match.txt")
    _ = try fixture.file(".hidden/match.txt")
    _ = try fixture.file(".ssh/match.txt")
    let loop = fixture.root.appendingPathComponent("loop")
    try FileManager().createSymbolicLink(at: loop, withDestinationURL: fixture.root)
    let scope = try SearchScope(root: fixture.root, excludedSubroots: [fixture.root.appendingPathComponent("Excluded")])
    let result = await collect(LocalMetadataSearch().start(request: try SearchRequest(filename: "match"), scope: scope))
    #expect(result.0.map(\.entry.name) == ["match.txt"])
    #expect(result.1?.boundaryCounts[.symbolicLink] == 1)
    #expect(result.1?.boundaryCounts[.package] == 1)
    #expect(result.1?.boundaryCounts[.hidden] == 1)
    #expect(result.1?.boundaryCounts[.credentialLocation] == 1)
    #expect(result.1?.boundaryCounts[.excluded] == 1)
    #expect(result.1?.isComplete == false)
}

@Test func projectSearchExcludesGitMetadataEvenWhenHiddenFilesAreShown() async throws {
    let fixture = try SearchFixture()
    defer { fixture.remove() }
    let editable = try fixture.file("Sources/.match.json")
    _ = try fixture.file(".git/match.txt")
    _ = try fixture.file("Module/.GIT/match.txt")
    let scope = try SearchScope(root: fixture.root, showHidden: true, excludesGitMetadata: true)
    let search = LocalMetadataSearch()
    let result = await collect(search.start(request: try SearchRequest(filename: "match", kind: .file), scope: scope))
    await search.cancelAndDrain()
    #expect(result.0.map(\.entry.url) == [editable])
    #expect(result.1?.boundaryCounts[.excluded] == 2)
    #expect(throws: SearchValidationError.self) {
        _ = try SearchScope(root: fixture.root.appendingPathComponent("Module/.GIT"), excludesGitMetadata: true)
    }
}

@Test func projectTextCandidatesCountOnlySupportedNamesAndSafeLocations() async throws {
    let fixture = try SearchFixture()
    defer { fixture.remove() }
    for name in ["00.bin", "01.txt.zip", "02.cache", ".env.local.txt", ".gitconfig", ".git/03.txt", "secrets/04.txt"] {
        _ = try fixture.file(name)
    }
    let makefile = try fixture.file("source/Makefile")
    let document = try fixture.file("source/README.TXT")
    let dependency = try fixture.file("source/Node_Modules/example.txt")
    _ = try fixture.file(".build/generated.txt")
    let filenames = try SearchRequest.FilenameAllowlist(names: ["makefile", ".gitconfig"], extensions: ["txt"])
    let request = try SearchRequest(filename: "", kind: .file, filenameAllowlist: filenames)
    let exclusions: Set<String> = ["node_modules", ".build"]
    let scope = try SearchScope(root: fixture.root, showHidden: true, excludesSensitiveText: true,
                                excludedDescendantNames: exclusions)
    let search = LocalMetadataSearch()
    let result = await collect(search.start(request: request, scope: scope, policy: .init(maximumResults: 3)))
    await search.cancelAndDrain()
    #expect(Set(result.0.map(\.entry.url)) == [makefile, document])
    #expect(result.1?.completion == .completed)
    let explicitScope = try SearchScope(root: dependency.deletingLastPathComponent(), showHidden: true, excludesSensitiveText: true,
                                        excludedDescendantNames: exclusions)
    let explicit = await collect(search.start(request: request, scope: explicitScope))
    await search.cancelAndDrain()
    #expect(explicit.0.map(\.entry.url) == [dependency])
    #expect(throws: SearchValidationError.self) {
        _ = try SearchScope(root: fixture.root, excludedDescendantNames: ["Sources/node_modules"])
    }
    #expect(throws: SearchValidationError.self) {
        _ = try SearchRequest.FilenameAllowlist(names: ["source/makefile"], extensions: ["txt"])
    }
    #expect(throws: SearchValidationError.self) {
        _ = try SearchScope(root: fixture.root.appendingPathComponent(".git"), excludesSensitiveText: true)
    }
}

@Test func rootSymlinkIsRejectedRatherThanFollowed() async throws {
    let fixture = try SearchFixture()
    defer { fixture.remove() }
    let target = try fixture.directory("target")
    _ = try fixture.file("target/match")
    let link = fixture.root.appendingPathComponent("redirect")
    try FileManager().createSymbolicLink(at: link, withDestinationURL: target)
    let result = await collect(LocalMetadataSearch().start(request: try SearchRequest(filename: "match"), scope: try SearchScope(root: link)))
    #expect(result.0.isEmpty)
    #expect(result.1?.completion == .failed)
    #expect(result.1?.isComplete == false)
}

@Test func explicitRootInsidePackageIsRejectedBeforeEnumeration() async throws {
    let fixture = try SearchFixture()
    defer { fixture.remove() }
    let root = try fixture.directory("Example.app/Contents")
    _ = try fixture.file("Example.app/Contents/match.txt")
    let result = await collect(LocalMetadataSearch().start(request: try SearchRequest(filename: "match"), scope: try SearchScope(root: root)))
    #expect(result.0.isEmpty)
    #expect(result.1?.searchedDirectories == 0)
    #expect(result.1?.completion == .failed)
    #expect(result.1?.boundaryCounts[.package] == 1)
}

@Test func resultTraversalDepthAndDiagnosticCapsAreHonest() async throws {
    let fixture = try SearchFixture()
    defer { fixture.remove() }
    for number in 0..<20 { _ = try fixture.file("item-\(number)") }
    let scope = try SearchScope(root: fixture.root)
    let service = LocalMetadataSearch()
    let results = await collect(service.start(request: try SearchRequest(filename: "item"), scope: scope,
                                               policy: SearchPolicy(maximumResults: 2, batchSize: 1)))
    #expect(results.0.count == 2)
    #expect(results.1?.completion == .resultLimit)
    let visited = await collect(service.start(request: try SearchRequest(filename: "absent"), scope: scope,
                                               policy: SearchPolicy(maximumVisitedEntries: 3)))
    #expect(visited.1?.visitedEntries == 3)
    #expect(visited.1?.completion == .traversalLimit)
    _ = try fixture.file("one/two/item")
    let depth = await collect(service.start(request: try SearchRequest(filename: "absent"), scope: scope,
                                             policy: SearchPolicy(maximumDepth: 0)))
    #expect(depth.1?.boundaryCounts[.depthLimit] == 1)
    for number in 0..<10 { _ = try fixture.file(".hidden-\(number)") }
    let issues = await collect(service.start(request: try SearchRequest(filename: "absent"), scope: scope,
                                              policy: SearchPolicy(maximumIssues: 2)))
    #expect(issues.1?.issues.count == 2)
    #expect(issues.1?.omittedIssues == 8)
}

@Test func cancelledAndSupersededSessionsCannotPublishNewBatches() async throws {
    let fixture = try SearchFixture()
    defer { fixture.remove() }
    _ = try fixture.file("final-name.txt")
    let scope = try SearchScope(root: fixture.root)
    let service = LocalMetadataSearch()
    var sessions: [SearchSession] = []
    for number in 0..<100 {
        sessions.append(service.start(request: try SearchRequest(filename: "absent-\(number)"), scope: scope))
    }
    let last = service.start(request: try SearchRequest(filename: "final-name"), scope: scope, policy: SearchPolicy(revision: 2))
    for session in sessions {
        let result = await collect(session)
        #expect(result.0.isEmpty)
        #expect(result.1 != nil)
    }
    let final = await collect(last)
    #expect(final.0.count == 1)
    #expect(final.1?.completion == .completed)
    let cancelled = service.start(request: try SearchRequest(filename: "absent"), scope: scope)
    cancelled.cancel()
    let end = await collect(cancelled)
    #expect(end.0.isEmpty)
    #expect(end.1?.completion == .cancelled || end.1?.completion == .completed)
    let old = SearchGeneration(sessionID: cancelled.id, policyRevision: 1)
    #expect(!old.accepts(SearchEvent(sessionID: last.id, policyRevision: 2, payload: .finished(final.1!))))
    #expect(!last.generation.accepts(SearchEvent(sessionID: last.id, policyRevision: 1, payload: .finished(final.1!))))
}

@Test func deniedAndUnavailableFoldersAreNotEmptySuccesses() async throws {
    let fixture = try SearchFixture()
    defer { fixture.remove() }
    let denied = try fixture.directory("denied")
    _ = try fixture.file("denied/match.txt")
    #expect(chmod(denied.path, 0) == 0)
    defer { _ = chmod(denied.path, 0o700) }
    let service = LocalMetadataSearch()
    if geteuid() != 0 {
        let result = await collect(service.start(request: try SearchRequest(filename: "match"), scope: try SearchScope(root: fixture.root)))
        #expect(result.0.isEmpty)
        #expect(result.1?.isComplete == false)
        let denied = result.1?.boundaryCounts[.denied] ?? 0
        let unavailable = result.1?.boundaryCounts[.metadataUnavailable] ?? 0
        #expect(denied > 0 || unavailable > 0)
    }
    let missing = await collect(service.start(request: try SearchRequest(filename: "match"), scope: try SearchScope(root: fixture.root.appendingPathComponent("absent"))))
    #expect(missing.0.isEmpty)
    #expect(missing.1?.completion == .failed)
    #expect(missing.1?.boundaryCounts[.unavailable] == 1)
}

@Test func indexedPlanHasOnlyFilesystemFilenamePredicateAndPathReturn() throws {
    #expect(SpotlightFilenamePlan.predicateFields == ["kMDItemFSName", "kMDItemContentTypeTree"])
    #expect(SpotlightFilenamePlan.returnedFields == ["kMDItemPath"])
    for literal in ["ordinary", "x", "文件 Café", "*", "?", "quote' OR kMDItemTextContent == '*'", "a\\b\"c"] {
        let request = try SearchRequest(filename: literal)
        let expression = SpotlightFilenamePlan.expression(request)
        #expect(expression.hasPrefix("kMDItemFSName == \""))
        #expect(expression.hasSuffix("\"cd"))
        // Creating/parsing a query does not execute it or access personal files.
        #expect(MDQueryCreate(kCFAllocatorDefault, expression as CFString, nil, nil) != nil)
    }
    let exact = SpotlightFilenamePlan.expression(try SearchRequest(filename: "Café.txt", filenameMatch: .exact))
    #expect(exact == "kMDItemFSName == \"Café.txt\"cd")
}

@Test func directoryCandidateHintIsFixedAndNeverChangesOrdinaryQueries() throws {
    for name in ["Nomad DB", "Nomad-DB", "*", "x' OR kMDItemTextContent == '*'", "日本語"] {
        let directory = try SearchRequest(filename: name, kind: .directory)
        let ordinary = SpotlightFilenamePlan.expression(directory)
        let candidate = SpotlightFilenamePlan.expression(directory, directoryHint: true)
        #expect(!ordinary.contains("kMDItemContentTypeTree"))
        #expect(candidate == "(" + ordinary + ") && (kMDItemContentTypeTree == \"public.directory\")")
        #expect(MDQueryCreate(kCFAllocatorDefault, candidate as CFString, nil, nil) != nil)
        let any = try SearchRequest(filename: name)
        #expect(SpotlightFilenamePlan.expression(any, directoryHint: true) == SpotlightFilenamePlan.expression(any))
    }
    #expect(SpotlightFilenamePlan.returnedFields == ["kMDItemPath"])
    let exact = try SearchRequest(filename: "Nomad DB", filenameMatch: .exact, kind: .directory)
    #expect(SpotlightFilenamePlan.expression(exact, directoryHint: true).contains("kMDItemFSName == \"Nomad DB\"cd"))
}

@Test func indexedDirectoryCandidatesStillRequireFreshDirectories() async throws {
    let fixture = try SearchFixture()
    defer { fixture.remove() }
    let directory = try fixture.directory("Match-Dir")
    let file = try fixture.file("Match_Dir.txt")
    let request = try SearchRequest(filename: "Match Dir", kind: .directory)
    let session = SearchSession(roots: [fixture.root], policy: SearchPolicy(), source: .spotlightIndex)
    for url in [file, directory, fixture.root.appendingPathComponent("Match Dir missing")] {
        IndexedResultGate.observe(url, roots: [fixture.root], request: request,
                                  includeExternalVolumes: true, state: session.state)
    }
    session.state.finish(.completed)
    let result = await collect(session)
    #expect(result.0.map(\.entry.url) == [directory])
    #expect(result.1?.isComplete == false)
}

@Test func injectedIndexedResultsAreRevalidatedAndHaveUnverifiedCoverage() async throws {
    let fixture = try SearchFixture()
    defer { fixture.remove() }
    let named = try fixture.file("FILE_SENTINEL_484.txt")
    let body = try fixture.file("ordinary.txt", body: "FILE_SENTINEL_484")
    let packageItem = try fixture.file("Example.app/FILE_SENTINEL_484.txt")
    let credential = try fixture.file(".ssh/FILE_SENTINEL_484.txt")
    let policy = SearchPolicy()
    let session = SearchSession(roots: [fixture.root], policy: policy, source: .spotlightIndex)
    let request = try SearchRequest(filename: "FILE_SENTINEL_484")
    // Injected paths only: no MDQueryExecute, mdfind, or system indexing.
    for url in [named, body, packageItem, credential, fixture.root.appendingPathComponent("absent.txt")] {
        IndexedResultGate.observe(url, roots: [fixture.root], request: request,
                                  includeExternalVolumes: true, state: session.state)
    }
    session.state.finish()
    let result = await collect(session)
    #expect(result.0.map(\.entry.url) == [named])
    #expect(result.0.first?.source == .spotlightIndex)
    #expect(result.1?.indexedCoverageUnverified == true)
    #expect(result.1?.isComplete == false)
    #expect(result.1?.boundaryCounts[.package] == 1)
    #expect(result.1?.boundaryCounts[.credentialLocation] == 1)
    #expect(result.1?.boundaryCounts[.unavailable] == 1)
}

@Test func injectedIndexRejectsSymlinkAncestorsScopeEscapesAndStaleSessions() async throws {
    let fixture = try SearchFixture()
    defer { fixture.remove() }
    let target = try fixture.directory("target")
    _ = try fixture.file("target/match.txt")
    let link = fixture.root.appendingPathComponent("link")
    try FileManager().createSymbolicLink(at: link, withDestinationURL: target)
    let session = SearchSession(roots: [fixture.root], policy: SearchPolicy(), source: .spotlightIndex)
    let request = try SearchRequest(filename: "match")
    IndexedResultGate.observe(link.appendingPathComponent("match.txt"), roots: [fixture.root], request: request,
                              includeExternalVolumes: true, state: session.state)
    IndexedResultGate.observe(URL(fileURLWithPath: fixture.root.path + "-escape/match.txt"), roots: [fixture.root], request: request,
                              includeExternalVolumes: true, state: session.state)
    session.cancel()
    IndexedResultGate.observe(target.appendingPathComponent("match.txt"), roots: [fixture.root], request: request,
                              includeExternalVolumes: true, state: session.state)
    let result = await collect(session)
    #expect(result.0.isEmpty)
    #expect(result.1?.completion == .cancelled)
    #expect(result.1?.boundaryCounts[.symbolicLink] == 1)
    #expect(result.1?.boundaryCounts[.excluded] == 1)
}

@Test func metadataPolicyHasFiniteLimitsAndDeadline() async throws {
    let policy = SearchPolicy(maximumResults: .max, maximumVisitedEntries: .max, maximumDepth: .max,
                              batchSize: .max, maximumIssues: .max, maximumDuration: .infinity)
    #expect(policy.maximumResults == 10_000)
    #expect(policy.maximumVisitedEntries == 1_000_000)
    #expect(policy.maximumDepth == 128)
    #expect(policy.batchSize == 256)
    #expect(policy.maximumIssues == 100)
    #expect(policy.maximumDuration == 20)
    let session = SearchSession(roots: [], policy: SearchPolicy(maximumDuration: 0.1), source: .spotlightIndex)
    try await Task.sleep(for: .milliseconds(120))
    #expect(session.state.isStopped)
    let result = await collect(session)
    #expect(result.1?.completion == .timedOut)
}

@Test func cancellationAtomicallyRejectsLateResultsAndBoundsBatches() async throws {
    let policy = SearchPolicy(batchSize: 2)
    let session = SearchSession(roots: [URL(fileURLWithPath: "/generated")], policy: policy, source: .recursiveMetadata)
    let early = FileEntry(url: URL(fileURLWithPath: "/generated/early"), name: "early", kind: .file)
    let late = FileEntry(url: URL(fileURLWithPath: "/generated/late"), name: "late", kind: .file)
    session.state.match(SearchMatch(entry: early))
    session.cancel()
    session.state.match(SearchMatch(entry: late))
    session.state.finish()
    let result = await collect(session)
    #expect(result.0.map(\.entry.name) == ["early"])
    #expect(result.1?.completion == .cancelled)
    #expect(result.1?.matchedEntries == 1)

    let batches = SearchSession(roots: [], policy: policy, source: .recursiveMetadata)
    for index in 0..<7 {
        batches.state.match(SearchMatch(entry: FileEntry(url: URL(fileURLWithPath: "/generated/item-\(index)"), name: "item-\(index)", kind: .file)))
    }
    batches.state.finish()
    var sizes: [Int] = []
    for await event in batches.events {
        if case .batch(let matches) = event.payload { sizes.append(matches.count) }
    }
    #expect(sizes == [1, 2, 2, 2])
}

@Test func firstUsefulMatchPublishesBeforeScanCompletion() async {
    let session = SearchSession(roots: [], policy: SearchPolicy(batchSize: 128), source: .recursiveMetadata)
    let timeout = Task {
        try? await Task.sleep(for: .milliseconds(500))
        if !Task.isCancelled { session.cancel() }
    }
    defer { timeout.cancel() }
    let match = SearchMatch(entry: FileEntry(url: URL(fileURLWithPath: "/generated/first.txt"), name: "first.txt", kind: .file))
    session.state.match(match)
    var iterator = session.events.makeAsyncIterator()
    let first = await iterator.next()
    if case .batch(let matches) = first?.payload { #expect(matches == [match]) }
    else { Issue.record("First useful match waited for scan completion.") }
    #expect(!session.state.isStopped)
    session.state.finish()
    var final: SearchCoverage?
    while let event = await iterator.next() {
        if case .finished(let coverage) = event.payload { final = coverage }
    }
    #expect(final?.matchedEntries == 1)
}

@Test func progressiveCountsFlushSparseRowsAndCannotClaimFinalCoverage() async throws {
    let session = SearchSession(roots: [URL(fileURLWithPath: "/generated")],
        policy: SearchPolicy(maximumDuration: 60), source: .recursiveMetadata)
    session.state.directory()
    #expect(session.state.visit())
    for name in ["first.txt", "second.txt"] {
        session.state.match(SearchMatch(entry: FileEntry(url: URL(fileURLWithPath: "/generated/" + name), name: name, kind: .file)))
    }
    try await Task.sleep(for: .milliseconds(280))
    #expect(!session.state.isStopped)
    for _ in 0..<100 { #expect(session.state.visit()); #expect(!session.state.isStopped) }
    session.cancel(); session.state.issue(URL(fileURLWithPath: "/generated/late"), .unavailable)
    session.state.match(SearchMatch(entry: FileEntry(url: URL(fileURLWithPath: "/generated/late"), name: "late", kind: .file)))
    var labels: [String] = [], finished = false
    for await event in session.events {
        #expect(!finished)
        switch event.payload {
        case .batch(let matches): labels += matches.map { "row:" + $0.entry.name }
        case .progress(let coverage):
            #expect(!coverage.isComplete && coverage.finishedAt == nil && coverage.visitedEntries == 1)
            #expect(coverage.matchedEntries == 2)
            labels.append("progress")
        case .finished(let coverage):
            #expect(coverage.completion == .cancelled && coverage.visitedEntries == 101)
            #expect(coverage.boundaryCounts.isEmpty && coverage.finishedAt != nil)
            finished = true; labels.append("finished")
        }
    }
    #expect(labels == ["row:first.txt", "row:second.txt", "progress", "finished"])
}

@Test func progressIsRateBoundedAndUnchangedCoverageIsQuiet() async throws {
    let session = SearchSession(roots: [], policy: SearchPolicy(maximumDuration: 60), source: .recursiveMetadata)
    #expect(session.state.visit())
    try await Task.sleep(for: .milliseconds(280)); #expect(!session.state.isStopped)
    try await Task.sleep(for: .milliseconds(280)); #expect(!session.state.isStopped)
    #expect(session.state.visit()); #expect(!session.state.isStopped)
    for _ in 0..<100 { #expect(!session.state.isStopped) }
    session.state.finish()
    var counts: [Int] = [], final: SearchCoverage?
    for await event in session.events {
        switch event.payload {
        case .progress(let value): counts.append(value.visitedEntries); #expect(!value.isComplete)
        case .finished(let value): final = value
        case .batch: Issue.record("Counter-only progress invented a search row")
        }
    }
    #expect(counts == [1, 2])
    #expect(final?.isComplete == true && final?.visitedEntries == 2)
}
