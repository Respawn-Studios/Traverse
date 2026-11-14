import Foundation
import Testing
@testable import ExplorerCore

@Suite struct WorkspaceProfileMemoryTests {
    private let key = String(repeating: "a", count: 64)
    private func snapshot(_ name: String = "Workspace") -> PaneWorkspaceSnapshot {
        let pane = UUID(), folder = URL(fileURLWithPath: "/generated/" + name)
        return .init(layout: .init(paneID: pane), activePane: pane,
            panes: [.init(id: pane, tabs: .init(tabs: [.init(location: .init(kind: .directory, url: folder),
                filter: "private filter", selection: [folder.appendingPathComponent("Selected.txt")], scrollOffset: 42)]), viewMode: DirectoryViewMode.details.rawValue)])
    }
    @Test func workingStateIsNormalizedWithoutChangingTheTemplate() throws {
        let original = snapshot(), id = UUID()
        var memory = WorkspaceProfileMemory()
        let value = try memory.enable(id, templateKey: key, includesFilters: false, snapshot: original)
        #expect(value.snapshot.panes[0].tabs.tabs[0].filter.isEmpty)
        #expect(value.snapshot.panes[0].tabs.tabs[0].selection.isEmpty)
        #expect(value.snapshot.panes[0].tabs.tabs[0].scrollOffset == 0)
        #expect(original.panes[0].tabs.tabs[0].selection.count == 1)
        let next = try memory.save(id, consent: value.consent, expected: value.revision, templateKey: key, snapshot: snapshot("Later"))
        #expect(next.revision != value.revision && next.consent == value.consent)
        #expect(next.snapshot != value.snapshot)
        #expect(try JSONDecoder().decode(WorkspaceProfileMemory.self, from: JSONEncoder().encode(memory)) == memory)
    }
    @Test func explicitFilterChoiceIsRetainedAndSelectionStillClears() throws {
        var memory = WorkspaceProfileMemory()
        let value = try memory.enable(UUID(), templateKey: key, includesFilters: true, snapshot: snapshot())
        #expect(value.snapshot.panes[0].tabs.tabs[0].filter == "private filter")
        #expect(value.snapshot.panes[0].tabs.tabs[0].selection.isEmpty)
    }
    @Test func disabledAndReenabledConsentCannotBeResurrected() throws {
        let id = UUID(); var memory = WorkspaceProfileMemory()
        let old = try memory.enable(id, templateKey: key, includesFilters: false, snapshot: snapshot())
        try memory.disable(id, consent: old.consent)
        #expect(throws: WorkspaceProfileMemory.Failure.missing) {
            try memory.save(id, consent: old.consent, expected: old.revision, templateKey: key, snapshot: snapshot())
        }
        let fresh = try memory.enable(id, templateKey: key, includesFilters: false, snapshot: snapshot())
        #expect(fresh.consent != old.consent)
        #expect(throws: WorkspaceProfileMemory.Failure.stale) { try memory.disable(id, consent: old.consent) }
        #expect(throws: WorkspaceProfileMemory.Failure.stale) {
            try memory.save(id, consent: old.consent, expected: fresh.revision, templateKey: key, snapshot: snapshot())
        }
    }
    @Test func revisionAndTemplateChangesRefuseWithoutMutation() throws {
        let id = UUID(); var memory = WorkspaceProfileMemory()
        let value = try memory.enable(id, templateKey: key, includesFilters: false, snapshot: snapshot())
        let original = memory
        for (revision, changedKey) in [(UUID(), key), (value.revision, String(repeating: "b", count: 64))] {
            #expect(throws: WorkspaceProfileMemory.Failure.stale) {
                try memory.save(id, consent: value.consent, expected: revision, templateKey: changedKey, snapshot: snapshot())
            }
            #expect(memory == original)
        }
        #expect(throws: WorkspaceProfileMemory.Failure.alreadyEnabled) {
            try memory.enable(id, templateKey: key, includesFilters: false, snapshot: snapshot())
        }
    }
    @Test func finiteCatalogAndStrictDocumentContract() throws {
        var memory = WorkspaceProfileMemory()
        #expect(throws: WorkspaceProfileMemory.Failure.invalidDocument) {
            try memory.enable(UUID(), templateKey: "bad", includesFilters: false, snapshot: snapshot())
        }
        #expect(memory.records.isEmpty)
        for _ in 0..<WorkspaceLaunchProfiles.maximumProfiles { try memory.enable(UUID(), templateKey: key, includesFilters: false, snapshot: snapshot()) }
        #expect(throws: WorkspaceProfileMemory.Failure.limitReached) {
            try memory.enable(UUID(), templateKey: key, includesFilters: false, snapshot: snapshot())
        }
        let bytes = try JSONEncoder().encode(memory)
        for field in ["version", "owner"] {
            var changed = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
            changed[field] = field == "version" ? 99 : "unknown"
            let decoded = try JSONDecoder().decode(WorkspaceProfileMemory.self, from: JSONSerialization.data(withJSONObject: changed))
            #expect(throws: WorkspaceProfileMemory.Failure.invalidDocument) { try decoded.validate() }
        }
    }
}
