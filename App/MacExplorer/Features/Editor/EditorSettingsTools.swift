import SwiftUI
import UniformTypeIdentifiers

/// Native forms use the existing full-heading TraverseDisclosureStyle. No
/// browsing, body reads, application launch or LaunchServices writes occur here.
struct EditorSettingsTools: View {
    @ObservedObject var settings: BrowserSettings
    @State private var defaultsExpanded = true
    @State private var syntaxExpanded = true
    @State private var openingExpanded = false
    @State private var addedExtension = ""
    @State private var extraTypesExpanded = false
    @State private var pendingApplicationExtension: String?
    @State private var choosingApplication = false
    @State private var notice = ""
    @Environment(\.settingsSearchPresentation) private var search
    private var preferences: Binding<EditorPreferences> {
        Binding(get: { settings.editorPreferences }, set: { value in settings.updateEditorPreferences(value) })
    }
    private var additionalTypes: [EditorOpeningSupport.FileType] {
        EditorOpeningSupport.additionalTypes(in: settings.editorPreferences)
    }
    private var revealsAdditionalType: Bool {
        guard let key = search.revealed?.id.key else { return false }
        return key == "Additional File Types" || additionalTypes.contains { SettingsSearchCatalog.openingKey(for: $0) == key }
    }
    private func openingSelection(for key: String) -> Binding<Int> {
        Binding(get: {
            switch settings.editorPreferences.target(forExtension: key) {
            case .traverse: 0
            case .systemDefault: 1
            case .externalApplication: 2
            }
        }, set: { choice in
            if choice == 2 {
                pendingApplicationExtension = key; choosingApplication = true
            } else { updateTarget(choice == 0 ? .traverse : .systemDefault, for: key) }
        })
    }
    private func chooseApplication(for key: String) {
        pendingApplicationExtension = key; choosingApplication = true
    }
    private func openingRow(_ type: EditorOpeningSupport.FileType) -> some View {
        let builtIn = EditorOpeningSupport.extensions.contains(type.fileExtension)
        return VStack(alignment: .leading, spacing: 4) {
            LabeledContent {
                Picker("Open \(type.title)", selection: openingSelection(for: type.fileExtension)) {
                    Text("Traverse Editor").tag(0)
                    Text("macOS Default").tag(1)
                    Text("Custom App…").tag(2)
                }
                .labelsHidden()
                .accessibilityLabel(builtIn ? "Open \(type.title) (\(type.matchLabel))" : "Open \(type.title)")
                .accessibilityIdentifier("EditorOpening-" + type.fileExtension)
                .frame(minWidth: 130, idealWidth: 175, maxWidth: 220)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(type.title)
                    if builtIn {
                        Text(type.matchLabel).interfaceFont(.caption).foregroundStyle(.secondary)
                            .lineLimit(2).help(type.matchLabel)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            if case .externalApplication(let url) = settings.editorPreferences.target(forExtension: type.fileExtension) {
                HStack {
                    Text(url.deletingPathExtension().lastPathComponent)
                        .interfaceFont(.caption).foregroundStyle(.secondary)
                        .lineLimit(2)
                    Spacer(minLength: 8)
                    Button("Change App…") { chooseApplication(for: type.fileExtension) }
                        .controlSize(.small)
                }
            }
        }
        .settingsSearchAnchor(SettingsSearchCatalog.openingKey(for: type))
        .contextMenu {
            Button("Use Recommended Choice") {
                var value = settings.editorPreferences
                do {
                    try value.clearTarget(forExtension: type.fileExtension)
                    settings.updateEditorPreferences(value); notice = ""
                } catch { notice = "This choice could not be reset." }
            }
        }
    }
    private func updateTarget(_ target: EditorOpeningTarget, for key: String) {
        var value = settings.editorPreferences
        do {
            try value.setTarget(target, forExtension: key)
            settings.updateEditorPreferences(value); notice = ""
        } catch { notice = "This choice could not be saved. Use an extension of up to 24 letters or numbers; up to 64 choices can be stored." }
    }
    var body: some View {
        Form {
            Section("Drives") {
                settingToggle("Live SMART readings while Drives is visible", isOn: Binding(get: {
                    DriveHealthFeature.liveUpdatesAvailable && settings.driveHealthLiveUpdatesSelected
                }, set: { settings.setDriveHealthLiveUpdates($0) }))
                    .disabled(!DriveHealthFeature.liveUpdatesAvailable)
                settingPicker("Update readings every", selection: $settings.driveHealthIntervalSeconds) {
                    ForEach([1, 2, 5, 10, 30, 60], id: \.self) { Text("\($0) second\($0 == 1 ? "" : "s")").tag($0) }
                }.disabled(!DriveHealthFeature.liveUpdatesAvailable)
                Text(DriveHealthFeature.liveUpdatesAvailable
                    ? (DriveHealthFeature.requiresLiveOptIn
                        ? "Enable Live to monitor internal drives in Overview, Health and Benchmark. Readings pause when the window is hidden or the Mac sleeps. Manual checks remain available for other connections."
                        : "Monitor the selected drive in Overview, Health and Benchmark. Readings pause when the window is hidden or the Mac sleeps. Availability depends on the drive and its connection.")
                    : DriveHealthFeature.liveUpdatesHelp)
                    .interfaceFont(.caption).foregroundStyle(.secondary)
            }
            if !settings.preferencesPersistenceStatus.isEmpty {
                Section { Text(settings.preferencesPersistenceStatus).interfaceFont(.caption).foregroundStyle(.secondary) }
            }
            Section {
                DisclosureGroup(isExpanded: expanded($defaultsExpanded, for: "Editor Defaults")) {
                    settingPicker("Open documents in", selection: preferences.windowArrangement) {
                        ForEach(EditorWindowArrangement.allCases) { Text($0.title).tag($0) }
                    }
                    Text("Choose how new documents open. Local files and each server connection have their own tabs. You can drag a tab out to use a separate window.")
                        .interfaceFont(.caption).foregroundStyle(.secondary)
                    settingToggle("Show the Files sidebar in new local editors", isOn: preferences.opensFileSidebar)
                    settingToggle("Include generated folders in project searches", isOn: preferences.includesGeneratedProjectFolders)
                        .help("Includes node_modules, .build, DerivedData, .venv and __pycache__. The hidden files preference also applies.")
                    settingToggle("Highlight on-disk changes in Git projects", isOn: preferences.showsWorkingGitChanges)
                        .disabled(!settings.showsGitControls)
                    Text("Checks whether the visible files’ bytes differ from the Git index. Files up to 1 MiB are eligible.")
                        .interfaceFont(.caption).foregroundStyle(.secondary)
                    settingToggle("Wrap lines", isOn: preferences.wrapsLines)
                    settingToggle("Show line numbers", isOn: preferences.showsLineNumbers)
                    settingToggle("Show indent guides", isOn: preferences.showsIndentGuides)
                    settingToggle("Highlight matching brackets", isOn: preferences.showsMatchingBrackets)
                    settingToggle("Show JSON issues while editing", isOn: preferences.showsLiveJSONIssues)
                        .help("Highlight the first syntax issue in JSON, JSON with Comments and JSON Lines documents up to 128 KiB.")
                    settingToggle("Show whitespace marks", isOn: preferences.showsWhitespaceMarks)
                        .help("Make spaces, tabs and line breaks visible in the editor and text comparisons.")
                    settingToggle("Mark unsaved lines", isOn: preferences.showsUnsavedLineChanges)
                    settingToggle("Show scope while scrolling", isOn: preferences.showsScrollContext)
                        .help("Show the active heading or supported code block beside the file path.")
                    settingToggle("Link scrolling in new text comparisons", isOn: preferences.linksComparisonScrolling)
                    settingPicker("Text size", selection: preferences.basePointSize) {
                        ForEach(11...22, id: \.self) { Text("\($0) pt").tag($0) }
                    }
                    settingPicker("Indent width", selection: preferences.indentation.columns) {
                        ForEach([2, 4, 8], id: \.self) { Text("\($0) columns").tag($0) }
                    }
                    settingPicker("Indent using", selection: preferences.indentation.insertion) {
                        Text("Spaces").tag(EditorIndentationPreferences.Insertion.spaces)
                        Text("Tabs").tag(EditorIndentationPreferences.Insertion.tabs)
                    }
                    settingToggle("Continue line indentation", isOn: preferences.indentation.continuesIndentation)
                    settingToggle("Backspace removes one indent level", isOn: preferences.backspaceUnindents)
                    settingToggle("Indent code blocks on Return", isOn: preferences.indentsCodeBlocks)
                        .help("Swift, Rust, JavaScript, TypeScript, C-family and CSS braces, and Python suite headers")
                    settingToggle("Indent JSON blocks on Return", isOn: preferences.indentsJSONBlocks)
                    settingToggle("Complete JSON brackets", isOn: preferences.completesJSONBrackets)
                    settingToggle("Complete code brackets", isOn: preferences.completesCodeBrackets)
                        .help("Complete parentheses, brackets and braces in supported code when the editor can identify the context.")
                    settingToggle("Suggest local names inline", isOn: preferences.showsInlineNames)
                        .help("Preview one matching name from this file. Press Tab to accept it or Escape to dismiss it.")
                    Text("Existing tabs use the chosen width. Continue line indentation keeps the current line’s spaces and tabs. JSON block indentation independently adds an inner line after a JSON or JSONC brace or bracket.")
                        .interfaceFont(.caption).foregroundStyle(.secondary)
                    Text("Complete JSON brackets inserts matching braces and brackets in JSON and JSONC. Type the matching close to move past it, or press Backspace inside an empty new pair to remove both.")
                        .interfaceFont(.caption).foregroundStyle(.secondary)
                    Text("In code, Backspace in leading spaces returns to the previous indent stop. Plain text, selected text and mixed tabs keep normal deletion.")
                        .interfaceFont(.caption).foregroundStyle(.secondary)
                    Text("Text size follows the app's Interface Size. Wrap and syntax changes made inside a document stay with that window until it closes.")
                        .interfaceFont(.caption).foregroundStyle(.secondary)
                } label: { Text("Editor Defaults").interfaceFont(.headline) }
            }
            Section {
                DisclosureGroup(isExpanded: expanded($syntaxExpanded, for: "Syntax & Theme")) {
                    settingPicker("Editor theme", selection: preferences.theme) {
                        ForEach(EditorTheme.allCases) { Text($0.title).tag($0) }
                    }
                    settingPicker("Syntax colors", selection: preferences.palette) {
                        ForEach(EditorSyntaxPalette.allCases) { Text($0.title).tag($0) }
                    }
                    settingPicker("Default syntax", selection: preferences.defaultLanguage) {
                        Text("Automatic").tag(Optional<TextSyntaxLanguage>.none)
                        ForEach(TextSyntaxLanguage.allCases, id: \.self) { Text($0.title).tag(Optional($0)) }
                    }
                    settingToggle("Detect language in files without an extension", isOn: preferences.detectsLanguageWithoutExtension)
                    Text("Recognize clear JSON, HTML, XML and script headers while editing. Your selected language always takes priority. This changes syntax and editing conveniences, and keeps the filename you chose.")
                        .interfaceFont(.caption).foregroundStyle(.secondary)
                    settingPicker("Find highlight", selection: preferences.findHighlightColor) {
                        ForEach(EditorFindHighlightColor.allCases) { Text($0.title).tag($0) }
                    }
                    Text("Find match")
                        .interfaceFont(.system(size: 12, design: .monospaced))
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(findPreviewColor.opacity(0.18), in: RoundedRectangle(cornerRadius: 3))
                        .overlay(RoundedRectangle(cornerRadius: 3).stroke(findPreviewColor.opacity(0.55), lineWidth: 1))
                        .accessibilityLabel("Find highlight color preview")
                    HStack(spacing: 12) {
                        sample("Key", .property); sample("String", .string); sample("123", .number)
                        sample("true / null", .literal); sample("{ : }", .punctuation)
                    }.accessibilityElement(children: .combine)
                    Text("Language colors are hints; your code is never run or indexed. Theme changes apply to the text area and leave the app's appearance choice intact.")
                        .interfaceFont(.caption).foregroundStyle(.secondary)
                } label: { Text("Syntax & Theme").interfaceFont(.headline) }
            }
            Section {
                DisclosureGroup(isExpanded: expanded($openingExpanded, for: "Open Files With")) {
                    Text("Supported text files open in Traverse by default. Choose a different app for any type below.")
                        .interfaceFont(.caption).foregroundStyle(.secondary)
                    ForEach(EditorOpeningSupport.fileTypes) { openingRow($0) }
                    DisclosureGroup(isExpanded: Binding(get: { extraTypesExpanded || revealsAdditionalType },
                        set: { extraTypesExpanded = $0 })) {
                        ForEach(additionalTypes, content: openingRow)
                        HStack {
                            TextField("Extension, without a dot", text: $addedExtension)
                                .onChange(of: addedExtension) { _, value in
                                    if value.count > 24 { addedExtension = String(value.prefix(24)) }
                                }
                            Button("Add") { addType() }
                                .disabled(EditorPreferences.extensionKey(addedExtension) == nil)
                        }
                    } label: { Text("Additional File Types").settingsSearchAnchor("Additional File Types") }
                    settingPicker("File icons", selection: preferences.openingIndicator) {
                        ForEach(EditorOpeningIndicator.allCases) { Text($0.title).tag($0) }
                    }
                    Text("Icon indicators show your opening choice inside Traverse. Files are checked when opened. Open in Default App always uses macOS’s choice; these settings do not change Finder.")
                        .interfaceFont(.caption).foregroundStyle(.secondary)
                    if !notice.isEmpty { Text(notice).interfaceFont(.caption).foregroundStyle(.secondary) }
                } label: { Text("Open Files With").interfaceFont(.headline).settingsSearchAnchor("Open Files With") }
            }
        }.formStyle(.grouped)
            .onChange(of: search.revealed, initial: true) { _, entry in
                if revealsAdditionalType { extraTypesExpanded = true }
                switch entry?.section {
                case "Editor Defaults": defaultsExpanded = true
                case "Syntax & Theme": syntaxExpanded = true
                case "Open Files With": openingExpanded = true
                default: break
                }
            }
        .fileImporter(isPresented: $choosingApplication, allowedContentTypes: [.applicationBundle], allowsMultipleSelection: false) { result in
            let key = pendingApplicationExtension; pendingApplicationExtension = nil
            guard let key else { return }
            switch result {
            case .success(let urls):
                guard urls.count == 1, let url = urls.first,
                      EditorPreferences.validTarget(.externalApplication(url)) else { notice = "Choose one local application."; return }
                updateTarget(.externalApplication(url), for: key)
            case .failure: notice = "Application choice was not changed."
            }
        }
        .fileDialogDefaultDirectory(URL(fileURLWithPath: "/Applications", isDirectory: true))
        .fileDialogConfirmationLabel("Choose Application")
    }

    private func expanded(_ value: Binding<Bool>, for section: String) -> Binding<Bool> {
        Binding(get: { value.wrappedValue || search.revealed?.section == section },
                set: { value.wrappedValue = $0 })
    }
    private func addType() {
        guard let key = EditorPreferences.extensionKey(addedExtension) else { return }
        updateTarget(.traverse, for: key)
        if notice.isEmpty { addedExtension = "" }
    }
    private var findPreviewColor: Color {
        switch settings.editorPreferences.findHighlightColor {
        case .blue: .blue
        case .accent: .accentColor
        case .purple: .purple
        case .teal: .teal
        case .orange: .orange
        }
    }
    private func sample(_ title: String, _ kind: TextSyntaxToken.Kind) -> some View {
        Text(title).interfaceFont(.system(size: 12, design: .monospaced))
            .foregroundStyle(Color(nsColor: EditorSyntaxColors.color(for: kind, palette: settings.editorPreferences.palette)))
    }
}
