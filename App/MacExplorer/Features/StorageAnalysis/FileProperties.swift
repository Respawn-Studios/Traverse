import AppKit
import Combine
import Darwin
import Foundation
import LocalStorage
import SwiftUI
@_spi(ApplicationOwnership) import StorageAnalysis

struct FilePropertyObservation: Identifiable, Sendable {
    let id: Int
    let url: URL
    let kind: String
    let byteCount: Int64?
    let createdAt: Date?
    let modifiedAt: Date?
    let accessedAt: Date?
    let mode: UInt16?
    let ownerID: UInt32?
    let groupID: UInt32?
    let isSymbolicLink: Bool
    let isDirectory: Bool
    let isImmutable: Bool?
    let isVolumeReadOnly: Bool?
    let failure: String?
    var volumeCapacity: PropertyVolumeCapacity?
    var allocatedByteCount: UInt64?
    var linkedNameCount: UInt64?

    var name: String { url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent }
    var sizeDescription: String {
        if isDirectory { return "Not calculated (folder contents are not read)" }
        guard let byteCount else { return "Unavailable" }
        let size = "\(FileSizeText.string(byteCount)) (\(byteCount) bytes)"
        return isSymbolicLink ? size + " · link itself" : size
    }
    var allocatedSizeDescription: String {
        guard let allocatedByteCount else {return "Unavailable"}
        guard allocatedByteCount<=UInt64(Int64.max) else {return "\(allocatedByteCount) bytes"}
        return "\(FileSizeText.string(Int64(allocatedByteCount))) (\(allocatedByteCount) bytes)"
    }

    var permissionDescription: String {
        guard let mode else { return "Unavailable" }
        var characters = Array("---------")
        for (index, mask) in [UInt16(0o400), 0o200, 0o100, 0o040, 0o020, 0o010, 0o004, 0o002, 0o001].enumerated() {
            if mode & mask != 0 { characters[index] = [Character("r"), "w", "x"][index % 3] }
        }
        if mode & 0o4000 != 0 { characters[2] = mode & 0o100 != 0 ? "s" : "S" }
        if mode & 0o2000 != 0 { characters[5] = mode & 0o010 != 0 ? "s" : "S" }
        if mode & 0o1000 != 0 { characters[8] = mode & 0o001 != 0 ? "t" : "T" }
        return "\(String(characters)) (\(String(format: "%04o", UInt32(mode))))"
    }

    var accessDescription: String {
        guard let mode, let isImmutable else { return "Unavailable" }
        var observations: [String] = []
        if isSymbolicLink { observations.append("Target permissions are not inspected") }
        else { observations.append(mode & 0o222 == 0 ? "No POSIX write bits" : "POSIX write bits present") }
        if isImmutable { observations.append("Immutable flag set") }
        switch isVolumeReadOnly {
        case true: observations.append("Volume is marked read only")
        case false: observations.append("Volume is not marked read only")
        case nil: observations.append("Volume access details unavailable")
        }
        return observations.joined(separator: " · ")
    }
}

struct PropertyVolumeCapacity: Sendable {
    let capacity: UInt64
    let available: UInt64
    let free: UInt64?
    let observedAt: Date
    let reportedUsed: NativeVolumeUsedSpace?
    var used: UInt64? { reportedUsed?.bytes }
    var capacityMinusFree: UInt64? { free.map { capacity - $0 } }
    var freeUnavailableToApps: UInt64? { free.flatMap { $0 >= available ? $0 - available : nil } }
    static func observed(blocks: UInt64, available: UInt64, blockSize: UInt64, freeBlocks: UInt64? = nil,
                         reportedUsed: NativeVolumeUsedSpace? = nil) -> Self? {
        let (total, totalOverflow) = blocks.multipliedReportingOverflow(by: blockSize)
        let (free, freeOverflow) = available.multipliedReportingOverflow(by: blockSize)
        guard blockSize > 0, !totalOverflow, !freeOverflow, free <= total else { return nil }
        let allFree = freeBlocks.flatMap { blocks -> UInt64? in
            let (bytes, overflow) = blocks.multipliedReportingOverflow(by: blockSize)
            return !overflow && bytes >= free && bytes <= total ? bytes : nil
        }
        return .init(capacity: total, available: free, free: allFree, observedAt: Date(), reportedUsed: reportedUsed)
    }
}

struct FilePropertiesReport: Sendable {
    let selectedCount: Int
    let observations: [FilePropertyObservation]
    var omittedCount: Int { max(0, selectedCount - observations.count) }
    var unavailableCount: Int { observations.filter { $0.failure != nil }.count }
    var directoryCount: Int { observations.filter(\.isDirectory).count }
    var linkCount: Int { observations.filter(\.isSymbolicLink).count }

    /// A subtotal of inspected regular files. Folder contents and link targets are excluded.
    var regularFileBytes: Int64? {
        var total: Int64 = 0
        for item in observations where !item.isDirectory && !item.isSymbolicLink {
            guard let size = item.byteCount else { continue }
            let (sum, overflow) = total.addingReportingOverflow(size)
            if overflow { return nil }
            total = sum
        }
        return total
    }
}

protocol FilePropertiesReading: Sendable {
    func read(_ urls: [URL]) async throws -> FilePropertiesReport
}

/// A small read-only adapter. POSIX metadata calls never open file bodies, recurse,
/// request thumbnails or download cloud content. At most two reads run concurrently.
final class FilePropertiesReader: FilePropertiesReading, @unchecked Sendable {
    static let maximumInspectedItems = 256
    private let queue: OperationQueue
    private let retainAccess: @MainActor @Sendable ([URL]) async -> (any Sendable)?

    static func allocatedBytes(blocks:Int64)->UInt64? {
        guard let blocks = UInt64(exactly:blocks) else {return nil}
        let (bytes,overflow) = blocks.multipliedReportingOverflow(by:512)
        return overflow ? nil : bytes
    }

    init(retainAccess: @escaping @MainActor @Sendable ([URL]) async -> (any Sendable)? = { _ in nil }) {
        self.retainAccess = retainAccess
        queue = OperationQueue()
        queue.name = "MacExplorer.PropertiesMetadata"
        queue.maxConcurrentOperationCount = 2
        queue.qualityOfService = .userInitiated
    }

