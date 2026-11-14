import Foundation
import Testing
@testable import StorageAnalysis

/// These are pure path-policy checks. Only the repository-owned vector source
/// is read; no URL described by a vector is queried or opened. The Swift policy
/// admits directory roots, so five file-specific native vectors are not applied
/// to its directory-only API (notably a regular .photoslibrary filename).
struct StorageAnalysisPolicyTests {
    private struct Vector {
        let directory: Bool
        let excluded: Bool
        let path: String
    }

    private enum VectorError: Error { case malformedLine(Int) }

    private func vectors() throws -> [Vector] {
        var repository = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { repository.deleteLastPathComponent() }
        let source = repository.appendingPathComponent("Workers/StorageScanner/policy-vectors.tsv")
        let text = try String(contentsOf: source, encoding: .utf8)
        return try text.split(separator: "\n", omittingEmptySubsequences: false).enumerated().compactMap { index, line in
            if line.isEmpty || line.hasPrefix("#") { return nil }
            let columns = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard columns.count == 3, ["d", "f"].contains(columns[0]), ["0", "1"].contains(columns[1]),
                  columns[2].hasPrefix("/"), !columns[2].contains("\0") else {
                throw VectorError.malformedLine(index + 1)
            }
            return Vector(directory: columns[0] == "d", excluded: columns[1] == "1", path: String(columns[2]))
        }
    }

