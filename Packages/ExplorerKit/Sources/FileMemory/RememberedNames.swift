import Foundation

/// B07.0 indexes only these explicitly authored fields. This is not a filesystem
/// reader or a provenance detector: the trusted UI must capture a deliberate
/// user edit. No Codable, generic metadata dictionary, body or import constructor.
public struct AuthoredNames: Sendable, Equatable {
    public let nickname: String?
    public let alternateNames: [String]
    public let labels: [String]

    public init(nickname: String? = nil, alternateNames: [String] = [], labels: [String] = []) throws {
        guard alternateNames.count <= 16, labels.count <= 16 else { throw NameIndexFailure.invalidInput }
        let nickname = try nickname.flatMap { try AuthoredText.validate($0, maximumBytes: 512, allowEmpty: true) }
        let alternates = try alternateNames.map { try AuthoredText.required($0, maximumBytes: 512) }
        let labels = try labels.map { try AuthoredText.required($0, maximumBytes: 128) }
        guard nickname != nil || !alternates.isEmpty || !labels.isEmpty else { throw NameIndexFailure.emptyInput }
        self.nickname = nickname
        self.alternateNames = Self.unique(alternates)
        self.labels = Self.unique(labels)
        // Validate the complete projection now, before an edit obtains authority.
        _ = try NameProjection.fields(self)
    }

    private static func unique(_ strings: [String]) -> [String] {
        var seen = Set<String>()
        return strings.filter { seen.insert($0).inserted }
    }
}

public enum RememberedNameField: Int, Sendable, CaseIterable, Hashable {
    case nickname = 0, alternateName = 1, label = 2
}

public struct RememberedItemID: Sendable, Hashable {
    public let rawValue: UUID
    internal init(_ value: UUID) { rawValue = value }
}

/// An authored index snapshot carries no URL, FileEntry or availability proof.
/// The separate native resolveReference interface supplies current observations;
/// a name hit alone never becomes an actionable file result.
public enum RememberedReferenceState: Sendable, Equatable {
    case notResolved
}

public struct RememberedNamesSnapshot: Sendable, Equatable {
    public let id: RememberedItemID
    public let revision: UInt64
    public let names: AuthoredNames
    public let referenceState: RememberedReferenceState
    internal init(id: RememberedItemID, revision: UInt64, names: AuthoredNames) {
        self.id = id; self.revision = revision; self.names = names; referenceState = .notResolved
    }
}

public enum NameIndexFailure: Error, Sendable, Equatable {
    case invalidInput, emptyInput, projectionLimit, invalidQuery, invalidPageSize
    case closed, staleEdit, stalePage, missingRecord, pendingLimit, cancelled
    case resourceLimit, storage(Int32)
}

internal enum AuthoredText {
    static func validate(_ input: String, maximumBytes: Int, allowEmpty: Bool) throws -> String? {
        guard input.utf8.count <= maximumBytes,
              !input.unicodeScalars.contains(where: {
                  $0.properties.generalCategory == .control || $0.value == 0x2028 || $0.value == 0x2029
              }) else { throw NameIndexFailure.invalidInput }
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty {
            guard allowEmpty else { throw NameIndexFailure.emptyInput }
            return nil
        }
        return value
    }

    static func required(_ input: String, maximumBytes: Int) throws -> String {
        guard let value = try validate(input, maximumBytes: maximumBytes, allowEmpty: false) else {
            throw NameIndexFailure.emptyInput
        }
        return value
    }
}
