import AppKit
import LocalStorage

/// Display facts from one current archive page. No local member URL, content
/// read, extraction permission or additional metadata request is implied.
struct ArchiveMemberObservation: Equatable {
    enum Kind: Equatable {
        case file, folder, symbolicLink, hardLink, other

        var title: String {
            switch self {
            case .file: "File"
            case .folder: "Folder"
            case .symbolicLink: "Symbolic link"
            case .hardLink: "Hard link"
            case .other: "Other item"
            }
        }
        var symbol: String {
            switch self {
            case .folder: "folder"
            case .symbolicLink, .hardLink: "link"
            case .file, .other: "doc"
            }
        }
        var describesSize: Bool { self == .file || self == .folder }
    }

    let archiveName: String
    let name: String
    let path: String
    let kind: Kind
    let logicalBytes: UInt64?
    let packedBytes: UInt64?
    let compression: String?
    let modification: ArchiveMemberModification?
    let isEncrypted: Bool

    init(zip item: ZIPArchiveItem, source: URL) {
        archiveName = source.lastPathComponent; name = item.name; path = item.path
        kind = switch item.kind {
        case .file: .file
        case .directory: .folder
        case .symbolicLink: .symbolicLink
        case .special: .other
        }
        logicalBytes = kind.describesSize ? item.logicalBytes : nil
        packedBytes = kind.describesSize ? item.packedBytes : nil
        compression = kind == .file && item.method != nil ? item.methodName : nil
        modification = item.modification
        isEncrypted = item.isEncrypted
    }

    init(tar item: TARArchiveItem, source: URL) {
        archiveName = source.lastPathComponent; name = item.name; path = item.path
        kind = switch item.kind {
        case .file: .file
        case .directory: .folder
        case .symbolicLink: .symbolicLink
        case .hardLink: .hardLink
        case .special: .other
        }
        logicalBytes = kind.describesSize ? item.logicalBytes : nil
        // A compressed TAR is one stream. It has no per-member packed size.
        packedBytes = nil; compression = nil; isEncrypted = false
        modification = item.modification
    }
}

extension ArchiveMemberModification {
    var displayText: String {
        if hasTimeZone { return date.formatted(date: .abbreviated, time: .shortened) }
        return date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, timeZone: .gmt))
    }
    var explanation: String {
        hasTimeZone ? "Modification time stored in the archive."
            : "Local time stored in the ZIP. Its time zone was not recorded."
    }
}

@MainActor extension BrowserViewController {
    var observedArchiveMember: ArchiveMemberObservation? {
        guard !isBrowserSuspended, view.window?.isVisible == true, !view.isHiddenOrHasHiddenAncestor,
              view.window?.attachedSheet == nil else { return nil }
        return currentArchive?.selectedMemberObservation
    }

    func showObservedArchiveProperties() {
        guard let member = observedArchiveMember else { return }
        showItemProperties(.archive(member), relativeTo: view.window)
    }

    func copyObservedArchiveMetadata(name: Bool) {
        guard let member = observedArchiveMember else { return }
        _ = publishObservedMetadataText(name ? member.name : member.path, noun: name ? "name" : "path in archive")
    }
}
