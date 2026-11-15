import ExplorerCore
import FileOperations
import Foundation

internal struct TARSourceBinding: Sendable {
    let source: URL
    let stamp: PinnedLocalFileSource.Stamp
    let witness: Data
    let compressed: TARCompressedSpoolLease?
    init(source: URL, stamp: PinnedLocalFileSource.Stamp, witness: Data,
         compressed: TARCompressedSpoolLease? = nil) {
        self.source = source; self.stamp = stamp; self.witness = witness; self.compressed = compressed
    }
}
/// Concrete local plain-TAR reader. All opening, positioned I/O, parsing and
/// hierarchy construction and explicit selected previews share one serial queue.
public final class TARArchiveReader: @unchecked Sendable {
    private let queue = DispatchQueue(label:"Traverse.TARDirectory",qos:.userInitiated)
    private let admission = NSLock()
    private var submitted = false
    private var drainWaiters = [CheckedContinuation<Void, Never>]()
    private let activity: FileActivityGate?, excludedRoots: [URL]
    private let compressedPool: TARCompressedPreparationPool?
    private let limits: TARReadLimits
    private let previewLimits:TARTextPreviewLimits
    internal enum Stage: Sendable { case opened, metadata, parsed, previewing, previewPayload, previewTransform, previewFinalMetadata, previewComplete }
    private let probe: (@Sendable (Stage,UInt64,Int) throws -> Void)?
    public init(activity: FileActivityGate? = nil, excludedRoots: [URL] = [],
                compressedPool: TARCompressedPreparationPool? = nil) {
        self.activity=activity;self.excludedRoots=excludedRoots;self.compressedPool=compressedPool
        limits = .init();previewLimits = .init();probe=nil
    }
    internal init(activity: FileActivityGate? = nil, excludedRoots: [URL] = [], limits: TARReadLimits = .init(),
                  previewLimits:TARTextPreviewLimits = .init(),
                  probe: @escaping @Sendable (Stage,UInt64,Int) throws -> Void) {
        self.activity=activity;self.excludedRoots=excludedRoots;self.compressedPool=nil
        self.limits=limits;self.previewLimits=previewLimits;self.probe=probe
    }
    public func open(_ url: URL, retaining lifetime: (any Sendable)? = nil) async throws -> TARArchiveSession {
        let output=try await perform(retaining:lifetime){try self.read(url,cancellation:$0)}
        return TARArchiveSession(output.storage,binding:output.binding)
    }
    /// Explicit full-body preparation; plain `open` remains metadata-only.
    public func prepareCompressed(_ original: URL, retaining lifetime: (any Sendable)? = nil,
        publicQuarantineSource: Bool = false,
        progress: @escaping @Sendable (TARCompressedPreparationProgress) -> Void = { _ in }) async throws -> TARArchiveSession {
        guard let compressedPool else { throw TARArchiveFailure.unsupported }
        guard admission.withLock({ if submitted { return false }; submitted = true; return true }) else {
            throw TARArchiveFailure.busy
        }
        defer { finishSubmission() }
        let prepared = try await compressedPool.prepare(original, excluding: excludedRoots,
                                                        publicQuarantineSource: publicQuarantineSource,
                                                        retaining: lifetime, progress: progress)
        if Task.isCancelled { throw TARArchiveFailure.stopped }
        return TARArchiveSession(prepared.catalog, binding: prepared.binding)
    }
    public func previewText(_ selection:TARTextPreviewSelection,retaining lifetime:(any Sendable)?=nil)async throws->TARTextPreview {
        try await perform(retaining:lifetime){cancellation in
            try TARTextPreviewReader.readChecked(selection,excluding:self.excludedRoots,limits:self.limits,
                previewLimits:self.previewLimits,check:cancellation.check,probe:self.probe){bytes,check in
                    try TARTextPreview.decode(bytes,check:check)
                }
        }
    }
    public func openTextForEdit(_ selection: TARTextPreviewSelection,
        retaining lifetime: (any Sendable)? = nil) async throws -> TARTextEditDocument {
        return try await perform(retaining: lifetime) { cancellation in
            if selection.binding.compressed != nil {
                _ = try TARMutationSource(selection.binding, check: cancellation.check)
            }
            return try TARTextPreviewReader.readChecked(selection, excluding: self.excludedRoots,
                limits: self.limits, previewLimits: self.previewLimits,
                check: cancellation.check, probe: self.probe) { bytes, check in
                try check(); return try TARTextEditDocument(selection: selection, bytes: bytes)
            }
        }
    }
    public func reopenTextForEdit(_ previous: TARTextEditDocument, at archive: URL? = nil,
        expecting contents: TextDocumentValue? = nil,
        retaining lifetime: (any Sendable)? = nil) async throws -> TARTextEditDocument {
        let url = archive ?? previous.archiveURL
        let compressed = previous.selection.binding.compressed != nil
        guard (compressed ? TARCompressedCodec.filename(url.lastPathComponent) == previous.selection.binding.compressed?.original.codec
            : url.pathExtension.lowercased() == "tar"),
              url == previous.archiveURL || (contents != nil
                && url.deletingLastPathComponent() == previous.archiveURL.deletingLastPathComponent()) else {
            throw TARArchiveFailure.invalidSelection
        }
        if compressed {
            // A user-requested Save/Reload may prepare the new generation. Tab
            // restoration and ordinary metadata browsing still never decode.
            let session = try await prepareCompressed(url, retaining: lifetime,
                publicQuarantineSource: previous.selection.binding.compressed?.original.security.publicWitness != nil)
            let selected: TARTextPreviewSelection
            do { selected = try await session.selectionForTextPreview(atPath: previous.archivePath) }
            catch { await session.close(); throw error }
            await session.close()
            let document = try await openTextForEdit(selected, retaining: lifetime)
            guard contents == nil || document.contents.encoded == contents?.encoded else { throw TARArchiveFailure.changed }
            return document
        }
        return try await perform(retaining: lifetime) { cancellation in
            let output = try self.read(url, cancellation: cancellation)
            var index = 0
            for part in previous.archivePath.split(separator: "/") {
                try cancellation.check()
                guard let next = output.storage.nodes[index].children.first(where: {
                    output.storage.nodes[$0].name.utf8.elementsEqual(part.utf8)
                }) else { throw TARArchiveFailure.changed }
                index = next
            }
            guard let record = output.storage.nodes[index].record, record.kind == .file else {
                throw TARArchiveFailure.changed
            }
            let selection = TARTextPreviewSelection(binding: output.binding, record: record)
            let document = try TARTextPreviewReader.readChecked(selection, excluding: self.excludedRoots,
                limits: self.limits, previewLimits: self.previewLimits,
                check: cancellation.check, probe: self.probe) { bytes, check in
                try check(); return try TARTextEditDocument(selection: selection, bytes: bytes)
            }
            guard contents == nil || document.contents.encoded == contents?.encoded else { throw TARArchiveFailure.changed }
            return document
        }
    }
    public func previewBytes(_ selection:TARTextPreviewSelection,retaining lifetime:(any Sendable)?=nil)async throws->TARBytePreview {
        try await perform(retaining:lifetime){cancellation in
            try TARTextPreviewReader.readChecked(selection,excluding:self.excludedRoots,limits:self.limits,
                previewLimits:self.previewLimits,check:cancellation.check,probe:self.probe){bytes,check in
                    .init(hexadecimalText:try TARBytePreview.render(bytes,check:check),byteCount:UInt64(bytes.count))
                }
        }
    }
    public func previewImage(_ selection: TARTextPreviewSelection,
        retaining lifetime: (any Sendable)? = nil) async throws -> ArchiveImagePreview {
        guard ArchiveImagePreview.supportsFilename(selection.displayName) else { throw ArchiveImagePreviewFailure.invalidImage }
        return try await perform(retaining: lifetime) { [self] cancellation in
            try TARTextPreviewReader.readChecked(selection, excluding: excludedRoots, limits: limits,
                previewLimits: .image, check: cancellation.check, probe: probe) { bytes, check in
                    try ArchiveImagePreview.decode(bytes, filename: selection.displayName, check: check)
                }
        }
    }
    private func perform<Value:Sendable>(retaining lifetime:(any Sendable)?,
        body:@escaping @Sendable(Cancellation)throws->Value)async throws->Value {
        guard admission.withLock({ if submitted { return false };submitted=true;return true })else{throw TARArchiveFailure.busy}
        let cancellation=Cancellation()
        let output: Value = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    let result: Result<Value,Error> = Result {
                        defer { withExtendedLifetime(lifetime){} }
                        try cancellation.check()
                        let lease=try activity?.begin();defer{withExtendedLifetime(lease){}}
                        do{return try body(cancellation)}catch let error as ZIPArchiveFailure{throw Self.failure(error)}
                    }
                    finishSubmission();continuation.resume(with:result)
                }
            }
        } onCancel:{ cancellation.cancel() }
        try cancellation.check()
        return output
    }
    public func drain() async {
        await withCheckedContinuation { continuation in
            let immediate = admission.withLock { () -> Bool in
                if submitted { drainWaiters.append(continuation); return false }
                return true
            }
            if immediate { continuation.resume() }
        }
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
    }
    private func finishSubmission() {
        let waiters = admission.withLock { () -> [CheckedContinuation<Void, Never>] in
            submitted = false
            let current = drainWaiters; drainWaiters.removeAll()
            return current
        }
        waiters.forEach { $0.resume() }
    }
    private struct Output: Sendable { let storage: TARCatalogStorage;let binding:TARSourceBinding }
    private func read(_ url:URL,cancellation:Cancellation)throws->Output {
        let started=ProcessInfo.processInfo.systemUptime
        func check()throws{
            try cancellation.check()
            guard ProcessInfo.processInfo.systemUptime-started<limits.seconds else{throw TARArchiveFailure.limited}
        }
        do {
            try check();let source=try PinnedLocalFileSource(url,excluding:excludedRoots)
            try probe?(.opened,0,0);try check()
            let storage=try TARSourceCatalog.read(source,limits:limits,check:check,didRead:{try self.probe?(.metadata,$0,$1)})
            try probe?(.parsed,0,0);try check();try source.validate()
            return .init(storage:storage,binding:.init(source:source.url,stamp:source.observed,witness:storage.witness))
        } catch let error as ZIPArchiveFailure {
            throw Self.failure(error)
        }
    }
    private static func failure(_ error:ZIPArchiveFailure)->TARArchiveFailure {
            switch error {
            case .changed:return .changed
            case .stopped:return .stopped
            case .unsupported:return .unsupported
            case .limited:return .limited
            case .malformed:return .malformed
            default:return .unavailable
            }
    }
    private final class Cancellation: @unchecked Sendable {
        private let lock=NSLock();private var cancelled=false
        func cancel(){lock.withLock{cancelled=true}}
        func check()throws{if lock.withLock({cancelled}){throw TARArchiveFailure.stopped}}
    }
}
