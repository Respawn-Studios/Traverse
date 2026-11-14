import Combine
import Foundation

/// Prospective App-only boundary. Implement this on an existing bounded serial
/// worker using BrowserSnapshotFile; this packet adds no file-writing primitive.
/// `nil` expected bytes means a successfully observed absent document, not an
/// unobserved file. Load must finish successfully before a save is admitted.
protocol BrowserSidebarLayoutPersistence: Sendable {
    func load() async throws -> Data?
    func save(_ bytes: Data, replacing expectedBytes: Data?) async throws
}

/// Inject one owner per private profile, shared across its panes/windows.
/// The default initializer is deliberately memory-only for qualification.
@MainActor
final class BrowserSidebarLayoutController: ObservableObject {
    @Published private(set) var preferences = SidebarLayoutPreferences()
    @Published private(set) var status = ""
    @Published private(set) var canEdit: Bool
    private let persistence: (any BrowserSidebarLayoutPersistence)?
    private var expectedBytes: Data?
    private var started = false
    private var work: Task<Void, Never>?

    init(persistence: (any BrowserSidebarLayoutPersistence)? = nil) {
        self.persistence = persistence
        canEdit = persistence == nil
    }

    func restoreIfNeeded() {
        guard !started else { return }
        started = true
        guard let persistence else { return }
        canEdit = false
        work = Task { [self] in
            do {
                let bytes = try await persistence.load()
                let value = try bytes.map(SidebarLayoutPreferences.decode) ?? .init()
                expectedBytes = bytes
                preferences = value
                canEdit = true
                status = ""
            } catch {
                // Never replace an invalid/unreadable existing preference file.
                status = "Saved sidebar layout needs review. Its data was preserved."
                canEdit = false
            }
            work = nil
        }
    }

    @discardableResult
    func moveSection(_ section: SidebarLayoutSection, before target: SidebarLayoutSection?,
                     expectedRevision: UInt64) -> Bool {
        edit(expectedRevision: expectedRevision) {
            try $0.moveSection(section, before: target, expectedRevision: expectedRevision)
        }
    }

    @discardableResult
    func moveItem(_ item: SidebarLayoutItemKey, before target: SidebarLayoutItemKey?,
                  in section: SidebarLayoutSection, observed: [SidebarLayoutItemKey],
                  expectedRevision: UInt64) -> Bool {
        edit(expectedRevision: expectedRevision) {
            try $0.moveItem(item, before: target, in: section, observed: observed,
                            expectedRevision: expectedRevision)
        }
    }

    @discardableResult
    func reset(expectedRevision: UInt64) -> Bool {
        edit(expectedRevision: expectedRevision) { try $0.reset() }
    }

    @discardableResult
    func setCollapsed(_ value: Bool, for section: SidebarLayoutSection,
                      expectedRevision: UInt64) -> Bool {
        edit(expectedRevision: expectedRevision) { try $0.setCollapsed(value, for: section) }
    }

    @discardableResult
    private func edit(expectedRevision: UInt64,
                      _ mutation: (inout SidebarLayoutPreferences) throws -> Void) -> Bool {
        guard canEdit, work == nil, preferences.revision == expectedRevision else {
            status = "Sidebar layout changed or is still saving. Try again."
            return false
        }
        do {
            var next = preferences
            try mutation(&next)
            guard next != preferences else { return true }
            let bytes = try next.encoded()
            preferences = next
            guard let persistence else {
                status = "Sidebar layout is available for this session."
                return true
            }
            canEdit = false
            status = "Saving sidebar layout…"
            let previous = expectedBytes
            work = Task { [self] in
                do {
                    try await persistence.save(bytes, replacing: previous)
                    expectedBytes = bytes
                    status = "Sidebar layout saved."
                    canEdit = true
                } catch {
                    status = "Layout changes remain in this session. Saving could not be confirmed; further layout edits are paused."
                    canEdit = false
                }
                work = nil
            }
            return true
        } catch SidebarLayoutFailure.capacity {
            status = "This section has reached its saved layout limit. Existing positions were preserved."
        } catch SidebarLayoutFailure.revisionExhausted {
            status = "The sidebar layout revision limit was reached. Existing positions were preserved."
        } catch {
            status = "Sidebar layout changed. Try the move again."
        }
        return false
    }

    func flush() async -> String? {
        await work?.value
        return canEdit ? nil : status
    }
}
