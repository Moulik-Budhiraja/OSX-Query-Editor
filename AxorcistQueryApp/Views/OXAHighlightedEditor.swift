import AppKit
import SwiftUI

struct OXAHighlightedEditor: NSViewRepresentable {
    @Binding var text: String

    var fontSize: CGFloat = 16
    var focusRequestID: UInt64 = 0
    var onRunAction: (() -> Void)?
    var onToggleMode: (() -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.usesFindBar = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.allowsUndo = true
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.textColor = .labelColor
        textView.insertionPointColor = .controlAccentColor
        textView.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.textContainer?.widthTracksTextView = true
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true

        scrollView.documentView = textView

        context.coordinator.textView = textView
        context.coordinator.applyHighlight(to: text, preserveSelection: false)

        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }
        textView.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)

        if context.coordinator.lastFocusRequestID != self.focusRequestID {
            context.coordinator.lastFocusRequestID = self.focusRequestID
            context.coordinator.focusTextView()
        }

        if textView.string != text {
            context.coordinator.applyHighlight(to: text, preserveSelection: true)
            context.coordinator.refreshAutocomplete()
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: OXAHighlightedEditor
        weak var textView: NSTextView?
        var lastFocusRequestID: UInt64 = 0
        private var isApplying = false
        private var pendingAutocompleteRefresh = false
        private var pendingAutocompleteForce = false
        private var suppressNextAutocompleteRefresh = false
        private var activeAutocompleteQuery: OXAAutocompleteQuery?
        private var currentSuggestions: [String] = []
        private var selectedSuggestionIndex = 0
        private let autocomplete = OXAAutocompleteEngine()
        private let suggestionPopoverController = OXASuggestionPopoverController()

        init(parent: OXAHighlightedEditor) {
            self.parent = parent
            super.init()
            self.suggestionPopoverController.onSelect = { [weak self] selectedIndex in
                self?.acceptSuggestion(at: selectedIndex)
            }
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            guard !self.isApplying else { return }

            let latest = textView.string
            if self.parent.text != latest {
                self.parent.text = latest
            }
            self.applyHighlight(to: latest, preserveSelection: true)
            if self.suppressNextAutocompleteRefresh {
                self.suppressNextAutocompleteRefresh = false
                self.dismissSuggestionPopover()
                return
            }
            self.scheduleAutocompleteRefresh()
        }

        func textDidEndEditing(_ notification: Notification) {
            self.dismissSuggestionPopover()
        }

        func textView(
            _ textView: NSTextView,
            doCommandBy commandSelector: Selector) -> Bool
        {
            if self.isCommandModeToggle() {
                self.parent.onToggleMode?()
                return true
            }
            if self.isCommandEnter(commandSelector) {
                self.dismissSuggestionPopover()
                self.parent.onRunAction?()
                return true
            }

            if commandSelector == #selector(NSResponder.complete(_:)) {
                self.scheduleAutocompleteRefresh(force: true)
                return true
            }

            guard !self.currentSuggestions.isEmpty else {
                return false
            }

            switch commandSelector {
            case #selector(NSResponder.moveUp(_:)):
                self.selectedSuggestionIndex = max(0, self.selectedSuggestionIndex - 1)
                self.updateSuggestionPopover()
                return true
            case #selector(NSResponder.moveDown(_:)):
                self.selectedSuggestionIndex = min(self.currentSuggestions.count - 1, self.selectedSuggestionIndex + 1)
                self.updateSuggestionPopover()
                return true
            case #selector(NSResponder.insertTab(_:)),
                 #selector(NSResponder.insertNewline(_:)),
                 #selector(NSResponder.insertLineBreak(_:)):
                self.acceptSelectedSuggestion()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                self.dismissSuggestionPopover()
                return true
            default:
                break
            }
            return false
        }

        func applyHighlight(to content: String, preserveSelection: Bool) {
            guard let textView else { return }
            guard !self.isApplying else { return }

            let selectedRanges = textView.selectedRanges
            let font = NSFont.monospacedSystemFont(ofSize: self.parent.fontSize, weight: .regular)
            let highlighted = OXAColorTheme.highlightedProgram(content, font: font)

            self.isApplying = true
            textView.textStorage?.setAttributedString(highlighted)
            if preserveSelection {
                textView.selectedRanges = selectedRanges
            }
            self.isApplying = false
        }

        private func isCommandEnter(_ commandSelector: Selector) -> Bool {
            let isEnterCommand =
                commandSelector == #selector(NSResponder.insertNewline(_:)) ||
                commandSelector == #selector(NSResponder.insertLineBreak(_:)) ||
                commandSelector == #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:))
            guard isEnterCommand else { return false }

            let flags = NSApp.currentEvent?.modifierFlags ?? []
            return flags.contains(.command)
        }

        private func isCommandModeToggle() -> Bool {
            guard let event = NSApp.currentEvent, event.type == .keyDown else {
                return false
            }
            let flags = event.modifierFlags
            guard flags.contains(.command) else {
                return false
            }
            return event.charactersIgnoringModifiers?.lowercased() == "i"
        }

        func focusTextView() {
            guard let textView else { return }
            DispatchQueue.main.async {
                guard let window = textView.window else { return }
                window.makeFirstResponder(textView)
            }
        }

        func refreshAutocomplete(force: Bool = false) {
            guard let textView else { return }
            guard !self.isApplying else { return }
            guard textView.window?.firstResponder === textView else {
                self.dismissSuggestionPopover()
                return
            }

            let selectedRange = textView.selectedRange()
            guard selectedRange.length == 0 else {
                self.dismissSuggestionPopover()
                return
            }

            guard let query = self.autocomplete.makeQuery(
                text: textView.string,
                cursorUTF16: selectedRange.location)
            else {
                self.dismissSuggestionPopover()
                return
            }

            let suggestions = self.autocomplete.suggestions(
                for: query,
                force: force,
                limit: OXAAutocompleteEngine.maxVisibleSuggestions)
            guard !suggestions.isEmpty else {
                self.dismissSuggestionPopover()
                return
            }

            self.activeAutocompleteQuery = query
            self.currentSuggestions = suggestions
            self.selectedSuggestionIndex = min(self.selectedSuggestionIndex, suggestions.count - 1)
            self.updateSuggestionPopover()
        }

        private func dismissSuggestionPopover() {
            self.currentSuggestions = []
            self.selectedSuggestionIndex = 0
            self.activeAutocompleteQuery = nil
            self.suggestionPopoverController.close()
        }

        private func scheduleAutocompleteRefresh(force: Bool = false) {
            if force {
                self.pendingAutocompleteForce = true
            }

            guard !self.pendingAutocompleteRefresh else { return }
            self.pendingAutocompleteRefresh = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.pendingAutocompleteRefresh = false
                let shouldForce = self.pendingAutocompleteForce
                self.pendingAutocompleteForce = false
                self.refreshAutocomplete(force: shouldForce)
            }
        }

        private func acceptSelectedSuggestion() {
            self.acceptSuggestion(at: self.selectedSuggestionIndex)
        }

        private func acceptSuggestion(at index: Int) {
            guard index >= 0, index < self.currentSuggestions.count else {
                return
            }
            guard let textView, let query = self.activeAutocompleteQuery else {
                return
            }

            var replacementText = self.currentSuggestions[index]
            if query.replacementRange.length == 0,
               query.replacementRange.location > 0,
               let previousCharacter = self.character(beforeUTF16Offset: query.replacementRange.location, in: textView.string),
               !previousCharacter.isWhitespace,
               previousCharacter != ";",
               previousCharacter != "+"
            {
                replacementText = " " + replacementText
            }

            let replacementRange = query.replacementRange
            guard NSMaxRange(replacementRange) <= textView.string.utf16.count else {
                return
            }

            self.suppressNextAutocompleteRefresh = true
            textView.textStorage?.replaceCharacters(in: replacementRange, with: replacementText)
            let cursor = replacementRange.location + (replacementText as NSString).length
            textView.setSelectedRange(NSRange(location: cursor, length: 0))
            textView.didChangeText()
            self.dismissSuggestionPopover()
        }

        private func character(beforeUTF16Offset offset: Int, in text: String) -> Character? {
            guard offset > 0, offset <= text.utf16.count else { return nil }
            let cursor = String.Index(utf16Offset: offset, in: text)
            guard cursor > text.startIndex else { return nil }
            return text[text.index(before: cursor)]
        }

        private func updateSuggestionPopover() {
            guard
                let textView,
                !self.currentSuggestions.isEmpty
            else {
                self.suggestionPopoverController.close()
                return
            }

            let anchorRect = self.caretAnchorRect(in: textView)
            self.suggestionPopoverController.update(
                suggestions: self.currentSuggestions,
                selectedIndex: self.selectedSuggestionIndex,
                fontSize: self.parent.fontSize)
            self.suggestionPopoverController.show(relativeTo: anchorRect, of: textView)
        }

        private func caretAnchorRect(in textView: NSTextView) -> NSRect {
            let selected = textView.selectedRange()
            guard let window = textView.window else {
                return NSRect(x: 0, y: 0, width: 1, height: textView.font?.pointSize ?? 16)
            }

            let screenRect = textView.firstRect(forCharacterRange: selected, actualRange: nil)
            let windowRect = window.convertFromScreen(screenRect)
            let localRect = textView.convert(windowRect, from: nil)

            let height = max(1, textView.font?.pointSize ?? 16)
            if localRect.isNull || !localRect.origin.x.isFinite || !localRect.origin.y.isFinite {
                return NSRect(x: textView.textContainerInset.width, y: textView.textContainerInset.height, width: 1, height: height)
            }

            return NSRect(x: localRect.minX, y: localRect.minY, width: max(1, localRect.width), height: max(height, localRect.height))
        }
    }
}

