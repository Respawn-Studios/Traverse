import ExplorerCore
import Foundation

internal struct TARSourceBinding: Sendable {
    let source: URL
    let stamp: PinnedLocalFileSource.Stamp
    let witness: Data
}
/// Concrete local plain-TAR reader. All opening, positioned I/O, parsing and
/// hierarchy construction occur on one queue; no payload-read API is exposed.
public final class TARArchiveReader: @unchecked Sendable {
    private let queue = DispatchQueue(label:"Traverse.TARDirectory",qos:.userInitiated)
    private let admission = NSLock()
    private var submitted = false
    private let activity: FileActivityGate?, excludedRoots: [URL]
    private let limits: TARReadLimits
    internal enum Stage: Sendable { case opened, metadata, parsed }
    private let probe: (@Sendable (Stage,UInt64,Int) throws -> Void)?
    public init(activity: FileActivityGate? = nil, excludedRoots: [URL] = []) {
        self.activity=activity;self.excludedRoots=excludedRoots;limits = .init();probe=nil
    }
    internal init(activity: FileActivityGate? = nil, excludedRoots: [URL] = [], limits: TARReadLimits = .init(),
                  probe: @escaping @Sendable (Stage,UInt64,Int) throws -> Void) {
        self.activity=activity;self.excludedRoots=excludedRoots;self.limits=limits;self.probe=probe
    }
    public func open(_ url: URL, retaining lifetime: (any Sendable)? = nil) async throws -> TARArchiveSession {
        guard admission.withLock({ if submitted { return false };submitted=true;return true })else{throw TARArchiveFailure.busy}
        let cancellation=Cancellation()
        let output: Output = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    let result: Result<Output,Error> = Result {
                        defer { withExtendedLifetime(lifetime){} }
                        try cancellation.check()
                        let lease=try activity?.begin();defer{withExtendedLifetime(lease){}}
                        return try read(url,cancellation:cancellation)
                    }
                    admission.withLock{submitted=false};continuation.resume(with:result)
                }
            }
        } onCancel:{ cancellation.cancel() }
        try cancellation.check()
        return TARArchiveSession(output.storage,binding:output.binding)
    }
    public func drain() async { await withCheckedContinuation { continuation in queue.async{continuation.resume()} } }
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
            switch error {
            case .changed:throw TARArchiveFailure.changed
            case .stopped:throw TARArchiveFailure.stopped
            case .unsupported:throw TARArchiveFailure.unsupported
            case .limited:throw TARArchiveFailure.limited
            case .malformed:throw TARArchiveFailure.malformed
            default:throw TARArchiveFailure.unavailable
            }
        }
    }
    private final class Cancellation: @unchecked Sendable {
        private let lock=NSLock();private var cancelled=false
        func cancel(){lock.withLock{cancelled=true}}
        func check()throws{if lock.withLock({cancelled}){throw TARArchiveFailure.stopped}}
    }
}
