import Darwin
import ExplorerCore
import FileOperations
import Foundation

/// Metadata browsing and separately explicit local content checks. No write,
/// materialization, automatic crawl or payload-indexing interface exists here.
public final class ZIPArchiveReader: @unchecked Sendable {
    private let queue = DispatchQueue(label: "MacExplorer.ZIPDirectory", qos: .userInitiated)
    private let admission = NSLock()
    private var submitted = false
    private let activity: FileActivityGate?
    private let excludedRoots: [URL]
    private let limits: ZIPReadLimits
    private let contentLimits: ZIPContentLimits
    private let previewLimits: ZIPTextPreviewLimits
    internal enum Stage: Sendable { case opened, read, parsed, checking, previewing }
    private let probe: (@Sendable (Stage) throws -> Void)?
    public init(activity: FileActivityGate? = nil, excludedRoots: [URL] = []) {
        self.activity = activity; self.excludedRoots = excludedRoots; limits = .init(); contentLimits = .init(); previewLimits = .init(); probe = nil
    }
    internal init(activity: FileActivityGate? = nil, excludedRoots: [URL] = [], limits: ZIPReadLimits = .init(), contentLimits: ZIPContentLimits = .init(), previewLimits: ZIPTextPreviewLimits = .init(),
                  probe: @escaping @Sendable (Stage) throws -> Void) {
        self.activity = activity; self.excludedRoots = excludedRoots; self.limits = limits; self.contentLimits = contentLimits; self.previewLimits = previewLimits; self.probe = probe
    }
    public func open(_ source: URL, retaining lifetime: (any Sendable)? = nil) async throws -> ZIPArchiveSession {
        let result = try await submit(source, retaining: lifetime, checkingContents: false, progress: nil)
        return ZIPArchiveSession(result.storage, binding: result.binding)
    }
    /// Explicit body checking only; browsing never calls this method.
    public func checkContents(_ source: URL, retaining lifetime: (any Sendable)? = nil,
                              progress: (@Sendable (ZIPContentProgress) -> Void)? = nil) async throws -> ZIPContentReport {
        let output = try await submit(source, retaining: lifetime, checkingContents: true, progress: progress)
        guard let report = output.report else { throw ZIPArchiveFailure.unavailable }; return report
    }
    /// Checks the exact source listed by this catalog. A replaced or changed
    /// archive refuses before any catalog or member bytes are read.
    public func checkContents(in session: ZIPArchiveSession, retaining lifetime: (any Sendable)? = nil,
                              progress: (@Sendable (ZIPContentProgress) -> Void)? = nil) async throws -> ZIPContentReport {
        let binding = try await session.contentCheckBinding()
        let output = try await perform(retaining: lifetime) { [self] cancellation in
            try read(binding.source, checkingContents: true, progress: progress,
                     cancellation: cancellation, matching: binding)
        }
        guard let report = output.report else { throw ZIPArchiveFailure.unavailable }
        return report
    }
    /// Explicit selected-member body reading. Browsing/hover never call this.
    /// The opaque selection is a source witness, never an access grant.
    public func previewText(_ selection: ZIPTextPreviewSelection, retaining lifetime: (any Sendable)? = nil) async throws -> ZIPTextPreview {
        try await perform(retaining: lifetime) { [self] cancellation in
            try ZIPTextPreviewReader.read(selection, excluding: excludedRoots, limits: limits,
                previewLimits: previewLimits, check: cancellation.check, probe: probe)
        }
    }