@MainActor
private final class OXASuggestionPopoverController {
    var onSelect: ((Int) -> Void)?

    private let popover: NSPopover
    private let hostingController: NSHostingController<OXASuggestionPopoverView>
    private var suggestions: [String] = []
    private var selectedIndex = 0
    private weak var anchorView: NSView?

    init() {
        self.popover = NSPopover()
        self.popover.behavior = .semitransient
        self.popover.animates = false

        self.hostingController = NSHostingController(
            rootView: OXASuggestionPopoverView(
                suggestions: [],
                selectedIndex: 0,
                fontSize: 14,
                onSelect: { _ in }))
        self.popover.contentViewController = self.hostingController
    }

    func update(suggestions: [String], selectedIndex: Int, fontSize: CGFloat) {
        self.suggestions = suggestions
        self.selectedIndex = max(0, min(selectedIndex, max(0, suggestions.count - 1)))
        self.hostingController.rootView = OXASuggestionPopoverView(
            suggestions: suggestions,
            selectedIndex: self.selectedIndex,
            fontSize: fontSize,
            onSelect: { [weak self] index in
                self?.onSelect?(index)
            })
        self.popover.contentSize = self.measuredSize(suggestions: suggestions, fontSize: fontSize)
    }

    func show(relativeTo rect: NSRect, of view: NSView) {
        guard !self.suggestions.isEmpty else {
            self.close()
            return
        }

        if self.popover.isShown {
            if self.anchorView === view {
                self.popover.positioningRect = rect
                return
            }
            self.popover.performClose(nil)
        }
        self.anchorView = view
        self.popover.show(relativeTo: rect, of: view, preferredEdge: .maxY)
    }

