import Foundation
import ExplorerCore

/// Stable UI identities only. A sidebar position never identifies a source
/// for file operations, supplies access, or starts a connection.
public enum SidebarLayoutSection: String, CaseIterable, Codable, Sendable {
    case computer, places, pinnedFolders, pinnedConnections, servers, locations, rememberedFolders
    public var canCollapse: Bool { self != .computer }
    public var hasStoredRowOrder: Bool {
        self == .places || self == .servers || self == .locations || self == .rememberedFolders
    }
}

public enum SidebarPlace: String, CaseIterable, Sendable {
    case home, desktop, documents, downloads
}

public struct SidebarLayoutItemKey: Hashable, Codable, Sendable {
    public let rawValue: String
    private init(_ value: String) { rawValue = value }
    public static func place(_ value: SidebarPlace) -> Self { .init("place:" + value.rawValue) }
    public static func volume(_ id: UUID) -> Self { .init("volume:" + id.uuidString.lowercased()) }
    public static func rememberedFolder(_ id: UUID) -> Self { .init("grant:" + id.uuidString.lowercased()) }
    public static func server(_ kind: WorkspaceConnectionBookmark.Kind, id: UUID) -> Self {
        .init("server:" + kind.rawValue + ":" + id.uuidString.lowercased())
    }
    public init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        guard Self.section(for: value) != nil else { throw SidebarLayoutFailure.invalid }
        rawValue = value
    }
    public func encode(to encoder: any Encoder) throws {
        guard Self.section(for: rawValue) != nil else { throw SidebarLayoutFailure.invalid }
        var container = encoder.singleValueContainer(); try container.encode(rawValue)
    }
    fileprivate var section: SidebarLayoutSection { Self.section(for: rawValue)! }
    private static func section(for value: String) -> SidebarLayoutSection? {
        if value.hasPrefix("place:"), SidebarPlace(rawValue: String(value.dropFirst(6))) != nil { return .places }
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        if parts.count == 3, parts[0] == "server",
           WorkspaceConnectionBookmark.Kind(rawValue: String(parts[1])) != nil,
           let id = UUID(uuidString: String(parts[2])), id.uuidString.lowercased() == parts[2] {
            return .servers
        }
        for (prefix, section) in [("volume:", SidebarLayoutSection.locations), ("grant:", .rememberedFolders)] {
            if value.hasPrefix(prefix) {
                let tail = String(value.dropFirst(prefix.count))
                guard let id = UUID(uuidString: tail), id.uuidString.lowercased() == tail else { return nil }
                return section
            }
        }
        return nil
    }
}

public enum SidebarLayoutFailure: Error, Equatable {
    case invalid, unsupported, capacity, staleItem, staleRevision, revisionExhausted
}

/// One small layout record, separate from folder pins, connection pins and
/// access grants. Unknown/unmounted rows retain their relative positions;
/// rendering merges only the currently observed, typed row identities.
public struct SidebarLayoutPreferences: Equatable, Sendable, CustomStringConvertible {
    public static let maximumEncodedBytes = 64 << 10
    public static let maximumStoredRowsPerSection = 128
    public static let maximumObservedRows = 512
    public private(set) var revision: UInt64 = 0
    public private(set) var sectionOrder = SidebarLayoutSection.allCases
    public private(set) var collapsed: Set<SidebarLayoutSection> = []
    private var rows: [SidebarLayoutSection: [SidebarLayoutItemKey]] = [:]
    public init() {}
    public var description: String { "<sidebar layout>" }
    func hasSameOrdering(as other: Self) -> Bool {
        sectionOrder == other.sectionOrder && rows == other.rows
    }

    public func orderedSections(_ visible: [SidebarLayoutSection]) throws -> [SidebarLayoutSection] {
        guard Set(visible).count == visible.count else { throw SidebarLayoutFailure.invalid }
        let shown = Set(visible)
        return sectionOrder.filter { shown.contains($0) }
    }

    public func orderedItems(_ observed: [SidebarLayoutItemKey], in section: SidebarLayoutSection) throws -> [SidebarLayoutItemKey] {
        try Self.validateObserved(observed, in: section)
        let present = Set(observed), stored = rows[section] ?? [], saved = Set(stored)
        return stored.filter { present.contains($0) } + observed.filter { !saved.contains($0) }
    }

    public mutating func moveSection(_ section: SidebarLayoutSection, before target: SidebarLayoutSection?, expectedRevision: UInt64) throws {
        guard revision == expectedRevision else { throw SidebarLayoutFailure.staleRevision }
        if section == target { return }
        let next = try Self.moved(section, before: target, in: sectionOrder)
        guard next != sectionOrder else { return }
        try advance(); sectionOrder = next
    }

    public mutating func setCollapsed(_ value: Bool, for section: SidebarLayoutSection) throws {
        guard section.canCollapse else { throw SidebarLayoutFailure.unsupported }
        guard collapsed.contains(section) != value else { return }
        try advance()
        if value { collapsed.insert(section) } else { collapsed.remove(section) }
    }