    func read(_ urls: [URL]) async throws -> FilePropertiesReport {
        let requestedCount = urls.count
        let inspected = Array(urls.prefix(Self.maximumInspectedItems))
        try Task.checkCancellation()
        let accessToken = await retainAccess(inspected)
        try Task.checkCancellation()
        let cancellation = PropertiesReadCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // Queued closures still run their cancellation check. Cancelling a
                // BlockOperation itself could strand its checked continuation.
                queue.addOperation {
                    // Keep security-scoped access alive until the actual worker exits,
                    // including when its consumer cancels or changes selection.
                    defer { withExtendedLifetime(accessToken) {} }
                    do {
                        try cancellation.check()
                        let activity = try ApplicationFileActivity.gate.begin()
                        defer { withExtendedLifetime(activity) {} }
                        var observations: [FilePropertyObservation] = []
                        for (index, url) in inspected.enumerated() {
                            try cancellation.check()
                            observations.append(Self.observe(url, index: index))
                        }
                        try cancellation.check()
                        continuation.resume(returning: FilePropertiesReport(selectedCount: requestedCount, observations: observations))
                    } catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { cancellation.cancel() }
    }

    private static func observe(_ url: URL, index: Int) -> FilePropertyObservation {
        func unavailable(_ message: String) -> FilePropertyObservation {
            FilePropertyObservation(id: index, url: url, kind: "Unavailable", byteCount: nil,
                                    createdAt: nil, modifiedAt: nil, accessedAt: nil, mode: nil,
                                    ownerID: nil, groupID: nil, isSymbolicLink: false, isDirectory: false,
                                    isImmutable: nil, isVolumeReadOnly: nil, failure: message)
        }
        guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost",
              url.query == nil, url.fragment == nil, !url.path.utf8.contains(0) else {
            return unavailable("Only local file paths can be inspected.")
        }
        var info = stat()
        let result = url.withUnsafeFileSystemRepresentation { path in path.map { lstat($0, &info) } ?? -1 }
        guard result == 0 else {
            switch errno {
            case EACCES, EPERM: return unavailable("Access to this item was denied. Its metadata is unavailable.")
            case ENOENT, ENOTDIR: return unavailable("This item is no longer at the selected path.")
            default: return unavailable("This item is unavailable. Check its connection and permissions.")
            }
        }
        let fileType = info.st_mode & S_IFMT
        let isLink = fileType == S_IFLNK
        let isDirectory = fileType == S_IFDIR
        let kind: String
        switch fileType {
        case S_IFDIR: kind = "Folder"
        case S_IFREG: kind = url.pathExtension.isEmpty ? "File" : "\(url.pathExtension.uppercased()) file"
        case S_IFLNK: kind = "Symbolic link"
        case S_IFIFO: kind = "Named pipe"
        case S_IFSOCK: kind = "Socket"
        case S_IFCHR: kind = "Character device"
        case S_IFBLK: kind = "Block device"
        default: kind = "Filesystem item"
        }
        // Observe the containing volume for a link; do not query its target.
        let volumePath = isLink ? url.deletingLastPathComponent() : url
        var volume = statfs()
        let volumeResult = volumePath.withUnsafeFileSystemRepresentation { path in path.map { statfs($0, &volume) } ?? -1 }
        let readOnly = volumeResult == 0 ? volume.f_flags & UInt32(MNT_RDONLY) != 0 : nil
        func date(_ value: timespec) -> Date {
            Date(timeIntervalSince1970: Double(value.tv_sec) + Double(value.tv_nsec) / 1_000_000_000)
        }
        var observation = FilePropertyObservation(
            id: index, url: url, kind: kind,
            byteCount: fileType == S_IFREG || isLink ? Int64(info.st_size) : nil,
            createdAt: info.st_birthtimespec.tv_sec == 0 && info.st_birthtimespec.tv_nsec == 0 ? nil : date(info.st_birthtimespec),
            modifiedAt: date(info.st_mtimespec), accessedAt: date(info.st_atimespec),
            mode: UInt16(info.st_mode & 0o7777), ownerID: info.st_uid, groupID: info.st_gid,
            isSymbolicLink: isLink, isDirectory: isDirectory,
            isImmutable: info.st_flags & UInt32(UF_IMMUTABLE | SF_IMMUTABLE) != 0,
            isVolumeReadOnly: readOnly, failure: nil
        )
        if fileType == S_IFREG {
            observation.allocatedByteCount = allocatedBytes(blocks:info.st_blocks)
            observation.linkedNameCount = info.st_nlink>0 ? UInt64(info.st_nlink) : nil
        }
        if isDirectory, volumeResult == 0, volume.f_bsize > 0 {
            let mount = withUnsafePointer(to: &volume.f_mntonname) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            if url.standardizedFileURL.path == mount {
                observation.volumeCapacity = .observed(blocks: volume.f_blocks, available: volume.f_bavail,
                    blockSize: UInt64(volume.f_bsize), freeBlocks: volume.f_bfree,
                    reportedUsed: observeVolumeUsed(url, expected: info, volume: volume))
            }
        }
        return observation
    }

    /// The supplemental query never becomes a traversal or replaces valid
    /// statfs facts. Bind it to the selected root before and after its one call.
    private static func observeVolumeUsed(_ url: URL, expected: stat, volume: statfs) -> NativeVolumeUsedSpace? {
        let descriptor = url.withUnsafeFileSystemRepresentation {
            $0.map { open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY) } ?? -1
        }
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        func same(_ value: stat) -> Bool {
            value.st_mode & S_IFMT == S_IFDIR && expected.st_dev == value.st_dev && expected.st_ino == value.st_ino
                && expected.st_gen == value.st_gen && expected.st_birthtimespec.tv_sec == value.st_birthtimespec.tv_sec
                && expected.st_birthtimespec.tv_nsec == value.st_birthtimespec.tv_nsec
        }
        func sameVolume(_ value: statfs) -> Bool {
            volume.f_fsid.val.0 == value.f_fsid.val.0 && volume.f_fsid.val.1 == value.f_fsid.val.1
                && withUnsafeBytes(of: volume.f_mntonname, Array.init) == withUnsafeBytes(of: value.f_mntonname, Array.init)
                && withUnsafeBytes(of: volume.f_mntfromname, Array.init) == withUnsafeBytes(of: value.f_mntfromname, Array.init)
        }
        var held = stat(), named = stat(), before = statfs(), after = statfs()
        guard fstat(descriptor, &held) == 0, same(held), fstatfs(descriptor, &before) == 0, sameVolume(before) else { return nil }
        let value = NativeVolumeUsedSpace.read(directoryDescriptor: descriptor)
        guard fstat(descriptor, &held) == 0, same(held), fstatfs(descriptor, &after) == 0, sameVolume(after),
              url.withUnsafeFileSystemRepresentation({ $0.map { lstat($0, &named) } ?? -1 }) == 0, same(named) else { return nil }
        return value
    }
}

private final class PropertiesReadCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.withLock { cancelled = true } }
    func check() throws { if lock.withLock({ cancelled }) { throw CancellationError() } }
}

@MainActor
final class FilePropertiesModel: ObservableObject {
    @Published private(set) var urls: [URL] = []
    @Published private(set) var report: FilePropertiesReport?
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published var selectedObservationID = 0
    @Published private(set) var analysisValue: FolderSummaryValue?
    @Published private(set) var attribution: AnalysisAttributionReport?
    @Published private(set) var startupAccounting: StartupStorageAccounting?
    @Published private(set) var canAnalyzeStartupData = false
    @Published var includeApplicationData = false
    @Published var rememberAnalysisScope = false
    private weak var settings: BrowserSettings?
    var allowsDetailMotion: Bool { settings?.motion.allows(.pages) ?? true }
    var detailMotionMode: BrowserMotionMode { settings?.motion.mode ?? .full }
    private var scopePreferenceSubscription: AnyCancellable?
    @Published private(set) var analysisMetadataPolicy: AnalysisMetadataPolicy?
    private var displayedAnalysisPolicy: AnalysisMetadataPolicy?
    private var opensFullAnalysisAfterRestore = false
    private let analysisOwner = UUID()
    let chartDrill = StorageBreakdownChartModel()
    private var recordedQueries: RecordedAnalysisQueries?
    private let analysisAccess: @MainActor ([URL]) async -> (any Sendable)?
    private let reader: any FilePropertiesReading
    private var loadTask: Task<Void, Never>?
    private var revision = UUID()
    let copyPaths: ([URL]) -> Void

    init(reader: any FilePropertiesReading = FilePropertiesReader(),
         analysisAccess: @escaping @MainActor ([URL]) async -> (any Sendable)? = { _ in nil },
         settings: BrowserSettings? = nil,
         copyPaths: @escaping ([URL]) -> Void) {
        self.reader = reader
        self.analysisAccess = analysisAccess
        self.settings = settings
        self.copyPaths = copyPaths
        if let settings {
            scopePreferenceSubscription = Publishers.CombineLatest(settings.$analysisIncludesApplicationDataByDefault, settings.$analysisLocationChoices)
                .dropFirst().receive(on: RunLoop.main).sink { [weak self, weak settings] _ in
                    guard let self, let settings, self.urls.count == 1, let root = self.urls.first else { return }
                    self.includeApplicationData = settings.analysisPolicy(for: root) == .applicationData
                    self.rememberAnalysisScope = settings.hasAnalysisChoice(for: root)
                }
        }
    }

    deinit { loadTask?.cancel() }

    func update(urls: [URL]) {
        cancel()
        self.urls = urls
        report = nil
        errorMessage = nil
        selectedObservationID = 0
        analysisValue = nil; attribution = nil; startupAccounting = nil; canAnalyzeStartupData = false
        displayedAnalysisPolicy = nil
        analysisMetadataPolicy = nil; includeApplicationData = false
        if urls.count == 1, let root = urls.first {
            includeApplicationData = settings?.analysisPolicy(for: root) == .applicationData
            rememberAnalysisScope = settings?.hasAnalysisChoice(for: root) == true
        }
        guard !urls.isEmpty else { return }
        isLoading = true
        let token = revision
        loadTask = Task { [weak self, reader] in
            do {
                let report = try await reader.read(urls)
                guard let self, self.revision == token, !Task.isCancelled else { return }
                self.report = report
                self.isLoading = false
                self.loadTask = nil
                self.restoreCachedStorageAnalysis()
            } catch {
                guard let self, self.revision == token, !Task.isCancelled else { return }
                self.errorMessage = "Metadata could not be loaded. Check the selected paths and try again."
                self.isLoading = false
                self.loadTask = nil
            }
        }
    }

