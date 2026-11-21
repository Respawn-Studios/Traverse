import AppKit
#if canImport(FileOperations)
import FileOperations
#endif

@MainActor
final class EditorCodeTextView: NSTextView {
    struct InlineName: Equatable {
        let suffix: String
        let offset: Int
    }

    var comparisonHighlights: [NSRange] = [] { didSet { needsDisplay = true } }
    var comparisonDetails: [NSRange] = [] { didSet { needsDisplay = true } }
    var comparisonAccent: EditorComparisonBackground.Accent? { didSet { needsDisplay = true } }
    var findHighlights: [NSRange] = [] { didSet { needsDisplay = true } }
    var currentFindHighlight: NSRange? { didSet { if oldValue != currentFindHighlight { needsDisplay = true } } }
    var findHighlightColor = NSColor.systemBlue { didSet { needsDisplay = true } }
    var bracketHighlights: [NSRange] = [] { didSet { if oldValue != bracketHighlights { needsDisplay = true } } }
    var diagnosticRanges: [NSRange] = [] { didSet { if oldValue != diagnosticRanges { needsDisplay = true } } }
    var foldedOpenings: [NSRange] = [] { didSet { if oldValue != foldedOpenings { needsDisplay = true } } }
    var showsInlineNames = false
    var inlineName: InlineName? { didSet { if oldValue != inlineName { needsDisplay = true } } }
    var onTypedNameKey: (() -> Void)?
    var onAcceptInlineName: (() -> Bool)?
    var onDismissInlineName: (() -> Bool)?
    #if DEBUG
    private(set) var findBackgroundDrawsForVerification = 0
    #endif
    var onFindAction: ((NSTextFinder.Action) -> Void)?
    var onCompleteLocalName: (() -> Void)?
    override func complete(_ sender: Any?) { onCompleteLocalName?() }
    override func performTextFinderAction(_ sender: Any?) {
        guard let item = sender as? NSMenuItem, let action = NSTextFinder.Action(rawValue: item.tag) else { return }
        onFindAction?(action)
    }
    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        EditorComparisonBackground.draw(comparisonHighlights, details: comparisonDetails, accent: comparisonAccent,
            text: self, dirtyRect: rect)
        EditorIndentGuides.draw(in: self, dirtyRect: rect)
        #if DEBUG
        if !findHighlights.isEmpty { findBackgroundDrawsForVerification += 1 }
        #endif
        EditorFindHighlights.draw(findHighlights, current: currentFindHighlight, color: findHighlightColor,
                                  text: self, dirtyRect: rect)
        drawMatchingBrackets(in: rect)
        drawDiagnostics(in: rect)
        EditorCodeFolding.drawOpenings(foldedOpenings, text: self, dirtyRect: rect)
        EditorWhitespaceMarks.draw(in: self, dirtyRect: rect)
        if let (suffix, frame, attributes) = inlineNameLayout(), frame.intersects(rect) {
            (suffix as NSString).draw(at: frame.origin, withAttributes: attributes)
        }
    }

    var hasVisibleInlineName: Bool { inlineNameLayout() != nil }

    private func inlineNameLayout() -> (String, NSRect, [NSAttributedString.Key: Any])? {
        guard let hint = inlineName, let font, let window, window.isKeyWindow, window.attachedSheet == nil,
              window.firstResponder === self,
              selectedRanges.count == 1, selectedRange() == NSRange(location: hint.offset, length: 0),
              !hasMarkedText(), isEditable else { return nil }
        var actual = NSRange()
        let screen = firstRect(forCharacterRange: selectedRange(), actualRange: &actual)
        guard actual == selectedRange(), screen.height > 0 else { return nil }
        let caret = convert(window.convertFromScreen(screen), from: nil)
        let color: NSColor = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? .labelColor : .secondaryLabelColor
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let size = (hint.suffix as NSString).size(withAttributes: attributes)
        let frame = NSRect(x: caret.minX, y: caret.minY + (caret.height - size.height) / 2,
                           width: size.width, height: size.height)
        guard visibleRect.insetBy(dx: textContainer?.lineFragmentPadding ?? 0, dy: 0).contains(frame) else { return nil }
        return (hint.suffix, frame, attributes)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, onDismissInlineName?() == true { return }
        guard showsInlineNames, isEditable, !hasMarkedText(), selectedRanges.count == 1,
              event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
              let typed = event.characters, typed.utf16.count == 1, let scalar = typed.unicodeScalars.first,
              scalar.isASCII, EditorDocumentOutline.isIdentifierContinuation(scalar, language: indentationLanguage) else {
            super.keyDown(with: event); return
        }
        let initial = selectedRange(), mutation = textMutationCount
        super.keyDown(with: event)
        if initial.length == 0, textMutationCount == mutation &+ 1, !hasMarkedText(),
           selectedRange() == NSRange(location: initial.location + 1, length: 0) {
            onTypedNameKey?()
        }
    }

    private func drawDiagnostics(in rect: NSRect) {
        guard !diagnosticRanges.isEmpty, !hasMarkedText(),
              let viewport = EditorTextViewport(self, drawing: rect) else { return }
        let line = NSBezierPath()
        line.lineWidth = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 2.5 : 1.8
        let flipped = isFlipped
        for range in diagnosticRanges {
            viewport.forEachVisibleBox(in: range) { bounds in
                let y = flipped ? bounds.maxY - 2 : bounds.minY + 2
                line.move(to: .init(x: bounds.minX, y: y))
                line.line(to: .init(x: max(bounds.maxX, bounds.minX + 5), y: y))
            }
        }
        NSColor.systemRed.setStroke()
        line.stroke()
    }

    private func drawMatchingBrackets(in rect: NSRect) {
        guard !bracketHighlights.isEmpty, window?.isKeyWindow == true, window?.firstResponder === self,
              !hasMarkedText(), let viewport = EditorTextViewport(self, drawing: rect) else { return }
        let highContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        let color = NSColor.labelColor
        for range in bracketHighlights {
            viewport.forEachVisibleBox(in: range) { bounds in
                let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: -0.5, dy: 0.5), xRadius: 2, yRadius: 2)
                color.withAlphaComponent(0.09).setFill()
                shape.fill()
                color.withAlphaComponent(highContrast ? 0.9 : 0.53).setStroke()
                shape.lineWidth = highContrast ? 1.5 : 1
                shape.stroke()
            }
        }
    }
    var indentationPreferences = EditorIndentationPreferences.fresh {
        didSet { if oldValue != indentationPreferences { clearBracketPairs(); needsDisplay = true } }
    }
    var indentationLanguage = TextSyntaxLanguage.plain {
        didSet { if oldValue != indentationLanguage { clearBracketPairs(); diagnosticRanges = []; needsDisplay = true } }
    }
    var showsIndentGuides = true { didSet { if oldValue != showsIndentGuides { needsDisplay = true } } }
    var showsWhitespaceMarks = false { didSet { if oldValue != showsWhitespaceMarks { needsDisplay = true } } }
    var completesJSONBrackets = true {
        didSet { if oldValue != completesJSONBrackets { clearBracketPairs() } }
    }
    var completesCodeBrackets = false {
        didSet { if oldValue != completesCodeBrackets { clearBracketPairs() } }
    }
    private var bracketPairingEnabled: Bool {
        EditorBracketPairing.isEnabled(in: indentationLanguage, json: completesJSONBrackets, code: completesCodeBrackets)
    }
    var indentsJSONBlocks = true {
        didSet { if oldValue != indentsJSONBlocks { clearBracketPairs() } }
    }
    var indentsCodeBlocks = true
    var backspaceUnindents = true
    private var bracketCloses: [Int: UInt16] = [:]
    private var bracketSelection: NSRange?
    private var bracketEpoch = UUID()
    private var trackedInput = false
    private var textMutationCount = 0
    var onIndentationRefusal: ((TextDocumentFailure) -> Void)?
    var onInputSettled: (() -> Void)?
    var onMarkedText: (() -> Void)?
    var onInputFocusLost: (() -> Void)?
    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted && !bracketHighlights.isEmpty { needsDisplay = true }
        return accepted
    }
    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            clearBracketPairs()
            onInputFocusLost?()
            if !bracketHighlights.isEmpty { needsDisplay = true }
        }
        return resigned
    }
    /// Native insertion still owns selection, replacement, IME and text Undo.
    /// Explicit pasted CRLF is normalized to the editor's LF buffer. Bracket
    /// completion remains one native insertion, with no secondary Undo stack.
    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        let normalized: String
        if let value = insertString as? String {
            normalized = value.replacingOccurrences(of: "\r\n", with: "\n")
        } else if let value = insertString as? NSAttributedString {
            normalized = value.string.replacingOccurrences(of: "\r\n", with: "\n")
        } else {
            clearBracketPairs()
            super.insertText(insertString, replacementRange: replacementRange)
            if !hasMarkedText() { onInputSettled?() }
            return
        }
        guard !trackedInput, isEditable, !hasMarkedText(), selectedRanges.count == 1,
              let storage = textStorage else {
            clearBracketPairs()
            super.insertText(normalized, replacementRange: replacementRange)
            if !hasMarkedText() { onInputSettled?() }
            return
        }
        let selected = selectedRange()
        let range = replacementRange.location == NSNotFound ? selected : replacementRange
        let length = storage.length
        guard range.location >= 0, range.length >= 0, range.location <= length,
              range.length <= length - range.location else {
            clearBracketPairs(); super.insertText(normalized, replacementRange: replacementRange)
            if !hasMarkedText() { onInputSettled?() }
            return
        }
        let source = storage.mutableString
        func scalarBoundary(_ offset: Int) -> Bool {
            offset == 0 || offset == length || !((0xD800...0xDBFF).contains(source.character(at: offset - 1))
                && (0xDC00...0xDFFF).contains(source.character(at: offset)))
        }
        var plan = EditorBracketPairing.Plan.native
        var closingOffset = range.location
        if bracketPairingEnabled, normalized.utf16.count == 1, let unit = normalized.utf16.first,
           range == selected, range.length == 0, scalarBoundary(range.location) {
            // Smart Return leaves an empty inner line before the owned close.
            // A closing key may cross only a small whitespace-only gap, never
            // user content or an unowned delimiter.
            if EditorBracketPairing.isClosing(unit),
               let offset = bracketCloses.keys.filter({ $0 >= range.location }).min(),
               offset < length, offset - range.location <= 4096,
               source.substring(with: .init(location: range.location, length: offset - range.location))
                .utf16.allSatisfy({ [9, 10, 32].contains($0) }) {
                closingOffset = offset
            }
            let next = closingOffset < length ? source.character(at: closingOffset) : nil
            let owned = next != nil && bracketCloses[closingOffset] == next
            if range.location < EditorIndentation.lexicalInputLimit,
               EditorBracketPairing.needsContext(unit, next: next, ownsNextClose: owned, language: indentationLanguage) {
                plan = EditorBracketPairing.plan(normalized, prefix: source.substring(to: range.location),
                    next: next, ownsNextClose: owned, language: indentationLanguage, enabled: true)
            }
            if case .insert = plan, bracketCloses.count >= 64 { clearBracketPairs(); plan = .native }
        }
        if case .skip = plan {
            bracketCloses.removeValue(forKey: closingOffset)
            setTrackedSelection(.init(location: closingOffset + 1, length: 0))
            scrollRangeToVisible(selectedRange())
            onInputSettled?(); return
        }
        let inserted: String
        let newClose: UInt16?
        if case .insert(let pair, let close) = plan { inserted = pair; newClose = close }
        else { inserted = normalized; newClose = nil }
        let epoch = bracketEpoch, mutation = textMutationCount
        trackedInput = true
        if newClose != nil { breakUndoCoalescing() }
        super.insertText(inserted, replacementRange: range)
        if newClose != nil { breakUndoCoalescing() }
        trackedInput = false
        // Native admission, callbacks or composition may reject/change input.
        // Verify only the bounded inserted span and length; no full-buffer copy.
        let insertedLength = inserted.utf16.count
        if bracketEpoch == epoch, textMutationCount == mutation &+ 1,
           storage.length == length - range.length + insertedLength,
           range.location + insertedLength <= storage.length,
           storage.mutableString.substring(with: .init(location: range.location, length: insertedLength)).utf16.elementsEqual(inserted.utf16) {
            var adjusted: [Int: UInt16] = [:]
            for (offset, close) in bracketCloses {
                if offset < range.location { adjusted[offset] = close }
                else if offset >= NSMaxRange(range) { adjusted[offset - range.length + insertedLength] = close }
            }
            bracketCloses = adjusted
            if let newClose {
                bracketCloses[range.location + 1] = newClose
                setTrackedSelection(.init(location: range.location + 1, length: 0))
            }
            bracketSelection = selectedRange()
        } else { clearBracketPairs() }
        if !hasMarkedText() { onInputSettled?() }
    }
    func clearBracketPairs() {
        bracketCloses.removeAll(keepingCapacity: true); bracketSelection = nil; bracketEpoch = UUID()
    }
    func nativeTextDidChange() {
        textMutationCount &+= 1
        if !trackedInput { clearBracketPairs() }
    }
    func nativeSelectionDidChange() {
        guard !trackedInput else { return }
        if bracketSelection != selectedRange() { clearBracketPairs() }
    }
    private func setTrackedSelection(_ range: NSRange) {
        bracketSelection = range
        setSelectedRange(range)
    }
    private func retainSelectionForRedo(_ range: NSRange) {
        guard let manager = undoManager, manager.isUndoRegistrationEnabled else { return }
        // Register after the native text edit. Undo keeps AppKit's selection;
        // Redo runs this after restoring the text and returns to its inner caret.
        manager.registerUndo(withTarget: self) { view in
            view.retainSelectionForRedo(range)
            guard view.undoManager?.isRedoing == true, let storage = view.textStorage,
                  range.location >= 0, range.length >= 0, range.location <= storage.length,
                  range.length <= storage.length - range.location else { return }
            view.setTrackedSelection(range)
            view.scrollRangeToVisible(range)
        }
    }
    override func unmarkText() {
        super.unmarkText()
        if !hasMarkedText() { onInputSettled?() }
    }
    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        clearBracketPairs()
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        if hasMarkedText() { onMarkedText?() } else { onInputSettled?() }
    }
    override func insertTab(_ sender: Any?) {
        guard onAcceptInlineName?() != true else { return }
        if !performIndentation(.indent) { super.insertTab(sender) }
    }
    override func insertBacktab(_ sender: Any?) { if !performIndentation(.outdent) { super.insertBacktab(sender) } }
    override func insertNewline(_ sender: Any?) { if !performIndentation(.newline) { super.insertNewline(sender) } }
    override func deleteBackward(_ sender: Any?) {
        let caret = selectedRange()
        guard bracketPairingEnabled, isEditable, !hasMarkedText(), selectedRanges.count == 1, caret.length == 0,
              let storage = textStorage, caret.location > 0, caret.location < storage.length,
              let close = bracketCloses[caret.location],
              storage.mutableString.character(at: caret.location) == close,
              EditorBracketPairing.close(forOpening: storage.mutableString.character(at: caret.location - 1)) == close else {
            clearBracketPairs()
            if backspaceUnindents, indentationLanguage != .plain, isEditable,
               !hasMarkedText(), selectedRanges.count == 1, let storage = textStorage,
               let deletion = EditorIndentation.backspaceRange(in: storage.mutableString,
                    selection: caret, preferences: indentationPreferences) {
                breakUndoCoalescing()
                insertText("", replacementRange: deletion)
                breakUndoCoalescing()
                return
            }
            super.deleteBackward(sender)
            if !hasMarkedText() { onInputSettled?() }; return
        }
        // Only this view's still-owned empty pair is removed together. The same
        // native insertion/admission path keeps one Undo and validates the edit.
        breakUndoCoalescing()
        insertText("", replacementRange: .init(location: caret.location - 1, length: 2))
        breakUndoCoalescing()
    }
    private func performIndentation(_ command: EditorIndentationCommand) -> Bool {
        guard isEditable, !hasMarkedText(), selectedRanges.count == 1 else { return false }
        let original = string
        switch EditorIndentation.plan(command, text: original, selection: selectedRange(),
                                      preferences: indentationPreferences, maximumBytes: TextDocumentValue.maximumBytes,
                                      language: indentationLanguage, indentsJSONBlocks: indentsJSONBlocks,
                                      indentsCodeBlocks: indentsCodeBlocks) {
        case .native: return false
        case .unchanged: return true
        case .refused(let reason):
            onIndentationRefusal?(reason == .tooLarge ? .tooLarge : .invalidReceipt)
            return true
        case .replace(let replacement):
            let expected = (original as NSString).replacingCharacters(in: replacement.range, with: replacement.text)
            guard expected.utf8.count <= TextDocumentValue.maximumBytes else {
                onIndentationRefusal?(.tooLarge); return true
            }
            breakUndoCoalescing()
            insertText(replacement.text, replacementRange: replacement.range)
            breakUndoCoalescing()
            // Native admission can refuse independently. Never publish the
            // planned selection unless the bounded actual buffer is exact.
            let actual = string
            if actual.utf8.count <= TextDocumentValue.maximumBytes,
               actual.utf16.elementsEqual(expected.utf16) {
                setTrackedSelection(replacement.selection)
                retainSelectionForRedo(replacement.selection)
            }
            return true
        }
    }
}

