import ExplorerCore
import Testing

struct ProgressCadenceTests {
    @Test func immediateBoundariesResetCadenceButSuppressedSamplesDoNot() {
        var cadence = ProgressCadence(interval: 0.25)
        let reports = [cadence.shouldPublish(at: 10), cadence.shouldPublish(at: 10.125),
                       cadence.shouldPublish(at: 10.125, immediately: true), cadence.shouldPublish(at: 10.25),
                       cadence.shouldPublish(at: 10.375)]
        #expect(reports == [true, false, true, false, true])
        #expect(cadence.lastPublication == 10.375)
    }

    @Test func seededClockWaitsBeforeItsFirstOrdinaryUpdate() {
        var cadence = ProgressCadence(interval: 0.25, startingAt: 10)
        let reports = [cadence.shouldPublish(at: 10.125), cadence.shouldPublish(at: 10.25)]
        #expect(reports == [false, true])
    }
}
