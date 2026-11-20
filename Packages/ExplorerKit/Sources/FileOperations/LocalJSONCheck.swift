import Foundation

/// Checks the captured buffer without editing it. A schema is an explicitly
/// supplied document and only in-document references can be resolved.
public enum LocalJSONCheck {
    public static let maximumBytes = 1 << 20
    public static let maximumSchemaBytes = 256 << 10

    public struct Issue: Equatable, Sendable {
        public let offset: Int
        public let line: Int
        public let column: Int
        public let message: String
    }

    public enum Result: Equatable, Sendable {
        case checked(issues: [Issue], moreIssues: Bool)
        case unavailable(String)
    }

    public static func check(_ text: String, allowsComments: Bool, schemaFile: URL) throws -> Result {
        let granted = schemaFile.startAccessingSecurityScopedResource()
        defer { if granted { schemaFile.stopAccessingSecurityScopedResource() } }
        let schema: TextDocumentValue
        do {
            schema = try withoutMaterialization {
                let bytes = try LocalTextComparisonRead.fileBytes(at: schemaFile, maximumBytes: maximumSchemaBytes) {
                    try Task.checkCancellation()
                }
                return try TextDocumentValue.original(bytes)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .unavailable("Choose a downloaded local UTF-8 JSON schema of 256 KiB or less that Traverse can read.")
        }
        return try check(text, allowsComments: allowsComments, schema: schema.text)
    }

    public static func check(_ text: String, allowsComments: Bool, schema: String? = nil) throws -> Result {
        guard text.utf8.count <= maximumBytes else { return .unavailable("Check a document of 1 MiB or less.") }
        let bytes = Array(text.utf8)
        do {
            var reader = JSONCheckReader(bytes, allowsComments: allowsComments)
            let value = try reader.read()
            guard let schema else { return .checked(issues: [], moreIssues: false) }
            guard schema.utf8.count <= maximumSchemaBytes else {
                return .unavailable("Choose a schema of 256 KiB or less.")
            }
            let schemaBytes = Array(schema.utf8)
            var schemaReader = JSONCheckReader(schemaBytes, allowsComments: false)
            let root: JSONCheckValue
            do {
                root = try schemaReader.read()
            } catch let failure as JSONCheckSyntax {
                let problem = location(failure, in: schemaBytes)
                return .unavailable("The selected schema needs attention at line \(problem.line). \(problem.message)")
            }
            var evaluation = JSONSchemaEvaluation(root: root)
            try evaluation.verify(root)
            try evaluation.apply(root, to: value)
            return .checked(issues: evaluation.issues.map { location($0, in: bytes) }, moreIssues: evaluation.moreIssues)
        } catch let syntax as JSONCheckSyntax {
            return .checked(issues: [location(syntax, in: bytes)], moreIssues: false)
        } catch let mismatch as JSONSchemaEvaluation.Unavailable {
            return .unavailable(mismatch.message)
        } catch is JSONCheckLimit {
            return .unavailable("This check exceeded the size or complexity it can review.")
        }
    }

    private static func location(_ finding: JSONCheckSyntax, in bytes: [UInt8]) -> Issue {
        var line = 1
        var start = 0
        for index in 0..<finding.offset {
            if bytes[index] == 13 || bytes[index] == 10 && (index == 0 || bytes[index - 1] != 13) { line += 1 }
            if bytes[index] == 13 || bytes[index] == 10 { start = index + 1 }
        }
        let offset = String(decoding: bytes[..<finding.offset], as: UTF8.self).utf16.count
        let column = String(decoding: bytes[start..<finding.offset], as: UTF8.self).utf16.count + 1
        return Issue(offset: offset, line: line, column: column, message: finding.message)
    }
}

private struct JSONSchemaEvaluation {
    struct Unavailable: Error { let message: String }
    private struct Visit: Hashable { let schema: Int; let document: Int }

    let root: JSONCheckValue
    private(set) var issues: [JSONCheckSyntax] = []
    private(set) var moreIssues = false
    private var visited: Set<Int> = []
    private var active: Set<Visit> = []
    private var steps = 100_000
    private var issueLimit = 24

    init(root: JSONCheckValue) { self.root = root }

