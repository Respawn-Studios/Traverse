import ExplorerCore
import Foundation

/// Explicit per-request metadata scope, independent of indexing or OS grants.
/// Explicit application-data scope never grants OS access or broadens hover scans.
public enum AnalysisMetadataPolicy: String, Sendable, CaseIterable {
    case standard = "local-metadata-v1"
    case applicationData = "local-metadata-app-data-v1"

    public var title: String { self == .standard ? "Standard metadata" : "Includes application data · metadata only" }
}

/// Known exclusions supplement native no-follow/local/mount/materialization
/// guards. A path match is not a TCC query or proof that an access is prompt-free.
public enum StorageAnalysisPolicy {
    public static let revision = "local-metadata-v1"

    public static func excludes(_ url: URL, policy: AnalysisMetadataPolicy = .standard) -> Bool {
        let parts = url.standardizedFileURL.pathComponents.dropFirst().map {
            $0.lowercased(with: Locale(identifier: "en_US_POSIX"))
        }
        return excludesComponents(Array(parts), policy: policy)
    }

    public static func excludesComponents(_ parts: [String], policy: AnalysisMetadataPolicy = .standard) -> Bool {
        let prefix = ["system", "volumes", "data"]
        if parts.starts(with: prefix), excludesLogicalComponents(Array(parts.dropFirst(3)), policy: policy) { return true }
        return excludesLogicalComponents(parts, policy: policy)
    }

    private static let privateLibrary: Set<String> = ["mail", "messages", "safari", "calendars", "contacts", "reminders",
        "personalizationportrait", "autosave information"]
    private static let containers: Set<String> = ["containers", "group containers"]
    private static let privateContainerFamilies = ["com.apple.mail", "com.apple.messages", "com.apple.ichat",
        "com.apple.mobilesms", "com.apple.safari", "com.apple.ical", "com.apple.calendaragent", "com.apple.calendars",
        "com.apple.addressbook", "com.apple.contacts", "com.apple.reminders", "com.apple.personalizationportrait",
        "com.apple.passwords", "com.apple.keychainaccess", "com.apple.tcc"]

    private static func excludesLibrary(_ parts: ArraySlice<String>) -> Bool {
        let parts = Array(parts)
        guard let first = parts.first else { return false }
        return privateLibrary.contains(first)
            || (parts.count >= 2 && first == "application support" && ["com.apple.tcc", "addressbook", "callhistorydb"].contains(parts[1]))
            || (parts.count >= 2 && first == "metadata" && parts[1] == "corespotlight")
    }

    private static func excludesLogicalComponents(_ parts: [String], policy: AnalysisMetadataPolicy) -> Bool {
        if parts.contains(where: {
            AutomaticMetadataPolicy.excludesComponent($0) || [".trash", ".trashes", "cloudstorage", "mobile documents"].contains($0)
                || $0.hasSuffix(".photoslibrary")
        }) { return true }
        guard let first = parts.first else { return false }
        if ["network", "net", ".vol"].contains(first) { return true }
        if parts.starts(with: ["library", "application support", "com.apple.tcc"]) { return true }
        if parts.count >= 4, first == "users", parts[2] == "library" {
            if excludesLibrary(parts[3...]) { return true }
            guard containers.contains(parts[3]) else { return false }
            if policy == .standard { return true }
            if parts.count >= 5 {
                let raw = parts[4], name = raw.hasPrefix("group.") ? String(raw.dropFirst(6)) : raw
                if privateContainerFamilies.contains(where: { name == $0 || name.hasPrefix($0 + ".") }) { return true }
            }
            if parts.count > 5 {
                for index in 5..<parts.count where parts[index] == "library" {
                    if excludesLibrary(parts[(index + 1)...])
                        || (index + 1 < parts.count && containers.contains(parts[index + 1])) { return true }
                }
            }
        }
        return false
    }