    func cancel() {
        // Closing the coordinator can publish its final stopped observation.
        // Reject that callback before it can reconfigure this closed chart.
        revision = UUID()
        opensFullAnalysisAfterRestore = false
        includeApplicationData = false
        rememberAnalysisScope = false
        chartDrill.close()
        recordedQueries = nil
        ApplicationStorageAnalysis.shared.closeProperties(owner: analysisOwner)
        loadTask?.cancel()
        loadTask = nil
        isLoading = false
    }

    var selectedObservation: FilePropertyObservation? {
        report?.observations.first { $0.id == selectedObservationID }
    }

    var canAnalyzeStorage: Bool {
        urls.count == 1 && selectedObservation?.isDirectory == true && selectedObservation?.failure == nil
    }

    #if DEBUG
    /// In-memory observations only, for native layout/motion inspection.
    func showStartupCapacityForVerification(_ value: StartupStorageAccounting) { startupAccounting = value }
    func showScanForVerification(_ value: FolderSummaryValue?, report attribution: AnalysisAttributionReport?) {
        urls = [URL(fileURLWithPath: "/Generated/Orion")]
        report = .init(selectedCount: 1, observations: [.init(id: 0, url: urls[0], kind: "Folder", byteCount: nil,
            createdAt: nil, modifiedAt: nil, accessedAt: nil, mode: nil, ownerID: nil, groupID: nil,
            isSymbolicLink: false, isDirectory: true, isImmutable: nil, isVolumeReadOnly: nil, failure: nil)])
        isLoading = false; errorMessage = nil; selectedObservationID = 0
        analysisValue = value; self.attribution = attribution; analysisMetadataPolicy = .standard
        displayedAnalysisPolicy = value?.counts == nil ? nil : .standard
        chartDrill.close()
    }
    #endif
    var canRememberAnalysisScope: Bool { settings != nil }
    func analyzeStorage(scanEveryFolder: Bool = false) {
        guard canAnalyzeStorage, let root = urls.first else { return }
        opensFullAnalysisAfterRestore = false
        startupAccounting = nil
        canAnalyzeStartupData = false
        let policy: AnalysisMetadataPolicy = includeApplicationData ? .applicationData : .standard
        settings?.rememberAnalysisPolicy(policy, for: root, remember: rememberAnalysisScope)
        includeApplicationData = settings?.analysisPolicy(for: root) == .applicationData; analysisMetadataPolicy = policy
        ApplicationStorageAnalysis.shared.configureScopePreferences(settings)
        // Reject callbacks from the previous explicit request even when this
        // same Properties selection remains open across Analyze Again.
        revision = UUID()
        let token = revision
        ApplicationStorageAnalysis.shared.analyzeProperties(owner: analysisOwner, root: root, metadataPolicy: policy,
        scanEveryFolder: scanEveryFolder, access: { [analysisAccess] in
            await analysisAccess([root]) ?? FileAccessLifetimes(leases: [])
        }, drainQueries: { [chartDrill] in chartDrill.close(); await chartDrill.waitUntilQueriesDrained() },
        onChange: { [weak self] value, attribution in
            self?.acceptStorageAnalysis(value, attribution: attribution, token: token, policy: policy)
        })
    }
    @discardableResult private func restoreCachedStorageAnalysis(policy requestedPolicy: AnalysisMetadataPolicy? = nil) -> Bool {
        guard canAnalyzeStorage, let root = urls.first else { return false }
        let policy = requestedPolicy ?? settings?.analysisPolicy(for: root) ?? .standard
        analysisMetadataPolicy = policy
        let token = revision
        ApplicationStorageAnalysis.shared.configureScopePreferences(settings)
        return ApplicationStorageAnalysis.shared.restoreProperties(owner: analysisOwner, root: root, metadataPolicy: policy, access: { [analysisAccess] in
            await analysisAccess([root]) ?? FileAccessLifetimes(leases: [])
        }, drainQueries: { [chartDrill] in chartDrill.close(); await chartDrill.waitUntilQueriesDrained() },
        onChange: { [weak self] value, attribution in
            guard let self, self.revision == token else { return }
            if value.counts == nil, !value.isRunning, value.scanStatus == nil,
               self.analysisValue?.counts == nil, !self.opensFullAnalysisAfterRestore {
                // A best-effort saved lookup is invisible when there is no
                // result. Keep the ordinary first-use Scan Storage prompt;
                // never leave an idle cache miss labelled as an active scan.
                self.analysisValue = nil; self.attribution = nil
                self.recordedQueries = nil; self.chartDrill.close()
                return
            }
            self.acceptStorageAnalysis(value, attribution: attribution, token: token, policy: policy)
            if self.opensFullAnalysisAfterRestore, !value.isRunning {
                // Clear before the handoff's synchronous revocation callback.
                self.opensFullAnalysisAfterRestore = false
                if value.counts == nil || attribution == nil || !ApplicationStorageAnalysis.shared.openFullAnalysis(
                    owner: self.analysisOwner, root: root, metadataPolicy: policy) {
                    self.showFullAnalysisUnavailable()
                }
            }
        })
    }
    private func acceptStorageAnalysis(_ value: FolderSummaryValue, attribution incomingAttribution: AnalysisAttributionReport?, token: UUID,
                                       policy: AnalysisMetadataPolicy) {
        guard revision == token else { return }
        canAnalyzeStartupData = ApplicationStorageAnalysis.shared.canOfferStartupDataVolume(owner: analysisOwner)
        let attribution = incomingAttribution
            // A superseded view keeps only its compact last observation. It
            // never retains another full folder tree after losing scan ownership.
            if value.counts == nil, displayedAnalysisPolicy == policy, let previous = analysisValue {
                let message = value.isRunning && previous.counts != nil
                    ? "Previous observation · " + value.message : value.message
                analysisValue = .init(counts: previous.counts, bytes: previous.bytes, isRunning: value.isRunning,
                    isComplete: !value.isRunning && previous.isComplete, message: message, observedAt: previous.observedAt,
                    scanStatus: value.scanStatus ?? previous.scanStatus, coverage: previous.coverage,
                    observationIsPrevious: previous.counts != nil, scanElapsed: previous.scanElapsed)
            } else {
                analysisValue = value
                displayedAnalysisPolicy = value.counts == nil ? nil : policy
            }
            self.attribution = attribution
            let accounting = ApplicationStorageAnalysis.shared.startupAccountingForProperties(owner: analysisOwner)
            if startupAccounting?.id != accounting?.id { startupAccounting = accounting }
            if attribution == nil || attribution?.isProvisional == true {
                chartDrill.close(); recordedQueries = nil
            } else if let live = ApplicationStorageAnalysis.shared.resultForProperties(owner: analysisOwner) {
                recordedQueries = nil; chartDrill.configure(live)
            } else if let queries = ApplicationStorageAnalysis.shared.recordedQueriesForProperties(owner: analysisOwner) {
                recordedQueries = queries; chartDrill.configureRecorded(queries)
            } else {
                chartDrill.close(); recordedQueries = nil
            }
    }

    func stopAnalysis() { ApplicationStorageAnalysis.shared.stopProperties(owner: analysisOwner) }
    func analyzeStartupDataVolume() {
        ApplicationStorageAnalysis.shared.chooseStartupDataVolume(owner: analysisOwner)
    }
    func openFullAnalysis() {
        guard let root = urls.first else { return }
        opensFullAnalysisAfterRestore = false
        if ApplicationStorageAnalysis.shared.openFullAnalysis(owner: analysisOwner, root: root,
            metadataPolicy: analysisMetadataPolicy ?? .standard) { return }
        revision = UUID()
        opensFullAnalysisAfterRestore = true
        if !restoreCachedStorageAnalysis(policy: analysisMetadataPolicy) {
            opensFullAnalysisAfterRestore = false
            showFullAnalysisUnavailable()
        }
    }
    private func showFullAnalysisUnavailable() {
        if let previous = analysisValue {
            analysisValue = .init(counts: previous.counts, bytes: previous.bytes, isRunning: false,
                isComplete: previous.isComplete, message: "The full breakdown could not be reopened. Refresh to check this folder.",
                observedAt: previous.observedAt, scanStatus: previous.scanStatus, coverage: previous.coverage,
                observationIsPrevious: previous.counts != nil, scanElapsed: previous.scanElapsed)
        }
    }
}