/// A native editing surface only. Reads, Save/Undo, access and durable recovery
/// belong to the separate document owner and FileOperations, never callbacks here.
@MainActor
final class NativeTextEditorSurface: NSView, NSTextViewDelegate, @preconcurrency NSTextStorageDelegate {
    static let whitespaceMarksTitle = "Show Whitespace Marks"

    struct OutlinePresentation {
        let value: EditorDocumentOutline
        let generation: UUID
        let language: TextSyntaxLanguage
    }
    struct ScrollContext: Equatable {
        let generation: UUID
        let scopes: [EditorDocumentOutline.Entry]
    }
    struct NameCompletion {
        let prefix: String
        let range: NSRange
        let entries: [EditorDocumentOutline.Entry]
        let generation: UUID
    }

    let scrollView = NSScrollView()
    let textView = EditorCodeTextView(frame: .zero)
    lazy var find = EditorFindController(surface: self)
    lazy var lineCommands = EditorLineCommandController(surface: self)
    private var jumps = EditorJumpTrail<EditorNavigationPosition>()
    private(set) var documentFormat = TextDocumentFormat(bom: false, lineEnding: .lf)
    private(set) var generation = UUID()
    private(set) var lineIndex: EditorLineIndex?
    private(set) var presentedGeneration: UUID?
    private(set) var outlinePresentation: OutlinePresentation?
    private(set) var styleRangeCount = 0
    private(set) var visibleStyleRangeCount = 0
    var onEdit: ((String, UUID) -> Void)?
    var onRejectedEdit: ((TextDocumentFailure) -> Void)?
    var onCaret: (((line: Int, column: Int)?) -> Void)?
    var onOutlineChanged: (() -> Void)?
    var onNavigationJump: ((EditorNavigationPosition) -> Void)?
    var onScrollContextChanged: ((ScrollContext?) -> Void)?
    struct JSONIssues: Equatable {
        let issues: [LocalJSONCheck.Issue]
        var hasMore = false
    }