    public mutating func moveItem(_ item: SidebarLayoutItemKey, before target: SidebarLayoutItemKey?,
                                 in section: SidebarLayoutSection, observed: [SidebarLayoutItemKey], expectedRevision: UInt64) throws {
        guard revision == expectedRevision else { throw SidebarLayoutFailure.staleRevision }
        try Self.validateObserved(observed, in: section)
        guard observed.contains(item), target.map(observed.contains) ?? true else { throw SidebarLayoutFailure.staleItem }
        if item == target { return }
        let visible = try orderedItems(observed, in: section)
        guard try Self.moved(item, before: target, in: visible) != visible else { return }
        let saved = rows[section] ?? [], known = Set(saved)
        let full = saved + observed.filter { !known.contains($0) }
        guard full.count <= Self.maximumStoredRowsPerSection else { throw SidebarLayoutFailure.capacity }
        let next = try Self.moved(item, before: target, in: full)
        guard next != full else { return }
        try advance(); rows[section] = next
    }

    /// Existing pin collections and live-server arrays use this same positional
    /// calculation, while retaining their own existing persistence/ownership.
    public static func moved<T: Hashable>(_ item: T, before target: T?, in values: [T]) throws -> [T] {
        guard values.count <= maximumObservedRows, Set(values).count == values.count else { throw SidebarLayoutFailure.invalid }
        guard values.contains(item), target.map(values.contains) ?? true else { throw SidebarLayoutFailure.staleItem }
        if item == target { return values }
        var next = values.filter { $0 != item }
        if let target, let index = next.firstIndex(of: target) { next.insert(item, at: index) }
        else { next.append(item) }
        return next
    }

    public mutating func reset() throws {
        let fresh = Self()
        guard sectionOrder != fresh.sectionOrder || collapsed != fresh.collapsed || !rows.isEmpty else { return }
        try advance(); sectionOrder = fresh.sectionOrder; collapsed = []; rows = [:]
    }

    public func encoded() throws -> Data {
        try validate()
        let groups = SidebarLayoutSection.allCases.compactMap { section in
            rows[section].map { Group(section: section, items: $0) }
        }
        // Existing layouts keep their canonical v1 bytes until a saved server
        // is actually reordered. Older apps preserve/refuse v2 rather than
        // interpreting these new keys or overwriting an unreadable layout.
        let version = rows[.servers] == nil ? 1 : 2
        let data = try Self.encoder.encode(Wire(version: version, revision: String(revision), sections: sectionOrder,
            collapsed: SidebarLayoutSection.allCases.filter { collapsed.contains($0) }, groups: groups))
        guard data.count <= Self.maximumEncodedBytes else { throw SidebarLayoutFailure.capacity }
        return data
    }

    public static func decode(_ data: Data) throws -> Self {
        guard !data.isEmpty, data.count <= maximumEncodedBytes else { throw SidebarLayoutFailure.capacity }
        let wire = try JSONDecoder().decode(Wire.self, from: data)
        guard [1, 2].contains(wire.version) else { throw SidebarLayoutFailure.unsupported }
        guard let revision = UInt64(wire.revision), String(revision) == wire.revision,
              Set(wire.collapsed).count == wire.collapsed.count,
              Set(wire.groups.map(\.section)).count == wire.groups.count else { throw SidebarLayoutFailure.invalid }
        var value = Self(); value.revision = revision; value.sectionOrder = wire.sections
        value.collapsed = Set(wire.collapsed); value.rows = Dictionary(uniqueKeysWithValues: wire.groups.map { ($0.section, $0.items) })
        try value.validate()
        guard try value.encoded() == data else { throw SidebarLayoutFailure.invalid }
        return value
    }

    private static func validateObserved(_ observed: [SidebarLayoutItemKey], in section: SidebarLayoutSection) throws {
        guard section.hasStoredRowOrder else { throw SidebarLayoutFailure.unsupported }
        guard observed.count <= maximumObservedRows, Set(observed).count == observed.count,
              observed.allSatisfy({ $0.section == section }) else { throw SidebarLayoutFailure.invalid }
    }
    private func validate() throws {
        guard sectionOrder.count == SidebarLayoutSection.allCases.count,
              Set(sectionOrder) == Set(SidebarLayoutSection.allCases),
              collapsed.allSatisfy(\.canCollapse) else { throw SidebarLayoutFailure.invalid }
        for (section, values) in rows {
            try Self.validateObserved(values, in: section)
            guard !values.isEmpty, values.count <= Self.maximumStoredRowsPerSection else { throw SidebarLayoutFailure.capacity }
        }
    }
    private mutating func advance() throws {
        guard revision != .max else { throw SidebarLayoutFailure.revisionExhausted }
        revision += 1
    }
    private static var encoder: JSONEncoder {
        let value = JSONEncoder(); value.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]; return value
    }
    private struct Group: Codable { let section: SidebarLayoutSection; let items: [SidebarLayoutItemKey] }
    private struct Wire: Codable {
        let version: Int, revision: String
        let sections: [SidebarLayoutSection], collapsed: [SidebarLayoutSection], groups: [Group]
    }
}