/// Retain one controller in the browser. Opening again replaces its selection;
/// closing cancels the pending metadata session and rejects any late completion.
@MainActor
final class FilePropertiesWindowController: NSWindowController, NSWindowDelegate {
    let model: FilePropertiesModel
    let namesEditor: PrivateNamesEditorModel?
    private var choosingDiscard = false

    init(reader: (any FilePropertiesReading)? = nil,
         retainAccess: @escaping @MainActor @Sendable ([URL]) async -> (any Sendable)? = { _ in nil },
         settings: BrowserSettings? = nil,
         namesOwner: ApplicationPrivateNames? = nil,
         copyPaths: @escaping ([URL]) -> Void) {
        if let namesOwner, let settings {
            namesEditor = PrivateNamesEditorModel(owner: namesOwner, settings: settings, access: { url in await retainAccess([url]) })
        } else { namesEditor = nil }
        model = FilePropertiesModel(reader: reader ?? FilePropertiesReader(retainAccess: retainAccess),
            analysisAccess: retainAccess, settings: settings, copyPaths: copyPaths)
        let window = ToolWindowChrome.makeWindow(title: "Properties", size: .init(width: 580, height: 600),
            minimumSize: .init(width: 440, height: 460),
            content: InterfaceHostingController(rootView: FilePropertiesView(model: model, namesEditor: namesEditor)))
        window.acceptsMouseMovedEvents = true
        super.init(window: window)
        window.delegate = self
        ToolWindowChrome.install(in: window, settings: settings)
        namesEditor?.clearNativeUndo = { [weak window] in clearPrivateTextUndo(in: window) }
    }

    required init?(coder: NSCoder) { nil }

    func show(urls: [URL], relativeTo parent: NSWindow? = nil) {
        guard !urls.isEmpty, let window else { return }
        update(urls: urls)
        if !window.isVisible {
            ToolWindowChrome.position(window, relativeTo: parent)
        }
        window.makeKeyAndOrderFront(nil)
    }

    func update(urls: [URL]) {
        guard namesEditor?.saving != true else { return }
        if namesEditor?.hasChanges == true, namesEditor?.source != urls.first, let window {
            confirmDiscard(in: window) { [weak self] in self?.update(urls: urls) }; return
        }
        model.update(urls: urls)
        if urls.count == 1, let first = urls.first {
            if namesEditor?.source != first || (namesEditor?.itemID == nil && namesEditor?.hasChanges != true) { namesEditor?.select(first) }
        } else { namesEditor?.cancel() }
    }
    func cancel() { namesEditor?.cancel(); model.cancel() }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard namesEditor?.saving != true else { return false }
        guard namesEditor?.hasChanges == true else { return true }
        confirmDiscard(in: sender) { sender.close() }; return false
    }
    private func confirmDiscard(in window: NSWindow, action: @escaping @MainActor () -> Void) {
        guard !choosingDiscard else { return }; choosingDiscard = true
        let alert = NSAlert(); alert.messageText = "Discard changes to names and labels?"
        alert.informativeText = "The saved description stays unchanged."; alert.addButton(withTitle: "Discard Changes"); alert.addButton(withTitle: "Keep Editing")
        Task { [weak self] in
            let response = await alert.beginSheetModal(for: window)
            self?.choosingDiscard = false
            if response == .alertFirstButtonReturn { self?.namesEditor?.cancel(); action() }
        }
    }
    func windowWillClose(_ notification: Notification) { cancel() }
}