    var onJSONIssuesChanged: ((JSONIssues) -> Void)?
    var onReviewUnsavedLine: ((Int) -> Bool)?
    var onUnsavedLineBaselineChanged: (() -> Void)?
    var onWindowAttachment: (() -> Void)?
    private(set) var scrollContext: ScrollContext?
    private var contextLine: Int?
    private var showsScrollContext = true
    private var installing = false
    private var lastEditOffset: Int?
    private var pendingInlineName: (generation: UUID, caret: NSRange)?
    private var offeredInlineName: (entry: EditorDocumentOutline.Entry, request: NameCompletion)?
    private var lineBookmarks = EditorLineBookmarks()
    private var gutter: EditorLineRuler!
    private var syntaxTokens: [TextSyntaxToken] = []
    private var styledRange = NSRange(location: 0, length: 0)
    private var refreshingViewport = false
    private var tabPresentationPending = true
    private var pointSizePending: CGFloat?
    private var defaultWhitespaceMarks = false
    private var whitespaceMarksOverride: Bool?
    private var requestedPointSize: CGFloat = 13
    private var applyingPendingPresentation = false
    private(set) var wrapsLines = true
    private(set) var syntaxPalette = EditorSyntaxPalette.adaptive
    private(set) var showsLineNumbers = true
    private var showsUnsavedLineChanges = true
    private var showsMatchingBrackets = true
    private var showsLiveJSONIssues = true
    private var liveJSONIssue: LocalJSONCheck.Issue?
    private var checkedJSONIssues: JSONIssues?
    private(set) var visibleJSONIssues = JSONIssues(issues: [])
    var jsonIssues: [LocalJSONCheck.Issue] { visibleJSONIssues.issues }
    private var bracketMatches: EditorDelimiterWalk.MatchIndex?
    private lazy var codeFolding = EditorCodeFolding(layout: textView.layoutManager)
    private var foldIndex: EditorFoldIndex?
    private var lineChangeBaselineID: UUID?
    private(set) var unsavedLineChanges: EditorUnsavedLineChanges? {
        didSet {
            if oldValue?.baselineID != unsavedLineChanges?.baselineID { onUnsavedLineBaselineChanged?() }
            gutter?.needsDisplay = true
            updateChangeMarkerCursor()
        }
    }
    private(set) var conflictMarkers: EditorConflictMarkers?

