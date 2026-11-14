import FileMemory
import Foundation
import NaturalLanguage

/// Experimental B08 adapter. No ordinary route or download path. One dedicated
/// RelatedNameSession worker constructs, calls and unloads this native object.
final class AppleRelatedNameEncoder: RelatedNameEncoder {
    let model: RelatedNameModel
    private let embedding: NLContextualEmbedding
    private var loaded = false
    #if DEBUG
    private(set) var lastSequenceLength = 0
    private(set) var lastEnumerationCount = 0
    #endif
    init(cancelled: @Sendable () -> Bool) throws {
        guard !cancelled() else { throw RelatedNameFailure.stopped }
        guard let metadata = NLContextualEmbedding(language: .english), metadata.languages.contains(.english) else {
            throw RelatedNameFailure.unsupported
        }
        model = try RelatedNameModel(identifier: metadata.modelIdentifier, revision: metadata.revision,
            language: "en", dimension: metadata.dimension, maximumSequenceLength: metadata.maximumSequenceLength)
        guard metadata.hasAvailableAssets else { throw RelatedNameFailure.assetsMissing }
        embedding = metadata
        guard !cancelled() else { throw RelatedNameFailure.stopped }
        guard metadata.hasAvailableAssets else { throw RelatedNameFailure.assetsMissing }
        do { try metadata.load(); loaded = true }
        catch { metadata.unload(); throw RelatedNameFailure.unavailable }
        guard !cancelled() else { close(); throw RelatedNameFailure.stopped }
    }
    func vector(for text: String, cancelled: @Sendable () -> Bool) throws -> [Double] {
        guard loaded, !cancelled() else { throw RelatedNameFailure.stopped }
        guard !text.isEmpty, text.utf8.count <= 128 else { throw RelatedNameFailure.limited }
        guard embedding.modelIdentifier == model.identifier, embedding.revision == model.revision,
              embedding.dimension == model.dimension, embedding.maximumSequenceLength == model.maximumSequenceLength else {
            throw RelatedNameFailure.changed
        }
        return try autoreleasepool {
            let result: NLContextualEmbeddingResult
            do { result = try embedding.embeddingResult(for: text, language: .english) }
            catch { throw RelatedNameFailure.encoderFailed }
            guard !cancelled() else { throw RelatedNameFailure.stopped }
            guard result.language == .english, result.string == text, result.sequenceLength > 0,
                  result.sequenceLength < model.maximumSequenceLength else { throw RelatedNameFailure.limited }
            let captured = result.string
            #if DEBUG
            lastSequenceLength = result.sequenceLength; lastEnumerationCount = 0
            #endif
            var sum = [Double](repeating: 0, count: model.dimension), count = 0, invalid = false
            var previous = captured.startIndex
            result.enumerateTokenVectors(in: captured.startIndex..<captured.endIndex) { vector, range in
                // The native sequence can include boundary vectors with empty
                // character ranges. Keep every emitted vector equally weighted;
                // do not invent special-token filtering or omit observations.
                guard !cancelled(), range.lowerBound >= previous,
                      range.upperBound <= captured.endIndex, vector.count == model.dimension,
                      vector.allSatisfy(\.isFinite), count < model.maximumSequenceLength else { invalid = true; return false }
                for index in sum.indices { sum[index] += vector[index] }
                count += 1; previous = range.upperBound; return true
            }
            #if DEBUG
            lastEnumerationCount = count
            #endif
            guard !cancelled() else { throw RelatedNameFailure.stopped }
            guard !invalid, count == result.sequenceLength, count > 0, sum.allSatisfy(\.isFinite) else { throw RelatedNameFailure.invalidVector }
            return sum.map { $0 / Double(count) }
        }
    }
    func close() { if loaded { embedding.unload(); loaded = false } }
    deinit { close() }
}
