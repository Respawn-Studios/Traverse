import Foundation

/// Opaque, revocable candidate publication. Contains no authored strings/vectors.
/// Callbacks are short and non-reentrant, like the existing B07 publication seam.
public final class RelatedNameResult: Sendable {
    public let model: RelatedNameModel
    public let scope: UUID
    public let epoch: UInt64
    public let observedRows: Int
    private let request: UUID
    private let authority: RelatedNameWorkState
    fileprivate init(model: RelatedNameModel, scope: UUID, epoch: UInt64, rows: Int, request: UUID, authority: RelatedNameWorkState) {
        self.model = model; self.scope = scope; self.epoch = epoch; observedRows = rows
        self.request = request; self.authority = authority
    }
    @discardableResult public func publish(_ body: ([RelatedNameCandidate]) -> Void) -> Bool {
        authority.publish(request, body)
    }
}

/// A bounded session, never a catalog. One active query and one latest pending
/// query; superseding cancels work and old result publication immediately.
/// Close/withdraw hides results synchronously, while drain waits for real work
/// and encoder/cache release. Exact B07 lookup does not call this worker.
public final class RelatedNameSession: Sendable {
    private let state: RelatedNameWorkState
    public init(input: RelatedNameInput, encoder: @escaping @Sendable (@Sendable () -> Bool) throws -> any RelatedNameEncoder) {
        state = RelatedNameWorkState(input: input, factory: encoder)
    }
    public func query(_ query: RelatedNameQuery) async throws -> RelatedNameResult {
        let token = RelatedNameWorkState.Cancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                state.submit(query, token: token, continuation: continuation)
            }
        } onCancel: { token.cancel(); state.cancel(token) }
    }
    public func withdraw() { state.close() }
    public func drain() async { await state.drain() }
    deinit { state.close() }
}

fileprivate final class RelatedNameWorkState: @unchecked Sendable {
    final class Cancellation: @unchecked Sendable {
        let id = UUID()
        private let lock = NSLock()
        private var value = false
        func cancel() { lock.withLock { value = true } }
        var cancelled: Bool { lock.withLock { value } }
    }
    struct Request {
        let query: RelatedNameQuery
        let token: Cancellation
        let continuation: CheckedContinuation<RelatedNameResult, Error>
    }
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "MacExplorer.RelatedNames", qos: .utility)
    private let factory: @Sendable (@Sendable () -> Bool) throws -> any RelatedNameEncoder
    private let scope: UUID
    private let epoch: UInt64
    private let rowCount: Int
    private var input: RelatedNameInput? // Confined to queue after init.
    private var encoder: (any RelatedNameEncoder)?
    private var vectors: [RelatedNameVectors.Entry] = []
    private var preparedModel: RelatedNameModel?
    private var failure: RelatedNameFailure?
    private var active: Cancellation?
    private var pending: Request?
    private var running = false
    private var closed = false
    private var current: UUID?
    private var published: [RelatedNameCandidate]?
    init(input: RelatedNameInput, factory: @escaping @Sendable (@Sendable () -> Bool) throws -> any RelatedNameEncoder) {
        self.input = input; self.factory = factory; scope = input.scope; epoch = input.epoch; rowCount = input.rows.count
    }
    func submit(_ query: RelatedNameQuery, token: Cancellation, continuation: CheckedContinuation<RelatedNameResult, Error>) {
        var rejected: Request?, start = false, refused = false
        lock.withLock {
            guard !closed, !token.cancelled else { refused = true; return }
            active?.cancel(); rejected = pending; pending?.token.cancel()
            current = token.id; published = nil
            pending = Request(query: query, token: token, continuation: continuation)
            if !running { running = true; start = true }
        }
        if refused { continuation.resume(throwing: RelatedNameFailure.stopped) }
        rejected?.continuation.resume(throwing: RelatedNameFailure.stopped)
        if start { queue.async { [self] in run() } }
    }
    func cancel(_ token: Cancellation) {
        var rejected: Request?
        lock.withLock {
            if current == token.id { published = nil }
            if pending?.token === token { rejected = pending; pending = nil }
        }
        rejected?.continuation.resume(throwing: RelatedNameFailure.stopped)
    }
    func close() {
        var rejected: Request?, release = false
        lock.withLock {
            guard !closed else { return }
            closed = true; current = nil; published = nil; active?.cancel()
            rejected = pending; pending?.token.cancel(); pending = nil
            if !running { running = true; release = true }
        }
        rejected?.continuation.resume(throwing: RelatedNameFailure.stopped)
        if release { queue.async { [self] in run() } }
    }
    func publish(_ request: UUID, _ body: ([RelatedNameCandidate]) -> Void) -> Bool {
        lock.withLock {
            guard !closed, current == request, let published else { return false }
            body(published); return true
        }
    }
    func drain() async { await withCheckedContinuation { continuation in queue.async { continuation.resume() } } }
    private func run() {
        while true {
            let request: Request? = lock.withLock {
                if let next = pending { pending = nil; active = next.token; return next }
                active = nil; running = false; return nil
            }
            guard let request else {
                if lock.withLock({ closed }) { release() }
                return
            }
            autoreleasepool { execute(request) }
        }
    }
    private func execute(_ request: Request) {
        do {
            guard !request.token.cancelled else { throw RelatedNameFailure.stopped }
            if let failure { throw failure }
            let cancelled: @Sendable () -> Bool = { request.token.cancelled }
            if encoder == nil { encoder = try factory(cancelled) }
            guard let encoder else { throw RelatedNameFailure.unavailable }
            let model = encoder.model
            if let preparedModel, preparedModel != model { throw RelatedNameFailure.changed }
            guard rowCount * model.dimension * MemoryLayout<Double>.stride <= 16 * 1_024 * 1_024 else { throw RelatedNameFailure.limited }
            if vectors.isEmpty {
                guard let input else { throw RelatedNameFailure.stopped }
                var prepared: [RelatedNameVectors.Entry] = []; prepared.reserveCapacity(input.rows.count)
                for row in input.rows {
                    guard !cancelled() else { throw RelatedNameFailure.stopped }
                    let vector = try RelatedNameVectors.normalized(encoder.vector(for: row.text, cancelled: cancelled), dimension: model.dimension)
                    prepared.append(.init(row: row, vector: vector))
                }
                guard encoder.model == model else { throw RelatedNameFailure.changed }
                vectors = prepared; preparedModel = model; self.input = nil
            }
            guard !cancelled() else { throw RelatedNameFailure.stopped }
            let query = try RelatedNameVectors.normalized(encoder.vector(for: request.query.text, cancelled: cancelled), dimension: model.dimension)
            guard encoder.model == model else { throw RelatedNameFailure.changed }
            let matches = try RelatedNameVectors.rank(vectors, query: query, threshold: request.query.threshold, cancelled: cancelled)
            let result = RelatedNameResult(model: model, scope: scope, epoch: epoch, rows: rowCount, request: request.token.id, authority: self)
            let admitted = lock.withLock {
                guard !closed, current == request.token.id, !request.token.cancelled else { return false }
                published = matches; return true
            }
            guard admitted else { throw RelatedNameFailure.stopped }
            request.continuation.resume(returning: result)
        } catch {
            let error = (error as? RelatedNameFailure) ?? .encoderFailed
            if error != .stopped { failure = error; release() }
            request.continuation.resume(throwing: error)
        }
    }
    private func release() { encoder?.close(); encoder = nil; vectors = []; input = nil }
}
