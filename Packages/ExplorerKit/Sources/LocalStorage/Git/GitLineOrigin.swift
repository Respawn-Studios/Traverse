import FileOperations
import Foundation

public struct GitLineOrigin: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let commit: GitCommitSummary
    public let author: String
    public let path: GitSnapshotPath
    public let line: Int
    public let isBoundary: Bool

    public var description: String { "<Git line origin>" }
    public var debugDescription: String { description }
}

extension GitReadView {
    func lineOrigin(of member: GitSnapshotMember, at commit: GitObjectID, line: Int) throws -> GitLineOrigin {
        guard member.isTextCandidate, let path = member.path.literalArgument,
              (1...TextDocumentValue.maximumLines).contains(line) else { throw GitInspectionFailure.lineUnavailable }
        let version = try fileVersion(of: member.path, at: .object(commit))
        guard version.state == .member(member) else { throw GitInspectionFailure.changed }
        return try lineOrigin(path: path, commit: version.commit, line: line, text: text(member))
    }

    func headLineOrigin(of path: GitSnapshotPath, matchingLine: (TextDocumentValue) throws -> Int) throws
        -> (version: GitFileVersion, line: Int, origin: GitLineOrigin)? {
        let version = try fileVersion(of: path, at: .head)
        guard case .member(let member) = version.state, member.isTextCandidate,
              let argument = path.literalArgument else { return nil }
        let source = try text(member)
        let line = try matchingLine(source)
        return (version, line, try lineOrigin(path: argument, commit: version.commit, line: line, text: source))
    }

    private func lineOrigin(path: String, commit: GitObjectID, line: Int, text: TextDocumentValue) throws -> GitLineOrigin {
        // The editor has a virtual empty row after the final newline.
        let fileLines = text.text.isEmpty ? 0 : text.lines - (text.text.hasSuffix("\n") ? 1 : 0)
        guard line > 0, line <= fileLines else { throw GitInspectionFailure.lineUnavailable }

        // Incremental blame supplies the origin and path without echoing
        // any source text. This isolated view has no working tree or config.
        let output = try run(["-c", "mailmap.blob=", "-c", "mailmap.file=/dev/null", "blame",
                              "--incremental", "--no-textconv", "--encoding=UTF-8", "-L", "\(line),\(line)",
                              commit.hex, "--", path], maximumBytes: 32 << 10, timeout: 8)
        return try readLineOrigin(output, selectedLine: line)
    }

    private func readLineOrigin(_ output: Data, selectedLine: Int) throws -> GitLineOrigin {
        let records = output.split(separator: 10, omittingEmptySubsequences: false)
        guard records.count >= 3, records.last?.isEmpty == true,
              let filename = records.dropLast().last, filename.starts(with: "filename ".utf8),
              let path = GitSnapshotPath(quotedByGit: filename.dropFirst(9)) else { throw GitInspectionFailure.invalidOutput }
        let header = records[0].split(separator: 32)
        func number(_ bytes: Data) -> Int? {
            guard !bytes.isEmpty, bytes.allSatisfy({ (48...57).contains($0) }) else { return nil }
            return Int(String(decoding: bytes, as: UTF8.self))
        }
        guard header.count == 4, let original = number(header[1]), original > 0,
              number(header[2]) == selectedLine, header[3] == Data([49]) else { throw GitInspectionFailure.invalidOutput }

        let metadata = records.dropFirst().dropLast(2)
        func field(_ name: String) throws -> Data {
            let prefix = Data((name + " ").utf8)
            let found = metadata.filter { $0.starts(with: prefix) }
            guard found.count == 1, let value = found.first else { throw GitInspectionFailure.invalidOutput }
            return value.dropFirst(prefix.count)
        }
        let commit = try commitSummary(object: header[0], date: field("author-time"), subject: field("summary"))
        let author = String(decoding: try field("author").prefix(256), as: UTF8.self)
        return .init(commit: commit, author: author, path: path, line: original,
                     isBoundary: metadata.contains(Data("boundary".utf8)))
    }
}

private extension GitSnapshotPath {
    init?(quotedByGit bytes: Data) {
        guard bytes.first == 34 else { self.init(bytes); return }
        guard bytes.count >= 2, bytes.last == 34 else { return nil }
        var input = bytes.dropFirst().dropLast().makeIterator()
        var decoded = Data()
        while let byte = input.next() {
            guard byte != 34 else { return nil }
            if byte != 92 { decoded.append(byte); continue }
            guard let escape = input.next() else { return nil }
            switch escape {
            case 34, 92: decoded.append(escape)
            case 97: decoded.append(7)
            case 98: decoded.append(8)
            case 116: decoded.append(9)
            case 110: decoded.append(10)
            case 118: decoded.append(11)
            case 102: decoded.append(12)
            case 114: decoded.append(13)
            case 48...51:
                guard let middle = input.next(), let last = input.next(),
                      (48...55).contains(middle), (48...55).contains(last) else { return nil }
                decoded.append((escape - 48) * 64 + (middle - 48) * 8 + (last - 48))
            default: return nil
            }
        }
        self.init(decoded)
    }
}
