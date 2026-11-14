import AppKit

/// Small native semantic target, pinned to loaded chart data. Owns no scanner,
/// catalog or source access. The chart retains at most15 current elements.
@MainActor final class StorageChartAccessibilityElement: NSAccessibilityElement {
    nonisolated private let destination: StorageChartAccessibilityTarget
    let index: Int
    init(owner: StorageDimensionalChartView, generation: UUID, sliceID: String, index: Int) {
        destination = StorageChartAccessibilityTarget(owner: owner, generation: generation, sliceID: sliceID, index: index)
        self.index = index; super.init()
    }
    nonisolated override func accessibilityFrame() -> NSRect {
        // The legacy AppKit override is not actor annotated. Only its immutable
        // global-actor target crosses this callback boundary; no NSView or
        // mutable accessibility-element state is read off the main queue.
        let destination = destination
        if Thread.isMainThread { return MainActor.assumeIsolated { destination.currentFrame() } }
        return DispatchQueue.main.sync { MainActor.assumeIsolated { destination.currentFrame() } }
    }
    nonisolated override func accessibilityPerformPress() -> Bool {
        let destination = destination
        if Thread.isMainThread { return MainActor.assumeIsolated { destination.press() } }
        return DispatchQueue.main.sync { MainActor.assumeIsolated { destination.press() } }
    }
}

@MainActor private final class StorageChartAccessibilityTarget {
    private weak var owner: StorageDimensionalChartView?
    private let generation: UUID
    private let sliceID: String
    private let index: Int
    init(owner: StorageDimensionalChartView, generation: UUID, sliceID: String, index: Int) {
        self.owner = owner; self.generation = generation; self.sliceID = sliceID; self.index = index
    }
    func currentFrame() -> NSRect {
        owner?.segmentAccessibilityFrame(generation: generation, sliceID: sliceID, index: index) ?? .zero
    }
    func press() -> Bool {
        owner?.pressAccessibilitySegment(generation: generation, sliceID: sliceID, index: index) ?? false
    }
}
