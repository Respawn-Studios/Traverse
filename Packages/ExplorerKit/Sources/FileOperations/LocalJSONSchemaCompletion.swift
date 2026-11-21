import Foundation

public enum LocalJSONSchemaCompletion {
    public static let maximumDocumentBytes = 128 << 10

    public struct Candidate: Sendable, Equatable {
        public let name: String
        public let required: Bool
        public let isDefault: Bool
        public let types: [String]
        public let summary: String?
        public let replacement: String
        public let selectionInReplacement: NSRange
    }

    public struct Plan: Sendable, Equatable {
        public enum Kind: Sendable, Equatable { case property, value }
        public let kind: Kind
        public let range: NSRange
        public let candidates: [Candidate]
    }

    public enum Result: Sendable {
        case suggestions(Plan)
        case unavailable(String)
    }

    private struct Position {
        enum Target { case property(hasValue: Bool), value(quotedPrefix: Bool) }

        let bytes: Range<Int>
        let prefix: Data
        let target: Target

        var kind: Plan.Kind {
            if case .property = target { return .property }
            return .value
        }
    }

    private enum Step {
        case property(Data)
        case item(Int)
    }

    public static func suggest(in text: String, selection: NSRange, allowsComments: Bool, schema: String) throws -> Result {
        guard text.utf8.count <= maximumDocumentBytes, schema.utf8.count <= LocalJSONCheck.maximumSchemaBytes else {
            return .unavailable("Schema completion supports documents up to 128 KiB and schemas up to 256 KiB.")
        }
        let length = text.utf16.count
        guard selection.location >= 0, selection.location <= length, selection.length >= 0,
              selection.length <= length - selection.location, let selected = Range(selection, in: text) else {
            return .unavailable("Place the caret in a JSON property or select one value.")
        }
        let input = Array(text.utf8)
        let startByte = text.utf8.distance(from: text.utf8.startIndex, to: selected.lowerBound)
        let endByte = text.utf8.distance(from: text.utf8.startIndex, to: selected.upperBound)
        guard let position = try position(input, selection: startByte..<endByte, allowsComments: allowsComments) else {
            return .unavailable("Place the caret in a JSON property or select one value.")
        }
        let marker = "__traverse_completion_\(UUID().uuidString)"
        let sample: String
        if case .property(hasValue: false) = position.target { sample = "\"\(marker)\":null" }
        else { sample = "\"\(marker)\"" }
        var shadow = input
        shadow.replaceSubrange(position.bytes, with: sample.utf8)
        let target: (steps: [Step], properties: Set<Data>)
        do {
            var parser = JSONCheckReader(shadow, allowsComments: allowsComments)
            let document = try parser.read()
            guard let found = try locate(in: document, sentinel: key(marker), kind: position.kind, path: []) else {
                return .unavailable("The caret does not identify a property or value.")
            }
            target = found
        } catch is JSONCheckSyntax {
            return .unavailable("Fix the surrounding JSON before requesting suggestions.")
        } catch is JSONCheckLimit {
            return .unavailable("This JSON document exceeds the completion limit.")
        }
        let candidates: [Candidate]
        do {
            let schemaBytes = Array(schema.utf8)
            var parser = JSONCheckReader(schemaBytes, allowsComments: false)
            let root = try parser.read()
            var evaluation = JSONSchemaEvaluation(root: root)
            try evaluation.verify(root)
            guard let rule = try rule(at: target.steps, in: root, evaluation: evaluation) else {
                return .unavailable("The selected schema has no rule for this location.")
            }
            let chain = try referenceChain(from: rule, evaluation: evaluation)
            switch position.target {
            case .property(let hasValue):
                let rules = chain.compactMap(\.dictionary).first { $0[key("properties")] != nil } ?? [:]
                candidates = try properties(in: rules, used: target.properties, prefix: position.prefix,
                                            hasValue: hasValue, evaluation: evaluation)
            case .value(let quoted):
                candidates = try values(in: chain, schemaBytes: schemaBytes, prefix: position.prefix,
                                        quoted: quoted, evaluation: &evaluation)
            }
        } catch is JSONCheckSyntax {
            return .unavailable("The selected schema contains invalid JSON.")
        } catch let error as JSONSchemaEvaluation.Unavailable {
            return .unavailable(error.message)
        } catch is JSONCheckLimit {
            return .unavailable("The selected schema exceeds the completion limit.")
        }
        let start = String(decoding: input[..<position.bytes.lowerBound], as: UTF8.self).utf16.count
        let replaced = String(decoding: input[position.bytes], as: UTF8.self).utf16.count
        return .suggestions(.init(kind: position.kind, range: .init(location: start, length: replaced), candidates: candidates))
    }

