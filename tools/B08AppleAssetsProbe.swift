import Foundation
import NaturalLanguage

// Generated qualification only. Construction selects metadata and defers model
// loading; no inference, load or asset-request API exists in this probe.
let result: [String: Any]
if let metadata = NLContextualEmbedding(language: .english) {
    result = ["available": metadata.hasAvailableAssets,
              "identifier": metadata.modelIdentifier, "revision": metadata.revision,
              "dimension": metadata.dimension, "maximumSequenceLength": metadata.maximumSequenceLength,
              "languages": metadata.languages.map(\.rawValue),
              "runtime": ProcessInfo.processInfo.operatingSystemVersionString,
              "loaded": false, "requestedAssets": false, "inference": false]
} else {
    result = ["available": false, "state": "unsupported", "loaded": false,
              "requestedAssets": false, "inference": false]
}
FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]))
