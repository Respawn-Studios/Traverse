import Foundation

enum SFTPPasswordInputFailure: Error { case invalid }

@_spi(Qualification) public struct SFTPPassword: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let bytes: Data
    public init(_ value: String) throws {
        let data = Data(value.utf8)
        guard !data.isEmpty, data.count <= 4096, !data.contains(0) else { throw SFTPPasswordInputFailure.invalid }; bytes = data
    }
    public var description: String { "<SFTP password>" }
    public var debugDescription: String { description }
}