    private static func properties(in rules: [Data: JSONCheckValue], used: Set<Data>,
                                   prefix: Data, hasValue: Bool, evaluation: JSONSchemaEvaluation) throws -> [Candidate] {
        let required = Set(rules[key("required")]?.elements?.compactMap(\.string) ?? [])
        let available = rules[key("properties")]?.dictionary ?? [:]
        let matches = available.keys.filter {
            $0.count <= 256 && $0.starts(with: prefix) && !used.contains($0)
        }.sorted {
            let lhs = required.contains($0), rhs = required.contains($1)
            return lhs != rhs ? lhs : $0.lexicographicallyPrecedes($1)
        }
        return try matches.prefix(64).compactMap { name -> Candidate? in
            try Task.checkCancellation()
            guard let rule = available[name] else { return nil }
            let chain: [JSONCheckValue]
            do { chain = try referenceChain(from: rule, evaluation: evaluation) }
            catch is JSONCheckLimit { chain = [rule] }
            let prohibited = chain.contains { item in
                if case .boolean(false) = item.kind { return true }
                return false
            }
            guard !prohibited else { return nil }
            let details = metadata(in: chain.compactMap(\.dictionary))
            let label = String(decoding: name, as: UTF8.self)
            guard !label.isEmpty, !label.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  let encoded = try? JSONSerialization.data(withJSONObject: label, options: [.fragmentsAllowed, .withoutEscapingSlashes])
            else { return nil }
            let quoted = String(decoding: encoded, as: UTF8.self)
            let replacement = hasValue ? quoted : quoted + ": null"
            let labelEnd = quoted.utf16.count
            return .init(name: label, required: required.contains(name), isDefault: false,
                types: details.types, summary: details.summary, replacement: replacement,
                selectionInReplacement: hasValue ? .init(location: labelEnd, length: 0)
                    : .init(location: labelEnd + 2, length: 4))
        }
    }

    private static func values(in chain: [JSONCheckValue], schemaBytes: [UInt8], prefix: Data,
                               quoted: Bool, evaluation: inout JSONSchemaEvaluation) throws -> [Candidate] {
        guard let rule = chain.first else { return [] }
        let rules = chain.compactMap(\.dictionary)
        let details = metadata(in: rules)
        let defaultValue = rules.lazy.compactMap { $0[key("default")] }.first
        var declared: [JSONCheckValue] = []
        if let constant = rules.lazy.compactMap({ $0[key("const")] }).first {
            declared.append(constant)
        } else if let variants = rules.lazy.compactMap({ $0[key("enum")]?.elements }).first {
            declared = variants
        } else if rules.contains(where: { rules in
            guard let type = rules[key("type")] else { return false }
            return type.string == key("boolean") || type.elements?.contains(where: { $0.string == key("boolean") }) == true
        }) {
            declared = [.init(offset: 0, kind: .boolean(true)), .init(offset: 0, kind: .boolean(false))]
        }
        if let defaultValue { declared.insert(defaultValue, at: 0) }
        var candidates: [Candidate] = [], seen = Set<Data>()
        for (index, value) in declared.enumerated() {
            try Task.checkCancellation()
            let literal: Data
            switch value.kind {
            case .object, .array: continue
            case .boolean(let enabled): literal = key(enabled ? "true" : "false")
            case .null: literal = key("null")
            case .string, .number:
                var start = value.offset
                guard let token = try JSONTextTokens.next(schemaBytes, cursor: &start, allowsComments: false),
                      token.range.count <= 256 else { continue }
                literal = Data(schemaBytes[token.range])
            }
            guard (!quoted || value.string != nil), (value.string ?? literal).starts(with: prefix),
                  seen.insert(literal).inserted,
                  try evaluation.satisfies(rule, value: value) else { continue }
            let spelling = String(decoding: literal, as: UTF8.self)
            candidates.append(.init(name: spelling, required: false, isDefault: index == 0 && defaultValue != nil,
                types: details.types, summary: details.summary, replacement: spelling,
                selectionInReplacement: .init(location: spelling.utf16.count, length: 0)))
            if candidates.count == 64 { break }
        }
        return candidates
    }

    private static func metadata(in rules: [[Data: JSONCheckValue]]) -> (types: [String], summary: String?) {
        let type = rules.lazy.compactMap { $0[key("type")] }.first
        let names = type?.elements?.compactMap(\.string) ?? type?.string.map { [$0] } ?? []
        let types = names.map { String(decoding: $0, as: UTF8.self) }
        let note = rules.lazy.compactMap { rule in rule[key("description")]?.string ?? rule[key("title")]?.string }.first
        guard let note else { return (types, nil) }
        var plain = String.UnicodeScalarView()
        for scalar in String(decoding: note, as: UTF8.self).unicodeScalars.prefix(240) {
            plain.append(scalar.properties.isWhitespace || CharacterSet.controlCharacters.contains(scalar) ? " " : scalar)
        }
        let summary = String(plain).split(separator: " ").joined(separator: " ")
        return (types, summary.isEmpty ? nil : summary)
    }