    private static let annotations: Set<String> = [
        "title", "description", "default", "examples", "readOnly", "writeOnly", "deprecated", "$comment"
    ]
    private static let types: Set<String> = ["object", "array", "string", "number", "integer", "boolean", "null"]
    private static let namedSubschemas: Set<String> = ["$defs", "properties"]
    private static let indexedSubschemas: Set<String> = ["allOf", "anyOf", "oneOf", "prefixItems"]
    private static let singleSubschemas: Set<String> = ["additionalProperties", "items", "not", "if", "then", "else"]

    private mutating func advance() throws {
        steps -= 1
        guard steps >= 0 else { throw JSONCheckLimit() }
        if steps & 63 == 0 { try Task.checkCancellation() }
    }

    mutating func verify(_ schema: JSONCheckValue, depth: Int = 0) throws {
        guard depth <= 64 else { throw JSONCheckLimit() }
        guard visited.insert(schema.offset).inserted else { return }
        try advance()
        if case .boolean = schema.kind { return }
        guard let rules = schema.dictionary else { throw Unavailable(message: "A schema rule must be an object or a Boolean.") }
        for (key, rule) in rules.sorted(by: { $0.value.offset < $1.value.offset }) {
            let name = String(decoding: key, as: UTF8.self)
            switch name {
            case "$schema":
                let dialect = "https://json-schema.org/draft/2020-12/schema"
                guard schema.offset == root.offset, rule.string == data(dialect) || rule.string == data(dialect + "#") else {
                    throw Unavailable(message: "Choose a JSON Schema using draft 2020-12.")
                }
            case "$id" where schema.offset == root.offset && rule.string != nil:
                break
            case "$ref":
                try verify(resolve(rule), depth: depth + 1)
            case _ where Self.namedSubschemas.contains(name):
                guard let definitions = rule.dictionary else { throw malformed(name) }
                for definition in definitions.values.sorted(by: { $0.offset < $1.offset }) {
                    try verify(definition, depth: depth + 1)
                }
            case _ where Self.indexedSubschemas.contains(name):
                guard let subschemas = rule.elements, !subschemas.isEmpty else { throw malformed(name) }
                for subschema in subschemas { try verify(subschema, depth: depth + 1) }
            case _ where Self.singleSubschemas.contains(name):
                try verify(rule, depth: depth + 1)
            case "required":
                guard let names = names(in: rule), Set(names).count == names.count else { throw malformed(name) }
            case "type":
                guard let options = typeNames(in: rule), !options.isEmpty, Set(options).count == options.count,
                      options.allSatisfy({ Self.types.contains($0) }) else { throw malformed(name) }
            case "enum":
                guard let values = rule.elements, !values.isEmpty else { throw malformed(name) }
            case "const":
                break
            case "minLength", "maxLength", "minItems", "maxItems", "minProperties", "maxProperties":
                guard size(rule) != nil else { throw malformed(name) }
            case "minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum":
                guard rule.number != nil else { throw malformed(name) }
            default:
                guard Self.annotations.contains(name) else {
                    throw Unavailable(message: "This check does not support the schema keyword “\(name.prefix(60))”.")
                }
            }
        }
    }

