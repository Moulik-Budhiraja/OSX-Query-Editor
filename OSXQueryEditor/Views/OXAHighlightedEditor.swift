import AppKit
import OSXQuery
import SwiftUI

struct OXAHighlightedEditor: NSViewRepresentable {
    @Binding var text: String

    var referenceRows: [QueryResultRow] = []
    var appBundleIdentifiers: [String] = []
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
        context.coordinator.parent = self
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
        private var currentSuggestions: [OXAAutocompleteSuggestion] = []
        private var selectedSuggestionIndex = 0
        private let autocomplete = OXAAutocompleteEngine()
        private let suggestionPopoverController = OXASuggestionPopoverController()
        private static let autoClosingPairs: [Character: Character] = [
            "[": "]",
            "(": ")",
            "{": "}",
            "\"": "\"",
            "'": "'",
        ]
        private static let autoClosingClosers: Set<Character> = ["]", ")", "}", "\"", "'"]

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
            shouldChangeTextIn affectedCharRange: NSRange,
            replacementString: String?) -> Bool
        {
            if let replacementString,
               replacementString.count == 1,
               let typed = replacementString.first,
               self.handleAutoClosingInsertion(typed, in: textView, affectedRange: affectedCharRange)
            {
                return false
            }
            return true
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

            if commandSelector == #selector(NSResponder.insertTab(_:)),
               self.currentSuggestions.isEmpty,
               self.handleTabSkipOut(in: textView)
            {
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

            if !force,
               self.shouldSuppressAutocompleteAfterSemicolon(
                   in: textView.string,
                   cursorUTF16: selectedRange.location)
            {
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
                limit: OXAAutocompleteEngine.maxVisibleSuggestions,
                referenceRows: self.parent.referenceRows,
                appBundleIdentifiers: self.parent.appBundleIdentifiers)
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

            var replacementText = self.currentSuggestions[index].insertionText
            if query.shouldPadWithLeadingSpace,
               query.replacementRange.length == 0,
               replacementText != "+",
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

        private func character(atUTF16Offset offset: Int, in text: String) -> Character? {
            guard offset >= 0, offset < text.utf16.count else { return nil }
            let index = String.Index(utf16Offset: offset, in: text)
            return text[index]
        }

        private func shouldSuppressAutocompleteAfterSemicolon(in text: String, cursorUTF16: Int) -> Bool {
            guard cursorUTF16 > 0, cursorUTF16 <= text.utf16.count else { return false }

            var cursor = String.Index(utf16Offset: cursorUTF16, in: text)
            while cursor > text.startIndex {
                let previousIndex = text.index(before: cursor)
                let character = text[previousIndex]
                if character.isWhitespace {
                    cursor = previousIndex
                    continue
                }
                return character == ";"
            }
            return false
        }

        private func handleAutoClosingInsertion(
            _ typed: Character,
            in textView: NSTextView,
            affectedRange: NSRange) -> Bool
        {
            let text = textView.string
            guard affectedRange.location >= 0,
                  NSMaxRange(affectedRange) <= text.utf16.count
            else {
                return false
            }

            if affectedRange.length == 0,
               Self.autoClosingClosers.contains(typed),
               let current = self.character(atUTF16Offset: affectedRange.location, in: text),
               current == typed
            {
                textView.setSelectedRange(NSRange(location: affectedRange.location + 1, length: 0))
                return true
            }

            guard affectedRange.length == 0,
                  let closer = Self.autoClosingPairs[typed]
            else {
                return false
            }

            if (typed == "\"" || typed == "'"),
               self.character(beforeUTF16Offset: affectedRange.location, in: text) == "\\"
            {
                return false
            }

            let insertion = String([typed, closer])
            textView.textStorage?.replaceCharacters(in: affectedRange, with: insertion)
            textView.setSelectedRange(NSRange(location: affectedRange.location + 1, length: 0))
            textView.didChangeText()
            return true
        }

        private func handleTabSkipOut(in textView: NSTextView) -> Bool {
            let selected = textView.selectedRange()
            guard selected.length == 0 else {
                return false
            }
            guard let current = self.character(atUTF16Offset: selected.location, in: textView.string),
                  Self.autoClosingClosers.contains(current)
            else {
                return false
            }

            textView.setSelectedRange(NSRange(location: selected.location + 1, length: 0))
            self.dismissSuggestionPopover()
            return true
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
    private var suggestions: [OXAAutocompleteSuggestion] = []
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

    func update(suggestions: [OXAAutocompleteSuggestion], selectedIndex: Int, fontSize: CGFloat) {
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

    private func measuredSize(suggestions: [OXAAutocompleteSuggestion], fontSize: CGFloat) -> NSSize {
        let maxRows = min(10, suggestions.count)
        let visibleSuggestions = Array(suggestions.prefix(maxRows))
        let keywordRowHeight = max(20, floor(fontSize) + 7)
        let referenceRowHeight = max(30, floor(fontSize) + 8)
        let contentRowsHeight = visibleSuggestions.reduce(CGFloat(0)) { partial, suggestion in
            switch suggestion.kind {
            case .keyword:
                return partial + keywordRowHeight
            case .reference:
                return partial + referenceRowHeight
            }
        }
        let includesReferenceRows = suggestions.contains { suggestion in
            if case .reference = suggestion.kind {
                return true
            }
            return false
        }
        let minimumRowsHeight = includesReferenceRows
            ? (referenceRowHeight * 3.5)
            : (keywordRowHeight * 6.0)
        let contentHeight = max(contentRowsHeight, minimumRowsHeight) + 42

        let maxCharacters = visibleSuggestions.map(\.displayWidthHint).max() ?? 20
        let estimatedWidth = CGFloat(maxCharacters) * max(6.2, fontSize * 0.48) + 68
        let width = min(max(232, estimatedWidth), 420)

        return NSSize(width: width, height: min(contentHeight, 286))
    }
}

@MainActor
private struct OXASuggestionPopoverView: View {
    let suggestions: [OXAAutocompleteSuggestion]
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
                            self.suggestionRow(suggestion, selected: index == selectedIndex)
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

    @ViewBuilder
    private func suggestionRow(_ suggestion: OXAAutocompleteSuggestion, selected: Bool) -> some View {
        switch suggestion.kind {
        case .keyword:
            HStack(spacing: 8) {
                Text(suggestion.insertionText)
                    .font(.system(size: max(11, fontSize - 2), weight: .regular, design: .monospaced))
                    .lineLimit(1)
                    .foregroundStyle(selected ? Color.white : Color.primary)
                Spacer(minLength: 8)
                self.badgeText("KW", selected: selected)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Color.accentColor.opacity(0.92) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())

        case let .reference(payload):
            let primaryText = self.primaryText(for: payload)
            let secondary = self.secondaryTexts(for: payload)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 8) {
                    Text(primaryText)
                        .font(.system(size: max(10, fontSize - 2), weight: .semibold, design: .monospaced))
                        .lineLimit(1)
                        .foregroundStyle(self.primaryMatchColor(payload.matchField))
                    Spacer(minLength: 8)
                    Text(payload.matchField.badge)
                        .font(.system(size: 8, weight: .bold, design: .rounded))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .foregroundStyle(Color.secondary)
                        .background(Color.secondary.opacity(0.14))
                        .clipShape(Capsule(style: .continuous))
                }

                HStack(spacing: 6) {
                    Text(secondary.left)
                        .font(.system(size: max(9, fontSize - 5), weight: .regular, design: .monospaced))
                        .foregroundStyle(selected ? Color.primary.opacity(0.92) : Color.secondary)
                        .lineLimit(1)
                    Text("·")
                        .font(.system(size: max(9, fontSize - 5), weight: .semibold, design: .rounded))
                        .foregroundStyle(selected ? Color.primary.opacity(0.55) : Color.secondary)
                    Text(secondary.right)
                        .font(.system(size: max(9, fontSize - 5), weight: .regular, design: .monospaced))
                        .foregroundStyle(selected ? Color.primary.opacity(0.92) : Color.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Color.white.opacity(0.10) : Color.secondary.opacity(0.06))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(Color.white.opacity(selected ? 0.18 : 0.08), lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
        }
    }

    private func badgeText(_ text: String, selected: Bool) -> some View {
        Text(text)
            .font(.system(size: 8, weight: .bold, design: .rounded))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .foregroundStyle(selected ? Color.white.opacity(0.92) : Color.secondary)
            .background(selected ? Color.white.opacity(0.2) : Color.secondary.opacity(0.14))
            .clipShape(Capsule(style: .continuous))
    }

    private func primaryText(for payload: OXAReferenceAutocompletePayload) -> String {
        switch payload.matchField {
        case .reference:
            return payload.reference
        case .cpName:
            let cpName = self.contextTruncatedText(
                payload.cpName,
                around: payload.cpNameMatchRange,
                maxLength: 26)
            return cpName
        case .role:
            return payload.role
        }
    }

    private func secondaryTexts(for payload: OXAReferenceAutocompletePayload) -> (left: String, right: String) {
        let truncatedCPName = self.tailTruncatedText(payload.cpName, maxLength: 14)

        switch payload.matchField {
        case .reference:
            return (left: truncatedCPName, right: self.tailTruncatedText(payload.role, maxLength: 12))
        case .cpName:
            return (left: payload.reference, right: self.tailTruncatedText(payload.role, maxLength: 12))
        case .role:
            return (left: truncatedCPName, right: payload.reference)
        }
    }

    private func tailTruncatedText(_ text: String, maxLength: Int) -> String {
        guard maxLength > 1 else { return text }
        let nsText = text as NSString
        guard nsText.length > maxLength else { return text }
        return nsText.substring(to: maxLength - 1) + "…"
    }

    private func contextTruncatedText(_ text: String, around matchRange: NSRange?, maxLength: Int) -> String {
        guard maxLength > 6 else { return self.tailTruncatedText(text, maxLength: maxLength) }
        let nsText = text as NSString
        guard nsText.length > maxLength else { return text }
        guard let matchRange else {
            return self.tailTruncatedText(text, maxLength: maxLength)
        }

        let clampedLocation = max(0, min(matchRange.location, nsText.length - 1))
        let clampedLength = max(1, min(matchRange.length, nsText.length - clampedLocation))
        let target = NSRange(location: clampedLocation, length: clampedLength)

        var start = max(0, target.location - (maxLength / 3))
        var end = min(nsText.length, start + maxLength)
        if end - start < maxLength {
            start = max(0, end - maxLength)
        }
        if target.location + target.length > end {
            end = min(nsText.length, target.location + target.length)
            start = max(0, end - maxLength)
        }

        var snippet = nsText.substring(with: NSRange(location: start, length: end - start))
        if start > 0 {
            snippet = "…" + snippet
        }
        if end < nsText.length {
            snippet += "…"
        }
        return snippet
    }

    private func primaryMatchColor(_ field: OXAReferenceMatchField) -> Color {
        switch field {
        case .reference:
            return Color(nsColor: OXAColorTheme.referenceToken)
        case .cpName:
            return Color(nsColor: OXAColorTheme.stringToken)
        case .role:
            return Color(nsColor: OXAColorTheme.attributeToken)
        }
    }
}

private struct OXAAutocompleteQuery {
    let prefix: String
    let replacementRange: NSRange
    let keywordCandidates: [String]
    let expectsReference: Bool
    let referenceIntent: OXAReferenceIntent
    let expectsAppIdentifier: Bool
    let shouldPadWithLeadingSpace: Bool
}

private enum OXAReferenceIntent {
    case none
    case readSource
    case textTarget
    case clickTarget
    case dragSource
    case dragTarget
    case hotkeyTarget
    case scrollTarget
}

private struct OXAAutocompleteSuggestion {
    enum Kind {
        case keyword
        case reference(OXAReferenceAutocompletePayload)
    }

    let insertionText: String
    let kind: Kind

    var displayWidthHint: Int {
        switch self.kind {
        case .keyword:
            return self.insertionText.count
        case let .reference(payload):
            let referenceLength = min(payload.reference.count, 10)
            let roleLength = min(payload.role.count, 10)
            let cpNameLength = min(payload.cpName.count, 12) + 2
            return min(34, max(cpNameLength + roleLength + 2, max(referenceLength, roleLength) + 6))
        }
    }
}

private enum OXAReferenceMatchField: Int {
    case reference = 0
    case cpName = 1
    case role = 2

    var label: String {
        switch self {
        case .reference:
            return "Ref ID Match"
        case .cpName:
            return "Name Match"
        case .role:
            return "Role Match"
        }
    }

    var badge: String {
        switch self {
        case .reference:
            return "REF"
        case .cpName:
            return "CP"
        case .role:
            return "ROLE"
        }
    }
}

private struct OXAReferenceAutocompletePayload {
    let reference: String
    let cpName: String
    let role: String
    let matchField: OXAReferenceMatchField
    let cpNameMatchRange: NSRange?
}

private struct OXAReferenceFieldMatch {
    let field: OXAReferenceMatchField
    let startIndex: Int
    let spanLength: Int
    let matchRange: NSRange

    var ranking: (Int, Int, Int) {
        (self.startIndex, self.field.rawValue, self.spanLength)
    }
}

private struct OXAReferenceSearchCandidate {
    let insertionText: String
    let payload: OXAReferenceAutocompletePayload
    let ranking: (Int, Int, Int)
    let rowOrder: Int
    let fitScore: Int
}

private struct OXAHotkeyTokenState {
    var usedModifiers: [String] = []
    var hasBaseKey = false
    var hasAnyToken = false
    var trailingPlus = false
    var hasToTarget = false
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
    let stringContext: OXAAutocompleteStringContext?
}

private struct OXAAutocompleteStringContext {
    enum Kind {
        case openOrCloseAppIdentifier
    }

    let kind: Kind
    let contentStartUTF16: Int
}

@MainActor
private struct OXAAutocompleteEngine {
    static let maxVisibleSuggestions = 16

    private static let statementKeywords = ["send", "read", "sleep", "open", "close"]
    private static let sendActions = ["text", "click", "right click", "drag", "hotkey", "scroll"]
    private static let scrollDirections = ["up", "down", "left", "right"]
    private static let hotkeyModifiers = ["cmd", "ctrl", "alt", "shift", "fn"]
    private static let hotkeyNamedBaseKeys = [
        "enter", "tab", "space", "escape", "backspace", "delete",
        "home", "end", "page_up", "page_down",
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
        let prefixStartIndex = String.Index(utf16Offset: replacementRange.location, in: text)
        let scanResult = self.scanContext(in: text, upTo: prefixStartIndex)
        if scanResult.inStringLiteral,
           let stringContext = scanResult.stringContext,
           case .openOrCloseAppIdentifier = stringContext.kind
        {
            let contentStart = max(0, min(stringContext.contentStartUTF16, clampedCursor))
            let stringReplacementRange = NSRange(
                location: contentStart,
                length: max(0, clampedCursor - contentStart))
            guard NSMaxRange(stringReplacementRange) <= text.utf16.count else {
                return nil
            }
            let stringPrefix = (text as NSString).substring(with: stringReplacementRange)
            return OXAAutocompleteQuery(
                prefix: stringPrefix,
                replacementRange: stringReplacementRange,
                keywordCandidates: [],
                expectsReference: false,
                referenceIntent: .none,
                expectsAppIdentifier: true,
                shouldPadWithLeadingSpace: false)
        }

        if scanResult.inStringLiteral {
            return nil
        }

        let prefix = (text as NSString).substring(with: replacementRange)
        let keywordCandidates = self.candidates(for: scanResult.tokens, queryPrefix: prefix)
        let expectsReference = self.isReferenceContext(for: scanResult.tokens)
        let referenceIntent = self.referenceIntent(for: scanResult.tokens)
        guard expectsReference || !keywordCandidates.isEmpty else {
            return nil
        }

        return OXAAutocompleteQuery(
            prefix: prefix,
            replacementRange: replacementRange,
            keywordCandidates: keywordCandidates,
            expectsReference: expectsReference,
            referenceIntent: referenceIntent,
            expectsAppIdentifier: false,
            shouldPadWithLeadingSpace: true)
    }

    func suggestions(
        for query: OXAAutocompleteQuery,
        force: Bool,
        limit: Int,
        referenceRows: [QueryResultRow],
        appBundleIdentifiers: [String]) -> [OXAAutocompleteSuggestion]
    {
        if query.expectsReference {
            let referenceSuggestions = self.referenceSuggestions(
                queryPrefix: query.prefix,
                referenceRows: referenceRows,
                intent: query.referenceIntent,
                limit: limit)
            if !referenceSuggestions.isEmpty {
                return referenceSuggestions
            }

            if !force {
                return []
            }
        }

        if query.expectsAppIdentifier {
            let appSuggestions = self.appIdentifierSuggestions(
                queryPrefix: query.prefix,
                appBundleIdentifiers: appBundleIdentifiers,
                limit: limit)
            if !appSuggestions.isEmpty {
                return appSuggestions.map { suggestion in
                    OXAAutocompleteSuggestion(insertionText: suggestion, kind: .keyword)
                }
            }
            return []
        }

        let prefix = query.prefix.lowercased()
        let filtered: [String]
        if prefix.isEmpty {
            filtered = query.keywordCandidates
        } else {
            filtered = query.keywordCandidates.filter { $0.lowercased().hasPrefix(prefix) }
        }

        var seen = Set<String>()
        var deduped: [OXAAutocompleteSuggestion] = []
        deduped.reserveCapacity(filtered.count)
        for suggestion in filtered {
            if seen.insert(suggestion).inserted {
                deduped.append(OXAAutocompleteSuggestion(insertionText: suggestion, kind: .keyword))
            }
            if deduped.count == limit {
                break
            }
        }
        return deduped
    }

    private func candidates(for tokens: [OXAAutocompleteToken], queryPrefix: String) -> [String] {
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
                    statementTokens: statementTokens,
                    queryPrefix: queryPrefix)
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
        statementTokens: [OXAAutocompleteToken],
        queryPrefix: String) -> [String]
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
                statementTokens: statementTokens,
                queryPrefix: queryPrefix)
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
        statementTokens: [OXAAutocompleteToken],
        queryPrefix: String) -> [String]
    {
        guard components.count >= 1 else {
            return []
        }

        let hotkeyTokens = self.hotkeyTokens(from: statementTokens, queryPrefix: queryPrefix)
        guard !hotkeyTokens.hasToTarget else {
            return []
        }

        if hotkeyTokens.hasBaseKey {
            return hotkeyTokens.trailingPlus ? [] : ["to"]
        }

        if hotkeyTokens.trailingPlus {
            return self.availableHotkeyParts(usedModifiers: hotkeyTokens.usedModifiers)
        }

        if hotkeyTokens.hasAnyToken {
            return ["+"]
        }

        return self.availableHotkeyParts(usedModifiers: [])
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

    private func availableHotkeyParts(usedModifiers: [String]) -> [String] {
        let usedModifierSet = Set(usedModifiers.map { $0.lowercased() })
        let remainingModifiers = Self.hotkeyModifiers.filter { !usedModifierSet.contains($0) }
        return remainingModifiers + self.hotkeyBaseKeys()
    }

    private func hotkeyBaseKeys() -> [String] {
        var keys: [String] = Self.hotkeyNamedBaseKeys
        keys.reserveCapacity(Self.hotkeyNamedBaseKeys.count + 26 + 10 + 24)

        for scalar in UnicodeScalar("a").value...UnicodeScalar("z").value {
            if let unicode = UnicodeScalar(scalar) {
                keys.append(String(unicode))
            }
        }
        for digit in 0...9 {
            keys.append(String(digit))
        }
        for number in 1...24 {
            keys.append("f\(number)")
        }
        return keys
    }

    private func hotkeyTokens(
        from statementTokens: [OXAAutocompleteToken],
        queryPrefix: String) -> OXAHotkeyTokenState
    {
        var analyzedTokens = statementTokens
        let normalizedPrefix = self.normalizeHotkeyToken(queryPrefix)
        if !normalizedPrefix.isEmpty,
           case let .word(rawLastWord) = analyzedTokens.last?.kind
        {
            let normalizedLastWord = self.normalizeHotkeyToken(rawLastWord)
            if normalizedLastWord == normalizedPrefix,
               !self.isRecognizedHotkeyToken(normalizedLastWord)
            {
                analyzedTokens.removeLast()
            }
        }

        let statementWords = analyzedTokens.compactMap { token -> String? in
            guard case let .word(value) = token.kind else {
                return nil
            }
            return value.lowercased()
        }

        guard statementWords.count >= 2,
              statementWords[0] == "send",
              statementWords[1] == "hotkey"
        else {
            return OXAHotkeyTokenState()
        }

        var usedModifiers: [String] = []
        var hasBaseKey = false
        var hasAnyToken = false
        var trailingPlus = false
        var hasToTarget = false

        var seenHotkeyKeyword = false
        for token in analyzedTokens {
            switch token.kind {
            case let .word(rawValue):
                let value = self.normalizeHotkeyToken(rawValue)
                if !seenHotkeyKeyword {
                    if value == "hotkey" {
                        seenHotkeyKeyword = true
                    }
                    trailingPlus = false
                    continue
                }

                if value == "to" {
                    hasToTarget = true
                    trailingPlus = false
                    continue
                }
                if hasToTarget {
                    trailingPlus = false
                    continue
                }

                hasAnyToken = true
                if Self.hotkeyModifiers.contains(value) {
                    usedModifiers.append(value)
                } else {
                    hasBaseKey = true
                }
                trailingPlus = false

            case .plus:
                if seenHotkeyKeyword, !hasToTarget {
                    trailingPlus = true
                }

            default:
                trailingPlus = false
            }
        }

        return OXAHotkeyTokenState(
            usedModifiers: Array(Set(usedModifiers)).sorted(),
            hasBaseKey: hasBaseKey,
            hasAnyToken: hasAnyToken,
            trailingPlus: trailingPlus,
            hasToTarget: hasToTarget)
    }

    private func normalizeHotkeyToken(_ token: String) -> String {
        let lowered = token
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")

        let aliases: [String: String] = [
            "command": "cmd",
            "control": "ctrl",
            "option": "alt",
            "opt": "alt",
            "return": "enter",
            "esc": "escape",
            "pageup": "page_up",
            "pagedown": "page_down",
            "arrowup": "up",
            "arrowdown": "down",
            "arrowleft": "left",
            "arrowright": "right",
        ]
        return aliases[lowered] ?? lowered
    }

    private func isRecognizedHotkeyToken(_ token: String) -> Bool {
        if Self.hotkeyModifiers.contains(token) {
            return true
        }
        if self.hotkeyBaseKeys().contains(token) {
            return true
        }
        if token == "send" || token == "hotkey" || token == "to" {
            return true
        }
        return false
    }

    private func isReferenceContext(for tokens: [OXAAutocompleteToken]) -> Bool {
        self.referenceIntent(for: tokens) != .none
    }

    private func referenceIntent(for tokens: [OXAAutocompleteToken]) -> OXAReferenceIntent {
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

        guard let firstWord = self.word(at: 0, in: components) else {
            return .none
        }

        switch firstWord {
        case "read":
            return self.isReadReferenceContext(components) ? .readSource : .none
        case "send":
            return self.sendReferenceIntent(components)
        default:
            return .none
        }
    }

    private func isReadReferenceContext(_ components: [OXAAutocompleteComponent]) -> Bool {
        guard components.count >= 3 else { return false }
        return self.word(at: 2, in: components) == "from"
    }

    private func sendReferenceIntent(_ components: [OXAAutocompleteComponent]) -> OXAReferenceIntent {
        let sendComponents = Array(components.dropFirst())
        guard let action = self.word(at: 0, in: sendComponents) else {
            return .none
        }

        switch action {
        case "text":
            let isDirectTextTarget = sendComponents.count >= 3
                && sendComponents[1] == .string
                && self.word(at: 2, in: sendComponents) == "to"
            let isKeysTextTarget = sendComponents.count >= 5
                && sendComponents[1] == .string
                && self.word(at: 2, in: sendComponents) == "as"
                && self.word(at: 3, in: sendComponents) == "keys"
                && self.word(at: 4, in: sendComponents) == "to"
            return (isDirectTextTarget || isKeysTextTarget) ? .textTarget : .none

        case "click":
            return (sendComponents.count >= 2 && self.word(at: 1, in: sendComponents) == "to") ? .clickTarget : .none

        case "right":
            return (sendComponents.count >= 3
                && self.word(at: 1, in: sendComponents) == "click"
                && self.word(at: 2, in: sendComponents) == "to") ? .clickTarget : .none

        case "drag":
            if sendComponents.count == 1 {
                return .dragSource
            }
            return (sendComponents.count >= 3 && self.word(at: 2, in: sendComponents) == "to") ? .dragTarget : .none

        case "hotkey":
            guard let toIndex = sendComponents.lastIndex(where: { component in
                if case .word("to") = component { return true }
                return false
            }) else {
                return .none
            }
            return toIndex == sendComponents.count - 1 ? .hotkeyTarget : .none

        case "scroll":
            if sendComponents.count >= 2 && self.word(at: 1, in: sendComponents) == "to" {
                return .scrollTarget
            }
            return (sendComponents.count >= 3 && self.word(at: 2, in: sendComponents) == "to") ? .scrollTarget : .none

        default:
            return .none
        }
    }

    private func referenceSuggestions(
        queryPrefix: String,
        referenceRows: [QueryResultRow],
        intent: OXAReferenceIntent,
        limit: Int) -> [OXAAutocompleteSuggestion]
    {
        let trimmedPrefix = queryPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
        let rowsWithReferences: [(row: QueryResultRow, reference: String, cpName: String, role: String)] = referenceRows.compactMap { row in
            guard let reference = row.reference?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !reference.isEmpty
            else {
                return nil
            }

            let cpNameCandidate = row.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let cpName = cpNameCandidate.isEmpty ? row.resultsDisplayName : cpNameCandidate
            return (row: row, reference: reference, cpName: cpName, role: row.role)
        }

        guard !rowsWithReferences.isEmpty else {
            return []
        }

        if trimmedPrefix.isEmpty {
            return rowsWithReferences
                .sorted { lhs, rhs in
                    let lhsFit = self.referenceFitScore(for: lhs.role, intent: intent)
                    let rhsFit = self.referenceFitScore(for: rhs.role, intent: intent)
                    if lhsFit != rhsFit {
                        return lhsFit > rhsFit
                    }
                    return lhs.row.index < rhs.row.index
                }
                .prefix(limit)
                .map { candidate in
                    let payload = OXAReferenceAutocompletePayload(
                        reference: candidate.reference,
                        cpName: candidate.cpName,
                        role: candidate.role,
                        matchField: .reference,
                        cpNameMatchRange: nil)
                    return OXAAutocompleteSuggestion(
                        insertionText: candidate.reference,
                        kind: .reference(payload))
                }
        }

        var ranked: [OXAReferenceSearchCandidate] = []
        ranked.reserveCapacity(rowsWithReferences.count)

        for candidate in rowsWithReferences {
            let fieldMatches: [OXAReferenceFieldMatch] = [
                self.matchField(candidate.reference, prefix: trimmedPrefix, field: .reference),
                self.matchField(candidate.cpName, prefix: trimmedPrefix, field: .cpName),
                self.matchField(candidate.role, prefix: trimmedPrefix, field: .role),
            ].compactMap { $0 }

            guard let bestMatch = fieldMatches.min(by: { lhs, rhs in
                if lhs.ranking != rhs.ranking {
                    return lhs.ranking < rhs.ranking
                }
                return lhs.field.rawValue < rhs.field.rawValue
            }) else {
                continue
            }

            let payload = OXAReferenceAutocompletePayload(
                reference: candidate.reference,
                cpName: candidate.cpName,
                role: candidate.role,
                matchField: bestMatch.field,
                cpNameMatchRange: bestMatch.field == .cpName ? bestMatch.matchRange : nil)
            ranked.append(OXAReferenceSearchCandidate(
                insertionText: candidate.reference,
                payload: payload,
                ranking: bestMatch.ranking,
                rowOrder: candidate.row.index,
                fitScore: self.referenceFitScore(for: candidate.role, intent: intent)))
        }

        ranked.sort { lhs, rhs in
            if lhs.fitScore != rhs.fitScore {
                return lhs.fitScore > rhs.fitScore
            }
            if lhs.ranking != rhs.ranking {
                return lhs.ranking < rhs.ranking
            }
            if lhs.rowOrder != rhs.rowOrder {
                return lhs.rowOrder < rhs.rowOrder
            }
            return lhs.payload.reference < rhs.payload.reference
        }

        return ranked.prefix(limit).map { candidate in
            OXAAutocompleteSuggestion(
                insertionText: candidate.insertionText,
                kind: .reference(candidate.payload))
        }
    }

    private func matchField(_ fieldText: String, prefix: String, field: OXAReferenceMatchField) -> OXAReferenceFieldMatch? {
        guard !prefix.isEmpty else { return nil }
        let normalizedField = fieldText.lowercased()
        let normalizedPrefix = prefix.lowercased()

        let normalizedNSString = normalizedField as NSString
        let contiguousRange = normalizedNSString.range(of: normalizedPrefix)
        if contiguousRange.location != NSNotFound {
            return OXAReferenceFieldMatch(
                field: field,
                startIndex: contiguousRange.location,
                spanLength: contiguousRange.length,
                matchRange: contiguousRange)
        }

        let fieldUnits = Array(normalizedField.utf16)
        let prefixUnits = Array(normalizedPrefix.utf16)
        guard !prefixUnits.isEmpty else { return nil }

        var prefixCursor = 0
        var startIndex: Int?
        var endIndex: Int?

        for (index, unit) in fieldUnits.enumerated() {
            guard unit == prefixUnits[prefixCursor] else {
                continue
            }

            if startIndex == nil {
                startIndex = index
            }
            endIndex = index
            prefixCursor += 1
            if prefixCursor == prefixUnits.count {
                break
            }
        }

        guard prefixCursor == prefixUnits.count, let startIndex, let endIndex else {
            return nil
        }

        return OXAReferenceFieldMatch(
            field: field,
            startIndex: startIndex,
            spanLength: max(1, endIndex - startIndex + 1),
            matchRange: NSRange(location: startIndex, length: max(1, endIndex - startIndex + 1)))
    }

    private func referenceFitScore(for role: String, intent: OXAReferenceIntent) -> Int {
        let normalizedRole = role.lowercased()
        switch intent {
        case .none, .readSource:
            return 0
        case .textTarget:
            if normalizedRole == AXRoleNames.kAXTextFieldRole.lowercased() { return 500 }
            if normalizedRole == AXRoleNames.kAXTextAreaRole.lowercased() { return 480 }
            if normalizedRole == AXRoleNames.kAXSearchFieldRole.lowercased() { return 460 }
            if normalizedRole == AXRoleNames.kAXComboBoxRole.lowercased() { return 420 }
            if normalizedRole == AXRoleNames.kAXWebAreaRole.lowercased() { return 250 }
            return 40

        case .clickTarget:
            if normalizedRole == AXRoleNames.kAXButtonRole.lowercased() { return 460 }
            if normalizedRole == AXRoleNames.kAXLinkRole.lowercased() { return 440 }
            if normalizedRole == AXRoleNames.kAXMenuItemRole.lowercased() { return 420 }
            if normalizedRole == AXRoleNames.kAXCheckBoxRole.lowercased() { return 400 }
            if normalizedRole == AXRoleNames.kAXRadioButtonRole.lowercased() { return 390 }
            if normalizedRole == AXRoleNames.kAXPopUpButtonRole.lowercased() { return 360 }
            return 60

        case .dragSource:
            if normalizedRole == AXRoleNames.kAXScrollBarRole.lowercased() { return 360 }
            if normalizedRole == AXRoleNames.kAXSliderRole.lowercased() { return 340 }
            if normalizedRole == AXRoleNames.kAXColumnRole.lowercased() || normalizedRole == AXRoleNames.kAXRowRole.lowercased() {
                return 300
            }
            return 100

        case .dragTarget:
            if normalizedRole == AXRoleNames.kAXScrollAreaRole.lowercased() { return 420 }
            if normalizedRole == AXRoleNames.kAXGroupRole.lowercased() { return 380 }
            if normalizedRole == AXRoleNames.kAXWindowRole.lowercased() { return 360 }
            if normalizedRole == AXRoleNames.kAXWebAreaRole.lowercased() { return 340 }
            return 120

        case .hotkeyTarget:
            if normalizedRole == AXRoleNames.kAXTextFieldRole.lowercased() { return 380 }
            if normalizedRole == AXRoleNames.kAXTextAreaRole.lowercased() { return 360 }
            if normalizedRole == AXRoleNames.kAXSearchFieldRole.lowercased() { return 340 }
            return 140

        case .scrollTarget:
            if normalizedRole == AXRoleNames.kAXScrollAreaRole.lowercased() { return 500 }
            if normalizedRole == AXRoleNames.kAXWebAreaRole.lowercased() { return 470 }
            if normalizedRole == AXRoleNames.kAXListRole.lowercased() { return 430 }
            if normalizedRole == AXRoleNames.kAXTableRole.lowercased() { return 410 }
            if normalizedRole == AXRoleNames.kAXOutlineRole.lowercased() { return 390 }
            return 80
        }
    }

    private func appIdentifierSuggestions(
        queryPrefix: String,
        appBundleIdentifiers: [String],
        limit: Int) -> [String]
    {
        let trimmedPrefix = queryPrefix.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !appBundleIdentifiers.isEmpty else {
            return []
        }

        var seen = Set<String>()
        var startsWithMatches: [String] = []
        var containsMatches: [String] = []

        for identifier in appBundleIdentifiers {
            let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                continue
            }

            let normalized = trimmed.lowercased()
            guard seen.insert(normalized).inserted else {
                continue
            }

            if trimmedPrefix.isEmpty {
                startsWithMatches.append(trimmed)
                continue
            }

            if normalized.hasPrefix(trimmedPrefix) {
                startsWithMatches.append(trimmed)
            } else if normalized.contains(trimmedPrefix) {
                containsMatches.append(trimmed)
            }
        }

        return Array((startsWithMatches + containsMatches).prefix(limit))
    }

    private func word(at index: Int, in components: [OXAAutocompleteComponent]) -> String? {
        guard index >= 0, index < components.count else {
            return nil
        }
        guard case let .word(value) = components[index] else {
            return nil
        }
        return value
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
                let statementTokensBeforeString = self.statementTokens(from: tokens)
                let statementComponents = statementTokensBeforeString.compactMap { token -> OXAAutocompleteComponent? in
                    switch token.kind {
                    case let .word(value):
                        return .word(value.lowercased())
                    case .string:
                        return .string
                    default:
                        return nil
                    }
                }

                let stringContextKind: OXAAutocompleteStringContext.Kind?
                if self.isOpenCloseStringContext(statementComponents) {
                    stringContextKind = .openOrCloseAppIdentifier
                } else {
                    stringContextKind = nil
                }

                index = text.index(after: index)
                let contentStartUTF16 = text.utf16.distance(
                    from: text.utf16.startIndex,
                    to: index.samePosition(in: text.utf16) ?? text.utf16.endIndex)
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
                    let stringContext = stringContextKind.map {
                        OXAAutocompleteStringContext(kind: $0, contentStartUTF16: contentStartUTF16)
                    }
                    return OXAAutocompleteScanResult(
                        tokens: tokens,
                        inStringLiteral: true,
                        stringContext: stringContext)
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

        return OXAAutocompleteScanResult(tokens: tokens, inStringLiteral: false, stringContext: nil)
    }

    private func isOpenCloseStringContext(_ components: [OXAAutocompleteComponent]) -> Bool {
        guard let first = self.word(at: 0, in: components) else {
            return false
        }
        guard first == "open" || first == "close" else {
            return false
        }
        return components.count == 1
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