    private static func position(_ bytes: [UInt8], selection: Range<Int>, allowsComments: Bool) throws -> Position? {
        let caret = selection.lowerBound
        var cursor = 0
        var previous: JSONTextTokens.Kind?, focused: Range<Int>?, next: JSONTextTokens.Kind?
        do {
            while let token = try JSONTextTokens.next(bytes, cursor: &cursor, allowsComments: allowsComments) {
                try Task.checkCancellation()
                if token.kind == .lineComment || token.kind == .blockComment {
                    if token.range.contains(caret) { return nil }
                    continue
                }
                if token.kind == .value, focused == nil, (token.range.lowerBound...token.range.upperBound).contains(caret) {
                    focused = token.range
                } else if token.range.upperBound <= caret {
                    previous = token.kind
                } else {
                    next = token.kind
                    break
                }
            }
        } catch let incomplete as JSONTextTokens.Incomplete {
            guard selection.isEmpty, !incomplete.comment, incomplete.offset < caret, focused == nil else { return nil }
            cursor = caret
            next = try JSONTextTokens.next(bytes, cursor: &cursor, allowsComments: allowsComments)?.kind
            focused = incomplete.offset..<caret
        }
        guard selection.isEmpty || focused == selection else { return nil }
        let atEndOfObject = (previous == .symbol(123) || previous == .symbol(44)) && next == .symbol(125)
        let range = focused ?? caret..<caret
        let quoted = !range.isEmpty && bytes[range.lowerBound] == 34
        let existingProperty = quoted && next == .symbol(58)
        let target: Position.Target
        if (existingProperty || atEndOfObject) && selection.isEmpty {
            target = .property(hasValue: existingProperty)
        } else {
            let objectValue = previous == .symbol(58) && (next == .symbol(125) || next == .symbol(44))
            let arrayValue = (previous == .symbol(91) || previous == .symbol(44)) && (next == .symbol(93) || next == .symbol(44))
            guard objectValue || arrayValue || (previous == nil && next == nil) else { return nil }
            let filtersByString = selection.isEmpty && quoted
            target = .value(quotedPrefix: filtersByString)
            if !selection.isEmpty || bytes[range].elementsEqual("null".utf8) {
                return .init(bytes: range, prefix: Data(), target: target)
            }
        }
        var prefix = Data(bytes[range.lowerBound..<caret])
        if quoted && !prefix.isEmpty {
            prefix.removeFirst()
            if prefix.last == 34 { prefix.removeLast() }
            var reader = JSONCheckReader([34] + prefix + [34], allowsComments: false)
            do {
                guard let decoded = try reader.read().string else { return nil }
                prefix = decoded
            } catch is JSONCheckSyntax { return nil }
        } else if case .property = target {
            guard prefix.allSatisfy({ (65...90).contains($0) || (97...122).contains($0)
                || (48...57).contains($0) || $0 == 95 || $0 == 45 }) else { return nil }
        }
        return .init(bytes: range, prefix: prefix, target: target)
    }

    private static func locate(in value: JSONCheckValue, sentinel: Data, kind: Plan.Kind,
                               path: [Step]) throws -> (steps: [Step], properties: Set<Data>)? {
        try Task.checkCancellation()
        if kind == .value, value.string == sentinel { return (path, []) }
        if let values = value.dictionary {
            if kind == .property, values[sentinel] != nil { return (path, Set(values.keys.filter { $0 != sentinel })) }
            for (key, child) in values {
                if let found = try locate(in: child, sentinel: sentinel, kind: kind, path: path + [.property(key)]) { return found }
            }
        } else if let values = value.elements {
            for (index, child) in values.enumerated() {
                if let found = try locate(in: child, sentinel: sentinel, kind: kind, path: path + [.item(index)]) { return found }
            }
        }
        return nil
    }

    private static func rule(at steps: [Step], in root: JSONCheckValue,
                             evaluation: JSONSchemaEvaluation) throws -> JSONCheckValue? {
        var selected = root
        for step in steps {
            let rules = try referenceChain(from: selected, evaluation: evaluation).compactMap(\.dictionary)
            let child: JSONCheckValue?
            switch step {
            case .property(let name):
                child = rules.lazy.compactMap { $0[key("properties")]?.dictionary?[name] }.first
                    ?? rules.lazy.compactMap { $0[key("additionalProperties")] }.first
            case .item(let index):
                child = rules.lazy.compactMap { current -> JSONCheckValue? in
                    let prefix = current[key("prefixItems")]?.elements ?? []
                    return prefix.indices.contains(index) ? prefix[index] : current[key("items")]
                }.first
            }
            guard let child else { return nil }
            selected = child
        }
        return selected
    }

    private static func referenceChain(from current: JSONCheckValue,
                                       evaluation: JSONSchemaEvaluation) throws -> [JSONCheckValue] {
        var rules = [current], seen: Set<Int> = [current.offset]
        var next = current
        while let reference = next.dictionary?[key("$ref")] {
            try Task.checkCancellation()
            next = try evaluation.resolve(reference)
            guard rules.count < 64, seen.insert(next.offset).inserted else { throw JSONCheckLimit() }
            rules.append(next)
        }
        return rules
    }

    private static func key(_ value: String) -> Data { Data(value.utf8) }
}
