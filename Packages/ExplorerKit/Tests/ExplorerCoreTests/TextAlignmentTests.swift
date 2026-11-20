import ExplorerCore
import Testing

@Suite struct TextAlignmentTests {
    @Test func sparseEditsKeepUnchangedRepeatedLinesAligned() throws {
        let context = Array(repeating: 7, count: 2_400)
        let left = [1] + context + [2, 9]
        let right = [3, 4] + context + [9]
        let result = try TextAlignment.lines(left, right, cancelled: { false })
        #expect(!result.grouped)
        #expect(result.spans == [.init(left: 0..<1, right: 0..<2), .init(left: 2_401..<2_402, right: 2_402..<2_402)])
        let backwards = try TextAlignment.lines(right, left, cancelled: { false })
        #expect(!backwards.grouped)
        #expect(backwards.spans == result.spans.map { .init(left: $0.right, right: $0.left) })
    }

    @Test func broadRewritesStayGroupedAndCancellationStops() throws {
        let left = Array(0..<1_100), right = Array(2_000..<3_100)
        let result = try TextAlignment.lines(left, right, cancelled: { false })
        #expect(result.grouped)
        #expect(result.spans == [.init(left: left.indices, right: right.indices)])
        #expect(throws: CancellationError.self) {
            _ = try TextAlignment.lines(left, right, cancelled: { true })
        }
    }

    @Test func inlineAlignmentUsesTheSharedRemainingCellBudget() throws {
        var remaining = 5
        let fine = try TextAlignment.inline([1, 2, 9], [3, 4, 9], remainingCells: &remaining, cancelled: { false })
        #expect(!fine.grouped)
        #expect(fine.spans == [.init(left: 0..<2, right: 0..<2)])
        #expect(remaining == 1)
        let grouped = try TextAlignment.inline([1, 2, 9], [3, 4, 9], remainingCells: &remaining, cancelled: { false })
        #expect(grouped.grouped)
        #expect(remaining == 1)
    }
}
