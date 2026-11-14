import Foundation
import FileOperations
@_spi(Qualification) import LocalStorage

/// Display and explicit review adapters for two real local recovery owners.
/// The concrete opaque choice remains held; display strings are never lookup,
/// server access, deletion, replay or mutation authority.
enum RemoteRetainedTextChoice: Sendable {
    case sftp(SFTPInPlaceRecoveryChoice), smb(SMBInPlaceRecoveryChoice)
    enum Version: Equatable, Sendable { case before, edited }
    enum Outcome: Equatable, Sendable { case retainedRead, notStarted, needsReview, verified }
    struct Presentation: Sendable { let fileName: String, server: String, account: String }

    var capturedEditorGeneration: UUID? {
        switch self {
        case .sftp(let choice): choice.capturedEditorGeneration
        case .smb(let choice): choice.capturedEditorGeneration
        }
    }
    /// Generation is a correlation fact only; the discovered opaque choice
    /// still owns the checked read. Never choose an older or ambiguous record.
    static func refusedChoice(in choices: [Self], generation: UUID) -> Self? {
        let matching = choices.filter { $0.capturedEditorGeneration == generation && $0.outcome == .notStarted }
        return matching.count == 1 ? matching[0] : nil
    }
    struct RefusedReview: Sendable {
        let generation: UUID
        let version: Version
    }

    var protocolName: String { switch self { case .sftp: "SFTP"; case .smb: "SMB" } }
    var presentation: Presentation {
        switch self {
        case .sftp(let choice): .init(fileName: choice.presentation.fileName, server: choice.presentation.server,
            account: choice.presentation.account)
        case .smb(let choice): .init(fileName: choice.presentation.fileName, server: choice.presentation.server,
            account: choice.presentation.account)
        }
    }
    var availableVersions: [Version] {
        switch self {
        case .sftp(let choice): choice.availableVersions.map { $0 == .before ? .before : .edited }
        case .smb(let choice): choice.availableVersions.map { $0 == .before ? .before : .edited }
        }
    }
    var outcome: Outcome {
        switch self {
        case .sftp(let choice):
            switch choice.outcome {
            case .retainedRead: .retainedRead
            case .notStarted: .notStarted
            case .needsReview: .needsReview
            case .verified: .verified
            }
        case .smb(let choice):
            switch choice.outcome {
            case .notStarted: .notStarted
            case .needsReview: .needsReview
            case .verified: .verified
            }
        }
    }
    func readPinnedVersion(_ version: Version) async throws -> RemoteRetainedTextView {
        switch self {
        case .sftp(let choice): .sftp(try await choice.readPinnedVersion(version == .before ? .before : .edited))
        case .smb(let choice): .smb(try await choice.readPinnedVersion(version == .before ? .before : .edited))
        }
    }
}

enum RemoteRetainedTextView: Sendable {
    case sftp(SFTPInPlaceViewedVersion), smb(SMBInPlaceViewedVersion)
    var protocolName: String { switch self { case .sftp: "SFTP"; case .smb: "SMB" } }
    var contents: TextDocumentValue {
        switch self { case .sftp(let view): view.contents; case .smb(let view): view.contents }
    }
    func closeAndDrain() async -> Bool {
        switch self { case .sftp(let view): await view.closeAndDrain(); case .smb(let view): await view.closeAndDrain() }
    }
}
