import FileOperations
import Foundation
import Testing

struct LocalJSONCheckTests {
    @Test func syntaxLocationsUseEditorOffsetsAcrossEmojiAndCRLF() throws {
        let source = "{\"🚀\": true,\r\n\"next\" false}"
        let result = try LocalJSONCheck.check(source, allowsComments: false)
        guard case .checked(let issues, false) = result else { Issue.record("Expected a location"); return }
        let issue = try #require(issues.first)
        #expect(issue.offset == (source as NSString).range(of: "false").location)
        #expect(issue.line == 2)
        #expect(issue.column == 8)
        #expect(issue.message.contains("colon"))
    }

    @Test func onlyJSONCAllowsCommentsAndTrailingCommas() throws {
        let jsonc = "{\"count\" /* label */: 2,\r\n\"keys\": [1, 2,], // note\n}"
        let valid = try LocalJSONCheck.check(jsonc, allowsComments: true)
        #expect(valid == .checked(issues: [], moreIssues: false))
        let strict = try LocalJSONCheck.check(jsonc, allowsComments: false)
        guard case .checked(let issues, false) = strict else { Issue.record("Expected strict syntax errors"); return }
        #expect(issues.first?.offset == (jsonc as NSString).range(of: "/*").location)
        let unclosed = try LocalJSONCheck.check("1 /* note", allowsComments: true)
        guard case .checked(let more, false) = unclosed else { Issue.record("Expected an unclosed comment"); return }
        #expect(more.first?.offset == 2)
    }

    @Test func JSONLinesChecksEveryRecordWithExactOffsetsAndBounds() throws {
        let valid = "{\"name\":\"🧭\"}\r\nfalse\n\"done\""
        #expect(try LocalJSONCheck.checkJSONLines(valid) == .checked(issues: [], moreIssues: false))
        #expect(try LocalJSONCheck.checkJSONLines("1\r\n") == .checked(issues: [], moreIssues: false))
        #expect(try LocalJSONCheck.checkJSONLines("") == .checked(issues: [], moreIssues: false))
        let draft = "\"🧭\"\r\n{\"broken\" true}\n\n[0,]\nnull\n"
        guard case .checked(let issues, false) = try LocalJSONCheck.checkJSONLines(draft) else {
            Issue.record("Expected all malformed record locations"); return
        }
        #expect(issues.map(\.line) == [2, 3, 4])
        #expect(issues.first?.offset == (draft as NSString).range(of: "true").location)
        #expect(issues.first?.message.contains("colon") == true)
        #expect(issues.dropFirst().first?.offset == (draft as NSString).range(of: "\n\n").location + 1)
        #expect(issues.dropFirst().first?.message.contains("blank line") == true)
        guard case .checked(let control, false) = try LocalJSONCheck.checkJSONLines("1\r 2") else {
            Issue.record("Expected a carriage-return finding"); return
        }
        #expect(control.first?.offset == 1)
        guard case .checked(let capped, true) = try LocalJSONCheck.checkJSONLines(String(repeating: ".\n", count: 25)) else {
            Issue.record("Expected a bounded list of findings"); return
        }
        #expect(capped.count == 24)
    }

    @Test func grammarDetectsIncompleteValuesAndRepeatedNames() throws {
        for text in ["", "0 1", "[1,]", "{\"a\": 1, \"a\": 2}", "01", "1.", "1e+", "\"\\j\""] {
            let check = try LocalJSONCheck.check(text, allowsComments: false)
            guard case .checked(let issues, false) = check else { Issue.record("Expected a syntax finding"); continue }
            #expect(issues.count == 1)
        }
        let differentScalars = "{\"é\":1,\"e\\u0301\":2}"
        #expect(try LocalJSONCheck.check(differentScalars, allowsComments: false) == .checked(issues: [], moreIssues: false))
    }