    mutating func apply(_ schema: JSONCheckValue, to value: JSONCheckValue, depth: Int = 0) throws {
        try advance()
        guard depth <= 64 else { throw JSONCheckLimit() }
        if issues.count == issueLimit {
            moreIssues = true
            return
        }
        if case .boolean(let allowed) = schema.kind {
            if !allowed { add("This schema does not allow a value here.", at: value) }
            return
        }
        guard let rules = schema.dictionary else { return }
        let visit = Visit(schema: schema.offset, document: value.offset)
        guard active.insert(visit).inserted else {
            throw Unavailable(message: "A schema reference returns to the same rule and value.")
        }
        defer { active.remove(visit) }
        if let reference = rules[data("$ref")] {
            try apply(resolve(reference), to: value, depth: depth + 1)
        }
        try applyComposition(rules, to: value, depth: depth + 1)
        if moreIssues { return }
        if let type = rules[data("type")], let options = typeNames(in: type),
           !options.contains(where: { matches(value, type: $0) }) {
            add("Expected \(options.joined(separator: " or ")).", at: value)
        }
        if let choices = rules[data("enum")]?.elements {
            var found = false
            for choice in choices {
                if try equal(value, choice) { found = true; break }
            }
            if !found { add("Choose one of the values listed by this schema.", at: value) }
        }
        if let fixed = rules[data("const")], try !equal(value, fixed) {
            add("This value differs from the constant required by the schema.", at: value)
        }
        if let dictionary = value.dictionary {
            checkSize(dictionary.count, measure: "Properties", rules: rules, value: value)
            if let required = rules[data("required")].flatMap(names(in:)) {
                for name in required where dictionary[name] == nil {
                    add("Add the required property “\(String(decoding: name, as: UTF8.self).prefix(60))”.", at: value)
                }
            }
            let properties = rules[data("properties")]?.dictionary ?? [:]
            let additional = rules[data("additionalProperties")]
            if !properties.isEmpty || additional != nil {
                for (key, child) in dictionary.sorted(by: { $0.value.offset < $1.value.offset }) {
                    if let rule = properties[key] ?? additional { try apply(rule, to: child, depth: depth + 1) }
                    if moreIssues { break }
                }
            }
        }
        if let elements = value.elements {
            checkSize(elements.count, measure: "Items", rules: rules, value: value)
            let prefix = rules[data("prefixItems")]?.elements ?? []
            for (child, rule) in zip(elements, prefix) {
                try apply(rule, to: child, depth: depth + 1)
                if moreIssues { return }
            }
            if let item = rules[data("items")] {
                for child in elements.dropFirst(prefix.count) {
                    try apply(item, to: child, depth: depth + 1)
                    if moreIssues { break }
                }
            }
        }
        if let string = value.string {
            checkSize(String(decoding: string, as: UTF8.self).unicodeScalars.count, measure: "Length", rules: rules, value: value)
        }
        if let number = value.number { checkNumber(number, rules: rules, value: value) }
    }

    private mutating func applyComposition(_ rules: [Data: JSONCheckValue], to value: JSONCheckValue, depth: Int) throws {
        if let all = rules[data("allOf")]?.elements {
            for rule in all {
                try apply(rule, to: value, depth: depth)
                if moreIssues { return }
            }
        }
        if let choices = rules[data("anyOf")]?.elements,
           try !choices.contains(where: { try satisfies($0, value: value, depth: depth) }) {
            add("Match at least one of the schema’s alternatives.", at: value)
        }
        if let choices = rules[data("oneOf")]?.elements {
            var count = 0
            for rule in choices where try satisfies(rule, value: value, depth: depth) {
                count += 1
                if count > 1 { break }
            }
            if count == 0 { add("Match one of the schema’s alternatives.", at: value) }
            if count > 1 { add("This value matches more than one of the schema’s alternatives.", at: value) }
        }
        if let rule = rules[data("not")], try satisfies(rule, value: value, depth: depth) {
            add("This value matches a rule the schema excludes.", at: value)
        }
        if let condition = rules[data("if")] {
            let thenRule = rules[data("then")]
            let elseRule = rules[data("else")]
            if thenRule != nil || elseRule != nil {
                let applies = try satisfies(condition, value: value, depth: depth)
                if let rule = applies ? thenRule : elseRule { try apply(rule, to: value, depth: depth) }
            }
        }
    }

    private mutating func satisfies(_ schema: JSONCheckValue, value: JSONCheckValue, depth: Int) throws -> Bool {
        // Speculative alternatives share the cycle and work limits with the main
        // check. Their findings must stay out of its issue list.
        let saved = (issues, moreIssues, issueLimit)
        issues = []
        moreIssues = false
        issueLimit = 1
        defer { (issues, moreIssues, issueLimit) = saved }
        try apply(schema, to: value, depth: depth)
        return issues.isEmpty
    }

    private mutating func equal(_ first: JSONCheckValue, _ second: JSONCheckValue) throws -> Bool {
        try advance()
        if let lhs = first.dictionary, let rhs = second.dictionary {
            guard lhs.count == rhs.count else { return false }
            for (key, value) in lhs {
                guard let other = rhs[key], try equal(value, other) else { return false }
            }
            return true
        }
        if let lhs = first.elements, let rhs = second.elements {
            guard lhs.count == rhs.count else { return false }
            for (value, other) in zip(lhs, rhs) {
                if try !equal(value, other) { return false }
            }
            return true
        }
        return first == second
    }

