import Foundation
import Observation

/// Presentation state only. A path is user intent; the authenticated action
/// owner must resolve it again before changing anything on the server.
@MainActor @Observable final class RemoteMoveDestinationModel {
    enum Operation {
        case move, copy, duplicate

        var title: String {
            switch self { case .move: "Move To"; case .copy: "Copy To"; case .duplicate: "Duplicate" }
        }
        var buttonTitle: String {
            switch self { case .move: "Move"; case .copy: "Copy"; case .duplicate: "Duplicate" }
        }
    }
    struct Suggestion: Identifiable {
        let id = UUID()
        let title: String
        let path: String
    }

    let name: String
    let isFolder: Bool
    let server: String
    let currentFolder: String
    let rootTitle: String
    let destinationNotice: String
    let suggestions: [Suggestion]
    let operation: Operation
    var path: String
    var destinationName: String
    private let validate: (String) -> String?
    private let validateCopy: ((String, String) -> String?)?

    init(name: String, isFolder: Bool = false, server: String, currentFolder: String,
         suggestions: [Suggestion] = [], rootTitle: String = "Share Root", initialPath: String? = nil,
         destinationNotice: String = "The name stays the same. Existing items are kept.",
         operation: Operation = .move, initialName: String? = nil,
         validateCopy: ((String, String) -> String?)? = nil,
         validate: @escaping (String) -> String?) {
        self.name = name; self.isFolder = isFolder; self.server = server; self.currentFolder = currentFolder
        self.path = initialPath ?? currentFolder; self.suggestions = suggestions
        self.rootTitle = rootTitle
        self.destinationNotice = destinationNotice
        self.operation = operation; self.destinationName = initialName ?? name
        self.validateCopy = validateCopy
        self.validate = validate
    }

    var isCopy: Bool { operation != .move }
    var issue: String? {
        if let issue = validate(path) { return issue }
        guard isCopy else { return nil }
        guard let validateCopy else { return "Copy is unavailable for this selection." }
        return validateCopy(path, destinationName)
    }
    var canMove: Bool { issue == nil }
}
