import Foundation

extension SSHConfiguration {
    static func parse(_ data: Data) throws -> [Line] {
        guard !data.contains(0), let text = String(data: data, encoding: .utf8), Data(text.utf8) == data else { throw SSHConfigurationFailure.encoding }
        let raw = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard raw.count <= 8192 else { throw SSHConfigurationFailure.capacity }
        var result: [Line] = []
        for (index, slice) in raw.enumerated() {
            if Task.isCancelled { throw SSHConfigurationFailure.cancelled }
            var line = String(slice)
            if line.hasSuffix("\r") { line.removeLast() }
            guard line.utf8.count <= 4096 else { throw SSHConfigurationFailure.capacity }
            let tokens = try lex(line)
            guard let key = tokens.first else { continue }
            guard tokens.count > 1, key.utf8.count <= 64,
                  key.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) }) else {
                throw SSHConfigurationFailure.syntax
            }
            result.append(.init(number: index + 1, keyword: key.lowercased(), arguments: Array(tokens.dropFirst())))
        }
        return result
    }

    private static func lex(_ line: String) throws -> [String] {
        var tokens: [String] = [], word = "", quote: Unicode.Scalar?, escaped = false, began = false, assignment = false
        func finish() throws {
            if began { tokens.append(word); word = ""; began = false }
            guard tokens.count <= 64 else { throw SSHConfigurationFailure.capacity }
        }
        for scalar in line.unicodeScalars {
            if escaped { word.unicodeScalars.append(scalar); began = true; escaped = false; continue }
            if scalar == "\\" { escaped = true; began = true; continue }
            if let current = quote {
                if scalar == current { quote = nil } else { word.unicodeScalars.append(scalar) }
                began = true; continue
            }
            if scalar == "\"" || scalar == "'" { quote = scalar; began = true; continue }
            if scalar == "#" { break }
            if scalar == "=", !assignment, tokens.isEmpty || tokens.count == 1 && !began {
                guard began || tokens.count == 1 else { throw SSHConfigurationFailure.syntax }
                try finish(); assignment = true; continue
            }
            if scalar == " " || scalar == "\t" {
                try finish(); continue
            }
            guard !CharacterSet.controlCharacters.contains(scalar) else { throw SSHConfigurationFailure.syntax }
            word.unicodeScalars.append(scalar); began = true
        }
        guard quote == nil, !escaped else { throw SSHConfigurationFailure.syntax }
        try finish(); return tokens
    }
}
