import Foundation
import FileOperations

/// A bounded presentation accumulator shared by exclusive commands and queued
/// transfers. Job ownership and worker completion are decided by the caller.
struct OperationProgressState {
    private var jobID: UUID?
    private var sequence: UInt64 = 0
    private var samples: [(TimeInterval, Double)] = []
    private var lastSample: TimeInterval = -.infinity

    mutating func receive(_ update: OperationProgress, stopping requestedStop: Bool) -> OperationProgressPresentation? {
        if let jobID {
            guard jobID == update.jobID, update.sequence >= sequence else { return nil }
        } else { jobID = update.jobID }
        sequence = update.sequence
        let phase: String = switch update.phase {
        case .planning: "Planning"
        case .copying: "Copy"
        case .verifying: "Verify"
        case .publishing: "Publish"
        case .syncing: "Save"
        case .retaining: "Retain source"
        case .stopping: "Stopping"
        case .completed: "Finishing"
        }
        let now = ProcessInfo.processInfo.systemUptime
        if update.phase == .copying, let speed = update.bytesPerSecond, speed.isFinite,
           now - lastSample >= 0.25 {
            samples.append((now, max(0, speed)))
            lastSample = now
        }
        samples.removeAll { now - $0.0 > 60 }
        if samples.count > 240 { samples.removeFirst(samples.count - 240) }
        let stopping = requestedStop || update.cancellationRequested || update.phase == .stopping
        let itemText = update.itemIndex.flatMap { index in
            update.itemCount.map { "Item \(min(max(1, index), $0)) of \($0)" }
        }
        let completed: String?
        let remaining: String?
        if let done = update.bytesCompleted, let total = update.bytesTotal {
            completed = "\(FileSizeText.string(done)) of \(FileSizeText.string(total)) in this phase"
            remaining = "\(FileSizeText.string(max(0, total - done))) remaining in this phase"
        } else if let done = update.itemsCompleted, let total = update.itemsTotal {
            completed = "\(done) of \(total) items in this phase"
            remaining = "\(max(0, total - done)) items remaining in this phase"
        } else { completed = nil; remaining = "Measuring this phase…" }
        let speed = update.phase == .copying ? update.bytesPerSecond.flatMap { value in
            value.isFinite && value >= 0
                ? "\(FileSizeText.string(Int64(min(value, Double(Int64.max / 2)))))/s · logical copy bytes" : nil
        } : nil
        return OperationProgressPresentation(
            phaseTitle: stopping ? "Stopping" : phase,
            percentage: update.isTerminal ? nil : update.fractionCompleted,
            summary: stopping ? "Stopping — finishing the current safe step. Completed changes are kept."
                : (itemText ?? "The percentage describes the named phase."),
            sourcePath: update.source?.path, destinationPath: update.destination?.path,
            currentItem: (update.currentItem ?? update.source)?.lastPathComponent,
            completedText: completed, remainingText: remaining, speedText: speed,
            samples: samples.map(\.1), stopping: stopping, terminal: update.isTerminal)
    }
}
