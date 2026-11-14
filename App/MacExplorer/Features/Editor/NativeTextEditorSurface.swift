import AppKit
#if canImport(FileOperations)
import FileOperations
#endif

@MainActor
final class EditorCodeTextView: NSTextView {
    var comparisonHighlights: [NSRange] = [] { didSet { needsDisplay = true } }
    var comparisonTint = NSColor.systemBlue { didSet { needsDisplay = true } }
    var findHighlights: [NSRange] = [] { didSet { needsDisplay = true } }
    var currentFindHighlight: NSRange? { didSet { if oldValue != currentFindHighlight { needsDisplay = true } } }
    var findHighlightColor = NSColor.systemBlue { didSet { needsDisplay = true } }
    #if DEBUG
    private(set) var findBackgroundDrawsForVerification = 0
    #endif
    var onFindAction: ((NSTextFinder.Action) -> Void)?
    override func performTextFinderAction(_ sender: Any?) {
        guard let item = sender as? NSMenuItem, let action = NSTextFinder.Action(rawValue: item.tag) else { return }
        onFindAction?(action)
    }
    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        EditorComparisonBackground.draw(comparisonHighlights, color: comparisonTint, text: self, dirtyRect: rect)
        #if DEBUG
        if !findHighlights.isEmpty { findBackgroundDrawsForVerification += 1 }
        #endif
        EditorFindHighlights.draw(findHighlights, current: currentFindHighlight, color: findHighlightColor,
                                  text: self, dirtyRect: rect)
    }
    var indentationPreferences = EditorIndentationPreferences.fresh {
        didSet { if oldValue != indentationPreferences { clearBracketPairs() } }
    }
    var indentationLanguage = TextSyntaxLanguage.plain {
        didSet { if oldValue != indentationLanguage { clearBracketPairs() } }
    }
    var completesJSONBrackets = true {
        didSet { if oldValue != completesJSONBrackets { clearBracketPairs() } }
    }
    var indentsJSONBlocks = true {
        didSet { if oldValue != indentsJSONBlocks { clearBracketPairs() } }
    }
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
    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { clearBracketPairs(); onInputFocusLost?() }
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
        if completesJSONBrackets, indentationLanguage == .json || indentationLanguage == .jsonc,
           range == selected, range.length == 0, scalarBoundary(range.location) {
            let unit = normalized.utf16.count == 1 ? normalized.utf16.first : nil
            // Only bracket keys need a bounded lexical prefix. In particular,
            // a close typed inside a newly opened string must stay literal.
            let prefix = (unit == 123 || unit == 91 || unit == 125 || unit == 93) && range.location < 65_536
                ? source.substring(to: range.location) : nil
            // Smart Return leaves an empty inner line before the owned close.
            // A closing key may cross only a small whitespace-only gap, never
            // user content or an unowned delimiter.
            if unit == 125 || unit == 93,
               let offset = bracketCloses.keys.filter({ $0 >= range.location }).min(),
               offset < length, offset - range.location <= 4096,
               source.substring(with: .init(location: range.location, length: offset - range.location))
                .utf16.allSatisfy({ [9, 10, 32].contains($0) }) {
                closingOffset = offset
            }
            let next = closingOffset < length ? source.character(at: closingOffset) : nil
            plan = EditorBracketPairing.plan(normalized, prefix: prefix, next: next,
                ownsNextClose: bracketCloses[closingOffset] == next && next != nil,
                language: indentationLanguage, enabled: completesJSONBrackets)
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
    override func insertTab(_ sender: Any?) { if !performIndentation(.indent) { super.insertTab(sender) } }
    override func insertBacktab(_ sender: Any?) { if !performIndentation(.outdent) { super.insertBacktab(sender) } }
    override func insertNewline(_ sender: Any?) { if !performIndentation(.newline) { super.insertNewline(sender) } }
    override func deleteBackward(_ sender: Any?) {
        let caret = selectedRange()
        guard completesJSONBrackets, indentationLanguage == .json || indentationLanguage == .jsonc,
              isEditable, !hasMarkedText(), selectedRanges.count == 1, caret.length == 0,
              let storage = textStorage, caret.location > 0, caret.location < storage.length,
              let close = bracketCloses[caret.location],
              storage.mutableString.character(at: caret.location) == close,
              (storage.mutableString.character(at: caret.location - 1) == 123 && close == 125
                || storage.mutableString.character(at: caret.location - 1) == 91 && close == 93) else {
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
                                      language: indentationLanguage, indentsJSONBlocks: indentsJSONBlocks) {
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
final class NativeTextEditorSurface: NSView, NSTextViewDelegate {
    let scrollView = NSScrollView()
    let textView = EditorCodeTextView(frame: .zero)
    lazy var find = EditorFindController(surface: self)
    lazy var lineCommands = EditorLineCommandController(surface: self)
    private(set) var documentFormat = TextDocumentFormat(bom: false, lineEnding: .lf)
    private(set) var generation = UUID()
    private(set) var lineIndex: EditorLineIndex?
    private(set) var presentedGeneration: UUID?
    private(set) var styleRangeCount = 0
    private(set) var visibleStyleRangeCount = 0
    var onEdit: ((String, UUID) -> Void)?
    var onRejectedEdit: ((TextDocumentFailure) -> Void)?
    var onCaret: (((line: Int, column: Int)?) -> Void)?
    private var installing = false
    private var gutter: EditorLineRuler!
    private var syntaxTokens: [TextSyntaxToken] = []
    private var styledRange = NSRange(location: 0, length: 0)
    private var refreshingViewport = false
    private var tabPresentationPending = true
    private var pointSizePending: CGFloat?
    private var requestedPointSize: CGFloat = 13
    private var applyingPendingPresentation = false
    private(set) var wrapsLines = true
    private(set) var syntaxPalette = EditorSyntaxPalette.adaptive
    private(set) var showsLineNumbers = true

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
        textView.delegate = self
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
        }
        textView.onFindAction = { [weak self] action in self?.find.perform(action) }
        textView.onMarkedText = { [weak self] in
            self?.lineCommands.inputDidChange(); self?.find.documentDidChange()
        }
        textView.onInputFocusLost = { [weak self] in self?.lineCommands.inputDidChange() }
        applyPendingPresentation()
    }
    required init?(coder: NSCoder) { nil }

    /// Initial/reloaded text is a document-owner decision. Never call this for
    /// syntax delivery: it intentionally replaces the native Undo stack.
    func install(_ value: TextDocumentValue) {
        textView.clearBracketPairs()
        lineCommands.inputDidChange()
        installing = true
        defer { installing = false; tabPresentationPending = true; applyPendingPresentation() }
        generation = UUID()
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
        lineCommands.inputDidChange()
        let historyChange = textView.undoManager.map { $0.isUndoing || $0.isRedoing } ?? false
        generation = UUID(); presentedGeneration = nil; lineIndex = nil
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
    func textViewDidChangeSelection(_ notification: Notification) {
        textView.nativeSelectionDidChange()
        lineCommands.selectionDidChange(); find.selectionDidChange(); publishCaret()
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
        return true
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

    /// Shared presentation for editable, read-only and comparison text. None of
    /// these choices changes characters, document format, generation or Undo.
    func applyEditorPreferences(_ value: EditorPreferences, pointSize: CGFloat, applyWrapping: Bool = true) {
        if applyWrapping { setWrapping(value.wrapsLines) }
        setLineNumbers(value.showsLineNumbers)
        setPointSize(pointSize)
        find.applyInterfaceScale(pointSize / CGFloat(value.basePointSize))
        setIndentation(value.indentation)
        textView.indentsJSONBlocks = value.indentsJSONBlocks
        textView.completesJSONBrackets = value.completesJSONBrackets
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
        let fitted = ceil(measured + padding * 2)
        let thickness = lineIndex == nil ? max(gutter.ruleThickness, fitted) : fitted
        if abs(gutter.ruleThickness - thickness) > 0.5 { gutter.ruleThickness = thickness }
    }
    func showFind() { find.perform(.showFindInterface) }
    var canGoToLine: Bool { lineIndex != nil && !textView.hasMarkedText() }
    @discardableResult
    func goToLine(_ line: Int, generation expected: UUID) -> Bool {
        guard generation == expected, !textView.hasMarkedText(), let lineIndex,
              lineIndex.matches(textView.string), let start = lineIndex.start(ofLine: line) else { return false }
        textView.setSelectedRange(.init(location: start, length: 0))
        textView.scrollRangeToVisible(textView.selectedRange())
        _ = window?.makeFirstResponder(textView)
        publishCaret()
        return true
    }
    func hideFind() { find.perform(.hideFindInterface) }
    @discardableResult
    func applyFindReplacement(_ plan: EditorFindReplacement, generation expected: UUID) -> Bool {
        guard generation == expected, textView.isEditable, !textView.hasMarkedText(),
              textView.string.utf16.elementsEqual(plan.original.utf16),
              plan.selection.location >= 0, plan.selection.length >= 0,
              plan.selection.location <= plan.value.utf16Count,
              plan.selection.length <= plan.value.utf16Count - plan.selection.location else { return false }
        textView.breakUndoCoalescing()
        textView.insertText(plan.value.text, replacementRange: .init(location: 0, length: plan.original.utf16.count))
        textView.breakUndoCoalescing()
        guard textView.string.utf16.elementsEqual(plan.value.text.utf16) else { return false }
        textView.undoManager?.setActionName(plan.count > 1 ? "Replace All" : "Replace")
        textView.setSelectedRange(plan.selection); textView.scrollRangeToVisible(plan.selection)
        return true
    }
    func clearPrivatePresentation() {
        lineCommands.close()
        find.clear(); textView.comparisonHighlights = []
        textView.onFindAction = nil; textView.onMarkedText = nil; textView.onInputFocusLost = nil
        onEdit = nil; onCaret = nil; onRejectedEdit = nil
        clearStyling()
        installing = true
        textView.string = ""; textView.undoManager?.removeAllActions()
        installing = false
        lineIndex = nil; presentedGeneration = nil; generation = UUID(); styleRangeCount = 0
        gutter.needsDisplay = true
    }
    private func clearStyling() {
        textView.layoutManager?.removeTemporaryAttribute(.foregroundColor,
            forCharacterRange: .init(location: 0, length: textView.string.utf16.count))
        styleRangeCount = 0
        visibleStyleRangeCount = 0; syntaxTokens = []; styledRange = .init(location: 0, length: 0)
    }
    @objc private func viewportChanged() { refreshVisibleStyling() }
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
        var lower = 0, upper = syntaxTokens.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if NSMaxRange(syntaxTokens[middle].range) <= range.location { lower = middle + 1 }
            else { upper = middle }
        }
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
    private func publishCaret() {
        onCaret?(lineIndex?.location(at: textView.selectedRange().location))
    }
}

@MainActor
private final class EditorLineRuler: NSRulerView {
    private weak var surface: NativeTextEditorSurface?
    init(surface: NativeTextEditorSurface) {
        self.surface = surface
        super.init(scrollView: surface.scrollView, orientation: .verticalRuler)
        clipsToBounds = true
        ruleThickness = 34
        clientView = surface.textView
    }
    required init(coder: NSCoder) { fatalError("Not a serialized view") }
    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let surface, let index = surface.lineIndex,
              let layout = surface.textView.layoutManager,
              let container = surface.textView.textContainer else { return }
        let text = surface.textView
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: max(10, (text.font?.pointSize ?? 13) - 2), weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        func label(_ number: Int, at point: NSPoint) {
            let string = String(number) as NSString
            let size = string.size(withAttributes: attributes)
            let converted = convert(point, from: text)
            string.draw(at: .init(x: ruleThickness - size.width - ceil(max(8, ((text.font?.pointSize ?? 13) - 2) * 0.65)), y: converted.y), withAttributes: attributes)
        }
        let glyphs = layout.glyphRange(forBoundingRect: text.visibleRect, in: container)
        layout.enumerateLineFragments(forGlyphRange: glyphs) { line, _, _, range, _ in
            let offset = layout.characterIndexForGlyph(at: range.location)
            guard let location = index.location(at: offset), location.column == 1 else { return }
            label(location.line, at: .init(x: 0, y: line.minY + text.textContainerInset.height))
        }
        if layout.extraLineFragmentTextContainer === container,
           index.starts.last == index.length {
            label(index.starts.count, at: .init(x: 0, y: layout.extraLineFragmentRect.minY + text.textContainerInset.height))
        }
    }
}