    override init(frame: NSRect) {
        super.init(frame: frame)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        // The native ruler may draw past its dirty region on recent macOS.
        // Keep its separator and partially visible labels inside the editor.
        scrollView.clipsToBounds = true
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.usesFindBar = false
        textView.isIncrementalSearchingEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.drawsBackground = false
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textColor = .labelColor
        textView.insertionPointColor = .labelColor
        textView.textContainerInset = .init(width: 10, height: 10)
        textView.minSize = .init(width: 0, height: 0)
        textView.maxSize = .init(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = .init(width: bounds.width, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        // The ruler, viewport styling and native caret share this layout
        // manager. Keep TextKit's contiguous default: native tab activation can
        // otherwise loop while filling layout holes in a multiline document.
        textView.layoutManager?.allowsNonContiguousLayout = false
        textView.layoutManager?.delegate = codeFolding
        textView.delegate = self
        // The callbacks belong to this main-actor text view's storage.
        textView.textStorage?.delegate = self
        textView.setAccessibilityLabel("Document text")
        textView.setAccessibilityElement(true)
        textView.setAccessibilityRole(.textArea)
        scrollView.documentView = textView
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(viewportChanged),
            name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(viewportChanged),
            name: NSView.frameDidChangeNotification, object: scrollView.contentView)
        gutter = EditorLineRuler(surface: self)
        scrollView.hasVerticalRuler = true
        scrollView.verticalRulerView = gutter
        scrollView.rulersVisible = true
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: find.bar.bottomAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        textView.onIndentationRefusal = { [weak self] value in self?.onRejectedEdit?(value) }
        textView.onInputSettled = { [weak self] in
            self?.applyPendingPresentation(); self?.find.inputSettled()
            self?.updateBracketHighlights()
        }
        textView.onFindAction = { [weak self] action in self?.find.perform(action) }
        textView.onMarkedText = { [weak self] in
            self?.lineCommands.inputDidChange(); self?.find.documentDidChange()
            self?.dismissInlineName()
            self?.updateBracketHighlights()
        }
        textView.onInputFocusLost = { [weak self] in
            self?.lineCommands.inputDidChange(preservingExpansion: true)
            self?.dismissInlineName()
        }
        textView.onTypedNameKey = { [weak self] in self?.requestInlineName() }
        textView.onAcceptInlineName = { [weak self] in self?.acceptInlineName() == true }
        textView.onDismissInlineName = { [weak self] in self?.dismissInlineName() == true }
        applyPendingPresentation()
    }
    required init?(coder: NSCoder) { nil }

    /// Initial/reloaded text is a document-owner decision. Never call this for
    /// syntax delivery: it intentionally replaces the native Undo stack.
    func install(_ value: TextDocumentValue) {
        textView.clearBracketPairs()
        dismissInlineName()
        lineCommands.inputDidChange()
        installing = true
        defer { installing = false; tabPresentationPending = true; applyPendingPresentation() }
        generation = UUID()
        jumps = .init()
        lastEditOffset = nil
        lineBookmarks = .init()
        lineChangeBaselineID = nil
        unsavedLineChanges = nil
        conflictMarkers = nil
        outlinePresentation = nil
        invalidateScrollContext()
        onOutlineChanged?()
        documentFormat = value.format
        textView.string = value.text
        textView.undoManager?.removeAllActions()
        lineIndex = EditorLineIndex(value.text)
        presentedGeneration = nil
        clearStyling()
        textView.setSelectedRange(.init(location: 0, length: 0))
        updateGutterWidth()
        gutter.needsDisplay = true
        find.documentDidChange()
        publishCaret()
    }

    func textDidChange(_ notification: Notification) {
        guard !installing else { return }
        textView.nativeTextDidChange()
        dismissInlineName()
        lineCommands.inputDidChange()
        let historyChange = textView.undoManager.map { $0.isUndoing || $0.isRedoing } ?? false
        generation = UUID(); presentedGeneration = nil; lineIndex = nil
        jumps = .init()
        unsavedLineChanges = nil
        conflictMarkers = nil
        invalidateScrollContext()
        if outlinePresentation != nil { onOutlineChanged?() }
        clearStyling()
        gutter.needsDisplay = true
        if historyChange && !applyingPendingPresentation {
            // Native history can restore old attributed paragraphs. Keep its
            // characters/selection, but use the user's latest presentation.
            pointSizePending = requestedPointSize; tabPresentationPending = true
            applyPendingPresentation()
        }
        find.documentDidChange()
        onEdit?(textView.string, generation)
        publishCaret()
    }

    func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                     range editedRange: NSRange, changeInLength delta: Int) {
        guard !installing, textView.isEditable, editedMask.contains(.editedCharacters),
              editedRange.location != NSNotFound else { return }
        lastEditOffset = min(editedRange.location, textStorage.length)
        lineBookmarks.followEdit(in: editedRange, delta: delta, length: textStorage.length)
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        if let expected = pendingInlineName?.caret ?? textView.inlineName.map({ NSRange(location: $0.offset, length: 0) }),
           textView.selectedRanges.count != 1 || textView.selectedRange() != expected { dismissInlineName() }
        if textView.selectedRanges.count == 1 { revealFoldedText(textView.selectedRange(), explicitly: false) }
        textView.nativeSelectionDidChange()
        lineCommands.selectionDidChange(); find.selectionDidChange(); publishCaret()
        updateBracketHighlights()
    }
    func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange,
                  replacementString: String?) -> Bool {
        guard let replacementString else { return true }
        let current = textView.string
        guard let affected = Range(affectedCharRange, in: current) else {
            onRejectedEdit?(.invalidReceipt); return false
        }
        let added = replacementString.utf8.count
        guard added <= TextDocumentValue.maximumBytes,
              current.utf8.count - current[affected].utf8.count <= TextDocumentValue.maximumBytes - added else {
            onRejectedEdit?(.tooLarge); return false
        }
        revealFoldedText(affectedCharRange)
        return true
    }

    @discardableResult func present(_ prepared: EditorPreparedPresentation, for expected: UUID) -> Bool {
        guard present(prepared.value, syntax: prepared.syntax, lines: prepared.lines, for: expected) else { return false }
        conflictMarkers = prepared.conflicts.blocks.isEmpty ? nil : prepared.conflicts
        if let marks = prepared.unsavedLines, marks.baselineID == lineChangeBaselineID, showsUnsavedLineChanges {
            unsavedLineChanges = marks
        }
        outlinePresentation = .init(value: prepared.outline, generation: expected, language: prepared.syntaxLanguage)
        bracketMatches = prepared.bracketMatches
        foldIndex = prepared.folds
        liveJSONIssue = prepared.syntaxLanguage == textView.indentationLanguage ? prepared.syntaxIssue : nil
        updateJSONIssues()
        updateGutterWidth()
        gutter.needsDisplay = true
        updateBracketHighlights()
        prepareInlineName()
        onOutlineChanged?()
        contextLine = nil
        refreshScrollContext()
        return true
    }

    func presentDiagnostics(_ issues: [LocalJSONCheck.Issue], hasMore: Bool = false, for expected: UUID) {
        guard generation == expected, !textView.hasMarkedText() else { return }
        checkedJSONIssues = JSONIssues(issues: issues.prefix(24).sorted { $0.offset < $1.offset },
                                       hasMore: hasMore || issues.count > 24)
        updateJSONIssues()
    }

    func clearCheckedJSONIssues() {
        checkedJSONIssues = nil
        updateJSONIssues()
    }

    private func updateJSONIssues() {
        let automatic = showsLiveJSONIssues ? liveJSONIssue.map { [$0] } ?? [] : []
        let presentation = checkedJSONIssues ?? JSONIssues(issues: automatic)
        if presentation != visibleJSONIssues {
            visibleJSONIssues = presentation
            onJSONIssuesChanged?(presentation)
        }
        let visible = presentation.issues
        let source = textView.string as NSString
        guard !visible.isEmpty, source.length > 0 else { textView.diagnosticRanges = []; return }
        textView.diagnosticRanges = visible.compactMap { issue in
            guard (0...source.length).contains(issue.offset) else { return nil }
            var index = min(issue.offset, source.length - 1)
            // At a missing token, mark the nearest preceding character a few
            // spaces away. Navigation retains the exact reported caret.
            let limit = max(0, index - 12)
            while index > limit, [9, 10, 13, 32].contains(source.character(at: index)) { index -= 1 }
            return source.rangeOfComposedCharacterSequence(at: index)
        }
    }

    func prepareLineChangeBaseline(_ baseline: EditorSavedTextBaseline?) -> EditorSavedTextBaseline? {
        let selected = showsUnsavedLineChanges ? baseline : nil
        if lineChangeBaselineID != selected?.id {
            lineChangeBaselineID = selected?.id
            unsavedLineChanges = nil
        }
        return selected
    }

    func needsLineChangePreparation(for baseline: EditorSavedTextBaseline?) -> Bool {
        lineChangeBaselineID != (showsUnsavedLineChanges ? baseline?.id : nil)
    }

    @discardableResult
    func present(_ value: TextDocumentValue, syntax: TextSyntaxResult,
                 lines: EditorLineIndex, for expected: UUID) -> Bool {
        guard generation == expected, textView.string == value.text,
              lines.length == value.utf16Count, lines.matches(value.text), !textView.hasMarkedText(),
              textView.layoutManager != nil else { return false }
        let tokens: [TextSyntaxToken]
        switch syntax { case .tokens(let values): tokens = values; case .plain: tokens = [] }
        guard tokens.count <= TextSyntax.maximumTokens,
              tokens.allSatisfy({ $0.range.location >= 0 && $0.range.length > 0
                  && $0.range.location <= value.utf16Count
                  && $0.range.length <= value.utf16Count - $0.range.location }) else { return false }
        var end = 0
        for token in tokens {
            guard token.range.location >= end else { return false }
            end = NSMaxRange(token.range)
        }
        clearStyling()
        // Retain the bounded, ordered token map, but install native attributes
        // only around the viewport. Styling must not rebuild57,000 ranges on
        // the main actor on each edit or carry them through a distant scroll.
        syntaxTokens = tokens
        lineIndex = lines; styleRangeCount = tokens.count; presentedGeneration = expected
        lineBookmarks.align(to: lines)
        refreshVisibleStyling()
        updateGutterWidth()
        gutter.needsDisplay = true
        publishCaret()
        return true
    }

    func setWrapping(_ enabled: Bool) {
        guard enabled != wrapsLines else { return }
        let selection = textView.selectedRange()
        wrapsLines = enabled
        scrollView.hasHorizontalScroller = !enabled
        textView.isHorizontallyResizable = !enabled
        textView.autoresizingMask = enabled ? [.width] : []
        textView.textContainer?.widthTracksTextView = enabled
        textView.textContainer?.containerSize = .init(width: enabled ? max(1, scrollView.contentSize.width) : CGFloat.greatestFiniteMagnitude,
                                                       height: CGFloat.greatestFiniteMagnitude)
        if enabled { textView.setFrameSize(.init(width: max(1, scrollView.contentSize.width), height: textView.frame.height)) }
        textView.setSelectedRange(selection)
        textView.needsDisplay = true; gutter.needsDisplay = true
        refreshVisibleStyling()
    }
    func setPointSize(_ size: CGFloat) {
        guard size.isFinite, (10...48).contains(size) else { return }
        requestedPointSize = size; pointSizePending = size; tabPresentationPending = true
        applyPendingPresentation()
    }

    var showsWhitespaceMarks: Bool { whitespaceMarksOverride ?? defaultWhitespaceMarks }

    func setWhitespaceMarks(_ visible: Bool) {
        whitespaceMarksOverride = visible
        textView.showsWhitespaceMarks = visible
    }

    /// Shared presentation for editable, read-only and comparison text. None of
    /// these choices changes characters, document format, generation or Undo.
    func applyEditorPreferences(_ value: EditorPreferences, pointSize: CGFloat, applyWrapping: Bool = true) {
        if showsScrollContext != value.showsScrollContext {
            showsScrollContext = value.showsScrollContext
            contextLine = nil
            refreshScrollContext()
        }
        if applyWrapping { setWrapping(value.wrapsLines) }
        setLineNumbers(value.showsLineNumbers)
        textView.showsIndentGuides = value.showsIndentGuides
        showsMatchingBrackets = value.showsMatchingBrackets
        updateBracketHighlights()
        if showsLiveJSONIssues != value.showsLiveJSONIssues {
            showsLiveJSONIssues = value.showsLiveJSONIssues
            updateJSONIssues()
        }
        defaultWhitespaceMarks = value.showsWhitespaceMarks
        textView.showsWhitespaceMarks = showsWhitespaceMarks
        if showsUnsavedLineChanges != value.showsUnsavedLineChanges {
            showsUnsavedLineChanges = value.showsUnsavedLineChanges
            if !showsUnsavedLineChanges { _ = prepareLineChangeBaseline(nil) }
        }
        setPointSize(pointSize)
        find.applyInterfaceScale(pointSize / CGFloat(value.basePointSize))
        setIndentation(value.indentation)
        textView.indentsJSONBlocks = value.indentsJSONBlocks
        textView.indentsCodeBlocks = value.indentsCodeBlocks
        textView.completesJSONBrackets = value.completesJSONBrackets
        textView.completesCodeBrackets = value.completesCodeBrackets
        textView.showsInlineNames = value.showsInlineNames
        if !value.showsInlineNames { dismissInlineName() }
        textView.backspaceUnindents = value.backspaceUnindents
        setSyntaxPalette(value.palette)
        textView.findHighlightColor = value.findHighlightColor.nativeColor
        switch value.theme {
        case .followApp: appearance = nil
        case .light: appearance = NSAppearance(named: .aqua)
        case .dark: appearance = NSAppearance(named: .darkAqua)
        }
        textView.drawsBackground = value.theme != .followApp
        textView.backgroundColor = .textBackgroundColor
    }
    var indentationPreferences: EditorIndentationPreferences { textView.indentationPreferences }
    @discardableResult
    func setIndentation(_ value: EditorIndentationPreferences) -> Bool {
        guard value.isValid else { return false }
        textView.indentationPreferences = value; tabPresentationPending = true
        applyPendingPresentation(); return true
    }
    private func applyPendingPresentation() {
        guard !installing, !applyingPendingPresentation, !textView.hasMarkedText(),
              pointSizePending != nil || tabPresentationPending else { return }
        applyingPendingPresentation = true
        defer { applyingPendingPresentation = false }
        let manager = textView.undoManager
        let registrationWasEnabled = manager?.isUndoRegistrationEnabled == true
        if registrationWasEnabled { manager?.disableUndoRegistration() }
        defer { if registrationWasEnabled { manager?.enableUndoRegistration() } }
        if let size = pointSizePending {
            pointSizePending = nil
            textView.font = .monospacedSystemFont(ofSize: size, weight: .regular)
            updateGutterWidth(); gutter?.needsDisplay = true; refreshVisibleStyling()
        }
        if tabPresentationPending,
           EditorTabPresentation.apply(columns: CGFloat(textView.indentationPreferences.columns), to: self) == .applied {
            tabPresentationPending = false
            refreshVisibleStyling()
        }
    }
    func setLineNumbers(_ enabled: Bool) {
        guard enabled != showsLineNumbers else { return }
        showsLineNumbers = enabled
        scrollView.rulersVisible = enabled
        updateGutterWidth()
        gutter.needsDisplay = true
    }
    func setSyntaxPalette(_ value: EditorSyntaxPalette) {
        guard value != syntaxPalette else { return }
        syntaxPalette = value
        visibleStyleRangeCount = 0
        refreshVisibleStyling()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        visibleStyleRangeCount = 0
        refreshVisibleStyling()
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, onWindowAttachment != nil else { return }
        Task { @MainActor [weak self] in self?.onWindowAttachment?() }
    }

    override func layout() {
        super.layout()
        updateGutterWidth()
    }
    private func updateGutterWidth() {
        guard gutter != nil else { return }
        // Fit the largest displayed line number using the actual scaled font.
        // Keep its last known width while a newer line index is preparing.
        let digits = max(2, String(lineIndex?.starts.count ?? 1).count)
        let font = NSFont.monospacedDigitSystemFont(ofSize: max(10, (textView.font?.pointSize ?? 13) - 2), weight: .regular)
        let measured = (String(repeating: "8", count: digits) as NSString).size(withAttributes: [.font: font]).width
        let padding = ceil(max(8, font.pointSize * 0.65))
        let fitted = ceil(measured + padding * 2 + foldGutterWidth)
        let thickness = lineIndex == nil ? max(gutter.ruleThickness, fitted) : fitted
        if abs(gutter.ruleThickness - thickness) > 0.5 { gutter.ruleThickness = thickness }
    }
    func showFind() { find.perform(.showFindInterface) }
    var canGoToLine: Bool { lineIndex != nil && !textView.hasMarkedText() }
    var canGoToLastEdit: Bool { canGoToLine && textView.isEditable && lastEditOffset != nil }

    var bookmarkCaretLine: Int? {
        guard canGoToLine, textView.isEditable, textView.selectedRanges.count == 1 else { return nil }
        return lineIndex?.location(at: textView.selectedRange().location)?.line
    }

    var bookmarkedLines: [Int] {
        guard let lineIndex, canGoToLine, textView.isEditable else { return [] }
        return lineBookmarks.lines(in: lineIndex)
    }

    func hasBookmark(on line: Int) -> Bool {
        lineIndex?.start(ofLine: line).map(lineBookmarks.contains) == true
    }

    func toggleBookmarkAtCaret() -> Bool {
        guard let line = bookmarkCaretLine, let offset = lineIndex?.start(ofLine: line), lineBookmarks.toggle(offset) else { return false }
        gutter.needsDisplay = true
        return true
    }

    func bookmarkLine(toward direction: EditorJumpDirection) -> Int? {
        guard let current = bookmarkCaretLine else { return nil }
        let lines = bookmarkedLines
        let target = direction == .next ? lines.first { $0 > current } ?? lines.first : lines.last { $0 < current } ?? lines.last
        return target == current ? nil : target
    }

    func selectionStructure() -> EditorSelectionStructure {
        let selection = textView.selectedRange()
        let word = selection.length == 0 ? rangeOfWord(at: selection) : nil
        let current = outlinePresentation?.generation == generation
            && outlinePresentation?.language == textView.indentationLanguage && presentedGeneration == generation
        return .init(word: word, tokens: current ? syntaxTokens : [], scopes: current ? outlinePresentation?.value.scopes ?? [] : [])
    }

    private func rangeOfWord(at selection: NSRange) -> NSRange {
        textView.selectionRange(forProposedRange: selection, granularity: .selectByWord)
    }

    func occurrenceSeed() -> (query: String, wholeWord: Bool)? {
        guard textView.isEditable, !textView.hasMarkedText(), textView.selectedRanges.count == 1 else { return nil }
        let selection = textView.selectedRange()
        guard selection.length <= 256 else { return nil }
        let word = rangeOfWord(at: .init(location: selection.location, length: 0))
        let chosen = selection.length == 0 ? word : selection
        let text = textView.string
        guard chosen.length > 0, chosen.length <= 256, let range = Range(chosen, in: text) else { return nil }
        let query = String(text[range])
        guard query.rangeOfCharacter(from: .newlines) == nil,
              query.rangeOfCharacter(from: CharacterSet.whitespaces.inverted) != nil else { return nil }
        return (query, chosen == word)
    }

    var currentOutlineForSymbols: OutlinePresentation? {
        guard let outlinePresentation, outlinePresentation.generation == generation,
              outlinePresentation.language == textView.indentationLanguage, outlinePresentation.value.availability == .ready,
              presentedGeneration == generation, !textView.hasMarkedText() else { return nil }
        return outlinePresentation
    }

    private var outlineSelection: (outline: EditorDocumentOutline, range: NSRange)? {
        guard let outline = currentOutlineForSymbols, let length = lineIndex?.length,
              textView.selectedRanges.count == 1 else { return nil }
        let selection = textView.selectedRange()
        guard selection.location >= 0, selection.location <= length,
              selection.length <= length - selection.location else { return nil }
        return (outline.value, selection)
    }

    var currentSearchScope: (name: String, range: NSRange)? {
        guard let selection = outlineSelection, let length = lineIndex?.length,
              let scope = selection.outline.scope(containing: selection.range) else { return nil }
        let start = scope.entry.offset, end = min(length, scope.end)
        guard start >= 0, end > start else { return nil }
        return (scope.entry.title, .init(location: start, length: end - start))
    }

    var enclosingOutlineEntry: EditorDocumentOutline.Entry? {
        guard let selection = outlineSelection else { return nil }
        return selection.outline.scope(containing: selection.range, includesStart: false)?.entry
    }

    func adjacentOutlineEntry(toward direction: EditorJumpDirection) -> EditorDocumentOutline.Entry? {
        guard let selection = outlineSelection else { return nil }
        switch direction {
        case .previous:
            return selection.outline.entries.last { $0.offset < selection.range.location }
        case .next:
            let minimum = selection.range.location + max(1, selection.range.length)
            return selection.outline.entries.first { $0.offset >= minimum }
        }
    }

    var canFindDeclaration: Bool {
        guard let outlinePresentation = currentOutlineForSymbols,
              textView.selectedRanges.count == 1, canGoToLine else { return false }
        return outlinePresentation.value.entries.contains { $0.kind.isDeclaration }
    }

    func matchingDeclarations() -> [EditorDocumentOutline.Match] {
        guard canFindDeclaration, let outline = outlinePresentation?.value, let lines = lineIndex else { return [] }
        let selection = textView.selectedRange(), source = textView.string as NSString
        let range = selection.length == 0 ? rangeOfWord(at: selection) : selection
        guard (1...180).contains(range.length), range.location >= 0, range.location <= source.length - range.length,
              isCode(range) else { return [] }
        let name = source.substring(with: range)
        return outline.entries.compactMap { entry in
            guard entry.kind.isDeclaration, entry.title.utf16.elementsEqual(name.utf16) else { return nil }
            let end = lines.start(ofLine: entry.line + 1) ?? lines.length
            let preview = source.substring(with: .init(location: entry.offset, length: min(180, end - entry.offset)))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .init(entry: entry, preview: preview)
        }
    }

    var canCompleteLocalName: Bool {
        canFindDeclaration && textView.isEditable && textView.selectedRange().length == 0
    }

    func nameCompletion() -> NameCompletion? {
        guard canCompleteLocalName, let outline = outlinePresentation else { return nil }
        let range = textView.rangeForUserCompletion, source = textView.string as NSString
        guard (1...180).contains(range.length), range.location >= 0, range.location <= source.length - range.length,
              NSMaxRange(range) == textView.selectedRange().location, isCode(range) else { return nil }
        let end = NSMaxRange(range)
        if end < source.length, let following = source.substring(with: source.rangeOfComposedCharacterSequence(at: end)).unicodeScalars.first,
           EditorDocumentOutline.isIdentifierContinuation(following, language: outline.language) { return nil }
        let prefix = source.substring(with: range)
        let entries = outline.value.completions(startingWith: prefix, language: outline.language)
        return entries.isEmpty ? nil : .init(prefix: prefix, range: range, entries: entries, generation: generation)
    }

    func completeLocalName(_ entry: EditorDocumentOutline.Entry, with request: NameCompletion) -> Bool {
        guard generation == request.generation, canCompleteLocalName, textView.rangeForUserCompletion == request.range,
              textView.selectedRange().location == NSMaxRange(request.range), request.entries.contains(entry),
              (textView.string as NSString).substring(with: request.range).utf16.elementsEqual(request.prefix.utf16) else { return false }
        textView.breakUndoCoalescing()
        textView.insertText(entry.title, replacementRange: request.range)
        textView.breakUndoCoalescing()
        guard generation != request.generation else { return false }
        textView.undoManager?.setActionName("Complete Local Name")
        return true
    }

    private func requestInlineName() {
        pendingInlineName = (generation, textView.selectedRange())
        if presentedGeneration == generation { prepareInlineName() }
    }

    private func prepareInlineName() {
        guard let pending = pendingInlineName else { return }
        pendingInlineName = nil
        guard textView.showsInlineNames, pending.generation == generation, pending.caret == textView.selectedRange(),
              window?.isKeyWindow == true, window?.attachedSheet == nil, window?.firstResponder === textView,
              let request = nameCompletion(), request.prefix.utf16.count >= 3, request.entries.count == 1,
              let entry = request.entries.first, entry.title.utf8.allSatisfy({ $0 < 128 }),
              let storage = textView.textStorage, (0...storage.length).contains(pending.caret.location),
              pending.caret.location == storage.length
                || storage.mutableString.character(at: pending.caret.location) == 10 else { return }
        offeredInlineName = (entry, request)
        textView.inlineName = .init(suffix: String(entry.title.dropFirst(request.prefix.count)), offset: pending.caret.location)
    }

    @discardableResult func dismissInlineName() -> Bool {
        let active = pendingInlineName != nil || offeredInlineName != nil
        pendingInlineName = nil; offeredInlineName = nil; textView.inlineName = nil
        return active
    }

    private func acceptInlineName() -> Bool {
        let visible = textView.hasVisibleInlineName
        let suggestion = offeredInlineName
        dismissInlineName()
        guard visible, let suggestion, generation == suggestion.request.generation else { return false }
        _ = completeLocalName(suggestion.entry, with: suggestion.request)
        return true
    }

    private func isCode(_ range: NSRange) -> Bool {
        var index = firstSyntaxToken(endingAfter: range.location)
        while index < syntaxTokens.count, syntaxTokens[index].range.location < NSMaxRange(range) {
            let kind = syntaxTokens[index].kind
            if kind == .string || kind == .comment { return false }
            index += 1
        }
        return true
    }
    @discardableResult
    func goToLine(_ line: Int, generation expected: UUID, remembersLocation: Bool = true) -> Bool {
        guard let start = lineIndex?.start(ofLine: line) else { return false }
        return goToTextOffset(start, generation: expected, remembersLocation: remembersLocation)
    }

    @discardableResult
    func goTo(_ address: EditorLineAddress, generation expected: UUID, remembersLocation: Bool = true) -> Bool {
        guard let offset = lineIndex?.offset(at: address) else { return false }
        return goToTextOffset(offset, generation: expected, remembersLocation: remembersLocation)
    }

    func goToLastEdit() {
        guard canGoToLastEdit, let offset = lastEditOffset else { return }
        _ = goToTextOffset(offset, generation: generation)
    }

    func unsavedChangeLine(toward direction: EditorJumpDirection) -> Int? {
        guard canGoToLine, textView.selectedRanges.count == 1,
              let line = lineIndex?.location(at: textView.selectedRange().location)?.line,
              let target = unsavedLineChanges?.line(from: line - 1, toward: direction) else { return nil }
        return target + 1
    }

    var selectedUnsavedLine: Int? {
        guard canGoToLine, textView.selectedRanges.count == 1,
              let line = lineIndex?.location(at: textView.selectedRange().location)?.line,
              unsavedLineChanges?.mark(at: line - 1) != nil else { return nil }
        return line
    }

    func unsavedLineAnchor(_ line: Int) -> (NSView, NSRect) {
        if !gutter.isHiddenOrHasHiddenAncestor, let rect = gutter.changeRect(at: line) { return (gutter, rect) }
        return (scrollView, .init(x: 0, y: scrollView.isFlipped ? 10 : scrollView.bounds.maxY - 10, width: 1, height: 1))
    }

    @discardableResult func goToTextOffset(_ offset: Int, generation expected: UUID, remembersLocation: Bool = true) -> Bool {
        guard generation == expected, !textView.hasMarkedText(), let lineIndex,
              lineIndex.matches(textView.string), (0...lineIndex.length).contains(offset) else { return false }
        revealNavigationSelection(.init(location: offset, length: 0), remembersLocation: remembersLocation)
        return true
    }

    @discardableResult func goToVisibleScope() -> Bool {
        guard let context = scrollContext, let entry = context.scopes.last,
              window?.attachedSheet == nil, !textView.hasMarkedText() else { return false }
        return goToTextOffset(entry.offset, generation: context.generation)
    }

    func setEditingLanguage(_ language: TextSyntaxLanguage) {
        guard textView.indentationLanguage != language else { return }
        dismissInlineName()
        lineCommands.inputDidChange()
        textView.indentationLanguage = language
        checkedJSONIssues = nil
        liveJSONIssue = nil
        updateJSONIssues()
        foldIndex = nil
        revealAllCodeBlocks()
        updateGutterWidth()
        gutter.needsDisplay = true
        find.outlineLanguageDidChange()
        updateBracketHighlights()
        contextLine = nil
        refreshScrollContext()
    }

    func revealNavigationSelection(_ range: NSRange, remembersLocation: Bool = true) {
        let origin = remembersLocation ? navigationPosition() : nil
        let expected = generation
        revealFoldedText(range)
        textView.setSelectedRange(range)
        textView.scrollRangeToVisible(range)
        _ = window?.makeFirstResponder(textView)
        publishCaret()
        if let origin, generation == expected, navigationPosition() != origin {
            if let onNavigationJump { onNavigationJump(origin) }
            else { jumps.record(origin) }
        }
    }

    func canVisitTextLocation(_ direction: EditorJumpDirection) -> Bool {
        guard let window, window.isKeyWindow, window.attachedSheet == nil, canGoToLine,
              (window.firstResponder as? NSTextView)?.hasMarkedText() != true,
              textView.selectedRanges.count == 1 else { return false }
        return jumps.hasLocation(direction)
    }

    func visitTextLocation(_ direction: EditorJumpDirection) {
        guard canVisitTextLocation(direction), let position = navigationPosition(),
              let destination = jumps.visit(direction, leaving: position) else { return }
        restoreNavigationPosition(destination)
    }

    func canRestoreNavigationPosition(_ position: EditorNavigationPosition) -> Bool {
        guard let lineIndex, !textView.hasMarkedText() else { return false }
        let range = position.selection
        return range.location >= 0 && range.location <= lineIndex.length
            && range.length >= 0 && range.length <= lineIndex.length - range.location
    }

    func restoreNavigationPosition(_ destination: EditorNavigationPosition) {
        guard canRestoreNavigationPosition(destination) else { return }
        _ = window?.makeFirstResponder(textView)
        revealFoldedText(destination.selection)
        textView.setSelectedRange(destination.selection)
        textView.scrollRangeToVisible(destination.selection)
        if let anchor = destination.anchor { scroll(to: anchor, horizontalOffset: destination.origin.x) }
        else { restoreViewportOrigin(destination.origin) }
        publishCaret()
    }

    func navigationPosition() -> EditorNavigationPosition? {
        guard canGoToLine, textView.selectedRanges.count == 1 else { return nil }
        return .init(selection: textView.selectedRange(), anchor: scrollAnchor(), origin: scrollView.contentView.bounds.origin)
    }

    func hideFind() { find.perform(.hideFindInterface) }
    @discardableResult
    func applyFindReplacement(_ plan: EditorFindReplacement, generation expected: UUID) -> Bool {
        guard generation == expected, textView.isEditable, !textView.hasMarkedText(),
              textView.string.utf16.elementsEqual(plan.original.utf16) else { return false }
        return applyTextReplacement(plan.edit, expecting: plan.value, action: plan.count > 1 ? "Replace All" : "Replace")
    }

    func applyTextReplacement(_ edit: EditorIndentationReplacement, expecting value: TextDocumentValue, action: String) -> Bool {
        let selection = edit.selection
        guard selection.location >= 0, selection.length >= 0, selection.location <= value.utf16Count,
              selection.length <= value.utf16Count - selection.location else { return false }
        textView.breakUndoCoalescing()
        textView.insertText(edit.text, replacementRange: edit.range)
        textView.breakUndoCoalescing()
        guard textView.string.utf16.elementsEqual(value.text.utf16) else { return false }
        textView.undoManager?.setActionName(action)
        textView.setSelectedRange(selection); textView.scrollRangeToVisible(selection)
        return true
    }
    func clearPrivatePresentation() {
        dismissInlineName()
        lineCommands.close()
        find.clear(); textView.comparisonHighlights = []; textView.comparisonDetails = []
        textView.onFindAction = nil; textView.onMarkedText = nil; textView.onInputFocusLost = nil; textView.onCompleteLocalName = nil
        onEdit = nil; onCaret = nil; onRejectedEdit = nil; onNavigationJump = nil
        outlinePresentation = nil; onOutlineChanged?(); onOutlineChanged = nil
        invalidateScrollContext(); onScrollContextChanged = nil
        checkedJSONIssues = nil; liveJSONIssue = nil
        updateJSONIssues(); onJSONIssuesChanged = nil
        clearStyling()
        installing = true
        textView.string = ""; textView.undoManager?.removeAllActions()
        installing = false
        lineIndex = nil; presentedGeneration = nil; generation = UUID(); styleRangeCount = 0
        jumps = .init()
        lineChangeBaselineID = nil; unsavedLineChanges = nil
        onReviewUnsavedLine = nil; onUnsavedLineBaselineChanged = nil
        conflictMarkers = nil
        gutter.needsDisplay = true
    }
    private func clearStyling() {
        textView.layoutManager?.removeTemporaryAttribute(.foregroundColor,
            forCharacterRange: .init(location: 0, length: textView.string.utf16.count))
        styleRangeCount = 0
        visibleStyleRangeCount = 0; syntaxTokens = []; styledRange = .init(location: 0, length: 0)
        bracketMatches = nil
        if presentedGeneration != generation {
            foldIndex = nil
            codeFolding.unfoldAll()
            textView.foldedOpenings = []
            checkedJSONIssues = nil
            liveJSONIssue = nil
            updateJSONIssues()
        }
        textView.bracketHighlights = []
    }

    var foldGutterWidth: CGFloat { foldIndex?.byLine.isEmpty == false ? 15 : 0 }
    var hasFoldedCode: Bool { codeFolding.hasFolds }
    func canFoldLine(_ line: Int) -> Bool {
        !textView.hasMarkedText() && foldIndex?.byLine[line] != nil && codeFolding.canToggle(on: line)
    }
    func isCodeFolded(on line: Int) -> Bool { codeFolding.isFolded(on: line) }

    private var selectedFoldBlock: EditorFoldIndex.Block? {
        guard textView.selectedRanges.count == 1, !textView.hasMarkedText(), let lineIndex else { return nil }
        let selected = textView.selectedRange()
        guard let line = lineIndex.location(at: selected.location)?.line else { return nil }
        return foldIndex?.block(for: selected, on: line)
    }
    func canSetSelectedBlock(folded: Bool) -> Bool {
        guard let block = selectedFoldBlock else { return false }
        return codeFolding.isFolded(on: block.line) != folded && codeFolding.canToggle(on: block.line)
    }
    func setSelectedBlock(folded: Bool) {
        guard canSetSelectedBlock(folded: folded), let block = selectedFoldBlock else { return }
        toggleCodeFold(on: block.line)
    }

    @discardableResult func toggleCodeFold(on line: Int) -> Bool {
        guard canFoldLine(line), let block = foldIndex?.byLine[line] else { return false }
        changeCodeFolds(collapsing: codeFolding.isFolded(on: line) ? [] : [block]) { codeFolding.toggle(block) }
        return true
    }

    var canFoldTopLevelBlocks: Bool {
        guard !textView.hasMarkedText(), let foldIndex else { return false }
        return codeFolding.canFoldAny(foldIndex.topLevel)
    }

    /// Return the number of additional top-level blocks left visible by the fold limit.
    func foldTopLevelBlocks() -> Int {
        guard canFoldTopLevelBlocks, let foldIndex else { return 0 }
        let requested = foldIndex.topLevel
        let collapsing = codeFolding.foldable(requested)
        changeCodeFolds(collapsing: collapsing) { codeFolding.fold(collapsing) }
        return requested.count { !codeFolding.isFolded(on: $0.line) }
    }

    private func changeCodeFolds(collapsing blocks: [EditorFoldIndex.Block], change: () -> Void) {
        var anchor = scrollAnchor()
        let x = scrollView.contentView.bounds.minX
        if let current = anchor, let offset = lineIndex?.start(ofLine: current.line + 1),
           let block = blocks.first(where: { NSLocationInRange(offset, $0.hidden) }) {
            anchor = .init(line: block.line - 1, column: 0, fragmentProgress: 0)
        }
        if textView.selectedRanges.count == 1 {
            let selection = textView.selectedRange()
            if let block = blocks.first(where: { $0.hidesSelectionEdge(selection) }) {
                textView.setSelectedRange(.init(location: block.opening.location, length: 0))
            }
        }
        change()
        if let anchor { scroll(to: anchor, horizontalOffset: x) }
        updateCodeFoldPresentation()
    }

    func revealAllCodeBlocks() {
        guard codeFolding.hasFolds, !textView.hasMarkedText() else { return }
        changeCodeFolds(collapsing: []) { codeFolding.unfoldAll() }
    }

    func revealFoldedText(_ range: NSRange, explicitly: Bool = true) {
        guard codeFolding.reveal(range, explicitly: explicitly) else { return }
        updateCodeFoldPresentation()
    }

    private func updateCodeFoldPresentation() {
        textView.foldedOpenings = codeFolding.visibleOpenings
        textView.needsDisplay = true
        gutter.needsDisplay = true
        window?.invalidateCursorRects(for: gutter)
        contextLine = nil
        refreshScrollContext()
    }

    private func updateBracketHighlights() {
        guard showsMatchingBrackets, presentedGeneration == generation, outlinePresentation?.generation == generation,
              outlinePresentation?.language == textView.indentationLanguage, !textView.hasMarkedText(), textView.selectedRanges.count == 1,
              let offsets = bracketMatches?.matchingOffsets(at: textView.selectedRange()) else {
            textView.bracketHighlights = []
            return
        }
        textView.bracketHighlights = [.init(location: offsets.0, length: 1), .init(location: offsets.1, length: 1)]
    }
    @objc private func viewportChanged() {
        refreshVisibleStyling()
        refreshScrollContext()
        if unsavedLineChanges?.marks.isEmpty == false { updateChangeMarkerCursor() }
    }

    private func updateChangeMarkerCursor() {
        guard let gutter, onReviewUnsavedLine != nil else { return }
        window?.invalidateCursorRects(for: gutter)
    }

    private func invalidateScrollContext() {
        contextLine = nil
        installScrollContext(nil)
    }

    private func refreshScrollContext() {
        guard showsScrollContext, onScrollContextChanged != nil, let prepared = outlinePresentation,
              prepared.generation == generation, prepared.language == textView.indentationLanguage,
              !prepared.value.scopes.isEmpty, !textView.hasMarkedText(),
              let anchor = scrollAnchor(), let start = lineIndex?.start(ofLine: anchor.line + 1) else {
            invalidateScrollContext(); return
        }
        let line = anchor.line + 1
        guard contextLine != line else { return }
        contextLine = line
        let entries = prepared.value.scrolledScopes(at: start, onLine: line, limit: 8)
        installScrollContext(entries.isEmpty ? nil : .init(generation: generation, scopes: entries))
    }

    private func installScrollContext(_ value: ScrollContext?) {
        guard scrollContext != value else { return }
        scrollContext = value
        onScrollContextChanged?(value)
    }
    private func refreshVisibleStyling() {
        guard !refreshingViewport, presentedGeneration == generation,
              !textView.hasMarkedText(), let lineIndex,
              let layout = textView.layoutManager, let container = textView.textContainer else { return }
        refreshingViewport = true
        defer { refreshingViewport = false }
        let viewport = textView.visibleRect.offsetBy(dx: -textView.textContainerInset.width,
            dy: -textView.textContainerInset.height).insetBy(dx: -80, dy: -120)
        let glyphs = layout.glyphRange(forBoundingRect: viewport, in: container)
        let range = NSIntersectionRange(layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil),
            NSRange(location: 0, length: lineIndex.length))
        guard range != styledRange || visibleStyleRangeCount == 0 else { return }
        if styledRange.length > 0 {
            layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: styledRange)
        }
        styledRange = range; visibleStyleRangeCount = 0
        guard range.length > 0 else { return }
        var lower = firstSyntaxToken(endingAfter: range.location)
        while lower < syntaxTokens.count && syntaxTokens[lower].range.location < NSMaxRange(range)
                && visibleStyleRangeCount < 2_048 {
            let token = syntaxTokens[lower]
            let color = EditorSyntaxColors.color(for: token.kind, palette: syntaxPalette)
            let clipped = NSIntersectionRange(token.range, range)
            if clipped.length > 0 {
                layout.addTemporaryAttribute(.foregroundColor, value: color, forCharacterRange: clipped)
                visibleStyleRangeCount += 1
            }
            lower += 1
        }
    }

    private func firstSyntaxToken(endingAfter offset: Int) -> Int {
        var lower = 0, upper = syntaxTokens.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if NSMaxRange(syntaxTokens[middle].range) <= offset { lower = middle + 1 }
            else { upper = middle }
        }
        return lower
    }
    private func publishCaret() {
        onCaret?(lineIndex?.location(at: textView.selectedRange().location))
    }
}