private struct FilePropertiesView: View {
    @ObservedObject var model: FilePropertiesModel
    var namesEditor: PrivateNamesEditorModel? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(model.urls.count == 1 ? "Properties" : "\(model.urls.count) items selected")
                    .interfaceFont(.title2.weight(.semibold))
                Spacer()
                if model.isLoading { ProgressView().controlSize(.small).accessibilityLabel("Loading metadata") }
            }.padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if model.isLoading {
                        Text("Reading selected-item metadata…").foregroundStyle(.secondary)
                    } else if let error = model.errorMessage {
                        Text(error).foregroundStyle(.secondary)
                        Button("Retry") { model.update(urls: model.urls) }
                        Button("Review Access…") { ApplicationStorageAnalysis.shared.reviewAccess() }
                    } else if let report = model.report {
                        if report.selectedCount > 1 { summary(report) }
                        if report.observations.count > 1 {
                            Picker("Inspect item", selection: $model.selectedObservationID) {
                                ForEach(report.observations) { item in
                                    Text(item.name).lineLimit(1).tag(item.id)
                                }
                            }
                        }
                        driveCapacitySection
                        if model.canAnalyzeStorage { storageSection }
                        else if report.observations.contains(where: { $0.failure != nil }) {
                            Button("Review Access…") { ApplicationStorageAnalysis.shared.reviewAccess() }
                        }
                        if let item = model.selectedObservation { details(item).toolPageEntrance(item.url, enabled: model.allowsDetailMotion, mode: model.detailMotionMode) }
                        if report.selectedCount == 1, let namesEditor {
                            Divider()
                            PrivateNamesEditorView(model: namesEditor, embedded: true)
                        }
                    } else {
                        Text("No items selected.").foregroundStyle(.secondary)
                    }
                    Text("Inspecting storage doesn’t change your files.")
                        .interfaceFont(.caption).foregroundStyle(.secondary)
                        .help("Properties reads selected-item metadata. Scanning reads names and sizes inside the chosen folder, never file contents. Symbolic-link targets are not followed. macOS privacy and file permissions can restrict access.")
                }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                Button(model.urls.count > 1 ? "Copy Paths" : "Copy Path") { model.copyPaths(model.urls) }
                    .disabled(model.urls.isEmpty)
                Spacer()
                Text("File details are read-only").interfaceFont(.caption).foregroundStyle(.secondary)
            }.padding(16)
        }
        .frame(minWidth: 400, minHeight: 400)
        .textSelection(.enabled)
    }

    private var storageSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()
            ViewThatFits(in: .horizontal) {
                HStack {
                    Text("Storage").interfaceFont(.headline)
                    Spacer()
                    storageActions
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Storage").interfaceFont(.headline)
                    storageActions
                }
            }
            if model.canAnalyzeStartupData {
                Button("Analyze Data Volume…") { model.analyzeStartupDataVolume() }
                    .accessibilityIdentifier("properties-startup-data")
                    .help("Choose a volume or folder to analyze separately, without the macOS System volume.")
            }
            if let value = model.analysisValue {
                if let root = model.urls.first {
                    Text(StorageScanPresentation.location(root)).interfaceFont(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle).help(root.path)
                        .accessibilityLabel("Scanned location: " + root.path)
                }
                if let timing = StorageScanPresentation.scanTime(value.scanElapsed,
                    working: value.isRunning, previous: value.observationIsPrevious) {
                    Text(timing)
                        .interfaceFont(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                if value.observationIsPrevious {
                    Text(value.message).interfaceFont(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("properties-analysis-last-analyzed")
                }
                let presentation = StorageScanPresentation(status: value.observationIsPrevious ? nil : value.scanStatus,
                    working: value.isRunning, coverage: value.coverage, hasCurrentResults: !value.observationIsPrevious,
                    fallback: value.observationIsPrevious
                        ? (value.scanStatus == .partial ? "Previous partial analysis" : "Previous analysis") : value.message)
                HStack(alignment: .top) {
                    if value.isRunning { ProgressView().controlSize(.small) }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(value.observationIsPrevious && value.isRunning ? "Refreshing…" : presentation.title)
                            .interfaceFont(.callout.weight(.medium))
                        if value.observationIsPrevious && value.isRunning {
                            Text("Previous results remain visible while this location is checked.")
                                .interfaceFont(.caption).foregroundStyle(.secondary)
                        } else if !presentation.guidance.isEmpty {
                            Text(presentation.guidance).interfaceFont(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if let counts = value.counts, let bytes = value.bytes {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(StorageScanPresentation.size(bytes, files: counts.regularFiles, live: value.isRunning && !value.observationIsPrevious))
                            .interfaceFont(.title3.weight(.semibold)).monospacedDigit()
                        Text(StorageScanPresentation.counts(counts) + (value.observationIsPrevious ? " · previous scan" : ""))
                            .interfaceFont(.caption).foregroundStyle(.secondary)
                    }.help(StorageScanPresentation.sizeHelp())
                }
                if let report = model.attribution {
                    StorageAttributionView(report: report, compact: true, drill: model.chartDrill,
                        folderRootTitle: model.selectedObservation?.name ?? "Selected folder", onOpenFullAnalysis: { model.openFullAnalysis() })
                        .toolPageEntrance("storage-breakdown", enabled: model.allowsDetailMotion,
                            mode: model.detailMotionMode, initiallyRevealed: false)
                }
                else if value.counts != nil && !value.isRunning {
                    Text("Recorded totals. Open Full Analysis for the breakdown.")
                        .interfaceFont(.caption).foregroundStyle(.secondary)
                } else { StorageScanPlaceholder(working: value.isRunning) }
                HStack {
                    Spacer()
                    Button("Review Access…") { ApplicationStorageAnalysis.shared.reviewAccess() }
                        .accessibilityIdentifier("properties-review-access")
                }
                DisclosureGroup("Scan details") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(value.message).interfaceFont(.caption).foregroundStyle(.secondary)
                        if let policy = model.analysisMetadataPolicy {
                            Text(policy.title).interfaceFont(.caption).foregroundStyle(.secondary)
                                .accessibilityIdentifier("properties-analysis-metadata-policy")
                        }
                        if value.coverage.hasExplanation {
                            Text(StorageAnalysisCoverageText.details(value.coverage, root: model.urls.first,
                                paired: model.startupAccounting != nil)).interfaceFont(.caption).foregroundStyle(.secondary)
                        }
                        if let counts = value.counts, let bytes = value.bytes {
                            StorageAccountingView(bytes: bytes, regularFiles: counts.regularFiles)
                        }
                    }.padding(.top, 4)
                }
            } else {
                Text("See what takes up space here. Scanning doesn’t change your files.")
                    .interfaceFont(.callout).foregroundStyle(.secondary)
            }
            DisclosureGroup("Scan options") {
                Toggle("Include application data", isOn: $model.includeApplicationData)
                    .toggleStyle(.checkbox)
                    .disabled(!ApplicationStorageAnalysis.shared.applicationDataControlsQualified)
                    .accessibilityIdentifier("properties-include-app-data")
                    .help(AnalysisMetadataPolicy.applicationDataHelp)
                Toggle("Remember for this location", isOn: $model.rememberAnalysisScope).toggleStyle(.checkbox).disabled(!model.canRememberAnalysisScope)
                    .help("Use this application-data choice next time you scan this location. Change defaults or clear remembered choices in Settings.")
                Text("Includes more local app folders. Private and online-only data stay excluded.")
                    .interfaceFont(.caption).foregroundStyle(.secondary).help(AnalysisMetadataPolicy.applicationDataHelp)
                Button("Scan Every Folder") { model.analyzeStorage(scanEveryFolder: true) }
                    .disabled(model.analysisValue?.isRunning == true)
                    .accessibilityIdentifier("properties-scan-every-folder")
                    .help(StorageScanPresentation.fullScanHelp)
            }
        }
    }

    private var storageActions: some View {
        HStack(spacing: 8) {
            if model.analysisValue != nil {
                Button("Open Full Analysis") { model.openFullAnalysis() }
                    .accessibilityIdentifier("properties-open-full-analysis")
            }
            if model.analysisValue?.isRunning == true {
                Button("Stop") { model.stopAnalysis() }.accessibilityIdentifier("properties-stop-storage")
            } else {
                Button(model.analysisValue?.counts == nil ? "Scan Storage" : "Refresh") { model.analyzeStorage() }
                    .accessibilityIdentifier("properties-analyze-storage")
                    .help(StorageScanPresentation.refreshHelp)
            }
        }
    }

    @ViewBuilder private var driveCapacitySection: some View {
        if model.startupAccounting != nil || model.selectedObservation?.volumeCapacity != nil {
            VStack(alignment:.leading,spacing:8) {
                Text("Drive capacity").interfaceFont(.headline)
                if let startup = model.startupAccounting { StartupStorageAccountingView(value:startup) }
                else if let volume = model.selectedObservation?.volumeCapacity { StorageVolumeAccountingView(value:volume) }
            }.help("Drive capacity comes from macOS. It includes storage that a file scan may not be able to count.")
        }
    }

    @ViewBuilder private func summary(_ report: FilePropertiesReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Selection").interfaceFont(.headline)
            property("Metadata coverage", "\(report.observations.count) of \(report.selectedCount) selected items")
            if report.omittedCount > 0 {
                Text("The remaining \(report.omittedCount) items were not inspected. Subtotals below cover only the inspected items.")
                    .interfaceFont(.caption).foregroundStyle(.secondary)
            }
            property("Observed folders / links", "\(report.directoryCount) folders · \(report.linkCount) symbolic links")
            property("Known file sizes", report.regularFileBytes.map(FileSizeText.string) ?? "Subtotal exceeds supported size")
            Text("Size subtotal excludes folders, package contents, symbolic links and unavailable sizes.")
                .interfaceFont(.caption).foregroundStyle(.secondary)
            if report.unavailableCount > 0 { property("Unavailable metadata", "\(report.unavailableCount) items") }
        }
    }

    @ViewBuilder private func details(_ item: FilePropertyObservation) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.urls.count > 1 { Text("Item metadata").interfaceFont(.headline) }
            property("Name", item.name)
            property("Kind", item.kind)
            property("Path", item.url.path)
            if let failure = item.failure {
                property("Status", failure)
            } else {
                property("Size", item.isDirectory && model.analysisValue != nil
                    ? "See Storage above for the separate descendant observation." : item.sizeDescription)
                if !item.isDirectory && !item.isSymbolicLink && item.byteCount != nil {
                    property("Size on disk",item.allocatedSizeDescription)
                    Text("Shared blocks and snapshots may remain after a file is deleted.")
                        .interfaceFont(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                    if let names = item.linkedNameCount,names>1 {
                        property("Linked names","\(names) names refer to this same file")
                    }
                }
                property("Created", formatted(item.createdAt))
                property("Modified", formatted(item.modifiedAt))
                property("Accessed", formatted(item.accessedAt))
                property("POSIX permissions", item.permissionDescription)
                if let owner = item.ownerID, let group = item.groupID {
                    property("Owner / group IDs", "\(owner) / \(group)")
                }
                property("Access observations", item.accessDescription)
                if item.isSymbolicLink {
                    property("Symbolic link", "These observations describe the link itself. Its target is not inspected.")
                }
            }
        }
    }

    private func property(_ name: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(name).interfaceFont(.caption).foregroundStyle(.secondary)
            Text(value).interfaceFont(.body).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
        }.accessibilityElement(children: .combine)
    }

    private func formatted(_ date: Date?) -> String {
        date?.formatted(date: .abbreviated, time: .standard) ?? "Unavailable"
    }
}

/// All values already belong to the observation. Expanding this explanation
/// performs no I/O and never subtracts logical sizes from physical volume use.
struct StorageAccountingView: View {
    let bytes: AnalysisByteSubtotals
    let regularFiles: UInt64
    var body: some View {
        DisclosureGroup("Storage accounting") {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(AnalysisByteMetric.allCases, id: \.self) { metric in
                    HStack {
                        Text(title(metric))
                        Spacer()
                        Text(storageMetricText(bytes[metric], files: regularFiles)).monospacedDigit()
                    }.interfaceFont(.caption)
                    let value = bytes[metric]
                    if value.notReturnedCount > 0 || value.failedCount > 0 || value.overflowed {
                        Text("\(value.notReturnedCount) missing · \(value.failedCount) unavailable" + (value.overflowed ? " · total overflowed" : ""))
                            .interfaceFont(.caption2).foregroundStyle(.secondary)
                    }
                }
                Text("These are observed regular-file names. Hard links, APFS clones, compression and sparse files mean logical size and allocated bytes differ. Allocated bytes are not exclusive or reclaimable space. Native volume usage also includes storage this scan cannot attribute; no unknown-byte estimate is invented.")
                    .interfaceFont(.caption).foregroundStyle(.secondary)
            }.padding(.top, 4)
        }.interfaceFont(.callout)
    }
    private func title(_ metric: AnalysisByteMetric) -> String {
        switch metric {
        case .dataLogical: "Logical file data"
        case .allForkLogical: "Logical data + resource forks"
        case .dataAllocated: "Allocated file data"
        case .allForkAllocated: "Allocated data + resource forks"
        }
    }
}

func storageMetricText(_ subtotal: AnalysisMetricSubtotal, files: UInt64) -> String {
    guard let value = subtotal.knownBytes, !subtotal.overflowed else { return "Unavailable" }
    let missing = subtotal.notReturnedCount + subtotal.failedCount
    if files > 0, missing >= files { return "Unknown" }
    let text = storageByteText(value)
    return missing > 0 ? "Known " + text : text
}

