import Foundation

// Source-only candidate. This performs lexical URL-data admission only. The
// unchanged retirementReturned reducer/codec and native tree proof remain later
// requirements. No standardization, resolution, resource query or target I/O.
internal enum NativeTrashURLRefusalV4:String,Codable,Sendable {
    case missingAbsolute,oversized,nonFile,authority,credentials,queryOrFragment
    case nestedBase,invalidBase,invalidRelative,invalidPath,malformedEscape
    case encodedStructuralByte,invalidUTF8,fileReference,absoluteSpellingChanged
    case directoryHintChanged,remainingBase
}
internal struct NativeTrashURLFlagsV4:Codable,Equatable,Sendable {
    let isFileURL:Bool,hasBaseURL:Bool,hasDirectoryPath:Bool
    init(_ raw:NSURL) {
        isFileURL=raw.isFileURL;hasBaseURL=raw.baseURL != nil;hasDirectoryPath=raw.hasDirectoryPath
    }
}
internal enum NativeTrashURLAdmissionV4:Sendable,CustomStringConvertible,CustomDebugStringConvertible {
    case accepted(URL,raw:NativeTrashURLFlagsV4,bridged:NativeTrashURLFlagsV4)
    case refused(NativeTrashURLRefusalV4,raw:NativeTrashURLFlagsV4)
    var description:String {"Native Trash URL admission (private representation omitted)"}
    var debugDescription:String {description}
}
internal enum NativeTrashURLPolicyV4 {
    static let maximumURLUTF8=4096,maximumPathUTF8=1024,maximumComponentUTF8=255,maximumComponents=256
    private static func hex(_ value:UInt8)->UInt8? {
        switch value {case 48...57:return value-48;case 65...70:return value-55;case 97...102:return value-87;default:return nil}
    }
    private static func component(_ raw:Substring)->NativeTrashURLRefusalV4? {
        guard !raw.isEmpty else{return .invalidPath}
        let source=Array(raw.utf8);var decoded:[UInt8]=[];decoded.reserveCapacity(source.count);var index=0
        while index<source.count {
            let value=source[index]
            if value==37 {
                guard index+2<source.count,let high=hex(source[index+1]),let low=hex(source[index+2])else{return .malformedEscape}
                let byte=high*16+low
                // Ordinary escaped spaces, UTF8 and literal percent names are
                // allowed. Encoded structural bytes remain inadmissible.
                if [0,46,47,92].contains(byte){return .encodedStructuralByte}
                decoded.append(byte);index+=3
            } else {
                if [0,47,92].contains(value){return .invalidPath}
                decoded.append(value);index+=1
            }
        }
        guard decoded.count<=maximumComponentUTF8 else{return .oversized}
        guard let value=String(bytes:decoded,encoding:.utf8)else{return .invalidUTF8}
        guard value != ".",value != ".."else{return .invalidPath}
        // A literal percent is valid. Refuse only a second structural escape
        // hidden behind it, rather than rejecting every percent-bearing volume.
        for index in decoded.indices where decoded[index]==37 && index+2<decoded.count {
            if let high=hex(decoded[index+1]),let low=hex(decoded[index+2]),[0,37,46,47,92].contains(high*16+low){return .encodedStructuralByte}
        }
        return nil
    }
    // Internal pure-data seam also admits direct malformed-string/boundary
    // controls without relying on a URL constructor preserving invalid syntax.
    static func path(_ raw:Substring,absolute:Bool)->NativeTrashURLRefusalV4? {
        guard raw.utf8.count<=maximumURLUTF8,absolute == raw.hasPrefix("/")else{return .invalidPath}
        let trailingSeparator=raw.hasSuffix("/")
        var parts=raw.split(separator:"/",omittingEmptySubsequences:false)
        if absolute {parts.removeFirst()}
        if parts.last?.isEmpty==true {parts.removeLast()}
        guard !parts.isEmpty,parts.count<=maximumComponents else{return .invalidPath}
        if absolute,parts.first==".file" {return .fileReference}
        var decodedBytes=(absolute ? 1:0)+(trailingSeparator ? 1:0)
        for (index,part) in parts.enumerated() {
            if let failure=component(part){return failure}
            guard let decoded=String(part).removingPercentEncoding else{return .malformedEscape}
            decodedBytes+=decoded.utf8.count+(index==0 ? 0:1)
        }
        guard decodedBytes<=maximumPathUTF8 else{return .oversized}
        return nil
    }
    private static func absolute(_ raw:NSURL)->NativeTrashURLRefusalV4? {
        guard raw.isFileURL,raw.scheme=="file"else{return .nonFile}
        guard raw.host==nil || raw.host==""else{return .authority}
        guard raw.user==nil,raw.password==nil,raw.port==nil else{return .credentials}
        guard raw.query==nil,raw.fragment==nil else{return .queryOrFragment}
        guard raw.baseURL==nil else{return .nestedBase}
        guard let value=raw.absoluteString else{return .missingAbsolute}
        guard value.utf8.count<=maximumURLUTF8 else{return .oversized}
        guard value.hasPrefix("file:///"),value.utf8.elementsEqual(raw.relativeString.utf8)else{return .invalidPath}
        return path(value.dropFirst("file://".count),absolute:true)
    }
    static func admit(_ raw:NSURL)->NativeTrashURLAdmissionV4 {
        let flags=NativeTrashURLFlagsV4(raw)
        func refused(_ reason:NativeTrashURLRefusalV4)->NativeTrashURLAdmissionV4 {.refused(reason,raw:flags)}
        guard raw.isFileURL,raw.scheme=="file"else{return refused(.nonFile)}
        guard raw.host==nil || raw.host==""else{return refused(.authority)}
        guard raw.user==nil,raw.password==nil,raw.port==nil else{return refused(.credentials)}
        guard raw.query==nil,raw.fragment==nil else{return refused(.queryOrFragment)}
        let relative=raw.relativeString
        guard relative.utf8.count<=maximumURLUTF8 else{return refused(.oversized)}
        if let base=raw.baseURL {
            let rawBase=base as NSURL
            guard rawBase.baseURL==nil else{return refused(.nestedBase)}
            guard absolute(rawBase)==nil,rawBase.hasDirectoryPath else{return refused(.invalidBase)}
            // Only one clean child, optionally carrying a trailing directory
            // hint. Root-relative paths and nested relative bases are refused.
            var child=relative[...]
            if child.last=="/" {child=child.dropLast()}
            guard !child.isEmpty,!child.contains("/"),!child.contains("?"),!child.contains("#")else{return refused(.invalidRelative)}
            if let failure=component(child){return refused(failure)}
        } else if let failure=absolute(raw){return refused(failure)}
        guard let originalAbsolute=raw.absoluteString,originalAbsolute.utf8.count<=maximumURLUTF8 else{return refused(.missingAbsolute)}
        let bridged=raw as URL,absoluteValue=bridged.absoluteURL,absoluteRaw=absoluteValue as NSURL
        guard absoluteValue.baseURL==nil else{return refused(.remainingBase)}
        guard absoluteValue.isFileURL else{return refused(.nonFile)}
        guard originalAbsolute.utf8.elementsEqual(absoluteValue.absoluteString.utf8)else{return refused(.absoluteSpellingChanged)}
        guard absoluteValue.hasDirectoryPath==raw.hasDirectoryPath else{return refused(.directoryHintChanged)}
        if let failure=absolute(absoluteRaw){return refused(failure)}
        return .accepted(absoluteValue,raw:flags,bridged:NativeTrashURLFlagsV4(bridged as NSURL))
    }
}
