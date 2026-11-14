/// Pure, bounded observations. No file, transport, recorder, task or user text is
/// accepted here. The responsible owner supplies actual stages and monotonic time.
public struct RemoteTransferDiagnosticTimeline: Sendable {
    public enum Stage: Sendable {
        case chooseSource, chooseDestination, access, source, destination, metadata, review
        case receive, prepareHistory, verify, publish, drain, retain, clean
        fileprivate var presentation: (DiagnosticPhase, DiagnosticCheckpoint) {
            switch self {
            case .chooseSource: (.waiting, .queueSources)
            case .chooseDestination: (.waiting, .queueDestination)
            case .access: (.resolving, .queueAccess)
            case .source: (.preparing, .queueSources)
            case .destination: (.preparing, .queueDestination)
            case .metadata: (.reading, .queueSources)
            case .review: (.waiting, .queueReady)
            case .receive: (.transferring, .queueMutation)
            case .prepareHistory: (.preparing, .queueStatePreparation)
            case .verify: (.verifying, .queuePlan)
            case .publish: (.committing, .queueMutation)
            case .drain: (.draining, .queueTerminal)
            case .retain: (.retaining, .queueTerminal)
            case .clean: (.cleaning, .queueTerminal)
            }
        }
    }
    public enum Outcome: Sendable {
        case completed, partial, cancelled, blocked, failed
        fileprivate var phase: DiagnosticPhase {
            switch self {
            case .completed: .completed; case .partial: .partial; case .cancelled: .cancelled
            case .blocked: .blocked; case .failed: .failed
            }
        }
    }
    public struct Observation: Sendable {
        public let phase: DiagnosticPhase
        public let context: DiagnosticContext
        public let count: UInt64?
        public let durationMilliseconds: UInt64
    }
    private let began: UInt64
    private var stage: Stage?
    private var lastCount: UInt64?
    private var lastSample: UInt64
    private var observations = 0
    private var reportedGap = false
    public private(set) var finished = false
    public init(uptimeNanoseconds: UInt64) {
        began = uptimeNanoseconds; lastSample = uptimeNanoseconds
    }
    /// Stage changes are immediate; repeated numerical progress is monotonic and
    /// sampled at most once a second. One gap records an exhausted event bound.
    public mutating func advance(_ next: Stage, count: UInt64? = nil, uptimeNanoseconds now: UInt64) -> Observation? {
        guard !finished else { return nil }
        let changed = stage != next
        if !changed {
            guard let count, count > (lastCount ?? 0), now >= lastSample,
                  now - lastSample >= 1_000_000_000 else { return nil }
        }
        stage = next; lastCount = count
        // A backwards clock cannot open the throttle or overflow elapsed time.
        lastSample = max(lastSample, now)
        guard observations < 2_048 else {
            guard !reportedGap else { return nil }; reportedGap = true
            return .init(phase: .gap, context: .init(.queueTerminal), count: nil,
                         durationMilliseconds: elapsed(now))
        }
        observations += 1
        let value = next.presentation
        return .init(phase: value.0, context: .init(value.1), count: count,
                     durationMilliseconds: elapsed(now))
    }
    /// Always reserve one terminal observation, even after an observation gap.
    public mutating func finish(_ outcome: Outcome, count: UInt64? = nil,
                                uptimeNanoseconds now: UInt64) -> Observation? {
        guard !finished else { return nil }; finished = true
        return .init(phase: outcome.phase, context: .init(.queueTerminal), count: count,
                     durationMilliseconds: elapsed(now))
    }
    private func elapsed(_ now: UInt64) -> UInt64 { now >= began ? (now - began) / 1_000_000 : 0 }
}
