import Foundation

public struct RememberedNameQuery: Sendable, Equatable {
    public enum Match: Sendable { case exact, prefixAndWords }
    public let text: String
    public let match: Match
    public let separatorTolerant: Bool
    public let fields: Set<RememberedNameField>
    public let pageSize: Int

    public init(text: String, match: Match = .prefixAndWords, separatorTolerant: Bool = true,
                fields: Set<RememberedNameField> = Set(RememberedNameField.allCases), pageSize: Int = 64) throws {
        guard (1...256).contains(pageSize) else { throw NameIndexFailure.invalidPageSize }
        guard !fields.isEmpty else { throw NameIndexFailure.invalidQuery }
        let capturedText: String
        do { capturedText = try AuthoredText.required(text, maximumBytes: 512) }
        catch { throw NameIndexFailure.invalidQuery }
        let key = RememberedNameNormalization.key(capturedText, separatorTolerant: separatorTolerant && match != .exact)
        let words = RememberedNameNormalization.words(key)
        guard !key.isEmpty, key.utf8.count <= 2_048, !words.isEmpty,
              words.count <= 16 else { throw NameIndexFailure.invalidQuery }
        self.text = capturedText; self.match = match; self.separatorTolerant = separatorTolerant
        self.fields = fields; self.pageSize = pageSize
    }
}

public enum RememberedNameMatchKind: Int, Sendable, Comparable {
    case literal = 0, normalized = 1, separatorEquivalent = 2, namePrefix = 3, wordPrefixes = 4
    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct RememberedNameMatchReason: Sendable, Equatable {
    public let field: RememberedNameField
    public let ordinal: Int
    public let value: String
    public let kind: RememberedNameMatchKind
    internal init(field: RememberedNameField, ordinal: Int, value: String, kind: RememberedNameMatchKind) {
        self.field = field; self.ordinal = ordinal; self.value = value; self.kind = kind
    }
}

public struct RememberedNameMatch: Sendable, Equatable {
    public let item: RememberedNamesSnapshot
    public let reasons: [RememberedNameMatchReason]
    internal init(item: RememberedNamesSnapshot, reasons: [RememberedNameMatchReason]) {
        self.item = item; self.reasons = reasons
    }
}

public enum RememberedNameCoverage: String, Sendable {
    case complete, candidateLimit, workLimit, timeLimit
}

/// A finite per-query work budget; not a maximum size of the remembered catalog.
public struct RememberedNameQueryBudget: Sendable {
    public let maximumPostings: Int
    public let maximumVMInstructions: Int
    public let maximumDuration: TimeInterval
    public init(maximumPostings: Int = 8_192, maximumVMInstructions: Int = 2_000_000,
                maximumDuration: TimeInterval = 1) {
        self.maximumPostings = min(max(1, maximumPostings), 32_768)
        self.maximumVMInstructions = min(max(1_000, maximumVMInstructions), 10_000_000)
        self.maximumDuration = maximumDuration.isFinite ? min(max(0.001, maximumDuration), 5) : 1
    }
}

public final class RememberedNameCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    public init() {}
    public func cancel() { lock.lock(); stopped = true; lock.unlock() }
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
}
