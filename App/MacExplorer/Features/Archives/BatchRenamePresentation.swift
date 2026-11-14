import FileOperations
import SwiftUI

/// Shared naming controls and preview, independent of local-file or ZIP
/// transaction ownership. Neither this value nor its views mutate any file.
struct BatchRenameOptions: Equatable, Sendable {
    enum Mode: String, CaseIterable, Sendable { case add = "Add Text", replace = "Replace Text", number = "Name and Number" }
    var mode = Mode.add
    var prefix = "", suffix = "", find = "", replacement = "", base = "Item", separator = " "
    var start = 1, digits = 3, preserveExtension = true
    var rule: BatchRenameRule {
        switch mode {
        case .add: .addText(prefix: prefix, suffix: suffix, preserveExtension: preserveExtension)
        case .replace: .replace(find: find, with: replacement, preserveExtension: preserveExtension)
        case .number: .numbered(base: base, separator: separator, start: start, digits: digits, preserveExtension: preserveExtension)
        }
    }
    func preview(_ names: [BatchRenameName]) throws -> [BatchRenamePreviewRow] {
        try zip(names, rule.names(for: names)).enumerated().map { index, value in
            let changed = !value.0.name.utf8.elementsEqual(value.1.utf8)
            return .init(id: index, before: value.0.name, after: value.1,
                status: changed ? "Will rename" : "Unchanged", changed: changed)
        }
    }
}

struct BatchRenamePreviewRow: Identifiable, Sendable {
    let id: Int, before: String, after: String, status: String
    let changed: Bool
}

struct BatchRenameRuleFields: View {
    @Binding var options: BatchRenameOptions
    @ObservedObject var settings: BrowserSettings
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Change", selection: $options.mode) {
                ForEach(BatchRenameOptions.Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented)
            Group {
                switch options.mode {
                case .add:
                    HStack { TextField("Prefix", text: $options.prefix); TextField("Suffix", text: $options.suffix) }
                case .replace:
                    HStack {
                        TextField("Find (literal)", text: $options.find); Image(systemName: "arrow.right")
                        TextField("Replace with", text: $options.replacement)
                    }
                case .number:
                    ViewThatFits(in: .horizontal) {
                        HStack { nameFields; numberFields }
                        VStack(alignment: .leading) { HStack { nameFields }; HStack { numberFields; Spacer() } }
                    }
                }
            }.textFieldStyle(ToolTextEntryStyle()).toolPageCrossfade(options.mode, motion: settings.motion)
            HStack {
                Toggle("Keep file extensions", isOn: $options.preserveExtension)
                Spacer(); Text("Numbers follow this captured order").interfaceFont(.caption).foregroundStyle(.secondary)
            }
        }
    }
    @ViewBuilder private var nameFields: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Base name").interfaceFont(.caption).foregroundStyle(.secondary)
            TextField("Base name", text: $options.base)
        }.frame(minWidth: 160)
        VStack(alignment: .leading, spacing: 4) {
            Text("Separator").interfaceFont(.caption).foregroundStyle(.secondary)
            TextField("Separator", text: $options.separator).accessibilityLabel("Number separator")
        }.frame(width: 85)
    }
    @ViewBuilder private var numberFields: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Start").interfaceFont(.caption).foregroundStyle(.secondary)
            TextField("Start", value: $options.start, format: .number.grouping(.never)).accessibilityLabel("Starting number")
        }.frame(width: 72)
        VStack(alignment: .leading, spacing: 4) {
            Text("Digits").interfaceFont(.caption).foregroundStyle(.secondary)
            Picker("Digits", selection: $options.digits) { ForEach(1...9, id: \.self) { Text(String($0)).tag($0) } }
                .labelsHidden()
        }.frame(width: 70)
    }
}

struct BatchRenamePreviewTable: View {
    let rows: [BatchRenamePreviewRow]
    @Binding var selection: Set<Int>
    var body: some View {
        Table(rows, selection: $selection) {
            TableColumn("Before") { Text($0.before).lineLimit(1).truncationMode(.middle).help($0.before) }
                .width(min: 160, ideal: 280)
            TableColumn("After") {
                Text($0.after).foregroundStyle($0.changed ? Color.primary : Color.secondary)
                    .lineLimit(1).truncationMode(.middle).help($0.after)
            }.width(min: 160, ideal: 280)
            TableColumn("Result") { Text($0.status).interfaceFont(.caption).foregroundStyle(.secondary) }.width(95)
        }.scrollContentBackground(.hidden).alternatingRowBackgrounds(.disabled)
    }
}