    /// Presentation/admission prefilter only. The app must also have a current
    /// ordinary-folder observation and signed access qualification. Never use
    /// this predicate to infer a grant or launch a whole-disk hover scan.
    public static func allowsAutomaticRoot(_ url: URL) -> Bool {
        guard url.isFileURL, !excludes(url) else { return false }
        let parts = url.standardizedFileURL.pathComponents.dropFirst().map {
            $0.lowercased(with: Locale(identifier: "en_US_POSIX"))
        }
        guard !parts.isEmpty else { return false }
        if let first = parts.first, ["system", "private", "library", "dev", "network", "net"].contains(first) { return false }
        if parts.count == 1 { return false }
        if parts.first == "users", parts.count == 2 { return false }
        // These privacy classes are deliberately not admitted by default hover
        // before signed, prompt-free qualification. A readable Home listing or
        // an old bookmark cannot establish descendant access. Explicit Analyze
        // remains a separate user action and uses the ordinary exclusions.
        if parts.first == "users", parts.count >= 3,
           ["library", "desktop", "documents", "downloads"].contains(parts[2]) { return false }
        if parts.first == "volumes", parts.count == 2 { return false }
        return true
    }
}

/// Bind scan headers and every read child to one policy. A mismatching helper
/// refuses rather than silently downgrading, broadening or switching engines.
struct AnalysisPolicyBinding: Sendable {
    let policy: AnalysisMetadataPolicy
    let policyAware: Bool
    let classificationRevision: AnalysisClassificationRevision
    let applicationLayoutRevision: Int?
    let storedLocationRevision: Int?
    let sortedPageRevision: Int?
    let largestFilesRevision: Int?
    let chartOverviewRevision: Int?
    let purposeJourneyRevision: Int?
    let isStartupPair: Bool
    let maximumPathComponents: Int
    let adaptiveCheckpoints: Bool
    // A paired catalog inserts one synthetic source root above each physical
    // hierarchy; that row is not a filesystem path component.
    var maximumStoredHierarchyDepth: Int { maximumPathComponents + (isStartupPair ? 1 : 0) }
    static let standard = AnalysisPolicyBinding()
    private init() { policy = .standard; policyAware = false; classificationRevision = .v2; applicationLayoutRevision = nil; storedLocationRevision = nil; sortedPageRevision = nil; largestFilesRevision = nil; chartOverviewRevision = nil; purposeJourneyRevision = nil; isStartupPair = false; maximumPathComponents = 64; adaptiveCheckpoints = false }
    /// Exact inactive retained v4 profile; Rust still verifies the stored
    /// profile/session/policy in its existing read-result query path.
    init(retained record: RetainedAnalysisRecord) throws {
        try record.validate()
        guard let policy = AnalysisMetadataPolicy(rawValue: record.metadataPolicy),
              record.profile.schema == (record.scope.isStartup ? 18 : 17) else { throw StorageScanFailure.invalidOutput }
        self.policy = policy; policyAware = true; classificationRevision = .v4
        applicationLayoutRevision = record.profile.applicationLayouts
        storedLocationRevision = record.profile.storedLocations
        sortedPageRevision = record.profile.sortedPages
        largestFilesRevision = record.profile.largestFiles
        chartOverviewRevision = record.profile.chartOverview
        purposeJourneyRevision = record.profile.purposeJourney
        isStartupPair = record.scope.isStartup; maximumPathComponents = 128; adaptiveCheckpoints = true
    }