    func close() {
        guard self.popover.isShown else { return }
        self.popover.performClose(nil)
        self.anchorView = nil
    }

    private func measuredSize(suggestions: [String], fontSize: CGFloat) -> NSSize {
        let maxRows = min(10, suggestions.count)
        let rowHeight = max(24, floor(fontSize) + 10)
        let contentHeight = CGFloat(maxRows) * CGFloat(rowHeight) + 52

        let maxCharacters = suggestions.map(\.count).max() ?? 16
        let estimatedWidth = CGFloat(maxCharacters) * max(7.4, fontSize * 0.58) + 88
        let width = min(max(240, estimatedWidth), 520)

        return NSSize(width: width, height: min(contentHeight, 340))
    }
}

@MainActor
private struct OXASuggestionPopoverView: View {
    let suggestions: [String]
    let selectedIndex: Int
    let fontSize: CGFloat
    let onSelect: (Int) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Action Grammar")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text("Tab/Enter to accept")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 6)

            Divider()
                .opacity(0.6)

            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: suggestions.count > 8) {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(suggestions.enumerated()), id: \.offset) { index, suggestion in
                            HStack(spacing: 8) {
                                Text(suggestion)
                                    .font(.system(size: max(12, fontSize - 1), weight: .regular, design: .monospaced))
                                    .lineLimit(1)
                                    .foregroundStyle(index == selectedIndex ? Color.white : Color.primary)
                                Spacer(minLength: 8)
                                Text("KW")
                                    .font(.system(size: 9, weight: .bold, design: .rounded))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .foregroundStyle(index == selectedIndex ? Color.white.opacity(0.92) : Color.secondary)
                                    .background(index == selectedIndex ? Color.white.opacity(0.2) : Color.secondary.opacity(0.14))
                                    .clipShape(Capsule(style: .continuous))
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(index == selectedIndex ? Color.accentColor.opacity(0.92) : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                            .contentShape(Rectangle())
                            .id(index)
                            .onTapGesture {
                                onSelect(index)
                            }
                        }
                    }
                    .onChange(of: selectedIndex) { _, newValue in
                        guard suggestions.indices.contains(newValue) else { return }
                        withAnimation(.easeOut(duration: 0.12)) {
                            proxy.scrollTo(newValue)
                        }
                    }
                    .onChange(of: suggestions.count) { _, _ in
                        guard suggestions.indices.contains(selectedIndex) else { return }
                        withAnimation(.easeOut(duration: 0.12)) {
                            proxy.scrollTo(selectedIndex)
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 6)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(.regularMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .stroke(Color(nsColor: NSColor.separatorColor).opacity(0.45), lineWidth: 1))
                .shadow(color: Color.black.opacity(0.16), radius: 12, x: 0, y: 5))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct OXAAutocompleteQuery {
    let prefix: String
    let replacementRange: NSRange
    let candidates: [String]
}

private struct OXAAutocompleteToken {
    enum Kind {
        case word(String)
        case string
        case semicolon
        case plus
        case other
    }

    let kind: Kind
}

private struct OXAAutocompleteScanResult {
    let tokens: [OXAAutocompleteToken]
    let inStringLiteral: Bool
}

@MainActor
private struct OXAAutocompleteEngine {
    static let maxVisibleSuggestions = 16

    private static let statementKeywords = ["send", "read", "sleep", "open", "close"]
    private static let sendActions = ["text", "click", "right click", "drag", "hotkey", "scroll"]
    private static let scrollDirections = ["up", "down", "left", "right"]
    private static let hotkeyParts = [
        "cmd", "ctrl", "alt", "shift", "fn",
        "enter", "tab", "space", "escape",
        "up", "down", "left", "right",
    ]

    func makeQuery(
        text: String,
        cursorUTF16: Int,
        partialWordRange: NSRange? = nil) -> OXAAutocompleteQuery?
    {
        let clampedCursor = max(0, min(cursorUTF16, text.utf16.count))
        let replacementRange = self.resolvePrefixRange(
            in: text,
            cursorUTF16: clampedCursor,
            partialWordRange: partialWordRange)
        let prefix = (text as NSString).substring(with: replacementRange)
        let prefixStartIndex = String.Index(utf16Offset: replacementRange.location, in: text)
        let scanResult = self.scanContext(in: text, upTo: prefixStartIndex)
        if scanResult.inStringLiteral {
            return nil
        }

        let candidates = self.candidates(for: scanResult.tokens)
        guard !candidates.isEmpty else {
            return nil
        }

        return OXAAutocompleteQuery(prefix: prefix, replacementRange: replacementRange, candidates: candidates)
    }

    func suggestions(for query: OXAAutocompleteQuery, force: Bool, limit: Int) -> [String] {
        let prefix = query.prefix.lowercased()
        let filtered: [String]
        if prefix.isEmpty {
            filtered = force ? query.candidates : query.candidates
        } else {
            filtered = query.candidates.filter { $0.lowercased().hasPrefix(prefix) }
        }

        var seen = Set<String>()
        var deduped: [String] = []
        deduped.reserveCapacity(filtered.count)
        for suggestion in filtered {
            if seen.insert(suggestion).inserted {
                deduped.append(suggestion)
            }
            if deduped.count == limit {
                break
            }
        }
        return deduped
    }

    private func candidates(for tokens: [OXAAutocompleteToken]) -> [String] {
        let statementTokens = self.statementTokens(from: tokens)
        let components = statementTokens.compactMap { token -> OXAAutocompleteComponent? in
            switch token.kind {
            case let .word(value):
                return .word(value.lowercased())
            case .string:
                return .string
            default:
                return nil
            }
        }

        guard let first = components.first else {
            return Self.statementKeywords
        }

        switch first {
        case let .word(keyword):
            switch keyword {
            case "send":
                return self.sendCandidates(
                    for: Array(components.dropFirst()),
                    statementTokens: statementTokens)
            case "read":
                return self.readCandidates(for: Array(components.dropFirst()))
            case "sleep", "open", "close":
                return []
            default:
                return Self.statementKeywords
            }
        case .string:
            return Self.statementKeywords
        }
    }

    private func readCandidates(for components: [OXAAutocompleteComponent]) -> [String] {
        guard !components.isEmpty else {
            return []
        }
        if components.count == 1 {
            return ["from"]
        }
        if case .word("from") = components[1] {
            return []
        }
        return ["from"]
    }

    private func sendCandidates(
        for components: [OXAAutocompleteComponent],
        statementTokens: [OXAAutocompleteToken]) -> [String]
    {
        guard let first = components.first else {
            return Self.sendActions
        }

        guard case let .word(action) = first else {
            return Self.sendActions
        }

        switch action {
        case "text":
            return self.sendTextCandidates(for: components)
        case "click":
            return self.sendClickCandidates(for: components)
        case "right":
            return self.sendRightClickCandidates(for: components)
        case "drag":
            return self.sendDragCandidates(for: components)
        case "hotkey":
            return self.sendHotkeyCandidates(
                for: components,
                statementTokens: statementTokens)
        case "scroll":
            return self.sendScrollCandidates(for: components)
        default:
            return Self.sendActions
        }
    }

    private func sendTextCandidates(for components: [OXAAutocompleteComponent]) -> [String] {
        guard components.count >= 2, components[1] == .string else {
            return []
        }

        if components.count == 2 {
            return ["to", "as keys"]
        }

        guard case let .word(word2) = components[2] else {
            return ["to", "as keys"]
        }

        if word2 == "to" {
            return []
        }

        if word2 == "as" {
            if components.count == 3 {
                return ["keys"]
            }
            guard case let .word(word3) = components[3] else {
                return ["keys"]
            }
            if word3 == "keys" {
                if components.count == 4 {
                    return ["to"]
                }
                if components.count >= 5,
                   case .word("to") = components[4]
                {
                    return []
                }
                return ["to"]
            }
            return ["keys"]
        }

        return ["to", "as keys"]
    }

    private func sendClickCandidates(for components: [OXAAutocompleteComponent]) -> [String] {
        if components.count == 1 {
            return ["to"]
        }
        if components.count >= 2,
           case .word("to") = components[1]
        {
            return []
        }
        return ["to"]
    }

    private func sendRightClickCandidates(for components: [OXAAutocompleteComponent]) -> [String] {
        if components.count == 1 {
            return ["click"]
        }
        if components.count == 2 {
            if case .word("click") = components[1] {
                return ["to"]
            }
            return ["click"]
        }
        if case .word("click") = components[1] {
            if case .word("to") = components[2] {
                return []
            }
            return ["to"]
        }
        return ["click"]
    }

    private func sendDragCandidates(for components: [OXAAutocompleteComponent]) -> [String] {
        if components.count <= 1 {
            return []
        }
        if components.count == 2 {
            return ["to"]
        }
        if case .word("to") = components[2] {
            return []
        }
        return ["to"]
    }

    private func sendHotkeyCandidates(
        for components: [OXAAutocompleteComponent],
        statementTokens: [OXAAutocompleteToken]) -> [String]
    {
        if components.count <= 1 {
            return Self.hotkeyParts
        }

        if case .plus = statementTokens.last?.kind {
            return Self.hotkeyParts
        }

        for component in components.dropFirst() {
            if case .word("to") = component {
                return []
            }
        }
        return ["to"] + Self.hotkeyParts
    }

    private func sendScrollCandidates(for components: [OXAAutocompleteComponent]) -> [String] {
        if components.count == 1 {
            return ["to"] + Self.scrollDirections
        }
        guard case let .word(word2) = components[1] else {
            return ["to"] + Self.scrollDirections
        }

        if word2 == "to" {
            return []
        }

        if Self.scrollDirections.contains(word2) {
            if components.count == 2 {
                return ["to"]
            }
            if case .word("to") = components[2] {
                return []
            }
            return ["to"]
        }

        return ["to"] + Self.scrollDirections
    }

    private func statementTokens(from tokens: [OXAAutocompleteToken]) -> [OXAAutocompleteToken] {
        guard let lastSemicolonIndex = tokens.lastIndex(where: { token in
            if case .semicolon = token.kind {
                return true
            }
            return false
        }) else {
            return tokens
        }
        return Array(tokens[(lastSemicolonIndex + 1)...])
    }

    private func scanContext(in text: String, upTo cursor: String.Index) -> OXAAutocompleteScanResult {
        var tokens: [OXAAutocompleteToken] = []
        var index = text.startIndex

        while index < cursor {
            let character = text[index]

            if character.isWhitespace {
                index = text.index(after: index)
                continue
            }

            if character == ";" {
                tokens.append(OXAAutocompleteToken(kind: .semicolon))
                index = text.index(after: index)
                continue
            }

            if character == "+" {
                tokens.append(OXAAutocompleteToken(kind: .plus))
                index = text.index(after: index)
                continue
            }

            if character == "\"" {
                index = text.index(after: index)
                var escaped = false
                var closed = false
                while index < cursor {
                    let current = text[index]
                    index = text.index(after: index)
                    if escaped {
                        escaped = false
                        continue
                    }
                    if current == "\\" {
                        escaped = true
                        continue
                    }
                    if current == "\"" {
                        closed = true
                        break
                    }
                }
                if !closed {
                    return OXAAutocompleteScanResult(tokens: tokens, inStringLiteral: true)
                }
                tokens.append(OXAAutocompleteToken(kind: .string))
                continue
            }

            if self.isIdentifierCharacter(character) {
                let start = index
                index = self.consumeIdentifier(in: text, from: start, limit: cursor)
                let token = String(text[start..<index])
                tokens.append(OXAAutocompleteToken(kind: .word(token)))
                continue
            }

            tokens.append(OXAAutocompleteToken(kind: .other))
            index = text.index(after: index)
        }

        return OXAAutocompleteScanResult(tokens: tokens, inStringLiteral: false)
    }

    private func resolvePrefixRange(in text: String, cursorUTF16: Int, partialWordRange: NSRange?) -> NSRange {
        if let partialWordRange,
           partialWordRange.location >= 0,
           partialWordRange.length >= 0,
           NSMaxRange(partialWordRange) <= text.utf16.count
        {
            return partialWordRange
        }

        guard cursorUTF16 > 0 else {
            return NSRange(location: cursorUTF16, length: 0)
        }

        let cursorIndex = String.Index(utf16Offset: cursorUTF16, in: text)
        var start = cursorIndex

        while start > text.startIndex {
            let previous = text.index(before: start)
            if self.isIdentifierCharacter(text[previous]) {
                start = previous
                continue
            }
            break
        }

        let utf16 = text.utf16
        let location = utf16.distance(
            from: utf16.startIndex,
            to: start.samePosition(in: utf16) ?? utf16.startIndex)
        let length = cursorUTF16 - location
        return NSRange(location: location, length: max(0, length))
    }

    private func consumeIdentifier(in text: String, from start: String.Index, limit: String.Index) -> String.Index {
        var index = start
        while index < limit, self.isIdentifierCharacter(text[index]) {
            index = text.index(after: index)
        }
        return index
    }

    private func isIdentifierCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_" || character == "-" || character == "."
    }
}

private enum OXAAutocompleteComponent: Equatable {
    case word(String)
    case string
}
