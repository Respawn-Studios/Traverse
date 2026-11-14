#if DEBUG
import AppKit

/// Reads only the generated sidebar's mounted cells. External accessibility
/// inspection is separate; querying virtual AX rows inside this task can stall.
@MainActor enum SidebarRowPresentationProbe {
    struct Expected {
        let item: NSObject
        let token: Int
        let title: String
        let group: Bool
        let height: CGFloat
    }
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }
    struct Row {
        let index: Int
        let expectedToken: Int
        let itemToken: Int?
        let renderedTexts: [String]
    }
    struct Sample {
        let phase: String
        let presentationChecked: Bool
        let rows: [Row]
        let issues: [String]
        func requireAgreement() throws {
            if let first = issues.first { throw Failure(description: phase + ":" + first) }
        }
    }
    private static let titles: Set<String> = [
        "This Mac", "Places", "Locations", "Home", "Desktop", "Documents", "Downloads"
    ]
    private static func texts(in view: NSView) -> [String] {
        guard !view.isHidden, view.alphaValue > 0.001 else { return [] }
        if let text = view as? NSTextField { return text.stringValue.isEmpty ? [] : [text.stringValue] }
        return view.subviews.flatMap { texts(in: $0) }
    }
    static func sample(_ outline: NSOutlineView, expected: [Expected], phase: String,
                       settled: Bool) throws -> Sample {
        guard !expected.isEmpty, expected.count <= 32, outline.numberOfRows <= 32,
              Set(expected.map(\.token)).count == expected.count,
              Set(expected.map { ObjectIdentifier($0.item) }).count == expected.count,
              expected.allSatisfy({ titles.contains($0.title) }), let window = outline.window else {
            throw Failure(description: "generated-presentation-precondition")
        }
        var rows: [Row] = [], issues: [String] = []
        if outline.numberOfRows != expected.count { issues.append("row-count") }
        for (index, wanted) in expected.enumerated() where index < outline.numberOfRows {
            let actual = outline.item(atRow: index) as? NSObject
            if actual !== wanted.item || outline.row(forItem: wanted.item) != index {
                issues.append("item-at-row-\(index)")
            }
            let nativeRow = outline.rowView(atRow: index, makeIfNecessary: false)
            let cell = outline.view(atColumn: 0, row: index, makeIfNecessary: false)
            let labels = cell.map { texts(in: $0) } ?? []
            if settled {
                if labels != [wanted.title] { issues.append("rendered-text-\(index)") }
                if nativeRow?.isGroupRowStyle != wanted.group { issues.append("group-kind-\(index)") }
                let frame = outline.rect(ofRow: index)
                let bodyHeight = frame.height - outline.intercellSpacing.height
                if abs(bodyHeight - wanted.height) > 0.75 { issues.append("row-height-\(index)") }
                if nativeRow?.window !== window || cell?.window !== window { issues.append("unmounted-row-\(index)") }
            }
            rows.append(.init(index: index, expectedToken: wanted.token,
                itemToken: actual.flatMap { item in expected.first { $0.item === item }?.token },
                renderedTexts: labels.map { titles.contains($0) ? $0 : "<unexpected fixture text>" }))
        }
        return .init(phase: phase, presentationChecked: settled, rows: rows, issues: issues)
    }
}
#endif