    init(header: [String: Any], startup: Bool, policy: AnalysisMetadataPolicy,
         classificationRevision: AnalysisClassificationRevision = .v2) throws {
        guard let schema = strictInteger(header["schema"]), header["policy_revision"] as? String == policy.rawValue else {
            throw StorageScanFailure.invalidOutput
        }
        isStartupPair = startup
        adaptiveCheckpoints = [startup ? 16 : 15, startup ? 18 : 17].contains(schema)
        let deeper = adaptiveCheckpoints || schema == (startup ? 14 : 13)
        maximumPathComponents = deeper ? 128 : 64
        if adaptiveCheckpoints {
            guard strictInteger(header["checkpoint_revision"]) == 1, strictInteger(header["checkpoint_rows"]) == 16384,
                  header["progress_revision"] as? String == (classificationRevision == .v4 ? "committed-totals-data-v4" : "committed-totals-adaptive-v1") else { throw StorageScanFailure.invalidOutput }
        } else { guard header["checkpoint_revision"] == nil else { throw StorageScanFailure.invalidOutput } }
        if deeper {
            guard classificationRevision.supportsApplicationRules, header["traversal_revision"] as? String == "bounded-depth-v1",
                  strictInteger(header["maximum_depth"]) == 128 else { throw StorageScanFailure.invalidOutput }
        } else {
            guard header["traversal_revision"] == nil, header["maximum_depth"] == nil else { throw StorageScanFailure.invalidOutput }
        }
        if let revision = header["application_layout_revision"] {
            guard classificationRevision.supportsApplicationRules, strictInteger(revision) == 1 else { throw StorageScanFailure.invalidOutput }
            applicationLayoutRevision = 1
        } else { applicationLayoutRevision = nil }
        if let revision = header["stored_location_revision"] {
            guard classificationRevision.supportsApplicationRules, strictInteger(revision) == 1 else { throw StorageScanFailure.invalidOutput }
            storedLocationRevision = 1
        } else { storedLocationRevision = nil }
        if let revision = header["sorted_page_revision"] {
            guard classificationRevision.supportsApplicationRules, strictInteger(revision) == 1 else { throw StorageScanFailure.invalidOutput }
            sortedPageRevision = 1
        } else { sortedPageRevision = nil }
        if let revision = header["largest_files_revision"] {
            guard classificationRevision.supportsApplicationRules, sortedPageRevision == 1, strictInteger(revision) == 1 else { throw StorageScanFailure.invalidOutput }
            largestFilesRevision = 1
        } else { largestFilesRevision = nil }
        if let revision = header["chart_overview_revision"] {
            guard classificationRevision == .v4, strictInteger(revision) == 1 else { throw StorageScanFailure.invalidOutput }
            chartOverviewRevision = 1
        } else { chartOverviewRevision = nil }
        if let revision = header["purpose_journey_revision"] {
            guard classificationRevision == .v4, strictInteger(revision) == 1 else { throw StorageScanFailure.invalidOutput }
            purposeJourneyRevision = 1
        } else { purposeJourneyRevision = nil }
        if classificationRevision == .v4 {
            guard schema == (startup ? 18 : 17), adaptiveCheckpoints,
                  strictInteger(header["classification_revision"]) == 4,
                  header["profile"] as? String == (startup ? "startup-result-data-v4" : "full-result-data-v4") else { throw StorageScanFailure.invalidOutput }
            self.policy = policy; policyAware = true; self.classificationRevision = .v4; return
        }
        if classificationRevision == .v3 {
            let profile = adaptiveCheckpoints ? (startup ? "startup-result-adaptive-v1" : "full-result-adaptive-v1")
                : deeper ? (startup ? "startup-result-depth128-v1" : "full-result-depth128-v1")
                : (startup ? "startup-result-classification-v3" : "full-result-classification-v3")
            guard (startup ? [12,14,16] : [11,13,15]).contains(schema), strictInteger(header["classification_revision"]) == 3,
                  header["profile"] as? String == profile else {
                throw StorageScanFailure.invalidOutput
            }
            self.policy = policy; policyAware = true; self.classificationRevision = .v3; return
        }
        guard header["classification_revision"] == nil else { throw StorageScanFailure.invalidOutput }
        let ordinary = startup ? 6 : 5, dense = startup ? 8 : 7, aware = startup ? 10 : 9
        let profile = schema == aware ? (startup ? "startup-result-policy-v1" : "full-result-policy-v1")
            : schema == dense ? (startup ? "startup-result-v2" : "full-result-v2")
            : (startup ? "startup-result-v1" : "full-result-v1")
        guard [ordinary, dense, aware].contains(schema), header["profile"] as? String == profile,
              policy == .standard || schema == aware else { throw StorageScanFailure.invalidOutput }
        self.policy = policy; policyAware = schema == aware; self.classificationRevision = .v2
    }

    var arguments: [String] { policyAware ? ["--metadata-policy", policy.rawValue] : [] }

    func validateQueryPrelude(_ frame: [String: Any], session: UUID) throws {
        guard policyAware, frame.count == (classificationRevision.supportsApplicationRules ? 4 : 3) + (maximumPathComponents == 128 ? 1 : 0) + (adaptiveCheckpoints ? 1 : 0), frame["kind"] as? String == "policy",
              frame["revision"] as? String == policy.rawValue, frame["session"] as? String == session.uuidString else {
            throw StorageScanFailure.invalidOutput
        }
        if classificationRevision.supportsApplicationRules, strictInteger(frame["classification_revision"]) != classificationRevision.rawValue { throw StorageScanFailure.invalidOutput }
        if maximumPathComponents == 128, strictInteger(frame["maximum_depth"]) != 128 { throw StorageScanFailure.invalidOutput }
        if adaptiveCheckpoints, strictInteger(frame["checkpoint_revision"]) != 1 { throw StorageScanFailure.invalidOutput }
    }
}
