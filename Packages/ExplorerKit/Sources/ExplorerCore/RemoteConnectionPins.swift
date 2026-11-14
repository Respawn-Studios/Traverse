import Foundation

/// Explicit saved-target shortcuts, separate from local pins and access grants.
public struct RemoteConnectionPin: Codable, Equatable, Identifiable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let id: UUID
    public let target: WorkspaceConnectionBookmark
    public var label: String
    public var description: String { "<remote connection pin>" }
    public var debugDescription: String { description }
    public init(id: UUID = UUID(), target: WorkspaceConnectionBookmark, label: String) {
        self.id = id; self.target = target; self.label = label
    }
}
public struct RemoteConnectionPinCollection: Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public static let maximumPins = 64, maximumLabelBytes = 256, maximumEncodedBytes = 512 * 1024
    public enum Failure: Error { case unsupportedVersion, invalidPin, duplicatePin, limitReached, missingPin, invalidPosition }
    public private(set) var version: Int
    public private(set) var pins: [RemoteConnectionPin]
    public var description: String { "<remote connection pins>" }
    public var debugDescription: String { description }
    public init(version: Int = 1, pins: [RemoteConnectionPin] = []) { self.version = version; self.pins = pins }
    private static func validLabel(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.utf8.count <= maximumLabelBytes
            && !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }
    private static func sameTarget(_ a: WorkspaceConnectionBookmark, _ b: WorkspaceConnectionBookmark) -> Bool {
        a.kind == b.kind && a.serverID == b.serverID && a.binding == b.binding
            && a.relativeToHome == b.relativeToHome && a.components == b.components
    }
    public func validate() throws {
        guard version == 1 else { throw Failure.unsupportedVersion }
        guard pins.count <= Self.maximumPins else { throw Failure.limitReached }
        var ids = Set<UUID>()
        for (index, pin) in pins.enumerated() {
            try pin.target.validate()
            guard Self.validLabel(pin.label) else { throw Failure.invalidPin }
            guard ids.insert(pin.id).inserted,
                  !pins.prefix(index).contains(where: { Self.sameTarget($0.target, pin.target) }) else { throw Failure.duplicatePin }
        }
    }
    @discardableResult public mutating func add(target: WorkspaceConnectionBookmark, label: String) throws -> UUID {
        try validate(); try target.validate()
        let label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.validLabel(label) else { throw Failure.invalidPin }
        if let old = pins.first(where: { Self.sameTarget($0.target, target) }) { return old.id }
        guard pins.count < Self.maximumPins else { throw Failure.limitReached }
        let value = RemoteConnectionPin(target: target, label: label); pins.append(value); return value.id
    }
    public mutating func remove(id: UUID) throws {
        try validate(); guard let index = pins.firstIndex(where: { $0.id == id }) else { throw Failure.missingPin }; pins.remove(at: index)
    }
    public mutating func relabel(id: UUID, label: String) throws {
        try validate(); guard let index = pins.firstIndex(where: { $0.id == id }) else { throw Failure.missingPin }
        let label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.validLabel(label) else { throw Failure.invalidPin }; pins[index].label = label
    }
    public mutating func move(id: UUID, to position: Int) throws {
        try validate(); guard pins.indices.contains(position) else { throw Failure.invalidPosition }
        guard let index = pins.firstIndex(where: { $0.id == id }) else { throw Failure.missingPin }
        let value = pins.remove(at: index); pins.insert(value, at: position)
    }
    public func encoded() throws -> Data {
        try validate(); let data = try JSONEncoder().encode(self)
        guard data.count <= Self.maximumEncodedBytes else { throw Failure.limitReached }; return data
    }
    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumEncodedBytes else { throw Failure.limitReached }
        let value = try JSONDecoder().decode(Self.self, from: data); try value.validate(); return value
    }
}
