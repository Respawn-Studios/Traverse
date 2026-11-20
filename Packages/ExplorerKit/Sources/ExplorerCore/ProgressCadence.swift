import Foundation

/// The producer supplies monotonic uptime and decides which progress boundaries
/// must be immediate. Suppressed samples never advance the reporting clock.
package struct ProgressCadence: Sendable {
    private let interval: TimeInterval
    package private(set) var lastPublication: TimeInterval?

    package init(interval: TimeInterval, startingAt start: TimeInterval? = nil) {
        self.interval = interval
        lastPublication = start
    }

    package mutating func shouldPublish(at now: TimeInterval, immediately: Bool = false) -> Bool {
        if !immediately, let lastPublication, now - lastPublication < interval { return false }
        lastPublication = now
        return true
    }
}
