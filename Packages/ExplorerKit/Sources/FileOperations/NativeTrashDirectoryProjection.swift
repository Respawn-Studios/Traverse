import Foundation

// Pure representation projection for a separately proved retained directory.
// The caller must establish the before-tree directory identity independently.
internal struct NativeTrashDirectoryProjectionV5:Sendable,CustomStringConvertible,CustomDebugStringConvertible {
    let url:URL,directoryHintAdded:Bool
    var description:String {"Retained directory projection (private URI omitted)"}
    var debugDescription:String {description}
}
internal enum NativeTrashDirectoryProjectionOutcomeV5:Sendable,CustomStringConvertible,CustomDebugStringConvertible {
    case accepted(NativeTrashDirectoryProjectionV5)
    case refused(NativeTrashURLRefusalV4)
    var description:String {"Retained directory projection outcome (private URI omitted)"}
    var debugDescription:String {description}
}
internal enum NativeTrashDirectoryPolicyV5 {
    static func project(_ admitted:URL)->NativeTrashDirectoryProjectionOutcomeV5 {
        guard admitted.baseURL==nil else{return .refused(.remainingBase)}
        guard case .accepted(let original,_,_)=NativeTrashURLPolicyV4.admit(admitted as NSURL)else{return .refused(.invalidPath)}
        let before=admitted.absoluteString
        guard original.absoluteString.utf8.elementsEqual(before.utf8)else{return .refused(.absoluteSpellingChanged)}
        guard before.hasSuffix("/")==admitted.hasDirectoryPath else{return .refused(.directoryHintChanged)}
        let added = !admitted.hasDirectoryPath,encoded=added ? before+"/":before
        guard encoded.utf8.count<=NativeTrashURLPolicyV4.maximumURLUTF8 else{return .refused(.oversized)}
        let encodedPath=encoded.dropFirst("file://".count)
        if let failure=NativeTrashURLPolicyV4.path(encodedPath,absolute:true){return .refused(failure)}
        guard let decodedBefore=String(before.dropFirst("file://".count)).removingPercentEncoding,
              let decodedAfter=String(encodedPath).removingPercentEncoding,
              decodedAfter.utf8.elementsEqual((added ? decodedBefore+"/":decodedBefore).utf8)else{return .refused(.absoluteSpellingChanged)}
        guard let projected=URL(string:encoded),projected.baseURL==nil,projected.isFileURL,projected.hasDirectoryPath,
              projected.absoluteString.utf8.elementsEqual(encoded.utf8),
              projected.path.utf8.elementsEqual(admitted.path.utf8)else{return .refused(.directoryHintChanged)}
        guard case .accepted(let checked,_,_)=NativeTrashURLPolicyV4.admit(projected as NSURL),
              checked.absoluteString.utf8.elementsEqual(encoded.utf8),checked.hasDirectoryPath else{return .refused(.invalidPath)}
        return .accepted(.init(url:projected,directoryHintAdded:added))
    }
}
