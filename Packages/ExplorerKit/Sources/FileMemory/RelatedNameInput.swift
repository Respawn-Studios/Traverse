import Foundation

public enum RelatedNameFailure: Error, Equatable, Sendable {
    case invalidInput, limited, unavailable, assetsMissing, unsupported
    case invalidVector, changed, stopped, encoderFailed
}

/// This projection accepts only deliberately authored B07 fields. It carries no
/// file reference, path or filesystem capability. A production caller must also
/// retain the B07 publication/use lease until the actual consumer drains.
public struct RelatedNameInput: Sendable {
    public struct Row: Sendable {
        public let id: RememberedItemID
        public let revision: UInt64
        public let field: RememberedNameField
        public let ordinal: Int
        public let text: String
    }
    public let scope: UUID
    public let epoch: UInt64
    public let policyVersion: UInt32
    public let rows: [Row]
    public let bytes: Int
    public init(items: [RememberedNamesSnapshot], scope: UUID, epoch: UInt64, policyVersion: UInt32 = 1) throws {
        guard policyVersion == 1, items.count <= 512, Set(items.map(\.id)).count == items.count else { throw RelatedNameFailure.limited }
        var rows: [Row] = [], bytes = 0
        for item in items {
            guard item.revision > 0 else { throw RelatedNameFailure.invalidInput }
            let fields: [(RememberedNameField, [String])] = [
                (.nickname, item.names.nickname.map { [$0] } ?? []),
                (.alternateName, item.names.alternateNames), (.label, item.names.labels)]
            for (field, texts) in fields {
                for (ordinal, text) in texts.enumerated() {
                    guard rows.count < 512, text.utf8.count <= 128, bytes + text.utf8.count <= 65_536 else {
                        throw RelatedNameFailure.limited
                    }
                    rows.append(Row(id: item.id, revision: item.revision, field: field, ordinal: ordinal, text: text))
                    bytes += text.utf8.count
                }
            }
        }
        guard !rows.isEmpty else { throw RelatedNameFailure.invalidInput }
        self.scope = scope; self.epoch = epoch; self.policyVersion = policyVersion; self.rows = rows; self.bytes = bytes
    }
}

public struct RelatedNameQuery: Sendable {
    public let text: String
    public let threshold: Double
    public init(_ text: String, threshold: Double) throws {
        guard threshold.isFinite, (-1...1).contains(threshold),
              let captured = try? AuthoredText.required(text, maximumBytes: 128) else { throw RelatedNameFailure.invalidInput }
        self.text = captured; self.threshold = threshold
    }
}

public struct RelatedNameModel: Sendable, Equatable {
    public let identifier: String
    public let revision: Int
    public let language: String
    public let dimension: Int
    public let maximumSequenceLength: Int
    public let poolingVersion = 1
    public init(identifier: String, revision: Int, language: String, dimension: Int, maximumSequenceLength: Int) throws {
        guard !identifier.isEmpty, identifier.utf8.count <= 256, revision > 0, language == "en",
              (1...2_048).contains(dimension), (8...2_048).contains(maximumSequenceLength) else { throw RelatedNameFailure.unsupported }
        self.identifier = identifier; self.revision = revision; self.language = language
        self.dimension = dimension; self.maximumSequenceLength = maximumSequenceLength
    }
}

/// Created, called and closed by one dedicated worker. The factory crosses the
/// thread seam; the non-Sendable encoder never does. Apple objects stay native.
public protocol RelatedNameEncoder: AnyObject {
    var model: RelatedNameModel { get }
    func vector(for text: String, cancelled: @Sendable () -> Bool) throws -> [Double]
    func close()
}

public struct RelatedNameCandidate: Sendable, Equatable {
    public let id: RememberedItemID
    public let revision: UInt64
    public let field: RememberedNameField
    public let ordinal: Int
    public let score: Double
}