    /// Review two distinct UTF-8 members from one observed directory without
    /// extracting either member or granting archive edit authority.
    public func readTextComparison(left: ZIPTextPreviewSelection, right: ZIPTextPreviewSelection,
                                   retaining lifetime: (any Sendable)? = nil) async throws -> TextComparisonDocuments {
        guard left.binding.source == right.binding.source, left.binding.stamp == right.binding.stamp,
              left.directoryWitness.digest == right.directoryWitness.digest,
              left.directoryWitness.offset == right.directoryWitness.offset,
              left.directoryWitness.bytes == right.directoryWitness.bytes,
              left.recordOffset != right.recordOffset else { throw ZIPTextPreviewFailure.unsupported }
        return try await perform(retaining: lifetime) { [self] cancellation in
            func checkedText(_ selection: ZIPTextPreviewSelection) throws -> TextDocumentValue {
                try ZIPTextPreviewReader.readChecked(selection, excluding: excludedRoots, limits: limits,
                    previewLimits: previewLimits, check: cancellation.check, probe: probe) { bytes, _, check in
                    try check()
                    _ = try ZIPTextPreviewReader.validatedText(bytes)
                    return try .original(bytes)
                }
            }
            return .init(left: try checkedText(left), right: try checkedText(right))
        }
    }
    /// Explicit selected-member edit admission retains the exact decoded byte
    /// sequence and its source witness. Browsing and Preview do not call this.
    public func openTextForEdit(_ selection: ZIPTextPreviewSelection,
        retaining lifetime: (any Sendable)? = nil) async throws -> ZIPTextEditDocument {
        try await perform(retaining: lifetime) { [self] cancellation in
            try ZIPTextPreviewReader.readChecked(selection, excluding: excludedRoots,
                limits: limits, previewLimits: previewLimits, check: cancellation.check,
                probe: probe) { bytes, _, check in
                try check()
                return try ZIPTextEditDocument(selection: selection, bytes: bytes)
            }
        }
    }
    /// Rebuilds a catalog and reads the same exact member after a committed
    /// update or an explicit Reload. A different URL is limited to a sibling
    /// ZIP and requires the bytes that the caller just committed.
    public func reopenTextForEdit(_ previous: ZIPTextEditDocument, at archive: URL? = nil,
        expecting contents: TextDocumentValue? = nil,
        retaining lifetime: (any Sendable)? = nil) async throws -> ZIPTextEditDocument {
        let url = archive ?? previous.archiveURL
        guard url.pathExtension.lowercased() == "zip",
              url == previous.archiveURL || (contents != nil
                && url.deletingLastPathComponent() == previous.archiveURL.deletingLastPathComponent()) else {
            throw ZIPArchiveFailure.unavailable
        }
        return try await perform(retaining: lifetime) { [self] cancellation in
            let opened = try read(url, checkingContents: false, progress: nil, cancellation: cancellation)
            let selection = try selectionForRebind(previous.archivePath, opened: opened,
                check: cancellation.check)
            let document = try ZIPTextPreviewReader.readChecked(selection,
                excluding: excludedRoots, limits: limits, previewLimits: previewLimits,
                check: cancellation.check, probe: probe) { bytes, _, check in
                    try check()
                    return try ZIPTextEditDocument(selection: selection, bytes: bytes)
                }
            guard contents == nil || document.contents.encoded == contents?.encoded else {
                throw ZIPArchiveFailure.changed
            }
            return document
        }
    }
    /// Explicit complete selected-member hex read. Metadata browsing never
    /// calls this or falls back here automatically after a text refusal.
    public func previewBytes(_ selection: ZIPTextPreviewSelection, retaining lifetime: (any Sendable)? = nil) async throws -> ZIPBytePreview {
        try await perform(retaining: lifetime) { [self] cancellation in
            try ZIPBytePreviewReader.read(selection, excluding: excludedRoots, limits: limits,
                previewLimits: previewLimits, check: cancellation.check, probe: probe)
        }
    }
    public func previewImage(_ selection: ZIPTextPreviewSelection,
        retaining lifetime: (any Sendable)? = nil) async throws -> ArchiveImagePreview {
        guard ArchiveImagePreview.supportsFilename(selection.displayName) else { throw ArchiveImagePreviewFailure.invalidImage }
        return try await perform(retaining: lifetime) { [self] cancellation in
            try ZIPTextPreviewReader.readChecked(selection, excluding: excludedRoots, limits: limits,
                previewLimits: .image, check: cancellation.check, probe: probe) { bytes, _, check in
                    try ArchiveImagePreview.decode(bytes, filename: selection.displayName, check: check)
                }
        }
    }
    private struct Output: Sendable { let storage: ZIPCatalogStorage; let report: ZIPContentReport?; let binding: ZIPSourceBinding }
    private func selectionForRebind(_ path: String, opened: Output,
        check: () throws -> Void) throws -> ZIPTextPreviewSelection {
        let storage = opened.storage
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.count <= limits.depth,
              parts.allSatisfy({ !$0.isEmpty }),
              let centralOffset = storage.centralOffset,
              let witness = storage.directoryWitness else { throw ZIPArchiveFailure.changed }
        var cursor = 0
        for part in parts {
            var match: Int?
            for child in storage.nodes[cursor].children {
                try check()
                if storage.nodes[child].name.utf8.elementsEqual(part.utf8) {
                    guard match == nil else { throw ZIPArchiveFailure.changed }
                    match = child
                }
            }
            guard let match else { throw ZIPArchiveFailure.changed }
            cursor = match
        }
        let member = storage.nodes[cursor]
        guard member.kind == .file, !member.encrypted,
              member.method == 0 || member.method == 8,
              member.logical <= ZIPTextPreview.maximumUTF8Bytes,
              member.packed <= ZIPTextPreview.maximumPackedBytes,
              let recordOffset = member.centralEntryOffset else { throw ZIPArchiveFailure.changed }
        return .init(binding: opened.binding, path: path, recordOffset: recordOffset,
            centralOffset: centralOffset,
            centralEnd: centralOffset + UInt64(storage.summary.centralBytes),
            directoryWitness: witness)
    }
    private func submit(_ source: URL, retaining lifetime: (any Sendable)?, checkingContents: Bool,
                        progress: (@Sendable (ZIPContentProgress) -> Void)?) async throws -> Output {
        try await perform(retaining: lifetime) { [self] cancellation in
            try read(source, checkingContents: checkingContents, progress: progress, cancellation: cancellation)
        }
    }
    private func perform<Value: Sendable>(retaining lifetime: (any Sendable)?,
        body: @escaping @Sendable (Cancellation) throws -> Value) async throws -> Value {
        guard admission.withLock({ if submitted { return false }; submitted = true; return true }) else { throw ZIPArchiveFailure.busy }
        let cancellation = Cancellation()
        let output: Value = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    let result: Result<Value, Error> = Result {
                        defer { withExtendedLifetime(lifetime) {} }
                        try cancellation.check()
                        let lease = try activity?.begin(); defer { withExtendedLifetime(lease) {} }
                        return try body(cancellation)
                    }
                    admission.withLock { submitted = false }
                    continuation.resume(with: result)
                }
            }
        } onCancel: { cancellation.cancel() }
        try cancellation.check()
        return output
    }
    public func drain() async { await withCheckedContinuation { continuation in queue.async { continuation.resume() } } }
    private func read(_ url: URL, checkingContents: Bool, progress: (@Sendable (ZIPContentProgress) -> Void)?,
                      cancellation: Cancellation, matching binding: ZIPSourceBinding? = nil) throws -> Output {
        let started = ProcessInfo.processInfo.systemUptime
        func check() throws {
            try cancellation.check()
            if checkingContents, ProcessInfo.processInfo.systemUptime - started >= contentLimits.seconds {
                throw ZIPContentProblem(member: nil, reason: .limitReached)
            }
        }
        try check()
        let source = try ZIPSourceFile(url, excluding: excludedRoots)
        if let binding {
            guard source.observed == binding.stamp,
                  source.url.path.utf8.elementsEqual(binding.source.path.utf8) else { throw ZIPArchiveFailure.changed }
        }
        try probe?(.opened)
        let positionedRead: (UInt64, Int) throws -> Data = { offset, count in
            let data = try source.read(offset, count, maximum: max(self.limits.centralBytes, 65_557), check: check)
            try self.probe?(.read)
            return data
        }
        var readLimits = limits, records: [ZIPPayloadRecord] = []
        if checkingContents { readLimits.members = min(readLimits.members, contentLimits.nodes); readLimits.nodes = min(readLimits.nodes, contentLimits.nodes + 1) }
        let capture: ((ZIPPayloadRecord) throws -> Void)? = checkingContents ? { records.append($0) } : nil
        let storage: ZIPCatalogStorage
        do {
            storage = try ZIPMetadataParser.parse(length: UInt64(source.observed.size), limits: readLimits, capture: capture,
                cancelled: { cancellation.stopped || checkingContents && ProcessInfo.processInfo.systemUptime - started >= self.contentLimits.seconds }, read: positionedRead)
        } catch {
            try check()
            try source.validate()
            if checkingContents, error as? ZIPArchiveFailure == .limited { throw ZIPContentProblem(member: nil, reason: .limitReached) }
            throw error
        }
        try probe?(.parsed)
        try check()
        var report: ZIPContentReport?
        if checkingContents {
            try probe?(.checking); try check()
            do { report = try ZIPContentVerifier.verify(records, limits: contentLimits, check: check, read: positionedRead, progress: progress) }
            catch { try check(); try source.validate(); throw error }
        }
        try check()
        try source.validate()
        if let checked = report {
            report = .init(files: checked.files, folders: checked.folders, decodedBytes: checked.decodedBytes,
                packedBytes: checked.packedBytes, seconds: ProcessInfo.processInfo.systemUptime - started, codecVersion: checked.codecVersion)
        }
        return .init(storage: storage, report: report, binding: .init(source: source.url, stamp: source.observed))
    }
    private final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func cancel() { lock.withLock { value = true } }
        var stopped: Bool { lock.withLock { value } }
        func check() throws { if stopped { throw ZIPArchiveFailure.stopped } }
    }
}