private func storageByteText(_ value: UInt64) -> String {
    value > UInt64(Int64.max) ? "\(value) bytes" : FileSizeText.string(Int64(value))
}

/// Shared read-only projection. Drill-down queries the existing catalog only.
struct StorageAttributionView: View {
    private enum Group: String, CaseIterable { case fileTypes = "File Types", roles = "Purpose", layouts = "App Libraries", projects = "Projects", folders = "Folders" }
    private struct Slice {
        let title: String
        let explanation: String
        let bytes: AnalysisByteSubtotals
        let files: UInt64
        let target: StoredAnalysisDrillTarget?
        var purposeTarget: StoredPurposeJourneyTarget? = nil
        var location: StoredPurposeLocation? = nil
    }
    let report: AnalysisAttributionReport
    var compact = false
    var overview = false
    @ObservedObject var drill: StorageBreakdownChartModel
    @ObservedObject private var chartAppearance = StorageChartIntegration.appearance
    var folderRootTitle: String
    var onOpenFullAnalysis: (() -> Void)? = nil
    #if DEBUG
    @State private var group = StorageChartIntegration.startAtFileTypesForQualification ? Group.fileTypes
        : StorageChartIntegration.startAtStorageRolesForQualification || StoragePurposeJourneyFeature.isEnabled ? .roles : .fileTypes
    #else
    @State private var group = StoragePurposeJourneyFeature.isEnabled ? Group.roles : .fileTypes
    #endif
    @State private var allocated = false
    @State private var showsOtherExplanation = false
    @State private var projectFacet = StoredAnalysisFacet.storageRoles
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    private var metric: AnalysisByteMetric { allocated ? .allForkAllocated : .dataLogical }
    private var displayGroup: Group { report.isProvisional ? .fileTypes : group }
    private var baseRows: [Slice] {
        let values: [AnalysisAttributionSlice]
        switch displayGroup {
        case .fileTypes, .folders: values = report.fileTypes
        case .roles: values = report.categories
        case .projects: values = report.projects
        case .layouts: values = drill.applicationLayouts?.attributionSlices(scopeName: folderRootTitle) ?? []
        }
        return values.filter { $0.files > 0 }.map {
            Slice(title: $0.title, explanation: $0.explanation, bytes: $0.bytes, files: $0.files, target: $0.storedTarget,
                purposeTarget: drill.canUsePurposeJourney && $0.storedTarget != .steamLibraries ? $0.purposeTarget : nil)
        }.sorted {
            let a = $0.bytes[metric].knownBytes ?? 0, b = $1.bytes[metric].knownBytes ?? 0
            return a == b ? $0.title < $1.title : a > b
        }
    }
    private func slices(_ breakdown: StoredAnalysisBreakdown) -> [Slice] {
        var values = breakdown.rows.filter { $0.value.counts.regularFiles > 0 }.map {
            Slice(title: $0.title, explanation: $0.explanation, bytes: $0.value.bytes, files: $0.value.counts.regularFiles,
                  target: $0.folder.map { breakdown.target(for: $0) })
        }
        if breakdown.remainder.counts.regularFiles > 0 {
            values.append(.init(title: "Other folders", explanation: "Remaining observed folders. Explore the folder table for individual totals.",
                                bytes: breakdown.remainder.bytes, files: breakdown.remainder.counts.regularFiles, target: nil))
        }
        return values
    }
    private func slices(_ level: StorageBreakdownChartModel.Level) -> [Slice] {
        if let projects = level.purposeProjects {
            return projects.slices(scopeName: folderRootTitle).map {
                Slice(title: $0.title, explanation: $0.explanation, bytes: $0.bytes, files: $0.files, target: nil, purposeTarget: $0.purposeTarget)
            }
        }
        if let locations = level.purposeLocations {
            var values = drill.visiblePurposeLocations.map {
                Slice(title: $0.title(scopeName: folderRootTitle), explanation: $0.recordedPath(scopeName: folderRootTitle)
                    + ($0.matchesWholeRecordedLocation ? ". Select to review this whole recorded location." : ". Includes other purposes; the matching portion cannot authorize moving the whole folder."),
                    bytes: $0.matchingValue.bytes, files: $0.matchingValue.counts.regularFiles, target: nil, location: $0)
            }
            if locations.remainder.counts.regularFiles > 0 {
                values.append(.init(title: "Other locations", explanation: "Remaining matching locations are included in this total. Scan a smaller project folder to inspect them individually.",
                    bytes: locations.remainder.bytes, files: locations.remainder.counts.regularFiles, target: nil))
            }
            return values
        }
        guard let composition = level.composition else { return slices(level.value) }
        return composition.slices(projectFacet).map {
            Slice(title: $0.title, explanation: $0.explanation, bytes: $0.bytes, files: $0.files, target: nil)
        }.sorted { ($0.bytes[metric].knownBytes ?? 0) > ($1.bytes[metric].knownBytes ?? 0) }
    }
    private var rows: [Slice] { report.isProvisional ? baseRows : drill.current.map(slices) ?? baseRows }
    private var backEnabled: Bool { !drill.levels.isEmpty && (group != .folders || drill.levels.count > 1) }
    private func open(_ row: Slice) {
        guard !report.isProvisional, !drill.loading, !drill.locationActionRunning else { return }
        if let location = row.location { drill.selectPurposeLocation(location.id); return }
        drill.setMetric(metric)
        if let purpose = row.purposeTarget { drill.openPurpose(purpose, title: row.title); return }
        guard let target = row.target else { return }
        if displayGroup == .projects && drill.levels.isEmpty { drill.openProject(target, title: row.title) }
        else { drill.open(target, title: row.title) }
    }
    private func sliceID(_ row: Slice, _ index: Int) -> String {
        if let purpose = row.purposeTarget { return StorageChartIntegration.key(purpose) }
        if let location = row.location { return "purpose-location-\(location.id)" }
        return row.target.map(StorageChartIntegration.key) ?? "static-\(index)"
    }
    private func chartFrame(_ values: [Slice], id: String, title: String) -> StorageChartFrame {
        .init(id: id, title: title, slices: values.enumerated().map { index, row in
            .init(id: sliceID(row, index), title: row.title, amount: storageMetricText(row.bytes[metric], files: row.files),
                bytes: row.bytes[metric].overflowed ? nil : row.bytes[metric].knownBytes,
                canOpen: (row.target != nil || row.purposeTarget != nil || row.location != nil) && drill.canBrowse && !drill.loading && !drill.locationActionRunning && !report.isProvisional,
                tint: .init(red: 0.5, green: 0.5, blue: 0.5))
        })
    }
    private var dimensionalFrames: [StorageChartFrame] {
        let root = "root-\(drill.scopeIdentity?.uuidString ?? "provisional")-\(displayGroup.rawValue)-\(allocated)"
        var frames = displayGroup == .folders && !report.isProvisional ? []
            : [chartFrame(baseRows, id: root, title: displayGroup.rawValue)]
        if !report.isProvisional {
            frames += drill.levels.map { level in
                let key = level.purposeTarget.map(StorageChartIntegration.key) ?? level.target.map(StorageChartIntegration.key) ?? level.id.uuidString
                return chartFrame(slices(level), id: key, title: level.title)
            }
        }
        return StorageChartIntegration.colored(frames)
    }
    private func returnToFrame(_ index: Int) {
        drill.returnToLevelCount(displayGroup == .folders ? index + 1 : index)
    }
    private func openNativeSlice(_ index: Int, frames: [StorageChartFrame]) {
        guard let current = frames.last, current.slices.indices.contains(index),
              let row = rows.enumerated().first(where: { sliceID($0.element, $0.offset) == current.slices[index].id })?.element else { return }
        open(row)
    }
    private func explanation(for slice: StorageChartSlice) -> String {
        rows.enumerated().first { sliceID($0.element, $0.offset) == slice.id }?.element.explanation
            ?? "Remaining observed groups; individual totals are available in the full folder table."
    }
    private var nativeBreadcrumbs: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
              if displayGroup == .folders && drill.levels.count == 1 {
                Text(folderRootTitle).fontWeight(.semibold)
              } else {
                Button(displayGroup == .folders ? folderRootTitle : displayGroup.rawValue) { returnToFrame(0) }.buttonStyle(.plain)
                ForEach(Array(drill.levels.dropLast().enumerated()), id: \.element.id) { index, level in
                    if displayGroup != .folders || index > 0 {
                        Image(systemName: "chevron.right").interfaceFont(.caption2).foregroundStyle(.secondary)
                        Button(level.title) { drill.returnToLevelCount(index + 1) }.buttonStyle(.plain)
                    }
                }
                Image(systemName: "chevron.right").interfaceFont(.caption2).foregroundStyle(.secondary)
                Text(drill.current?.title ?? "").fontWeight(.semibold)
              }
            }.lineLimit(1)
        }.scrollIndicators(.hidden).interfaceFont(.caption)
    }
    private var sizePicker: some View {
        Picker("Size", selection: $allocated) { Text("File size").tag(false); Text("On disk").tag(true) }.frame(maxWidth: 210)
            .help("File size counts file data. On disk shows reported allocation, including resource forks. Shared blocks, hard links and snapshots mean neither is space guaranteed to be freed by deletion.")
    }
    var body: some View {
        let frames = dimensionalFrames
        return VStack(alignment: .leading, spacing: 10) {
            if report.isProvisional {
                Text("Counted so far").interfaceFont(.callout.weight(.semibold))
            }
            HStack {
              Picker("Group", selection: Binding(get: { displayGroup }, set: { if !report.isProvisional { group = $0 } })) {
                ForEach(Group.allCases.filter { ($0 != .folders || drill.canBrowse) && ($0 != .layouts || drill.canShowApplicationLayouts) }, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.menu).fixedSize(horizontal: true, vertical: false).disabled(report.isProvisional)
                .help(report.isProvisional ? "More views and folder details become available when scanning finishes." : "File Types groups by filename. Purpose and App Libraries use known folder layouts. Projects opens each recognized project’s own composition. These are clues, not a cleanup recommendation.")
              if overview {
                  Spacer()
                  if drill.loading { ProgressView().controlSize(.small).help("Loading stored totals") }
                  sizePicker
              }
            }
            if !report.isProvisional, displayGroup == .projects {
                Text(drill.levels.isEmpty ? "Recognized project roots" : drill.current?.composition != nil ? "Project composition" : "Recorded folders within this project")
                    .interfaceFont(.callout.weight(.medium))
                Text("Select a project to see what’s inside.").interfaceFont(.caption).foregroundStyle(.secondary)
                    .help("Projects are recognized from marker names. Nested projects keep their own totals. Folder browsing is available separately.")
                if drill.current?.composition != nil {
                    HStack {
                        Picker("Within project", selection: $projectFacet) {
                            Text("Purpose").tag(StoredAnalysisFacet.storageRoles)
                            Text("File Types").tag(StoredAnalysisFacet.fileTypes)
                        }.pickerStyle(.menu).fixedSize()
                        Spacer(minLength: 8)
                        Button("Browse Recorded Folders…") { drill.browseRecordedProjectFolders() }.disabled(drill.loading)
                    }
                }
            }
            if !overview { HStack {
                sizePicker
                Spacer()
                if drill.loading { ProgressView().controlSize(.small).help("Loading stored totals") }
            } }
            if drill.current?.purposeProjects != nil {
                Text("Inside project").interfaceFont(.callout.weight(.medium))
                    .help("These are the selected purpose’s files inside recognized project folders. Shared and outside-project locations stay separate. This does not establish ownership or active use.")
            } else if drill.current?.purposeLocations != nil {
                Text("Matching locations").interfaceFont(.callout.weight(.medium))
                Text("Choose one location to inspect. Folder browsing stays separate.").interfaceFont(.caption).foregroundStyle(.secondary)
            }
            if !report.isProvisional, let level = drill.current {
                HStack(spacing: 8) {
                    Button { drill.back() } label: { Image(systemName: "chevron.left") }.disabled(!backEnabled).help("Previous breakdown")
                    nativeBreadcrumbs
                    Spacer()
                    Text(storageMetricText(level.value.value.bytes[metric], files: level.value.value.counts.regularFiles))
                        .interfaceFont(.caption).monospacedDigit()
                }
            }
            if !drill.message.isEmpty { Text(drill.message).interfaceFont(.caption).foregroundStyle(.secondary) }
            if drill.canExplainOther {
                Button("Why are these files Other?") { showsOtherExplanation = true; drill.explainOther() }
                    .disabled(drill.loading).help("Explain filename patterns and storage roles using this scan; no rescan or file-content reads.")
                    .accessibilityIdentifier("storage-explain-other")
                    .popover(isPresented: $showsOtherExplanation, arrowEdge: .top) {
                        if let explanation = drill.current?.otherExplanation {
                            StorageOtherExplanationView(value: explanation, metric: metric).padding(10).frame(width: compact ? 360 : 420)
                        } else {
                            VStack(alignment: .leading, spacing: 10) {
                                if drill.loading { ProgressView("Reading stored explanation…").controlSize(.small) }
                                else { Text(drill.message.isEmpty ? "This explanation is unavailable. Select Other again." : drill.message).interfaceFont(.callout) }
                                Text("No new scan or file-content reads.").interfaceFont(.caption).foregroundStyle(.secondary)
                            }.padding(18).frame(width: 300, alignment: .leading)
                        }
                    }
            }
            if !report.hasLayoutAttribution && (displayGroup == .roles || displayGroup == .projects) {
                Text("Layout attribution was not completed. File Types and stored folder totals remain available.").foregroundStyle(.secondary)
            } else if rows.isEmpty {
                Text(drill.loading ? "Loading breakdown…" : drill.hasConfirmedPurposeChanges && drill.current?.purposeLocations != nil
                    ? "Shown locations were moved since this scan. Scan again to update the recorded totals." : "No regular-file bytes were observed.").foregroundStyle(.secondary)
            } else {
                HStack(alignment: .top, spacing: 18) {
                        StorageDimensionalChart(frames: frames, scopeIdentity: drill.scopeIdentity, style: chartAppearance.style,
                            interactive: !report.isProvisional && !drill.loading,
                            reduceMotion: reduceMotion || !chartAppearance.motion.allows(.charts),
                            reduceTransparency: reduceTransparency, motionMode: chartAppearance.motion.mode,
                            onOpen: { openNativeSlice($0, frames: frames) },
                            onReturn: returnToFrame, onStyle: { chartAppearance.choose($0) })
                            .frame(width: compact ? 200 : overview ? 250 : 300, height: compact || overview ? 220 : 300)
                    VStack(alignment: .leading, spacing: 5) {
                      if let frame = frames.last {
                        ForEach(Array(frame.slices.prefix(compact ? 5 : 15).enumerated()), id: \.element.id) { index, slice in
                            if slice.canOpen {
                                Button { openNativeSlice(index, frames: frames) } label: { nativeLegend(slice) }
                                    .buttonStyle(.plain).disabled(drill.loading).help(explanation(for: slice) + " Open stored breakdown.")
                            } else { nativeLegend(slice).help(explanation(for: slice)) }
                        }
                        if compact && frame.slices.count > 5 { Text("\(frame.slices.count - 5) more groups in Full Analysis").interfaceFont(.caption).foregroundStyle(.secondary) }
                        if displayGroup == .layouts, drill.levels.isEmpty, baseRows.count > 5 {
                            Menu("All \(baseRows.count) layouts") {
                                ForEach(Array(baseRows.enumerated()), id: \.offset) { _, row in
                                    Button("\(row.title) · \(storageMetricText(row.bytes[metric], files: row.files))") { open(row) }
                                }
                            }.fixedSize(horizontal: true, vertical: false).disabled(drill.loading)
                        }
                      }
                      if let selection = drill.selectedPurposeLocation {
                          purposeLocationDetails(selection)
                      }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if !drill.locationMessage.isEmpty { Text(drill.locationMessage).interfaceFont(.caption).foregroundStyle(.secondary) }
            if drill.hasConfirmedPurposeChanges, drill.current?.purposeTarget != nil {
                Text("Confirmed moved locations are hidden · sizes remain recorded until the next scan.").interfaceFont(.caption).foregroundStyle(.secondary)
            }
            Text(report.isProvisional ? "The chart shows counted files, not scan progress." : report.isComplete ? "Sizes from this scan" : "Counted files only · some items weren’t included")
                .interfaceFont(.caption).foregroundStyle(.secondary)
            if displayGroup == .projects {
                Text("\(report.projectCount) observed project scopes · nested projects excluded from their parent.").interfaceFont(.caption).foregroundStyle(.secondary)
            } else if displayGroup == .fileTypes {
                Text("Grouped by filename.").interfaceFont(.caption).foregroundStyle(.secondary)
                    .help("File contents were not read. Unfamiliar or missing extensions remain Other.")
            } else if displayGroup == .roles {
                Text("Purpose is inferred from folder layouts.").interfaceFont(.caption).foregroundStyle(.secondary)
                    .help("These hints do not verify app ownership or cleanup safety. Select a section to inspect its stored subtotals.")
            } else if displayGroup == .layouts {
                Text("Recognized app and library folders.").interfaceFont(.caption).foregroundStyle(.secondary)
                    .help("An alternate view of the same counted files. Unclassified layouts lack a supported rule or enough context. No file contents or manifests were read.")
            } else {
                Text("Select a chart segment or folder row to explore stored subtotals. Other folders remain available in the full folder table.").interfaceFont(.caption).foregroundStyle(.secondary)
            }
            if report.crossFolderHardlinkObjects > 0 {
                Text("\(report.crossFolderHardlinkObjects) objects have names in multiple folders. Group totals may overlap physical storage.").interfaceFont(.caption).foregroundStyle(.secondary)
            } else if !report.crossFolderHardlinkCountIsKnown {
                Text("Shared storage may be counted more than once.").interfaceFont(.caption).foregroundStyle(.secondary)
                    .help("Hard links and shared APFS data can overlap physical storage. These totals do not measure exclusive or reclaimable space.")
            }
        }
        .onChange(of: group) { _, value in
            drill.reset(); drill.setMetric(metric)
            if value == .folders { drill.open(.folder(0), title: folderRootTitle) }
            if value == .layouts { drill.loadApplicationLayouts() }
        }
        .onChange(of: allocated) { _, _ in drill.setMetric(metric) }
        .onChange(of: drill.current?.id) { _, _ in showsOtherExplanation = false }
        .onDisappear { showsOtherExplanation = false }
        .onChange(of: drill.canBrowse) { _, available in if !available && group == .folders { group = .fileTypes } }
        .onChange(of: drill.canShowApplicationLayouts) { _, available in if !available && group == .layouts { group = .fileTypes } }
    }
    @ViewBuilder private func purposeLocationDetails(_ selection: StorageBreakdownChartModel.PurposeLocationSelection) -> some View {
        let location = selection.location
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    purposeLocationHeading(location)
                    Spacer(minLength: 6)
                    purposeLocationActions(selection)
                }
                VStack(alignment: .leading, spacing: 8) {
                    purposeLocationHeading(location)
                    purposeLocationActions(selection)
                }
            }
            Text(location.recordedPath(scopeName: folderRootTitle)).interfaceFont(.caption).foregroundStyle(.secondary)
                .lineLimit(3).textSelection(.enabled)
                .help("Recorded location label. An ellipsis means earlier components are hidden. Actions resolve the exact recorded identity and check the current location; this label is never used as a path.")
            if !location.matchesWholeRecordedLocation {
                Text("The matching portion is \(storageMetricText(location.matchingValue.bytes[metric], files: location.matchingValue.counts.regularFiles)); the whole recorded folder is \(storageMetricText(location.wholeRecordedValue.bytes[metric], files: location.wholeRecordedValue.counts.regularFiles)). Open it to choose specific items.")
                    .interfaceFont(.caption).foregroundStyle(.secondary)
            }
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
            .toolPageEntrance(location.id, enabled: chartAppearance.motion.allows(.pages), mode: chartAppearance.motion.mode, initiallyRevealed: false)
    }
    private func purposeLocationHeading(_ location: StoredPurposeLocation) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                Image(systemName: "folder")
                Text(location.title(scopeName: folderRootTitle)).fontWeight(.medium)
                if !location.matchesWholeRecordedLocation { Text("Mixed").foregroundStyle(.secondary) }
            }.interfaceFont(.callout)
            if location.matchesWholeRecordedLocation {
                Text("\(storageMetricText(location.wholeRecordedValue.bytes[metric], files: location.wholeRecordedValue.counts.regularFiles)) · \(location.wholeRecordedValue.counts.regularFiles.formatted()) recorded \(location.wholeRecordedValue.counts.regularFiles == 1 ? "file" : "files")")
                    .interfaceFont(.caption).monospacedDigit()
                    .help(location.isSourceRoot ? "Scan and drive roots stay protected." : "Review acts on the entire folder. Apps may still need these files; current contents and access are checked again.")
            }
        }
    }
    @ViewBuilder private func purposeLocationActions(_ selection: StorageBreakdownChartModel.PurposeLocationSelection) -> some View {
        if drill.onLocationAction != nil {
                ViewThatFits(in: .horizontal) {
                    purposeLocationButtons(selection, vertical: false)
                    purposeLocationButtons(selection, vertical: true)
                }
        } else if let onOpenFullAnalysis {
            Button("Open Full Analysis") { onOpenFullAnalysis() }
        }
    }
    @ViewBuilder private func purposeLocationButtons(_ selection: StorageBreakdownChartModel.PurposeLocationSelection, vertical: Bool) -> some View {
        let location = selection.location
        let content = SwiftUI.Group {
            Button("Show in Explorer") { drill.actOnPurposeLocation(selection, action: .showInExplorer) }
                .disabled(!drill.canActOnPurposeLocation(selection, action: .showInExplorer))
            Menu("More") {
                Button("Properties") { drill.actOnPurposeLocation(selection, action: .properties) }
                    .disabled(!drill.canActOnPurposeLocation(selection, action: .properties))
                Button("Copy Path") { drill.actOnPurposeLocation(selection, action: .copyPath) }
                    .disabled(!drill.canActOnPurposeLocation(selection, action: .copyPath))
            }
            if location.matchesWholeRecordedLocation && !location.isSourceRoot {
                Button("Review whole folder…") { drill.actOnPurposeLocation(selection, action: .reviewTrash) }
                    .disabled(!drill.canActOnPurposeLocation(selection, action: .reviewTrash))
                    .help(StoredLocationAction.reviewTrash.unavailableHelp
                        ?? "Review moving this entire folder to Trash through the normal guarded operation. This does not delete only a filtered portion.")
                    .background {
                        #if DEBUG
                        if StoragePurposeLocationProbe.enabled { StoragePurposeReviewBounds(node: location.id) }
                        #endif
                    }
            }
        }
        if vertical { VStack(alignment: .leading, spacing: 7) { content } }
        else { HStack(spacing: 8) { content } }
    }
    #if DEBUG
    static func verificationView(report: AnalysisAttributionReport, drill: StorageBreakdownChartModel) -> Self {
        var view = Self(report: report, drill: drill, folderRootTitle: "Generated layout sample")
        view._group = State(initialValue: .roles)
        return view
    }
    static func applicationLayoutsVerificationView(report: AnalysisAttributionReport, drill: StorageBreakdownChartModel) -> Self {
        var view = Self(report: report, drill: drill, folderRootTitle: "Generated layout sample")
        view._group = State(initialValue: .layouts)
        return view
    }
    #endif
    private func nativeLegend(_ slice: StorageChartSlice) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Circle().fill(Color(red: slice.tint.red, green: slice.tint.green, blue: slice.tint.blue)).frame(width: 7, height: 7)
            Text(slice.title).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            Text(slice.amount).monospacedDigit()
            if slice.canOpen { Image(systemName: slice.id.hasPrefix("purpose-location-") ? "info.circle" : "chevron.right").interfaceFont(.caption2).foregroundStyle(.secondary) }
        }.interfaceFont(.caption).contentShape(Rectangle()).accessibilityElement(children: .combine)
    }
}

struct AppStorageAccountingView: View {
    let rows: [AppStorageComponent]
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("App-owned components").interfaceFont(.headline)
            Text("Declared app-state components and the separately measured temporary-analysis pool. These interval observations do not add to the directory chart or describe reclaimable space.")
                .interfaceFont(.caption).foregroundStyle(.secondary)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(row.title).interfaceFont(.callout.weight(.medium))
                        Spacer()
                        Text(row.logical).monospacedDigit().interfaceFont(.callout)
                    }
                    Text("Observed allocation: \(row.allocation)").interfaceFont(.caption)
                    Text(row.note).interfaceFont(.caption).foregroundStyle(.secondary)
                }.accessibilityElement(children: .combine)
            }
        }
    }
}