    private mutating func checkSize(_ count: Int, measure: String, rules: [Data: JSONCheckValue], value: JSONCheckValue) {
        if let minimum = rules[data("min" + measure)].flatMap(size), count < minimum {
            add("Expected at least \(minimum) \(unit(for: measure)).", at: value)
        }
        if let maximum = rules[data("max" + measure)].flatMap(size), count > maximum {
            add("Expected at most \(maximum) \(unit(for: measure)).", at: value)
        }
    }

    private mutating func checkNumber(_ number: JSONCheckNumber, rules: [Data: JSONCheckValue], value: JSONCheckValue) {
        if let minimum = rules[data("minimum")]?.number, number < minimum {
            add("This number is below the schema’s minimum.", at: value)
        }
        if let maximum = rules[data("maximum")]?.number, number > maximum {
            add("This number is above the schema’s maximum.", at: value)
        }
        if let minimum = rules[data("exclusiveMinimum")]?.number, number <= minimum {
            add("This number must be greater than the schema’s lower bound.", at: value)
        }
        if let maximum = rules[data("exclusiveMaximum")]?.number, number >= maximum {
            add("This number must be less than the schema’s upper bound.", at: value)
        }
    }

    private func unit(for measure: String) -> String { measure == "Length" ? "Unicode characters" : measure.lowercased() }

    private mutating func add(_ message: String, at value: JSONCheckValue) {
        guard issues.count < issueLimit else { moreIssues = true; return }
        issues.append(.init(offset: value.offset, message: message))
    }

    private func data(_ name: String) -> Data { Data(name.utf8) }
    private func malformed(_ name: String) -> Unavailable { .init(message: "Check the schema’s “\(name)” rule.") }

    private func names(in value: JSONCheckValue) -> [Data]? {
        guard let elements = value.elements else { return nil }
        let names = elements.compactMap(\.string)
        return names.count == elements.count ? names : nil
    }

    private func typeNames(in value: JSONCheckValue) -> [String]? {
        if let name = value.string { return [String(decoding: name, as: UTF8.self)] }
        return names(in: value)?.map { String(decoding: $0, as: UTF8.self) }
    }

    private func matches(_ value: JSONCheckValue, type: String) -> Bool {
        switch (type, value.kind) {
        case ("object", .object), ("array", .array), ("string", .string),
             ("number", .number), ("boolean", .boolean), ("null", .null):
            return true
        case ("integer", .number(let number)):
            return number.isInteger
        default:
            return false
        }
    }

    private func size(_ rule: JSONCheckValue) -> Int? {
        guard case .number(let number) = rule.kind, number.isInteger, !number.negative,
              number.digits.count + number.exponent <= 10 else { return nil }
        var result = number.digits.reduce(0) { $0 * 10 + Int($1 - 48) }
        for _ in 0..<number.exponent { result *= 10 }
        return result
    }

    private func resolve(_ reference: JSONCheckValue) throws -> JSONCheckValue {
        guard let raw = reference.string else { throw malformed("$ref") }
        let string = String(decoding: raw, as: UTF8.self)
        guard let pointer = string.removingPercentEncoding, pointer == "#" || pointer.hasPrefix("#/"),
              string.hasPrefix("#") else {
            throw Unavailable(message: "This check can only follow references inside the selected schema.")
        }
        if pointer == "#" { return root }
        var found = root
        var segments = pointer.dropFirst(2).split(separator: "/", omittingEmptySubsequences: false).makeIterator()
        let missing = Unavailable(message: "A local reference did not identify a schema rule.")
        while let next = segments.next() {
            let name = String(next)
            guard let child = found.dictionary?[data(name)] else { throw missing }
            switch name {
            case _ where Self.singleSubschemas.contains(name):
                found = child
            case _ where Self.namedSubschemas.contains(name):
                guard let member = segments.next(),
                      let property = child.dictionary?[data(try decodePointerName(member))] else { throw missing }
                found = property
            case _ where Self.indexedSubschemas.contains(name):
                guard let member = segments.next(), let index = Int(member), member == String(index),
                      let children = child.elements, children.indices.contains(index) else { throw missing }
                found = children[index]
            default:
                throw missing
            }
        }
        return found
    }

    private func decodePointerName(_ name: Substring) throws -> String {
        var check = name
        while let escaped = check.firstIndex(of: "~") {
            check = check[check.index(after: escaped)...]
            guard check.first == "0" || check.first == "1" else {
                throw Unavailable(message: "A schema reference has an invalid JSON pointer.")
            }
            check = check.dropFirst()
        }
        return name.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
    }
}