@MainActor
private final class EditorLineRuler: NSRulerView {
    private weak var surface: NativeTextEditorSurface?
    private let bookmarkSymbol = NSImage(systemSymbolName: "bookmark.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(paletteColors: [.controlAccentColor]))
    private let foldSymbol = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(paletteColors: [.labelColor]))
    private let unfoldSymbol = NSImage(systemSymbolName: "chevron.forward", accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(paletteColors: [.labelColor]))
    init(surface: NativeTextEditorSurface) {
        self.surface = surface
        super.init(scrollView: surface.scrollView, orientation: .verticalRuler)
        clipsToBounds = true
        ruleThickness = 34
        clientView = surface.textView
    }
    required init(coder: NSCoder) { fatalError("Not a serialized view") }
    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let surface else { return }
        let text = surface.textView
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: max(10, (text.font?.pointSize ?? 13) - 2), weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        let inset = ceil(max(8, ((text.font?.pointSize ?? 13) - 2) * 0.65))
        let flagWidth = min(8, inset - 2), flagHeight = flagWidth * 1.5
        forEachVisibleLine { [self] number, line in
            let foldWidth = surface.foldGutterWidth
            if surface.canFoldLine(number) {
                let symbol = surface.isCodeFolded(on: number) ? unfoldSymbol : foldSymbol
                let marker = NSRect(x: (foldWidth - 10) / 2, y: line.midY - 5, width: 10, height: 10)
                symbol?.draw(in: marker, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
            let string = String(number) as NSString
            let size = string.size(withAttributes: attributes)
            string.draw(at: .init(x: ruleThickness - size.width - inset, y: line.minY), withAttributes: attributes)
            if surface.hasBookmark(on: number) {
                let marker = NSRect(x: foldWidth + (inset - flagWidth) / 2, y: line.midY - flagHeight / 2,
                                    width: flagWidth, height: flagHeight)
                bookmarkSymbol?.draw(in: marker, from: .zero,
                    operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
            guard let mark = surface.unsavedLineChanges?.kind(at: number - 1) else { return }
            let color: NSColor = switch mark { case .added: .systemGreen; case .changed: .controlAccentColor; case .removed: .systemOrange }
            let height: CGFloat = mark == .removed ? 3 : min(14, line.height - 2)
            let width: CGFloat = mark == .removed ? 5 : 2
            let stroke = NSRect(x: ruleThickness - width - 1, y: line.minY + (line.height - height) / 2, width: width, height: height)
            color.setFill()
            NSBezierPath(roundedRect: stroke, xRadius: 1, yRadius: 1).fill()
        }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        forEachVisibleFold { _, rect in self.addCursorRect(rect, cursor: .pointingHand) }
        guard surface?.onReviewUnsavedLine != nil, surface?.unsavedLineChanges?.marks.isEmpty == false else { return }
        forEachVisibleChange { _, rect in self.addCursorRect(rect, cursor: .pointingHand) }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        var foldLine: Int?
        forEachVisibleFold { number, rect in if rect.contains(point) { foldLine = number } }
        if let foldLine, surface?.toggleCodeFold(on: foldLine) == true { return }
        var clickedLine: Int?
        forEachVisibleChange { number, rect in if rect.contains(point) { clickedLine = number } }
        if let clickedLine, surface?.onReviewUnsavedLine?(clickedLine) == true { return }
        super.mouseDown(with: event)
    }

    private func forEachVisibleFold(_ body: @escaping (Int, NSRect) -> Void) {
        guard let surface, surface.foldGutterWidth > 0 else { return }
        forEachVisibleLine { number, line in
            guard surface.canFoldLine(number) else { return }
            let hit = NSRect(x: 0, y: line.minY, width: surface.foldGutterWidth, height: line.height).intersection(self.bounds)
            if !hit.isEmpty { body(number, hit) }
        }
    }

    func changeRect(at line: Int) -> NSRect? {
        var rectangle: NSRect?
        forEachVisibleChange { number, rect in if number == line { rectangle = rect } }
        return rectangle
    }

    private func forEachVisibleChange(_ body: @escaping (Int, NSRect) -> Void) {
        guard let marks = surface?.unsavedLineChanges, !marks.marks.isEmpty else { return }
        forEachVisibleLine { number, line in
            guard marks.kind(at: number - 1) != nil else { return }
            let hit = NSRect(x: self.ruleThickness - 9, y: line.minY, width: 9, height: line.height).intersection(self.bounds)
            if !hit.isEmpty { body(number, hit) }
        }
    }

    private func forEachVisibleLine(_ body: @escaping (Int, NSRect) -> Void) {
        guard let surface, let index = surface.lineIndex, let layout = surface.textView.layoutManager,
              let container = surface.textView.textContainer else { return }
        let text = surface.textView
        func visit(_ number: Int, _ line: NSRect) {
            let y = convert(NSPoint(x: 0, y: line.minY + text.textContainerInset.height), from: text).y
            body(number, NSRect(x: 0, y: y, width: ruleThickness, height: line.height))
        }
        let glyphs = layout.glyphRange(forBoundingRect: text.visibleRect, in: container)
        layout.enumerateLineFragments(forGlyphRange: glyphs) { line, _, _, range, _ in
            let offset = layout.characterIndexForGlyph(at: range.location)
            guard let location = index.location(at: offset), location.column == 1 else { return }
            visit(location.line, line)
        }
        if layout.extraLineFragmentTextContainer === container,
           index.starts.last == index.length {
            visit(index.starts.count, layout.extraLineFragmentRect)
        }
    }
}