    @Test func validatesLocalReferencesPropertiesAndArrayItems() throws {
        let schema = """
        {
          "$schema": "https://json-schema.org/draft/2020-12/schema",
          "$defs": {"a/b": {"type": "integer"}},
          "properties": {
            "targets": {"type": "array", "items": {"$ref": "#/$defs/a~1b"}}
          },
          "required": ["targets", "format"], "additionalProperties": false
        }
        """
        let source = """
        {
          "targets": [1, false, 3],
          "extra": "unused"
        }
        """
        let result = try LocalJSONCheck.check(source, allowsComments: false, schema: schema)
        guard case .checked(let issues, false) = result else { Issue.record("Expected schema findings"); return }
        #expect(issues.count == 3)
        #expect(issues.map(\.line) == [1, 2, 3])
        #expect(issues[1].offset == (source as NSString).range(of: "false").location)
    }

    @Test func schemaPropertyCompletionUsesTheActualObjectAndPreservesValues() throws {
        let schema = """
        {"$defs":{"service":{"properties":{"name":{"type":"string"},"port":{"$ref":"#/$defs/port"},"path":true},
                                  "required":["port"]}, "port":{"type":"integer","description":"Listen port\\n  for the process."}},
         "properties":{"services":{"items":{"$ref":"#/$defs/service"}}}}
        """
        let draft = "{\"services\":[{\"name\":\"Orion 🧭\", \"p\n}]}"
        let source = draft as NSString
        let key = source.range(of: "\"p")
        guard case .suggestions(let insertion) = try LocalJSONSchemaCompletion.suggest(in: draft,
            selection: .init(location: NSMaxRange(key), length: 0), allowsComments: false, schema: schema) else {
            Issue.record("Expected suggestions inside the incomplete nested key"); return
        }
        #expect(insertion.kind == .property && insertion.range == key)
        #expect(insertion.candidates.map(\.name) == ["port", "path"])
        #expect(insertion.candidates.first?.required == true)
        let proposed = try #require(insertion.candidates.first)
        #expect(proposed.replacement == "\"port\": null")
        #expect(proposed.types == ["integer"] && proposed.summary == "Listen port for the process.")
        #expect((proposed.replacement as NSString).substring(with: proposed.selectionInReplacement) == "null")
        let changing = "{\"services\":[{\"p\":321,\"path\":\"home\"}]}"
        let existing = (changing as NSString).range(of: "\"p\"")
        guard case .suggestions(let replacement) = try LocalJSONSchemaCompletion.suggest(in: changing,
            selection: .init(location: existing.location + 2, length: 0), allowsComments: false, schema: schema) else {
            Issue.record("Expected replacement for the existing key"); return
        }
        #expect(replacement.range == existing)
        #expect(replacement.candidates.map(\.replacement) == ["\"port\""])
        #expect((changing as NSString).replacingCharacters(in: replacement.range,
            with: replacement.candidates[0].replacement).contains("\"port\":321"))
        let unsupported = try LocalJSONSchemaCompletion.suggest(in: "{ }", selection: .init(location: 2, length: 0), allowsComments: false,
            schema: #"{"$ref":"https://example.invalid/schema"}"#)
        guard case .unavailable = unsupported else { Issue.record("External reference did not refuse"); return }
    }

    @Test func schemaValueCompletionReusesLeafRulesAndKeepsExactScalars() throws {
        let schema = """
        {"$defs":{"mode":{"enum":["true",true,"debug","production","debug"],"default":"production","title":"Logging mode"}},
         "properties":{"options":{"prefixItems":[{"$ref":"#/$defs/mode","type":"string"},{"type":"boolean","default":"invalid"}]},
                       "precise":{"const":9007199254740993}}}
        """
        let document = #"{"name":"🧭","options":[null,false],"precise":null}"#
        let source = document as NSString
        let first = source.range(of: "null")
        let second = source.range(of: "false")
        let last = source.range(of: "null", options: .backwards)
        for (selection, expected) in [(first, [#""production""#, #""true""#, #""debug""#]),
                                      (second, ["true", "false"]), (last, ["9007199254740993"])] {
            guard case .suggestions(let plan) = try LocalJSONSchemaCompletion.suggest(in: document, selection: selection,
                allowsComments: false, schema: schema) else { Issue.record("Expected value suggestions"); continue }
            #expect(plan.kind == .value && plan.range == selection)
            #expect(plan.candidates.map(\.replacement) == expected)
            #expect(plan.candidates.filter(\.isDefault).map(\.replacement) == (selection == first ? [#""production""#] : []))
            if selection == first { #expect(plan.candidates.first?.summary == "Logging mode") }
        }
        guard case .suggestions(let preciseDefault) = try LocalJSONSchemaCompletion.suggest(in: "null",
            selection: .init(location: 0, length: 4), allowsComments: false,
            schema: #"{"type":"integer","default":9007199254740993}"#) else {
            Issue.record("Expected validated scalar default without an enum"); return
        }
        #expect(preciseDefault.candidates.first?.replacement == "9007199254740993")
        #expect(preciseDefault.candidates.first?.isDefault == true)
        let partial = #"{"options":["pr",false]}"#
        let prefix = (partial as NSString).range(of: #""pr""#)
        guard case .suggestions(let typed) = try LocalJSONSchemaCompletion.suggest(in: partial,
            selection: .init(location: NSMaxRange(prefix) - 1, length: 0), allowsComments: false, schema: schema) else {
            Issue.record("Expected a completion for the string prefix"); return
        }
        #expect(typed.range == prefix && typed.candidates.map(\.replacement) == [#""production""#])
        let tooWide = NSRange(location: first.location, length: NSMaxRange(second) - first.location)
        guard case .unavailable = try LocalJSONSchemaCompletion.suggest(in: document, selection: tooWide,
            allowsComments: false, schema: schema) else { Issue.record("Accepted a selection crossing values"); return }
    }

    @Test func delimiterRepairChangesOnlyOnePunctuationMarkAndRequiresACompleteResult() throws {
        let missingColon = #"{"🧭" true}"#
        let colonPlan = try LocalJSONCheck.singleDelimiterRepair(in: missingColon, allowsComments: false)
        let colon = try #require(colonPlan)
        #expect(colon.delimiter == .colon)
        #expect((missingColon as NSString).replacingCharacters(in: .init(location: colon.offset, length: 0),
            with: colon.delimiter.rawValue) == #"{"🧭": true}"#)
        let missingComma = "[{\"key\": \"🧭\"} /* keep the explanation */\n false]"
        let commaPlan = try LocalJSONCheck.singleDelimiterRepair(in: missingComma, allowsComments: true)
        let comma = try #require(commaPlan)
        #expect(comma.delimiter == .comma)
        #expect((missingComma as NSString).replacingCharacters(in: .init(location: comma.offset, length: 0),
            with: comma.delimiter.rawValue) == "[{\"key\": \"🧭\"}, /* keep the explanation */\n false]")
        for draft in [missingComma, #"{"a" true "b": 2}"#, #"{"a": "unfinished}"#, #"{"a": true}"#] {
            #expect(try LocalJSONCheck.singleDelimiterRepair(in: draft, allowsComments: false) == nil)
        }
    }

    @Test func schemaValuesCompareExactlyAndBooleanIsNotANumber() throws {
        let schema = #"{"const":{"values":[1e1,-0,9007199254740993,true]}}"#
        let exact = try LocalJSONCheck.check(#"{"values":[10.0,0,9007199254740993,true]}"#, allowsComments: false, schema: schema)
        #expect(exact == .checked(issues: [], moreIssues: false))
        for text in [#"{"values":[10,0,9007199254740992,true]}"#, #"{"values":[10,0,9007199254740993,1]}"#] {
            let result = try LocalJSONCheck.check(text, allowsComments: false, schema: schema)
            guard case .checked(let issues, false) = result else { Issue.record("Expected a constant mismatch"); continue }
            #expect(issues.count == 1)
        }
        let length = try LocalJSONCheck.check(#""🚀e\u0301""#, allowsComments: false, schema: #"{"minLength":3,"maxLength":3}"#)
        #expect(length == .checked(issues: [], moreIssues: false))
    }

    @Test func refusesUnsupportedRulesAndBoundsFindings() throws {
        let rejected = [
            #"{"$ref":"https://example.invalid/schema.json"}"#,
            ##"{"$defs":{"item":true},"$ref":"#/$defs/item~2"}"##,
            ##"{"$ref":"#"}"##,
            #"{"properties":{"unused":{"pattern":"x"}}}"#,
            #"{"type":"unknown"}"#,
            ##"{"const":true,"$ref":"#/const"}"##
        ]
        for schema in rejected {
            guard case .unavailable = try LocalJSONCheck.check("{}", allowsComments: false, schema: schema) else {
                Issue.record("An unsupported or invalid schema was accepted")
                continue
            }
        }
        let array = "[" + Array(repeating: "null", count: 32).joined(separator: ",") + "]"
        let bounded = try LocalJSONCheck.check(array, allowsComments: false, schema: #"{"items":false}"#)
        guard case .checked(let issues, true) = bounded else { Issue.record("Expected a bounded result"); return }
        #expect(issues.count == 24)
        let deeplyNested = String(repeating: "[", count: 80) + "0" + String(repeating: "]", count: 80)
        guard case .unavailable = try LocalJSONCheck.check(deeplyNested, allowsComments: false) else {
            Issue.record("The check exceeded its nesting limit"); return
        }
    }

    @Test func schemaNumericBoundsRetainExactPrecision() throws {
        let cases: [(String, String, Bool)] = [
            ("9007199254740992", #"{"minimum":9007199254740993}"#, false),
            ("9.007199254740993e15", #"{"minimum":9007199254740993}"#, true),
            ("1.000001", #"{"maximum":1}"#, false),
            ("-2.0001", #"{"exclusiveMaximum":-2}"#, true),
            ("-2.0", #"{"exclusiveMaximum":-2}"#, false),
            ("1e-900", #"{"exclusiveMinimum":0}"#, true),
            ("-1e-900", #"{"minimum":0}"#, false),
            ("-0.00", #"{"maximum":0}"#, true),
            ("true", #"{"minimum":2}"#, true)
        ]
        for (text, schema, expected) in cases {
            let result = try LocalJSONCheck.check(text, allowsComments: false, schema: schema)
            guard case .checked(let issues, false) = result else { Issue.record("Expected a numeric check"); return }
            #expect(issues.isEmpty == expected)
            #expect((issues.first?.offset ?? 0) == 0)
        }
        guard case .unavailable = try LocalJSONCheck.check("1", allowsComments: false, schema: #"{"maximum":"1"}"#) else {
            Issue.record("Expected the schema to refuse a nonnumeric limit"); return
        }
    }

    @Test func schemaAlternativesDoNotLeakTrialFindings() throws {
        let alternatives = #"{"anyOf":[{"items":false},{"type":"array"}],"minItems":2}"#
        let result = try LocalJSONCheck.check("[null]", allowsComments: false, schema: alternatives)
        guard case .checked(let issues, false) = result else { Issue.record("Expected one count finding"); return }
        #expect(issues.map(\.message) == ["Expected at least 2 items."])
        let array = "[" + Array(repeating: "null", count: 32).joined(separator: ",") + "]"
        #expect(try LocalJSONCheck.check(array, allowsComments: false, schema: alternatives) == .checked(issues: [], moreIssues: false))

        let cases: [(String, String, Bool)] = [
            ("2", #"{"allOf":[{"minimum":1},{"maximum":3}]}"#, true),
            ("4", #"{"allOf":[{"minimum":1},{"maximum":3}]}"#, false),
            ("true", #"{"anyOf":[{"type":"number"},false]}"#, false),
            ("1.5", #"{"oneOf":[{"type":"number"},{"type":"integer"}]}"#, true),
            ("1", #"{"oneOf":[{"type":"number"},{"type":"integer"}]}"#, false),
            ("null", #"{"oneOf":[{"type":"number"},{"type":"integer"}]}"#, false),
            ("null", #"{"not":{"type":"integer"}}"#, true),
            ("1", #"{"not":{"type":"integer"}}"#, false),
            ("1", #"{"allOf":[{"if":true},{"then":false}]}"#, true),
            ("1", ##"{"$defs":{"choice":{"oneOf":[true,false]}},"$ref":"#/$defs/choice/oneOf/0"}"##, true),
            ("1", ##"{"$defs":{"choice":{"if":true,"then":false}},"$ref":"#/$defs/choice/then"}"##, false)
        ]
        for (text, schema, expected) in cases {
            let result = try LocalJSONCheck.check(text, allowsComments: false, schema: schema)
            guard case .checked(let findings, false) = result else { Issue.record("Expected a composition result"); return }
            #expect(findings.isEmpty == expected)
        }
        for schema in [#"{"anyOf":[]}"#, #"{"allOf":[1]}"#, #"{"if":false,"then":{"pattern":"x"}}"#,
                       ##"{"$defs":{"choice":{"oneOf":[true,false]}},"$ref":"#/$defs/choice/oneOf/01"}"##] {
            guard case .unavailable = try LocalJSONCheck.check("{}", allowsComments: false, schema: schema) else {
                Issue.record("Expected malformed or unsupported rule to be unavailable"); return
            }
        }
    }

    @Test func schemaConditionSelectsOneBranchAndTupleChecksRemainingItems() throws {
        let condition = #"{"if":{"type":"number"},"then":{"minimum":2},"else":{"type":"string"}}"#
        let valid = try LocalJSONCheck.check(#""text""#, allowsComments: false, schema: condition)
        #expect(valid == .checked(issues: [], moreIssues: false))
        let invalid = try LocalJSONCheck.check("1", allowsComments: false, schema: condition)
        guard case .checked(let selected, false) = invalid else { Issue.record("Expected the number rule"); return }
        #expect(selected.map(\.message) == ["This number is below the schema’s minimum."])

        let tuple = #"{"prefixItems":[{"type":"string"},{"type":"integer"}],"items":false}"#
        let short = try LocalJSONCheck.check(#"["only one"]"#, allowsComments: false, schema: tuple)
        #expect(short == .checked(issues: [], moreIssues: false))
        let source = #"["one",false,3]"#
        let extra = try LocalJSONCheck.check(source, allowsComments: false, schema: tuple)
        guard case .checked(let issues, false) = extra else { Issue.record("Expected both invalid positions"); return }
        #expect(issues.map(\.offset) == [7, 13])
        #expect(issues.map(\.message) == ["Expected integer.", "This schema does not allow a value here."])
    }

    @Test func selectedSchemaReadIsBoundedAndDoesNotFollowLinks() throws {
        let root = try FileOperationTestFixtures.base().appendingPathComponent(UUID().uuidString, isDirectory: true)
        let files = FileManager.default
        try files.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? files.removeItem(at: root) }
        let url = root.appendingPathComponent("schema.json")
        let schema = Data(#"{"type":"object"}"#.utf8)
        try schema.write(to: url)
        let passed = try LocalJSONCheck.check("{}", allowsComments: false, schemaFile: url)
        #expect(passed == .checked(issues: [], moreIssues: false))
        #expect(try Data(contentsOf: url) == schema)
        let link = root.appendingPathComponent("linked.json")
        try files.createSymbolicLink(at: link, withDestinationURL: url)
        guard case .unavailable = try LocalJSONCheck.check("{}", allowsComments: false, schemaFile: link) else {
            Issue.record("The schema reader followed a symbolic link"); return
        }
        try Data(repeating: 32, count: LocalJSONCheck.maximumSchemaBytes + 1).write(to: url)
        guard case .unavailable = try LocalJSONCheck.check("{}", allowsComments: false, schemaFile: url) else {
            Issue.record("The schema reader exceeded its byte limit"); return
        }
    }
}
