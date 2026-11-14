import Foundation

// Immutable recorded metadata only. These values perform no disk operations,
// acquire no access and confer no current-identity or mutation authority.
enum RetainedAnalysisFailure: Error, Equatable { case invalid, unsupported, capacity, stale, forgetPending, overflow }

struct RetainedAnalysisRecord: Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    // Only the two existing qualified v4 profiles; no provider abstraction.
    struct Profile: Codable, Equatable, Sendable {
        let schema: Int
        let catalogRevision: Int
        let profile: String
        let classification: Int
        let maximumDepth: Int
        let checkpointRevision: Int
        let checkpointRows: Int
        let traversal: String
        let progress: String
        let applicationLayouts: Int
        let storedLocations: Int
        let sortedPages: Int
        let largestFiles: Int
        let purposeJourney: Int
        let chartOverview: Int?
        init(startup: Bool, chartOverview: Bool = false) {
            schema = startup ? 18 : 17; catalogRevision = startup ? 1016 : 1015
            profile = startup ? "startup-result-data-v4" : "full-result-data-v4"
            classification = 4; maximumDepth = 128; checkpointRevision = 1; checkpointRows = 16384
            traversal = "bounded-depth-v1"; progress = "committed-totals-data-v4"
            applicationLayouts = 1; storedLocations = 1; sortedPages = 1; largestFiles = 1; purposeJourney = 1
            self.chartOverview = chartOverview ? 1 : nil
        }
        func validate(startup: Bool) throws {
            guard self == Profile(startup: startup) || self == Profile(startup: startup, chartOverview: true) else {
                throw RetainedAnalysisFailure.unsupported
            }
        }
    }

    struct Time: Codable, Equatable, Sendable {
        // Integer Unix seconds + nanoseconds avoid Date/JSON floating-point loss.
        let seconds: String
        let nanoseconds: Int
        init(seconds: Int64, nanoseconds: Int = 0) throws {
            self.seconds = String(seconds); self.nanoseconds = nanoseconds; try validate()
        }
        func validate() throws {
            guard let value = Int64(seconds), String(value) == seconds, (0..<1_000_000_000).contains(nanoseconds) else {
                throw RetainedAnalysisFailure.invalid
            }
        }
        func precedesOrEquals(_ other: Self) -> Bool {
            guard let lhs = Int64(seconds), let rhs = Int64(other.seconds) else { return false }
            return lhs < rhs || lhs == rhs && nanoseconds <= other.nanoseconds
        }
    }

    struct Root: Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
        let locator: String
        let volume: UUID
        let inode: String
        let generation: UInt32
        let birth: Time
        init(locator: String, volume: UUID, inode: UInt64, generation: UInt32, birth: Time) throws {
            self.locator = locator; self.volume = volume; self.inode = String(inode)
            self.generation = generation; self.birth = birth; try validate()
        }
        func validate() throws {
            let bytes = locator.utf8
            guard bytes.count <= 8192 else { throw RetainedAnalysisFailure.invalid }
            let components = locator.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
            let validComponents = locator == "/" || !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
            guard locator.hasPrefix("/"), retainedNonzero(volume),
                  !bytes.contains(0), !locator.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  locator == "/" || !locator.hasSuffix("/"), validComponents,
                  try retainedUnsigned(inode) > 0 else { throw RetainedAnalysisFailure.invalid }
            try birth.validate()
        }
        // These are recorded native observations, NOT proof of durable object
        // incarnation, a current mount/dev_t, a bookmark or permission to reopen.
        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.locator.utf8.elementsEqual(rhs.locator.utf8) && lhs.volume == rhs.volume && lhs.inode == rhs.inode &&
                lhs.generation == rhs.generation && lhs.birth == rhs.birth
        }
        var description: String { "<recorded analysis root>" }
        var debugDescription: String { description }
    }

    enum ActiveSystem: Equatable, Sendable, Codable {
        case liveSystem
        case snapshot(UUID)
        private enum CodingKeys: String, CodingKey { case kind, snapshot }
        private enum Kind: String, Codable { case liveSystem, snapshot }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            switch try c.decode(Kind.self, forKey: .kind) {
            case .liveSystem: self = .liveSystem
            case .snapshot: self = .snapshot(try c.decode(UUID.self, forKey: .snapshot))
            }
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .liveSystem: try c.encode(Kind.liveSystem, forKey: .kind)
            case .snapshot(let uuid): try c.encode(Kind.snapshot, forKey: .kind); try c.encode(uuid, forKey: .snapshot)
            }
        }
    }
    struct Source1Data: Codable, Equatable, Sendable {
        let sourceID: Int
        let root: Root
        let physicalRootInode: String
        init(root: Root, physicalRootInode: UInt64) { sourceID = 1; self.root = root; self.physicalRootInode = String(physicalRootInode) }
    }
    struct Source2System: Codable, Equatable, Sendable {
        let sourceID: Int
        let root: Root
        let physicalRootInode: String
        let backingVolume: UUID
        let activeDisk: UUID
        let active: ActiveSystem
        init(root: Root, physicalRootInode: UInt64, backingVolume: UUID, activeDisk: UUID, active: ActiveSystem) {
            sourceID = 2; self.root = root; self.physicalRootInode = String(physicalRootInode)
            self.backingVolume = backingVolume; self.activeDisk = activeDisk; self.active = active
        }
    }
    struct StartupPair: Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
        let discoveryRevision: String
        let container: UUID
        let group: UUID
        let data: Source1Data
        let system: Source2System
        init(container: UUID, group: UUID, data: Source1Data, system: Source2System) throws {
            discoveryRevision = "apple-diskutil-startup-27-v2"; self.container = container; self.group = group
            self.data = data; self.system = system; try validate()
        }
        func validate() throws {
            try data.root.validate(); try system.root.validate()
            guard discoveryRevision == "apple-diskutil-startup-27-v2", retainedNonzero(container), retainedNonzero(group),
                  data.sourceID == 1, system.sourceID == 2, data.root.locator != "/", data.root.locator.utf8.count < 1024,
                  system.root.locator == "/",
                  try retainedUnsigned(data.physicalRootInode) > 0, try retainedUnsigned(system.physicalRootInode) > 0,
                  retainedNonzero(system.backingVolume), retainedNonzero(system.activeDisk),
                  data.root.volume != system.backingVolume, data.root.volume != system.root.volume,
                  data.root.volume != system.activeDisk else { throw RetainedAnalysisFailure.invalid }
            switch system.active {
            case .liveSystem:
                guard system.root.volume == system.backingVolume, system.activeDisk == system.backingVolume else {
                    throw RetainedAnalysisFailure.invalid
                }
            case .snapshot(let id):
                guard retainedNonzero(id) else { throw RetainedAnalysisFailure.invalid }
                // Actual decoder permits active volume/disk identity to differ
                // from the backing System member when a snapshot is active.
            }
        }
        var description: String { "<recorded startup analysis pair>" }
        var debugDescription: String { description }
    }
    enum Scope: Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
        case single(Root)
        case startup(StartupPair)
        private enum CodingKeys: String, CodingKey { case kind, root, pair }
        private enum Kind: String, Codable { case single, startup }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            switch try c.decode(Kind.self, forKey: .kind) {
            case .single: self = .single(try c.decode(Root.self, forKey: .root))
            case .startup: self = .startup(try c.decode(StartupPair.self, forKey: .pair))
            }
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .single(let root): try c.encode(Kind.single, forKey: .kind); try c.encode(root, forKey: .root)
            case .startup(let pair): try c.encode(Kind.startup, forKey: .kind); try c.encode(pair, forKey: .pair)
            }
        }
        var isStartup: Bool { if case .startup = self { return true }; return false }
        func validate() throws {
            switch self {
            case .single(let root):
                try root.validate()
                // Preserve current session-reuse scope restriction. A whole
                // startup request must use the explicit pair, not one path.
                guard root.locator != "/", root.locator != "/System/Volumes/Data" else { throw RetainedAnalysisFailure.unsupported }
            case .startup(let pair): try pair.validate()
            }
        }
        // Retention grouping only, never cold-open/native identity admission.
        // A newly scanned active snapshot can replace the old same APFS group;
        // both records still preserve their own distinct active identity.
        func sameRetentionScope(as other: Self) -> Bool {
            switch (self, other) {
            case (.single(let a), .single(let b)): return a == b
            case (.startup(let a), .startup(let b)):
                return a.container == b.container && a.group == b.group && a.data.root.volume == b.data.root.volume &&
                    a.system.backingVolume == b.system.backingVolume
            default: return false
            }
        }
        var description: String { "<recorded analysis scope>" }
        var debugDescription: String { description }
    }

    // Cleanup correlation evidence only. Native exact-namespace/seal/lock
    // validation is still mandatory; these values are not deletion authority.
    struct Catalog: Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
        let catalogID: UUID
        let bytes: String
        let sha256: String
        init(catalogID: UUID, bytes: UInt64, sha256: String) throws {
            self.catalogID = catalogID; self.bytes = String(bytes); self.sha256 = sha256; try validate()
        }
        func validate() throws {
            let size = try retainedUnsigned(bytes)
            guard size > 0, size <= 2 << 30, sha256.utf8.count == 64,
                  sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw RetainedAnalysisFailure.invalid }
        }
        var sessionChild: String { "session-" + catalogID.uuidString.replacingOccurrences(of: "-", with: "").lowercased() }
        var catalogComponents: [String] { [sessionChild, "result.sqlite"] }
        var description: String { "<retained catalog cleanup evidence>" }
        var debugDescription: String { description }
    }

    struct Coverage: Codable, Equatable, Sendable {
        // Exact existing AnalysisScanCoverageReason order, frozen by format2.
        // Counts are notices, not unique omitted objects or omitted bytes.
        let reasonCounts: [String]
        let reportedNotices: String
        let workerNotices: String
        let uncategorizedNotices: String
        let reasonCountsAreComplete: Bool
        let terminalReason: Int?
        init(reasonCounts: [UInt64], reportedNotices: UInt64, workerNotices: UInt64,
             uncategorizedNotices: UInt64, reasonCountsAreComplete: Bool, terminalReason: AnalysisScanCoverageReason?) throws {
            self.reasonCounts = reasonCounts.map(String.init); self.reportedNotices = String(reportedNotices)
            self.workerNotices = String(workerNotices); self.uncategorizedNotices = String(uncategorizedNotices)
            self.reasonCountsAreComplete = reasonCountsAreComplete; self.terminalReason = terminalReason?.rawValue
            try validate()
        }
        func validate() throws {
            let order: [AnalysisScanCoverageReason] = [.scopeBoundary, .policyExclusion, .accessDenied, .directoryQueueLimit,
                .entryLimit, .depthLimit, .pathLimit, .changed, .materializationDeferred, .missingMetadata, .unavailable, .temporaryStorageLimit]
            guard order.map(\.rawValue) == Array(0..<12), reasonCounts.count == 12, AnalysisScanCoverageReason.allCases.count == 12,
                  terminalReason.map({ AnalysisScanCoverageReason(rawValue: $0) != nil }) ?? true else { throw RetainedAnalysisFailure.invalid }
            let reported = try retainedUnsigned(reportedNotices), worker = try retainedUnsigned(workerNotices)
            let other = try retainedUnsigned(uncategorizedNotices)
            var sum: UInt64 = 0
            for raw in reasonCounts {
                let next = sum.addingReportingOverflow(try retainedUnsigned(raw))
                guard !next.overflow else { throw RetainedAnalysisFailure.overflow }; sum = next.partialValue
            }
            guard reported <= 100, reported <= worker else { throw RetainedAnalysisFailure.invalid }
            if reasonCountsAreComplete {
                guard other == 0, sum == worker else { throw RetainedAnalysisFailure.invalid }
            } else {
                // Diagnostics can supply complete numeric totals with an
                // uncategorized remainder; ordinary coverage can be sampled.
                let total = sum.addingReportingOverflow(other)
                guard !total.overflow, total.partialValue <= worker else { throw RetainedAnalysisFailure.invalid }
            }
        }
        var hasGaps: Bool {
            terminalReason != nil || workerNotices != "0" || reportedNotices != "0" || uncategorizedNotices != "0"
        }
    }

    let catalog: Catalog
    // Exact bundled scanner helper used to create this generation. A cold
    // opener rehashes its current bundled helper before query admission.
    let helperSHA256: String
    let profile: Profile
    let metadataPolicy: String
    let scope: Scope
    let observedFrom: Time
    let observedThrough: Time
    let coverage: Coverage
    let complete: Bool
    let projected: Bool
    let committedEntries: String
    let refreshCheckpoint: AnalysisRefreshCheckpoint?
    let scanElapsed: TimeInterval?

    init(catalog: Catalog, helperSHA256: String, policy: AnalysisMetadataPolicy, scope: Scope, chartOverview: Bool = false,
         observedFrom: Time, observedThrough: Time, coverage: Coverage, complete: Bool,
         committedEntries: UInt64, refreshCheckpoint: AnalysisRefreshCheckpoint? = nil,
         scanElapsed: TimeInterval? = nil) throws {
        self.catalog = catalog; self.helperSHA256 = helperSHA256
        profile = .init(startup: scope.isStartup, chartOverview: chartOverview)
        metadataPolicy = policy.rawValue; self.scope = scope
        self.observedFrom = observedFrom; self.observedThrough = observedThrough; self.coverage = coverage
        self.complete = complete; projected = true; self.committedEntries = String(committedEntries)
        self.refreshCheckpoint = refreshCheckpoint
        self.scanElapsed = scanElapsed
        try validate()
    }
    func validate() throws {
        try profile.validate(startup: scope.isStartup); try scope.validate(); try catalog.validate()
        if let scanElapsed, !scanElapsed.isFinite || scanElapsed < 0 { throw RetainedAnalysisFailure.invalid }
        if let refreshCheckpoint {
            try refreshCheckpoint.validate()
            guard refreshCheckpoint.catalogID == catalog.catalogID, !scope.isStartup,
                  metadataPolicy == AnalysisMetadataPolicy.standard.rawValue, complete else {
                throw RetainedAnalysisFailure.invalid
            }
        }
        guard helperSHA256.utf8.count == 64,
              helperSHA256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
        else { throw RetainedAnalysisFailure.invalid }
        try observedFrom.validate(); try observedThrough.validate(); try coverage.validate()
        let entries = try retainedUnsigned(committedEntries)
        guard AnalysisMetadataPolicy(rawValue: metadataPolicy) != nil, projected,
              observedFrom.precedesOrEquals(observedThrough), entries < UInt64(Int64.max),
              !complete || !coverage.hasGaps else { throw RetainedAnalysisFailure.invalid }
    }
    var catalogID: UUID { catalog.catalogID }
    var maximumStoredHierarchyDepth: Int { scope.isStartup ? 129 : 128 }
    var description: String { "<retained analysis record>" }
    var debugDescription: String { description }
}

private func retainedUnsigned(_ raw: String) throws -> UInt64 {
    guard let value = UInt64(raw), String(value) == raw else { throw RetainedAnalysisFailure.invalid }; return value
}

private func retainedNonzero(_ value: UUID) -> Bool {
    value != UUID(uuid: (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0))
}
