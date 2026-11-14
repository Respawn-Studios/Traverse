import Foundation

/// A bounded aid for user-authored report text, not an anonymity guarantee.
/// Capture projection separately omits unknown/native free-form fields.
public enum CrashReportRedaction {
    public static let maximumBytes = 512 << 10

    public static func hidePrivateDetails(in text: String, privatePrefixes: [String] = []) throws -> String {
        guard text.utf8.count <= maximumBytes, privatePrefixes.count <= 16,
              privatePrefixes.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 4096 }) else { throw CrashReportFailure.capacity }
        var result = text
        for prefix in privatePrefixes.sorted(by: { $0.count > $1.count }) {
            result = result.replacingOccurrences(of: prefix, with: "[private location]", options: .literal)
            guard result.utf8.count <= maximumBytes else { throw CrashReportFailure.capacity }
        }
        let patterns: [(String, String)] = [
            (#"(?i)\b(?:https?|sftp|smb|ftp|file)://[^\s<>\"']+"#, "[network or file address]"),
            (#"(?<![\p{L}\p{N}_])(?:~/(?:[^\s<>\"']+)?|/(?:[^\s<>\"']+))"#, "[private path]"),
            (#"(?i)\b[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,63}\b"#, "[email address]"),
            (#"\b(?:[0-9]{1,3}\.){3}[0-9]{1,3}\b"#, "[network address]")]
        for (pattern, replacement) in patterns {
            let expression = try NSRegularExpression(pattern: pattern)
            result = expression.stringByReplacingMatches(in: result,
                range: NSRange(result.startIndex..., in: result), withTemplate: replacement)
            guard result.utf8.count <= maximumBytes else { throw CrashReportFailure.capacity }
        }
        return result
    }
}
