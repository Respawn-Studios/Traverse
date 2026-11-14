import Foundation

/// User-created path shortcuts, deliberately separate from access bookmarks.
/// Validation is lexical only: displaying/restoring a pin never probes its path.
public struct BrowserPin: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let url: URL
    public var label: String

    public init(id: UUID = UUID(), url: URL, label: String) {
        self.id = id; self.url = url; self.label = label
    }
}

public struct BrowserPinCollection: Codable, Equatable, Sendable {
    public static let maximumPins = 64
    public static let maximumLabelBytes = 256
    public static let maximumPathBytes = 4_096
    public static let maximumEncodedBytes = 512 * 1_024
    public private(set) var version: Int
    public private(set) var pins: [BrowserPin]
    public enum Failure: Error { case unsupportedVersion, invalidPin, duplicatePin, limitReached, missingPin, invalidPosition }

    public init(version: Int = 1, pins: [BrowserPin] = []) {
        self.version = version; self.pins = pins
    }

    public func validate() throws {
        guard version == 1 else { throw Failure.unsupportedVersion }
        guard pins.count <= Self.maximumPins else { throw Failure.limitReached }
        var ids: Set<UUID> = []
        var locations: Set<String> = []
        for pin in pins {
            try Self.validate(pin)
            guard ids.insert(pin.id).inserted, locations.insert(pin.url.standardizedFileURL.path).inserted else {
                throw Failure.duplicatePin
            }
        }
    }

    private static func validate(_ pin: BrowserPin) throws {
        let url = pin.url
        guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost",
              url.user == nil, url.password == nil, url.port == nil, url.query == nil, url.fragment == nil,
              url.path.hasPrefix("/"), !url.path.utf8.contains(0),
              url.path.utf8.count <= maximumPathBytes,
              !pin.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              pin.label.utf8.count <= maximumLabelBytes,
              !pin.label.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw Failure.invalidPin
        }
    }

    /// Repeated Add selects the existing shortcut without changing its label.
    @discardableResult
    public mutating func add(url: URL, label: String) throws -> UUID {
        try validate()
        let cleanedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        try Self.validate(BrowserPin(url: url, label: cleanedLabel))
        let normalized = URL(fileURLWithPath: url.standardizedFileURL.path, isDirectory: true)
        let candidate = BrowserPin(url: normalized, label: cleanedLabel)
        if let existing = pins.first(where: { $0.url.standardizedFileURL.path == normalized.path }) { return existing.id }
        guard pins.count < Self.maximumPins else { throw Failure.limitReached }
        pins.append(candidate)
        return candidate.id
    }

    public mutating func remove(id: UUID) throws {
        try validate()
        guard let index = pins.firstIndex(where: { $0.id == id }) else { throw Failure.missingPin }
        pins.remove(at: index)
    }

    public mutating func relabel(id: UUID, label: String) throws {
        try validate()
        guard let index = pins.firstIndex(where: { $0.id == id }) else { throw Failure.missingPin }
        let candidate = BrowserPin(id: id, url: pins[index].url, label: label.trimmingCharacters(in: .whitespacesAndNewlines))
        try Self.validate(candidate)
        pins[index] = candidate
    }

    public mutating func move(id: UUID, to index: Int) throws {
        try validate()
        guard pins.indices.contains(index) else { throw Failure.invalidPosition }
        guard let oldIndex = pins.firstIndex(where: { $0.id == id }) else { throw Failure.missingPin }
        let pin = pins.remove(at: oldIndex)
        pins.insert(pin, at: index)
    }

    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumEncodedBytes else { throw Failure.limitReached }
        let collection = try JSONDecoder().decode(Self.self, from: data)
        try collection.validate()
        return collection
    }

    public func encoded() throws -> Data {
        try validate()
        let data = try JSONEncoder().encode(self)
        guard data.count <= Self.maximumEncodedBytes else { throw Failure.limitReached }
        return data
    }
}