    @Test func directoryPolicyMatchesEverySharedDirectoryVector() throws {
        let all = try vectors()
        #expect(all.count == 52)
        #expect(all.filter { !$0.directory }.count == 5)
        let directories = all.filter(\.directory)
        #expect(directories.count == 47)
        for vector in directories {
            let url = URL(fileURLWithPath: vector.path, isDirectory: true)
            #expect(StorageAnalysisPolicy.excludes(url) == vector.excluded,
                    "Directory vector disagrees: \(vector.path)")
            let folded = url.standardizedFileURL.pathComponents.dropFirst().map {
                $0.lowercased(with: Locale(identifier: "en_US_POSIX"))
            }
            #expect(StorageAnalysisPolicy.excludesComponents(folded) == vector.excluded,
                    "Component policy disagrees: \(vector.path)")
        }
    }

    @Test func absoluteURLsFoldCaseAndNormalizeExclusionAliases() throws {
        let blocked = [
            "file:///USERS/U/.SSH/child",
            "file:///Users/u/Library/Messages/../Mail",
            "file:///Users/u/Library/Mobile%20Documents/child",
            "file:///SYSTEM/VOLUMES/DATA/USERS/U/LIBRARY/MAIL",
            "file:///System/Volumes/Data/Library/Application%20Support/COM.APPLE.TCC",
            "file:///System/Volumes/Data/Network/share",
        ]
        for spelling in blocked {
            let url = try #require(URL(string: spelling))
            #expect(url.isFileURL)
            #expect(StorageAnalysisPolicy.excludes(url), "Expected exclusion: \(spelling)")
        }
    }

    @Test func nearPrefixesDoNotBroadenTheExclusionBoundary() {
        let ordinary = [
            "/Users/u/.ssh-backup", "/Users/u/Documents/credentials-backup",
            "/Users/u/Library/Mailbox", "/Users/u/Library/Metadata/CoreSpotlightOther",
            "/Users/u/Library/Application Support/AddressBookOther",
            "/Volumes/Test/Images.photoslibrary-other", "/Volumes/Network/public",
            "/System/Volumes/Data2/Users/u/Library/Mail",
            "/System/Volumes/Database/Users/u/Library/Mail",
        ]
        for path in ordinary {
            #expect(!StorageAnalysisPolicy.excludes(URL(fileURLWithPath: path, isDirectory: true)),
                    "Near-prefix path overblocked: \(path)")
        }
    }

    @Test func automaticAdmissionRejectsWideRootsAndUnqualifiedSystemAliases() {
        let wide = [
            "/", "/Users", "/Users/u", "/Users/u/Library", "/Library",
            "/Volumes", "/Volumes/Drive", "/System", "/private", "/home",
            "/users/u", "/USERS/u/LIBRARY", "/VOLUMES/Drive",
            "/System/Volumes/Data", "/System/Volumes/Data/Users/u",
            "/System/Volumes/Data/Users/u/Library", "/SYSTEM/VOLUMES/DATA/VOLUMES/Drive",
            "/System/Volumes/Data/Users/u/Documents",
            "/Users/u/Documents", "/Users/u/Desktop/Generated", "/Users/u/Downloads/Generated",
            "/Users/u/Library/Other", "/USERS/u/DOWNLOADS",
            "/Users/u/Library/../Documents",
        ]
        // Logical spellings improve known exclusion matching only. They never
        // grant automatic eligibility through an otherwise unqualified System
        // path. Protected user-folder classes also require separate signed
        // automatic-access qualification before admission.
        for path in wide {
            #expect(!StorageAnalysisPolicy.allowsAutomaticRoot(URL(fileURLWithPath: path, isDirectory: true)),
                    "Wide automatic scope accepted: \(path)")
        }
    }

    @Test func automaticAdmissionAllowsOrdinaryFolderPrefiltersOnly() throws {
        let ordinary = [
            "/Users/u/Projects", "/Users/u/Projects/Library", "/Volumes/Drive/project",
        ]
        for path in ordinary {
            #expect(StorageAnalysisPolicy.allowsAutomaticRoot(URL(fileURLWithPath: path, isDirectory: true)),
                    "Ordinary folder prefilter refused: \(path)")
        }
        let web = try #require(URL(string: "https://example.invalid/Users/u/Documents"))
        #expect(!StorageAnalysisPolicy.allowsAutomaticRoot(web))
        // Passing a lexical prefilter never proves an access grant, a local
        // ordinary-folder observation, TCC behavior or worker drain.
    }

    @Test func applicationDataSharesCanonicalPolicyVectorsAndKeepsAutomaticScopesConservative() throws {
        var repository = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { repository.deleteLastPathComponent() }
        let text = try String(contentsOf: repository.appendingPathComponent("Workers/StorageScanner/policy-app-data-vectors.tsv"), encoding: .utf8)
        var count = 0
        for line in text.split(separator: "\n") where !line.hasPrefix("#") {
            let columns = line.split(separator: "\t", omittingEmptySubsequences: false)
            #expect(columns.count == 4)
            // Swift admission is directory-only; Rust also tests file vectors.
            if columns[0] != "d" { continue }
            let path = String(columns[3])
            for (policy, index) in [(AnalysisMetadataPolicy.standard, 1), (.applicationData, 2)] {
                for spelling in [path, "/System/Volumes/Data" + path] {
                    let url = URL(fileURLWithPath: spelling, isDirectory: true)
                    #expect(StorageAnalysisPolicy.excludes(url, policy: policy) == (columns[index] == "1"), "\(spelling), \(policy)")
                }
            }
            if path.lowercased().hasPrefix("/users/u/library/") {
                #expect(!StorageAnalysisPolicy.allowsAutomaticRoot(URL(fileURLWithPath: path)))
            }
            count += 1
        }
        #expect(count >= 40)
        #expect(StorageAnalysisPolicy.revision == AnalysisMetadataPolicy.standard.rawValue)
    }

    @Test func policyHeaderAndReadProvenanceNeverSilentlyChangeTheRequestedScope() throws {
        let id = UUID()
        for startup in [false, true] {
            for policy in AnalysisMetadataPolicy.allCases {
                let header: [String: Any] = ["schema": startup ? 10 : 9,
                    "profile": startup ? "startup-result-policy-v1" : "full-result-policy-v1", "policy_revision": policy.rawValue]
                let binding = try AnalysisPolicyBinding(header: header, startup: startup, policy: policy)
                #expect(binding.policyAware)
                #expect(binding.arguments == ["--metadata-policy", policy.rawValue])
                let frame: [String: Any] = ["kind": "policy", "revision": policy.rawValue, "session": id.uuidString]
                try binding.validateQueryPrelude(frame, session: id)
                for (key, wrong) in [("kind", "summary"), ("revision", "unknown"), ("session", UUID().uuidString), ("extra", "1")] {
                    var bad = frame; bad[key] = wrong
                    #expect(throws: StorageScanFailure.invalidOutput) { try binding.validateQueryPrelude(bad, session: id) }
                }
                var changed = header
                changed["policy_revision"] = policy == .standard ? AnalysisMetadataPolicy.applicationData.rawValue : AnalysisMetadataPolicy.standard.rawValue
                #expect(throws: StorageScanFailure.invalidOutput) { try AnalysisPolicyBinding(header: changed, startup: startup, policy: policy) }
                changed = header; changed["schema"] = startup ? 9 : 10
                #expect(throws: StorageScanFailure.invalidOutput) { try AnalysisPolicyBinding(header: changed, startup: startup, policy: policy) }
                changed = header; changed["schema"] = true
                #expect(throws: StorageScanFailure.invalidOutput) { try AnalysisPolicyBinding(header: changed, startup: startup, policy: policy) }
            }
            let ordinary: [String: Any] = ["schema": startup ? 6 : 5, "profile": startup ? "startup-result-v1" : "full-result-v1",
                "policy_revision": AnalysisMetadataPolicy.standard.rawValue]
            #expect(try !AnalysisPolicyBinding(header: ordinary, startup: startup, policy: .standard).policyAware)
            #expect(throws: StorageScanFailure.invalidOutput) { try AnalysisPolicyBinding(header: ordinary, startup: startup, policy: .applicationData) }
            var fake = ordinary; fake["policy_revision"] = AnalysisMetadataPolicy.applicationData.rawValue
            #expect(throws: StorageScanFailure.invalidOutput) { try AnalysisPolicyBinding(header: fake, startup: startup, policy: .applicationData) }
        }
        #expect(throws: StorageScanFailure.invalidOutput) { try AnalysisPolicyBinding.standard.validateQueryPrelude([:], session: id) }
    }
}
