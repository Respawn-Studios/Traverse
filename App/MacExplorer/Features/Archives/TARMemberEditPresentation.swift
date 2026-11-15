import Foundation
import LocalStorage

/// Presentation facts and draft field changes for the existing archive review.
/// Only the concrete session can mint the source/destination selections.
extension TARMemberMutation {
    var memberSelection: TARMemberSelection? {
        switch self {
        case .rename(let v, _), .batchRename(let v, _), .remove(let v), .duplicate(let v, _), .move(let v, _), .group(let v, _): v
        default: nil
        }
    }
    var destination: TARMemberDestination? {
        switch self {
        case .duplicate(_, let v): v
        case .move(_, let v), .newFile(let v, _), .newFolder(let v, _), .add(let v, _): v
        default: nil
        }
    }
    var draftName: String {
        switch self { case .rename(_, let n), .newFile(_, let n), .newFolder(_, let n), .group(_, let n): n; default: "" }
    }
    func reviewed(name: String, addedSources: [URL]) -> Self {
        switch self {
        case .rename(let v, _): .rename(v, to: name)
        case .newFile(let v, _): .newFile(v, name: name)
        case .newFolder(let v, _): .newFolder(v, name: name)
        case .group(let v, _): .group(v, name: name)
        case .add(let v, _): .add(v, sources: addedSources)
        default: self
        }
    }
    var folderPath: String {
        destination?.virtualFolder ?? memberSelection?.archivePaths.first.map {
            $0.split(separator: "/").dropLast().joined(separator: "/")
        } ?? ""
    }
}
