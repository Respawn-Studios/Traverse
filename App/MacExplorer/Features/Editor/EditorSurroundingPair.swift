import Foundation

/// Explicit buffer editing, not language detection or escaping. The selected
/// UTF-16 text stays selected and unchanged inside the chosen delimiters.
enum EditorSurroundingPair: Int, CaseIterable, Equatable, Sendable {
    case doubleQuotes, singleQuotes, parentheses, squareBrackets, braces, backticks

    var title: String {
        switch self {
        case .doubleQuotes: "Double Quotes"
        case .singleQuotes: "Single Quotes"
        case .parentheses: "Parentheses"
        case .squareBrackets: "Square Brackets"
        case .braces: "Braces"
        case .backticks: "Backticks"
        }
    }
    var open: String {
        switch self {
        case .doubleQuotes: "\""
        case .singleQuotes: "'"
        case .parentheses: "("
        case .squareBrackets: "["
        case .braces: "{"
        case .backticks: "`"
        }
    }
    var close: String {
        switch self {
        case .parentheses: ")"
        case .squareBrackets: "]"
        case .braces: "}"
        default: open
        }
    }
}
