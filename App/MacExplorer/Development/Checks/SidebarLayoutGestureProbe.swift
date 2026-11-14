#if DEBUG
import AppKit

/// Observes the actual generated name/drop path without querying this process's
/// virtual accessibility rows. Only fixed fixture labels enter its receipt.
@MainActor final class SidebarLayoutGestureProbe {
    private weak var browser: BrowserViewController?
    private let home: URL
    private let tokens: [ObjectIdentifier: Int]
    private let identities: Set<ObjectIdentifier>
    private var records: [[String: Any]] = []
    private var settled: Task<Void, Never>?
    private var starts = 0, accepts = 0, ends = 0
    private var invalidFixture = false

    init(_ browser: BrowserViewController, root: URL) throws {
        home = root.appendingPathComponent("source/Sidebar Home", isDirectory: true)
        guard browser.isVerificationSession, BrowsingHome.url == home,
              browser.volumes.isEmpty, browser.rememberedFolders.isEmpty,
              browser.connectedLocationSnapshot.isEmpty,
              browser.pinsController.collection.pins.isEmpty,
              browser.remotePins.collection.pins.isEmpty else {
            throw SidebarRowPresentationProbe.Failure(description: "generated-name-scope")
        }
        let nodes = browser.sidebarRoots.flatMap { [$0] + ($0.children ?? []) }
        guard nodes.count == 7, Set(nodes.map(\.title)) == Set([
            "This Mac", "Places", "Locations", "Home", "Desktop", "Documents", "Downloads"
        ]) else { throw SidebarRowPresentationProbe.Failure(description: "generated-name-nodes") }
        let identifiers = Dictionary(uniqueKeysWithValues: nodes.enumerated().map { (ObjectIdentifier($0.element), $0.offset + 1) })
        tokens = identifiers
        identities = Set(identifiers.keys)
        self.browser = browser
        browser.sidebarLayout.drag.qualificationObserver = { [weak self] stage, accepted in
            self?.observe(stage, accepted: accepted)
        }
        capture("ready", settled: true)
    }

    private func observe(_ stage: String, accepted: Bool?) {
        if stage == "name-start" || stage == "outline-start" { starts += 1 }
        if stage == "accept-complete" && accepted == true { accepts += 1 }
        if stage == "session-end" { ends += 1 }
        capture(stage, settled: false, accepted: accepted)
        if stage == "session-end" {
            settled?.cancel()
            settled = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
                self?.capture("after-native-end", settled: true)
            }
        }
    }

    private func capture(_ phase: String, settled: Bool, accepted: Bool? = nil) {
        guard records.count < 48, let browser else { invalidFixture = true; return }
        let all = browser.sidebarRoots.flatMap { [$0] + ($0.children ?? []) }
        guard BrowsingHome.url == home, Set(all.map(ObjectIdentifier.init)) == identities else {
            invalidFixture = true
            records.append(["phase": phase, "fixtureIdentityChanged": true])
            return
        }
        let outline = browser.outline
        let visible = browser.sidebarRoots.flatMap { node in
            [node] + (outline.isItemExpanded(node) ? (node.children ?? []) : [])
        }
        let expected = visible.map { node in
            SidebarRowPresentationProbe.Expected(item: node, token: tokens[ObjectIdentifier(node)]!,
                title: node.title, group: node.group,
                height: node.group ? InterfaceMetrics.points(24) : outline.rowHeight)
        }
        do {
            let sample = try SidebarRowPresentationProbe.sample(outline, expected: expected, phase: phase, settled: settled)
            records.append(["phase": phase, "settled": settled, "accepted": accepted.map { $0 as Any } ?? NSNull(),
                "nativeSessionLive": browser.sidebarLayout.drag.isDragging,
                "layoutRevision": browser.sidebarLayoutOwner.preferences.revision,
                "modelLabels": visible.map(\.title),
                "issues": sample.issues,
                "rows": sample.rows.map { row in
                    ["index": row.index, "expectedToken": row.expectedToken,
                     "itemToken": row.itemToken.map { $0 as Any } ?? NSNull(), "renderedTexts": row.renderedTexts] as [String: Any]
                }])
        } catch {
            invalidFixture = true
            records.append(["phase": phase, "observationRefused": true])
        }
    }

    func finish() async -> [String: Any] {
        browser?.sidebarLayout.drag.qualificationObserver = nil
        if let settled { await settled.value }
        capture("review-finished", settled: true)
        let matchingEnds = records.filter { $0["phase"] as? String == "session-end" }
            .allSatisfy { $0["accepted"] as? Bool == true }
        let cleanups = records.filter { $0["phase"] as? String == "session-restored" }.count
        let settledMismatch = records.contains { record in
            record["settled"] as? Bool == true && !(record["issues"] as? [String] ?? []).isEmpty
        }
        return ["passed": !invalidFixture && !settledMismatch && starts > 0 && accepts > 0 && ends > 0
                    && matchingEnds && cleanups == ends,
            "realStarts": starts, "acceptedDrops": accepts, "nativeEnds": ends,
            "matchingNativeEnds": matchingEnds, "nativeEndCleanups": cleanups,
            "fixtureIdentityChanged": invalidFixture, "settledMismatch": settledMismatch,
            "samples": records, "externalAccessibility": "NOT EXERCISED",
            "fileOperations": 0, "personalProfileAccess": false]
    }
}
#endif
