import AXorcist
import AppKit
import SwiftUI

struct OXQHighlightedEditor: NSViewRepresentable {
    @Binding var text: String

    var fontSize: CGFloat = 16
    var focusRequestID: UInt64 = 0
    var onRunQuery: (() -> Void)?
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
        var parent: OXQHighlightedEditor
        weak var textView: NSTextView?
        var lastFocusRequestID: UInt64 = 0
        private var isApplying = false
        private var lastEditInsertedRoleTrigger = false
        private var lastEditWasDeletion = false
        private var pendingAutocompleteRefresh = false
        private var pendingAutocompleteForce = false
        private var suppressNextAutocompleteRefresh = false
        private var autocompleteSuppressedUntilInsertion = false
        private var activeAutocompleteQuery: OXQAutocompleteQuery?
        private var currentSuggestions: [String] = []
        private var selectedSuggestionIndex = 0
        private let autocomplete = OXQAutocompleteEngine()
        private let suggestionPopoverController = OXQSuggestionPopoverController()

        init(parent: OXQHighlightedEditor) {
            self.parent = parent
            super.init()
            self.suggestionPopoverController.onSelect = { [weak self] selectedIndex in
                self?.acceptSuggestion(at: selectedIndex)
            }
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            guard !isApplying else { return }
            let latest = textView.string
            if parent.text != latest {
                parent.text = latest
            }
            applyHighlight(to: latest, preserveSelection: true)
            if self.suppressNextAutocompleteRefresh {
                self.suppressNextAutocompleteRefresh = false
                self.dismissSuggestionPopover()
                return
            }
            scheduleAutocompleteRefresh()
        }

        func textDidEndEditing(_ notification: Notification) {
            self.dismissSuggestionPopover()
        }

        func textView(
            _ textView: NSTextView,
            shouldChangeTextIn affectedCharRange: NSRange,
            replacementString: String?) -> Bool
        {
            defer {
                if let replacementString {
                    let isDeletion = replacementString.isEmpty && affectedCharRange.length > 0
                    self.lastEditWasDeletion = isDeletion
                    if isDeletion {
                        self.autocompleteSuppressedUntilInsertion = true
                    } else if !replacementString.isEmpty {
                        self.autocompleteSuppressedUntilInsertion = false
                    }
                } else {
                    self.lastEditWasDeletion = false
                }
                if let replacementString, replacementString.count == 1, let char = replacementString.first {
                    self.lastEditInsertedRoleTrigger = char == ">" || char == "," || char == "(" || char == ":"
                } else {
                    self.lastEditInsertedRoleTrigger = false
                }
            }

            return true
        }

        func textView(
            _ textView: NSTextView,
            doCommandBy commandSelector: Selector) -> Bool
        {
            if self.isCommandModeToggle() {
                self.dismissSuggestionPopover()
                self.parent.onToggleMode?()
                return true
            }

            if self.isCommandEnter(commandSelector) {
                self.dismissSuggestionPopover()
                self.parent.onRunQuery?()
                return true
            }

            if commandSelector == #selector(NSResponder.complete(_:)) {
                self.scheduleAutocompleteRefresh(force: true)
                return true
            }

            guard !self.currentSuggestions.isEmpty else { return false }

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
                return false
            }
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

        func applyHighlight(to content: String, preserveSelection: Bool) {
            guard let textView else { return }
            guard !isApplying else { return }

            let selectedRanges = textView.selectedRanges
            let font = NSFont.monospacedSystemFont(ofSize: parent.fontSize, weight: .regular)
            let highlighted = OXQColorTheme.highlightedQuery(content, font: font)

            isApplying = true
            textView.textStorage?.setAttributedString(highlighted)
            if preserveSelection {
                textView.selectedRanges = selectedRanges
            }
            isApplying = false
        }

        func refreshAutocomplete(force: Bool = false) {
            guard let textView else { return }
            guard !isApplying else { return }
            guard textView.window?.firstResponder === textView else {
                self.dismissSuggestionPopover()
                return
            }

            let selected = textView.selectedRange()
            guard selected.length == 0 else {
                self.dismissSuggestionPopover()
                return
            }

            if !force, self.autocompleteSuppressedUntilInsertion {
                self.dismissSuggestionPopover()
                return
            }

            guard let query = autocomplete.makeQuery(
                text: textView.string,
                cursorUTF16: selected.location,
                allowEmptyRolePrefix: self.lastEditInsertedRoleTrigger || force)
            else {
                self.dismissSuggestionPopover()
                return
            }

            let suggestions = autocomplete.suggestions(for: query, limit: OXQAutocompleteEngine.maxVisibleSuggestions)
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
            guard
                let textView,
                let query = self.activeAutocompleteQuery,
                self.currentSuggestions.indices.contains(index)
            else {
                return
            }

            let suggestion = self.currentSuggestions[index]
            let replacementRange = query.replacementRange
            guard NSMaxRange(replacementRange) <= textView.string.utf16.count else { return }

            self.suppressNextAutocompleteRefresh = true
            textView.textStorage?.replaceCharacters(in: replacementRange, with: suggestion)
            let cursor = replacementRange.location + (suggestion as NSString).length
            textView.setSelectedRange(NSRange(location: cursor, length: 0))
            textView.didChangeText()

            self.lastEditInsertedRoleTrigger = false
            self.lastEditWasDeletion = false
            self.autocompleteSuppressedUntilInsertion = false
            self.dismissSuggestionPopover()
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
            let domain = self.activeAutocompleteQuery?.domain ?? .role
            self.suggestionPopoverController.update(
                suggestions: self.currentSuggestions,
                selectedIndex: self.selectedSuggestionIndex,
                fontSize: self.parent.fontSize,
                domain: domain)
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
private final class OXQSuggestionPopoverController {
    var onSelect: ((Int) -> Void)?

    private let popover: NSPopover
    private let hostingController: NSHostingController<OXQSuggestionPopoverView>
    private var suggestions: [String] = []
    private var selectedIndex = 0
    private var domain: OXQCompletionDomain = .role
    private weak var anchorView: NSView?

    init() {
        self.popover = NSPopover()
        self.popover.behavior = .semitransient
        self.popover.animates = false

        self.hostingController = NSHostingController(
            rootView: OXQSuggestionPopoverView(
                suggestions: [],
                selectedIndex: 0,
                fontSize: 14,
                domain: .role,
                onSelect: { _ in }))
        self.popover.contentViewController = self.hostingController
    }

    func update(suggestions: [String], selectedIndex: Int, fontSize: CGFloat, domain: OXQCompletionDomain) {
        self.suggestions = suggestions
        self.selectedIndex = max(0, min(selectedIndex, max(0, suggestions.count - 1)))
        self.domain = domain
        self.hostingController.rootView = OXQSuggestionPopoverView(
            suggestions: suggestions,
            selectedIndex: self.selectedIndex,
            fontSize: fontSize,
            domain: domain,
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

        let maxCharacters = suggestions.map(\.count).max() ?? 24
        let estimatedWidth = CGFloat(maxCharacters) * max(7.4, fontSize * 0.58) + 88
        let width = min(max(280, estimatedWidth), 560)

        return NSSize(width: width, height: min(contentHeight, 360))
    }
}

@MainActor
private struct OXQSuggestionPopoverView: View {
    let suggestions: [String]
    let selectedIndex: Int
    let fontSize: CGFloat
    let domain: OXQCompletionDomain
    let onSelect: (Int) -> Void

    private var domainLabel: String {
        switch domain {
        case .role:
            return "Roles"
        case .attribute:
            return "Attributes"
        case .function:
            return "Functions"
        }
    }

    private var tagLabel: String {
        switch domain {
        case .role:
            return "ROLE"
        case .attribute:
            return "ATTR"
        case .function:
            return "FUNC"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(domainLabel)
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
                                Text(tagLabel)
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

private enum OXQCompletionDomain {
    case role
    case attribute
    case function
}

private struct OXQAutocompleteQuery {
    let domain: OXQCompletionDomain
    let prefix: String
    let replacementRange: NSRange
    let previousRole: String?
    let hostRole: String?
    let previousAttribute: String?
}

private enum OXQRoleCategory {
    case text
    case actionable
    case container
    case list
    case menu
    case web
    case window
    case indicator
    case other
}

private struct OXQAutocompleteScanState {
    var inStringLiteral = false
    var attributeDepth = 0
    var expectingAttributeName = false
    var roleHistory: [String] = []
    var attributeRoleStack: [String?] = []
    var attributeHistoryStack: [[String]] = []
}

@MainActor
private struct OXQAutocompleteEngine {
    static let maxVisibleSuggestions = 16

    func makeQuery(
        text: String,
        cursorUTF16: Int,
        allowEmptyRolePrefix: Bool,
        partialWordRange: NSRange? = nil) -> OXQAutocompleteQuery?
    {
        let clampedCursor = max(0, min(cursorUTF16, text.utf16.count))

        let prefixRange = self.resolvePrefixRange(
            in: text,
            cursorUTF16: clampedCursor,
            partialWordRange: partialWordRange)
        let prefix = (text as NSString).substring(with: prefixRange)
        let prefixStartIndex = String.Index(utf16Offset: prefixRange.location, in: text)
        let scanState = self.scanContext(in: text, upTo: prefixStartIndex)
        if scanState.inStringLiteral {
            return nil
        }

        let grammarExpectation = self.grammarExpectation(
            in: text,
            cursorUTF16: prefixRange.location)

        switch grammarExpectation {
        case .attribute:

            var previousAttribute = scanState.attributeHistoryStack.last?.last
            if !prefix.isEmpty,
               let prior = previousAttribute,
               prior.caseInsensitiveCompare(prefix) == .orderedSame,
               let history = scanState.attributeHistoryStack.last
            {
                previousAttribute = history.count >= 2 ? history[history.count - 2] : nil
            }

            return OXQAutocompleteQuery(
                domain: .attribute,
                prefix: prefix,
                replacementRange: prefixRange,
                previousRole: scanState.roleHistory.last,
                hostRole: scanState.attributeRoleStack.last ?? scanState.roleHistory.last,
                previousAttribute: previousAttribute)

        case .role:
            let previousBeforePrefix = self.previousNonWhitespaceCharacter(in: text, before: prefixStartIndex)
            let hasRolePrefix = !prefix.isEmpty && previousBeforePrefix != ":"
            let shouldSuggestEmptyRole = prefix.isEmpty && allowEmptyRolePrefix

            guard hasRolePrefix || shouldSuggestEmptyRole else {
                return nil
            }

            var previousRole = scanState.roleHistory.last
            if !prefix.isEmpty,
               let prior = previousRole,
               prior.caseInsensitiveCompare(prefix) == .orderedSame
            {
                previousRole = scanState.roleHistory.count >= 2 ? scanState.roleHistory[scanState.roleHistory.count - 2] : nil
            }

            return OXQAutocompleteQuery(
                domain: .role,
                prefix: prefix,
                replacementRange: prefixRange,
                previousRole: previousRole,
                hostRole: nil,
                previousAttribute: nil)

        case .function:
            guard !prefix.isEmpty || allowEmptyRolePrefix else {
                return nil
            }
            return OXQAutocompleteQuery(
                domain: .function,
                prefix: prefix,
                replacementRange: prefixRange,
                previousRole: nil,
                hostRole: nil,
                previousAttribute: nil)

        case .none:
            return nil
        }
    }

    func suggestions(for query: OXQAutocompleteQuery, limit: Int) -> [String] {
        switch query.domain {
        case .role:
            return self.rankRoleSuggestions(
                prefix: query.prefix,
                previousRole: query.previousRole,
                limit: limit)
        case .attribute:
            return self.rankAttributeSuggestions(
                prefix: query.prefix,
                hostRole: query.hostRole,
                previousAttribute: query.previousAttribute,
                limit: limit)
        case .function:
            return self.rankFunctionSuggestions(prefix: query.prefix, limit: limit)
        }
    }

    private static let roleTokens: [String] = [
        AXRoleNames.kAXApplicationRole,
        AXRoleNames.kAXSystemWideRole,
        AXRoleNames.kAXWindowRole,
        AXRoleNames.kAXSheetRole,
        AXRoleNames.kAXDrawerRole,
        AXRoleNames.kAXDialogRole,
        AXRoleNames.kAXGroupRole,
        AXRoleNames.kAXScrollAreaRole,
        AXRoleNames.kAXSplitGroupRole,
        AXRoleNames.kAXSplitterRole,
        AXRoleNames.kAXToolbarRole,
        AXRoleNames.kAXLayoutAreaRole,
        AXRoleNames.kAXLayoutItemRole,
        AXRoleNames.kAXButtonRole,
        AXRoleNames.kAXRadioButtonRole,
        AXRoleNames.kAXCheckBoxRole,
        AXRoleNames.kAXPopUpButtonRole,
        AXRoleNames.kAXMenuButtonRole,
        AXRoleNames.kAXSliderRole,
        AXRoleNames.kAXIncrementorRole,
        AXRoleNames.kAXScrollBarRole,
        AXRoleNames.kAXDisclosureTriangleRole,
        AXRoleNames.kAXComboBoxRole,
        AXRoleNames.kAXTextFieldRole,
        AXRoleNames.kAXColorWellRole,
        AXRoleNames.kAXSearchFieldRole,
        AXRoleNames.kAXSwitchRole,
        AXRoleNames.kAXStaticTextRole,
        AXRoleNames.kAXTextAreaRole,
        AXRoleNames.kAXMenuBarRole,
        AXRoleNames.kAXMenuBarItemRole,
        AXRoleNames.kAXMenuRole,
        AXRoleNames.kAXMenuItemRole,
        AXRoleNames.kAXListRole,
        AXRoleNames.kAXTableRole,
        AXRoleNames.kAXOutlineRole,
        AXRoleNames.kAXColumnRole,
        AXRoleNames.kAXRowRole,
        AXRoleNames.kAXCellRole,
        AXRoleNames.kAXValueIndicatorRole,
        AXRoleNames.kAXBusyIndicatorRole,
        AXRoleNames.kAXProgressIndicatorRole,
        AXRoleNames.kAXRelevanceIndicatorRole,
        AXRoleNames.kAXLevelIndicatorRole,
        AXRoleNames.kAXImageRole,
        AXRoleNames.kAXWebAreaRole,
        AXRoleNames.kAXLinkRole,
        AXRoleNames.kAXHelpTagRole,
        AXRoleNames.kAXMatteRole,
        AXRoleNames.kAXRulerRole,
        AXRoleNames.kAXRulerMarkerRole,
        AXRoleNames.kAXGridRole,
        AXRoleNames.kAXGrowAreaRole,
        AXRoleNames.kAXHandleRole,
        AXRoleNames.kAXPopoverRole,
    ]

    private static let attributeTokens: [String] = [
        AXAttributeNames.kAXPIDAttribute,
        AXAttributeNames.kAXRoleAttribute,
        AXAttributeNames.kAXSubroleAttribute,
        AXAttributeNames.kAXRoleDescriptionAttribute,
        AXAttributeNames.kAXTitleAttribute,
        AXAttributeNames.kAXValueAttribute,
        AXAttributeNames.kAXValueDescriptionAttribute,
        AXAttributeNames.kAXDescriptionAttribute,
        AXAttributeNames.kAXHelpAttribute,
        AXAttributeNames.kAXIdentifierAttribute,
        AXAttributeNames.kAXDOMClassListAttribute,
        AXAttributeNames.kAXDOMIdentifierAttribute,
        AXAttributeNames.kAXEnabledAttribute,
        AXAttributeNames.kAXFocusedAttribute,
        AXAttributeNames.kAXElementBusyAttribute,
        AXAttributeNames.kAXHiddenAttribute,
        AXAttributeNames.kAXParentAttribute,
        AXAttributeNames.kAXChildrenAttribute,
        AXAttributeNames.kAXSelectedChildrenAttribute,
        AXAttributeNames.kAXVisibleChildrenAttribute,
        AXAttributeNames.kAXWindowAttribute,
        AXAttributeNames.kAXMainWindowAttribute,
        AXAttributeNames.kAXFocusedWindowAttribute,
        AXAttributeNames.kAXFocusedUIElementAttribute,
        AXAttributeNames.kAXWindowsAttribute,
        AXAttributeNames.kAXSheetsAttribute,
        AXAttributeNames.kAXMenuBarAttribute,
        AXAttributeNames.kAXFrontmostAttribute,
        AXAttributeNames.kAXMainAttribute,
        AXAttributeNames.kAXMinimizedAttribute,
        AXAttributeNames.kAXFullScreenAttribute,
        AXAttributeNames.kAXCloseButtonAttribute,
        AXAttributeNames.kAXZoomButtonAttribute,
        AXAttributeNames.kAXMinimizeButtonAttribute,
        AXAttributeNames.kAXFullScreenButtonAttribute,
        AXAttributeNames.kAXDefaultButtonAttribute,
        AXAttributeNames.kAXCancelButtonAttribute,
        AXAttributeNames.kAXGrowAreaAttribute,
        AXAttributeNames.kAXModalAttribute,
        AXAttributeNames.kAXPositionAttribute,
        AXAttributeNames.kAXSizeAttribute,
        AXAttributeNames.kAXMinValueAttribute,
        AXAttributeNames.kAXMaxValueAttribute,
        AXAttributeNames.kAXValueIncrementAttribute,
        AXAttributeNames.kAXAllowedValuesAttribute,
        AXAttributeNames.kAXPlaceholderValueAttribute,
        AXAttributeNames.kAXSelectedTextAttribute,
        AXAttributeNames.kAXActionNamesAttribute,
        AXAttributeNames.kAXURLAttribute,
        AXAttributeNames.kAXDocumentAttribute,
        AXAttributeNames.kAXRowsAttribute,
        AXAttributeNames.kAXColumnsAttribute,
        AXAttributeNames.kAXSelectedRowsAttribute,
        AXAttributeNames.kAXSelectedColumnsAttribute,
        AXAttributeNames.kAXVisibleRowsAttribute,
        AXAttributeNames.kAXVisibleColumnsAttribute,
        AXAttributeNames.kAXHeaderAttribute,
        AXAttributeNames.kAXIndexAttribute,
        AXAttributeNames.kAXDisclosingAttribute,
        AXAttributeNames.kAXDisclosedRowsAttribute,
        AXAttributeNames.kAXDisclosureLevelAttribute,
        AXAttributeNames.kAXTabsAttribute,
        AXAttributeNames.kAXTitleUIElementAttribute,
        AXAttributeNames.kAXLinkedUIElementsAttribute,
        AXAttributeNames.kAXContentsAttribute,
        AXAttributeNames.kAXValueWrapsAttribute,
        AXMiscConstants.computedNameAttributeKey,
        "CPName",
        AXMiscConstants.isIgnoredAttributeKey,
        "role",
        "subrole",
        "title",
        "value",
        "id",
        "identifier",
        "description",
        "help",
        "placeholder",
        "enabled",
        "focused",
        "domid",
        "domclass",
    ]

    private static let functionTokens: [String] = [
        "has",
        "not",
    ]

    private static let roleCommonBoost: [String: Int] = [
        AXRoleNames.kAXButtonRole: 320,
        AXRoleNames.kAXTextFieldRole: 310,
        AXRoleNames.kAXTextAreaRole: 300,
        AXRoleNames.kAXStaticTextRole: 280,
        AXRoleNames.kAXGroupRole: 260,
        AXRoleNames.kAXLinkRole: 250,
        AXRoleNames.kAXWindowRole: 240,
        AXRoleNames.kAXComboBoxRole: 220,
        AXRoleNames.kAXImageRole: 210,
        AXRoleNames.kAXMenuItemRole: 190,
    ]

    private static let roleNeighborBoost: [String: [String: Int]] = [
        AXRoleNames.kAXTextFieldRole: [
            AXRoleNames.kAXTextAreaRole: 290,
            AXRoleNames.kAXComboBoxRole: 260,
            AXRoleNames.kAXSearchFieldRole: 240,
            AXRoleNames.kAXStaticTextRole: 210,
        ],
        AXRoleNames.kAXTextAreaRole: [
            AXRoleNames.kAXTextFieldRole: 270,
            AXRoleNames.kAXStaticTextRole: 220,
            AXRoleNames.kAXComboBoxRole: 200,
        ],
        AXRoleNames.kAXButtonRole: [
            AXRoleNames.kAXLinkRole: 260,
            AXRoleNames.kAXMenuItemRole: 220,
            AXRoleNames.kAXMenuButtonRole: 200,
            AXRoleNames.kAXPopUpButtonRole: 180,
        ],
        AXRoleNames.kAXLinkRole: [
            AXRoleNames.kAXButtonRole: 250,
            AXRoleNames.kAXStaticTextRole: 200,
            AXRoleNames.kAXImageRole: 170,
        ],
        AXRoleNames.kAXWindowRole: [
            AXRoleNames.kAXGroupRole: 260,
            AXRoleNames.kAXToolbarRole: 230,
            AXRoleNames.kAXScrollAreaRole: 220,
            AXRoleNames.kAXWebAreaRole: 200,
        ],
        AXRoleNames.kAXTableRole: [
            AXRoleNames.kAXRowRole: 290,
            AXRoleNames.kAXCellRole: 260,
            AXRoleNames.kAXColumnRole: 250,
            AXRoleNames.kAXOutlineRole: 170,
        ],
        AXRoleNames.kAXListRole: [
            AXRoleNames.kAXRowRole: 260,
            AXRoleNames.kAXCellRole: 210,
            AXRoleNames.kAXButtonRole: 140,
        ],
        AXRoleNames.kAXWebAreaRole: [
            AXRoleNames.kAXLinkRole: 290,
            AXRoleNames.kAXButtonRole: 230,
            AXRoleNames.kAXTextFieldRole: 220,
            AXRoleNames.kAXStaticTextRole: 210,
        ],
    ]

    private static let attributeCommonBoost: [String: Int] = [
        "CPName": 460,
        AXMiscConstants.computedNameAttributeKey: 430,
        AXAttributeNames.kAXDescriptionAttribute: 380,
        AXAttributeNames.kAXTitleAttribute: 360,
        AXAttributeNames.kAXValueAttribute: 350,
        AXAttributeNames.kAXIdentifierAttribute: 340,
        AXAttributeNames.kAXRoleAttribute: 320,
        AXAttributeNames.kAXSubroleAttribute: 260,
        AXAttributeNames.kAXEnabledAttribute: 250,
        AXAttributeNames.kAXFocusedAttribute: 240,
        AXAttributeNames.kAXPlaceholderValueAttribute: 220,
        AXAttributeNames.kAXSelectedTextAttribute: 210,
        AXAttributeNames.kAXHelpAttribute: 200,
        AXAttributeNames.kAXDOMIdentifierAttribute: 190,
        AXAttributeNames.kAXDOMClassListAttribute: 180,
    ]

    private static let attributeTransitionBoost: [String: [String: Int]] = [
        AXAttributeNames.kAXRoleAttribute: [
            AXAttributeNames.kAXSubroleAttribute: 240,
            AXAttributeNames.kAXRoleDescriptionAttribute: 190,
        ],
        AXAttributeNames.kAXSubroleAttribute: [
            AXAttributeNames.kAXRoleDescriptionAttribute: 180,
            AXAttributeNames.kAXTitleAttribute: 120,
        ],
        AXAttributeNames.kAXTitleAttribute: [
            AXAttributeNames.kAXIdentifierAttribute: 150,
            AXAttributeNames.kAXDescriptionAttribute: 130,
            "CPName": 130,
        ],
        AXAttributeNames.kAXValueAttribute: [
            AXAttributeNames.kAXSelectedTextAttribute: 160,
            AXAttributeNames.kAXPlaceholderValueAttribute: 140,
            AXAttributeNames.kAXEnabledAttribute: 120,
        ],
        AXAttributeNames.kAXEnabledAttribute: [
            AXAttributeNames.kAXFocusedAttribute: 120,
        ],
        AXAttributeNames.kAXPositionAttribute: [
            AXAttributeNames.kAXSizeAttribute: 140,
        ],
        AXAttributeNames.kAXRowsAttribute: [
            AXAttributeNames.kAXColumnsAttribute: 150,
            AXAttributeNames.kAXSelectedRowsAttribute: 130,
        ],
    ]

    private func rankRoleSuggestions(prefix: String, previousRole: String?, limit: Int) -> [String] {
        let lowerPrefix = prefix.lowercased()

        let scored = Self.roleTokens.compactMap { role -> (String, Int)? in
            guard let prefixScore = self.prefixMatchScore(token: role, lowerPrefix: lowerPrefix) else {
                return nil
            }

            var score = prefixScore
            score += Self.roleCommonBoost[role] ?? 0

            if let previousRole {
                score += Self.roleNeighborBoost[previousRole]?[role] ?? 0
                score += self.categoryTransitionScore(from: self.roleCategory(for: previousRole), to: self.roleCategory(for: role))
                if previousRole == role {
                    score -= 180
                }
            }

            return (role, score)
        }

        return self.sortedTokens(scored: scored, limit: limit)
    }

    private func rankAttributeSuggestions(prefix: String, hostRole: String?, previousAttribute: String?, limit: Int) -> [String] {
        let lowerPrefix = prefix.lowercased()

        let scored = Self.attributeTokens.compactMap { attribute -> (String, Int)? in
            guard let prefixScore = self.prefixMatchScore(token: attribute, lowerPrefix: lowerPrefix) else {
                return nil
            }

            var score = prefixScore
            score += Self.attributeCommonBoost[attribute] ?? 0

            if let hostRole {
                score += self.attributeBoost(for: attribute, hostRole: hostRole)
            }

            if let previousAttribute {
                score += Self.attributeTransitionBoost[previousAttribute]?[attribute] ?? 0
                if previousAttribute.caseInsensitiveCompare(attribute) == .orderedSame {
                    score -= 120
                }
            }

            let isCanonicalAXAttribute = attribute.hasPrefix("AX")
            if !isCanonicalAXAttribute,
               attribute != AXMiscConstants.computedNameAttributeKey,
               attribute != AXMiscConstants.isIgnoredAttributeKey,
               attribute != "CPName"
            {
                score -= 30
            }

            return (attribute, score)
        }

        return self.sortedTokens(scored: scored, limit: limit)
    }

    private func sortedTokens(scored: [(String, Int)], limit: Int) -> [String] {
        let ordered = scored.sorted {
            if $0.1 == $1.1 {
                return $0.0.localizedCaseInsensitiveCompare($1.0) == .orderedAscending
            }
            return $0.1 > $1.1
        }

        var seen = Set<String>()
        var output: [String] = []
        output.reserveCapacity(min(limit, ordered.count))

        for (token, _) in ordered {
            let key = token.lowercased()
            if seen.contains(key) {
                continue
            }
            seen.insert(key)
            output.append(token)
            if output.count >= limit {
                break
            }
        }

        return output
    }

    private func rankFunctionSuggestions(prefix: String, limit: Int) -> [String] {
        let lowerPrefix = prefix.lowercased()

        let scored = Self.functionTokens.compactMap { functionName -> (String, Int)? in
            guard let prefixScore = self.prefixMatchScore(token: functionName, lowerPrefix: lowerPrefix) else {
                return nil
            }
            return (functionName, prefixScore + 400)
        }

        return self.sortedTokens(scored: scored, limit: limit)
    }

    private func prefixMatchScore(token: String, lowerPrefix: String) -> Int? {
        if lowerPrefix.isEmpty {
            return 360
        }

        let tokenLower = token.lowercased()
        if tokenLower == lowerPrefix {
            return 1300
        }

        if tokenLower.hasPrefix(lowerPrefix) {
            let gap = max(0, tokenLower.count - lowerPrefix.count)
            return 1120 - min(gap * 4, 200)
        }

        if let range = tokenLower.range(of: lowerPrefix) {
            let distance = tokenLower.distance(from: tokenLower.startIndex, to: range.lowerBound)
            return 800 - min(distance * 18, 260)
        }

        return nil
    }

    private func categoryTransitionScore(from: OXQRoleCategory, to: OXQRoleCategory) -> Int {
        switch (from, to) {
        case (.text, .text):
            return 260
        case (.text, .actionable), (.text, .container):
            return 150

        case (.actionable, .actionable):
            return 230
        case (.actionable, .web), (.actionable, .menu):
            return 180
        case (.actionable, .text):
            return 130

        case (.container, .container):
            return 210
        case (.container, .actionable), (.container, .text), (.container, .web):
            return 140

        case (.list, .list):
            return 250
        case (.list, .actionable), (.list, .text):
            return 140

        case (.menu, .menu):
            return 250
        case (.menu, .actionable):
            return 180

        case (.web, .web):
            return 260
        case (.web, .actionable), (.web, .text):
            return 180
        case (.web, .container):
            return 120

        case (.window, .container):
            return 230
        case (.window, .actionable):
            return 160
        case (.window, .text), (.window, .web):
            return 130

        case (.indicator, .indicator):
            return 210
        case (.indicator, .actionable):
            return 100

        default:
            return 0
        }
    }

    private func roleCategory(for role: String) -> OXQRoleCategory {
        switch role {
        case AXRoleNames.kAXTextFieldRole,
             AXRoleNames.kAXTextAreaRole,
             AXRoleNames.kAXComboBoxRole,
             AXRoleNames.kAXSearchFieldRole,
             AXRoleNames.kAXStaticTextRole:
            return .text

        case AXRoleNames.kAXButtonRole,
             AXRoleNames.kAXRadioButtonRole,
             AXRoleNames.kAXCheckBoxRole,
             AXRoleNames.kAXPopUpButtonRole,
             AXRoleNames.kAXMenuButtonRole,
             AXRoleNames.kAXSliderRole,
             AXRoleNames.kAXSwitchRole,
             AXRoleNames.kAXDisclosureTriangleRole:
            return .actionable

        case AXRoleNames.kAXGroupRole,
             AXRoleNames.kAXScrollAreaRole,
             AXRoleNames.kAXSplitGroupRole,
             AXRoleNames.kAXSplitterRole,
             AXRoleNames.kAXToolbarRole,
             AXRoleNames.kAXLayoutAreaRole,
             AXRoleNames.kAXLayoutItemRole,
             AXRoleNames.kAXGridRole,
             AXRoleNames.kAXPopoverRole:
            return .container

        case AXRoleNames.kAXListRole,
             AXRoleNames.kAXTableRole,
             AXRoleNames.kAXOutlineRole,
             AXRoleNames.kAXColumnRole,
             AXRoleNames.kAXRowRole,
             AXRoleNames.kAXCellRole:
            return .list

        case AXRoleNames.kAXMenuRole,
             AXRoleNames.kAXMenuBarRole,
             AXRoleNames.kAXMenuBarItemRole,
             AXRoleNames.kAXMenuItemRole:
            return .menu

        case AXRoleNames.kAXWebAreaRole,
             AXRoleNames.kAXLinkRole,
             AXRoleNames.kAXImageRole:
            return .web

        case AXRoleNames.kAXApplicationRole,
             AXRoleNames.kAXWindowRole,
             AXRoleNames.kAXDialogRole,
             AXRoleNames.kAXSheetRole,
             AXRoleNames.kAXDrawerRole:
            return .window

        case AXRoleNames.kAXValueIndicatorRole,
             AXRoleNames.kAXBusyIndicatorRole,
             AXRoleNames.kAXProgressIndicatorRole,
             AXRoleNames.kAXRelevanceIndicatorRole,
             AXRoleNames.kAXLevelIndicatorRole:
            return .indicator

        default:
            return .other
        }
    }

    private func attributeBoost(for attribute: String, hostRole: String) -> Int {
        let category = self.roleCategory(for: hostRole)

        switch category {
        case .text:
            switch attribute {
            case AXAttributeNames.kAXValueAttribute:
                return 330
            case AXAttributeNames.kAXSelectedTextAttribute:
                return 320
            case AXAttributeNames.kAXPlaceholderValueAttribute:
                return 300
            case "CPName", AXMiscConstants.computedNameAttributeKey:
                return 280
            case AXAttributeNames.kAXTitleAttribute,
                 AXAttributeNames.kAXDescriptionAttribute,
                 AXAttributeNames.kAXIdentifierAttribute,
                 AXAttributeNames.kAXEnabledAttribute,
                 AXAttributeNames.kAXFocusedAttribute:
                return 220
            default:
                return 0
            }

        case .actionable:
            switch attribute {
            case AXAttributeNames.kAXTitleAttribute:
                return 300
            case AXAttributeNames.kAXDescriptionAttribute:
                return 280
            case "CPName", AXMiscConstants.computedNameAttributeKey:
                return 250
            case AXAttributeNames.kAXHelpAttribute,
                 AXAttributeNames.kAXEnabledAttribute,
                 AXAttributeNames.kAXFocusedAttribute,
                 AXAttributeNames.kAXIdentifierAttribute:
                return 210
            default:
                return 0
            }

        case .web:
            switch attribute {
            case AXAttributeNames.kAXDOMClassListAttribute:
                return 320
            case AXAttributeNames.kAXDOMIdentifierAttribute:
                return 300
            case AXAttributeNames.kAXURLAttribute:
                return 280
            case AXAttributeNames.kAXTitleAttribute,
                 AXAttributeNames.kAXDescriptionAttribute,
                 "CPName",
                 AXMiscConstants.computedNameAttributeKey:
                return 240
            default:
                return 0
            }

        case .list:
            switch attribute {
            case AXAttributeNames.kAXRowsAttribute,
                 AXAttributeNames.kAXColumnsAttribute,
                 AXAttributeNames.kAXSelectedRowsAttribute,
                 AXAttributeNames.kAXSelectedColumnsAttribute,
                 AXAttributeNames.kAXHeaderAttribute,
                 AXAttributeNames.kAXIndexAttribute,
                 AXAttributeNames.kAXDisclosureLevelAttribute,
                 AXAttributeNames.kAXDisclosedRowsAttribute:
                return 260
            case AXAttributeNames.kAXRoleAttribute,
                 AXAttributeNames.kAXSubroleAttribute,
                 AXAttributeNames.kAXTitleAttribute,
                 AXAttributeNames.kAXIdentifierAttribute:
                return 180
            default:
                return 0
            }

        case .container, .window:
            switch attribute {
            case AXAttributeNames.kAXRoleAttribute,
                 AXAttributeNames.kAXSubroleAttribute,
                 AXAttributeNames.kAXTitleAttribute,
                 AXAttributeNames.kAXIdentifierAttribute,
                 AXAttributeNames.kAXChildrenAttribute,
                 AXAttributeNames.kAXDescriptionAttribute,
                 AXAttributeNames.kAXPositionAttribute,
                 AXAttributeNames.kAXSizeAttribute,
                 AXAttributeNames.kAXMainAttribute,
                 AXAttributeNames.kAXFocusedAttribute:
                return 220
            default:
                return 0
            }

        case .menu:
            switch attribute {
            case AXAttributeNames.kAXTitleAttribute,
                 AXAttributeNames.kAXDescriptionAttribute,
                 AXAttributeNames.kAXEnabledAttribute,
                 AXAttributeNames.kAXIdentifierAttribute,
                 AXAttributeNames.kAXRoleAttribute,
                 AXAttributeNames.kAXSubroleAttribute:
                return 220
            default:
                return 0
            }

        case .indicator:
            switch attribute {
            case AXAttributeNames.kAXValueAttribute,
                 AXAttributeNames.kAXMinValueAttribute,
                 AXAttributeNames.kAXMaxValueAttribute,
                 AXAttributeNames.kAXValueDescriptionAttribute:
                return 220
            default:
                return 0
            }

        case .other:
            return 0
        }
    }

    private func grammarExpectation(in text: String, cursorUTF16: Int) -> OXQAutocompleteGrammarExpectation {
        let clampedCursor = max(0, min(cursorUTF16, text.utf16.count))
        let prefixText = (text as NSString).substring(with: NSRange(location: 0, length: clampedCursor))

        let tokens: [OXQToken]
        do {
            tokens = try OXQLexer().tokenize(prefixText)
        } catch {
            return .none
        }

        var stream = OXQAutocompleteTokenStream(tokens: tokens)
        do {
            try self.parseSelectorList(
                &stream,
                stopAtRightParen: false,
                allowLeadingCombinatorAtSelectorStart: false)

            guard stream.peek() == nil else {
                return .none
            }
            if self.isAfterImplicitDescendantCombinator(in: text, cursorUTF16: clampedCursor) {
                return .role
            }
            return .none
        } catch let signal as OXQAutocompleteGrammarSignal {
            switch signal {
            case .needRole:
                return .role
            case .needAttribute:
                return .attribute
            case .needFunction:
                return .function
            case .needOther, .invalid:
                return .none
            }
        } catch {
            return .none
        }
    }

    private func parseSelectorList(
        _ stream: inout OXQAutocompleteTokenStream,
        stopAtRightParen: Bool,
        allowLeadingCombinatorAtSelectorStart: Bool) throws
    {
        try self.parseSelector(
            &stream,
            allowLeadingCombinatorAtStart: allowLeadingCombinatorAtSelectorStart)

        while stream.consumeComma() != nil {
            try self.parseSelector(
                &stream,
                allowLeadingCombinatorAtStart: allowLeadingCombinatorAtSelectorStart)
        }

        if stopAtRightParen, stream.isAtEnd {
            return
        }
    }

    private func parseSelector(
        _ stream: inout OXQAutocompleteTokenStream,
        allowLeadingCombinatorAtStart: Bool) throws
    {
        if allowLeadingCombinatorAtStart {
            _ = stream.consumeCombinator()
        }

        try self.parseCompound(&stream)

        while stream.consumeCombinator() != nil {
            try self.parseCompound(&stream)
        }
    }

    private func parseCompound(_ stream: inout OXQAutocompleteTokenStream) throws {
        if stream.consumeWildcard() != nil || stream.consumeIdentifier() != nil {
            if stream.peekIsLeftBracket {
                _ = stream.consumeLeftBracket()
                try self.parseAttributeGroupBody(&stream)
            }
            try self.parsePseudos(&stream)
            return
        }

        if stream.peekIsLeftBracket {
            _ = stream.consumeLeftBracket()
            try self.parseAttributeGroupBody(&stream)
            try self.parsePseudos(&stream)
            return
        }

        if stream.peekIsColon {
            try self.parsePseudos(&stream, requireAtLeastOne: true)
            return
        }

        if stream.isAtEnd {
            throw OXQAutocompleteGrammarSignal.needRole
        }
        throw OXQAutocompleteGrammarSignal.invalid
    }

    private func parseAttributeGroupBody(_ stream: inout OXQAutocompleteTokenStream) throws {
        try self.parseAttribute(&stream)
        while stream.consumeComma() != nil {
            try self.parseAttribute(&stream)
        }

        guard stream.consumeRightBracket() != nil else {
            if stream.isAtEnd {
                throw OXQAutocompleteGrammarSignal.needOther
            }
            throw OXQAutocompleteGrammarSignal.invalid
        }
    }

    private func parseAttribute(_ stream: inout OXQAutocompleteTokenStream) throws {
        guard stream.consumeIdentifier() != nil else {
            if stream.isAtEnd {
                throw OXQAutocompleteGrammarSignal.needAttribute
            }
            throw OXQAutocompleteGrammarSignal.invalid
        }

        guard stream.consumeAttributeOperator() != nil else {
            if stream.isAtEnd {
                throw OXQAutocompleteGrammarSignal.needOther
            }
            throw OXQAutocompleteGrammarSignal.invalid
        }

        guard stream.consumeString() != nil else {
            if stream.isAtEnd {
                throw OXQAutocompleteGrammarSignal.needOther
            }
            throw OXQAutocompleteGrammarSignal.invalid
        }
    }

    private func parsePseudos(
        _ stream: inout OXQAutocompleteTokenStream,
        requireAtLeastOne: Bool = false) throws
    {
        var parsedAny = false
        while stream.peekIsColon {
            parsedAny = true
            try self.parsePseudo(&stream)
        }

        if requireAtLeastOne, !parsedAny {
            if stream.isAtEnd {
                throw OXQAutocompleteGrammarSignal.needOther
            }
            throw OXQAutocompleteGrammarSignal.invalid
        }
    }

    private func parsePseudo(_ stream: inout OXQAutocompleteTokenStream) throws {
        guard stream.consumeColon() != nil else {
            throw OXQAutocompleteGrammarSignal.invalid
        }

        guard let pseudoName = stream.consumeIdentifier() else {
            if stream.isAtEnd {
                throw OXQAutocompleteGrammarSignal.needFunction
            }
            throw OXQAutocompleteGrammarSignal.invalid
        }

        guard stream.consumeLeftParen() != nil else {
            if stream.isAtEnd {
                throw OXQAutocompleteGrammarSignal.needOther
            }
            throw OXQAutocompleteGrammarSignal.invalid
        }

        switch pseudoName.lowercased() {
        case "has":
            try self.parseSelectorList(
                &stream,
                stopAtRightParen: true,
                allowLeadingCombinatorAtSelectorStart: true)
        case "not":
            try self.parseSelectorList(
                &stream,
                stopAtRightParen: true,
                allowLeadingCombinatorAtSelectorStart: false)
        default:
            throw OXQAutocompleteGrammarSignal.invalid
        }

        guard stream.consumeRightParen() != nil else {
            if stream.isAtEnd {
                throw OXQAutocompleteGrammarSignal.needOther
            }
            throw OXQAutocompleteGrammarSignal.invalid
        }
    }

    private func scanContext(in text: String, upTo cursor: String.Index) -> OXQAutocompleteScanState {
        var state = OXQAutocompleteScanState()
        var index = text.startIndex
        var activeQuote: Character?
        var escaped = false

        while index < cursor {
            let character = text[index]

            if let quote = activeQuote {
                if escaped {
                    escaped = false
                    index = text.index(after: index)
                    continue
                }

                if character == "\\" {
                    escaped = true
                    index = text.index(after: index)
                    continue
                }

                if character == quote {
                    activeQuote = nil
                }

                index = text.index(after: index)
                continue
            }

            if character == "\"" || character == "'" {
                activeQuote = character
                index = text.index(after: index)
                continue
            }

            if character == "[" {
                state.attributeDepth += 1
                state.expectingAttributeName = true
                state.attributeRoleStack.append(state.roleHistory.last)
                state.attributeHistoryStack.append([])
                index = text.index(after: index)
                continue
            }

            if character == "]" {
                if state.attributeDepth > 0 {
                    state.attributeDepth -= 1
                }
                if !state.attributeRoleStack.isEmpty {
                    state.attributeRoleStack.removeLast()
                }
                if !state.attributeHistoryStack.isEmpty {
                    state.attributeHistoryStack.removeLast()
                }
                state.expectingAttributeName = false
                index = text.index(after: index)
                continue
            }

            if character == "," {
                if state.attributeDepth > 0 {
                    state.expectingAttributeName = true
                }
                index = text.index(after: index)
                continue
            }

            if state.attributeDepth > 0, character == "=" || character == "*" || character == "^" || character == "$" {
                state.expectingAttributeName = false
                index = text.index(after: index)
                continue
            }

            if self.isIdentifierStart(character) {
                let start = index
                let end = self.consumeIdentifier(in: text, from: start, limit: cursor)
                let token = String(text[start..<end])

                if state.attributeDepth > 0 {
                    if state.expectingAttributeName {
                        if !state.attributeHistoryStack.isEmpty {
                            state.attributeHistoryStack[state.attributeHistoryStack.count - 1].append(token)
                        }
                        state.expectingAttributeName = false
                    }
                } else {
                    let beforeToken = self.previousNonWhitespaceCharacter(in: text, before: start)
                    if beforeToken != ":" {
                        state.roleHistory.append(token)
                    }
                }

                index = end
                continue
            }

            index = text.index(after: index)
        }

        state.inStringLiteral = activeQuote != nil
        return state
    }

    private func resolvePrefixRange(in text: String, cursorUTF16: Int, partialWordRange: NSRange?) -> NSRange {
        if let partialWordRange,
           partialWordRange.location >= 0,
           partialWordRange.location <= cursorUTF16,
           NSMaxRange(partialWordRange) <= text.utf16.count
        {
            return partialWordRange
        }

        let cursorIndex = String.Index(utf16Offset: cursorUTF16, in: text)
        var start = cursorIndex

        while start > text.startIndex {
            let previous = text.index(before: start)
            if self.isIdentifierContinue(text[previous]) {
                start = previous
            } else {
                break
            }
        }

        let location = text.utf16.distance(from: text.utf16.startIndex, to: start.samePosition(in: text.utf16) ?? text.utf16.startIndex)
        let length = cursorUTF16 - location
        return NSRange(location: location, length: max(0, length))
    }

    private func isAfterImplicitDescendantCombinator(in text: String, cursorUTF16: Int) -> Bool {
        guard cursorUTF16 > 0 else { return false }
        let cursorIndex = String.Index(utf16Offset: cursorUTF16, in: text)
        guard cursorIndex > text.startIndex else { return false }

        let previousIndex = text.index(before: cursorIndex)
        guard text[previousIndex].isWhitespaceLike else { return false }
        guard let previousNonWhitespace = self.previousNonWhitespaceCharacter(in: text, before: cursorIndex) else {
            return false
        }

        return self.isIdentifierContinue(previousNonWhitespace) ||
            previousNonWhitespace == "*" ||
            previousNonWhitespace == "]" ||
            previousNonWhitespace == ")"
    }

    private func previousNonWhitespaceCharacter(in text: String, before index: String.Index) -> Character? {
        var cursor = index
        while cursor > text.startIndex {
            cursor = text.index(before: cursor)
            let character = text[cursor]
            if !character.isWhitespaceLike {
                return character
            }
        }
        return nil
    }

    private func consumeIdentifier(in text: String, from start: String.Index, limit: String.Index) -> String.Index {
        var index = start
        while index < limit, self.isIdentifierContinue(text[index]) {
            index = text.index(after: index)
        }
        return index
    }

    private func isIdentifierStart(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { scalar in
            CharacterSet.letters.contains(scalar) || scalar == "_"
        }
    }

    private func isIdentifierContinue(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "-"
        }
    }
}

private enum OXQAutocompleteGrammarExpectation {
    case role
    case attribute
    case function
    case none
}

private enum OXQAutocompleteGrammarSignal: Error {
    case needRole
    case needAttribute
    case needFunction
    case needOther
    case invalid
}

@MainActor
private struct OXQAutocompleteTokenStream {
    let tokens: [OXQToken]
    var index = 0

    var isAtEnd: Bool {
        self.index >= self.tokens.count
    }

    var peekIsLeftBracket: Bool {
        if case .leftBracket = self.peek()?.kind {
            return true
        }
        return false
    }

    var peekIsColon: Bool {
        if case .colon = self.peek()?.kind {
            return true
        }
        return false
    }

    func peek() -> OXQToken? {
        guard self.index < self.tokens.count else { return nil }
        return self.tokens[self.index]
    }

    mutating func consumeWildcard() -> OXQToken? {
        self.consumeIf { kind in
            if case .star = kind {
                return true
            }
            return false
        }
    }

    mutating func consumeIdentifier() -> String? {
        guard let token = self.peek() else { return nil }
        guard case let .identifier(value) = token.kind else { return nil }
        self.index += 1
        return value
    }

    mutating func consumeString() -> String? {
        guard let token = self.peek() else { return nil }
        guard case let .string(value) = token.kind else { return nil }
        self.index += 1
        return value
    }

    mutating func consumeLeftBracket() -> OXQToken? {
        self.consumeIf { kind in
            if case .leftBracket = kind {
                return true
            }
            return false
        }
    }

    mutating func consumeRightBracket() -> OXQToken? {
        self.consumeIf { kind in
            if case .rightBracket = kind {
                return true
            }
            return false
        }
    }

    mutating func consumeLeftParen() -> OXQToken? {
        self.consumeIf { kind in
            if case .leftParen = kind {
                return true
            }
            return false
        }
    }

    mutating func consumeRightParen() -> OXQToken? {
        self.consumeIf { kind in
            if case .rightParen = kind {
                return true
            }
            return false
        }
    }

    mutating func consumeColon() -> OXQToken? {
        self.consumeIf { kind in
            if case .colon = kind {
                return true
            }
            return false
        }
    }

    mutating func consumeComma() -> OXQToken? {
        self.consumeIf { kind in
            if case .comma = kind {
                return true
            }
            return false
        }
    }

    mutating func consumeCombinator() -> OXQToken? {
        self.consumeIf { kind in
            switch kind {
            case .child, .desc:
                return true
            default:
                return false
            }
        }
    }

    mutating func consumeAttributeOperator() -> OXQToken? {
        self.consumeIf { kind in
            switch kind {
            case .eq, .contains, .startsWith, .endsWith:
                return true
            default:
                return false
            }
        }
    }

    private mutating func consumeIf(_ predicate: (OXQTokenKind) -> Bool) -> OXQToken? {
        guard let token = self.peek(), predicate(token.kind) else { return nil }
        self.index += 1
        return token
    }
}

private extension Character {
    var isWhitespaceLike: Bool {
        self.unicodeScalars.allSatisfy { CharacterSet.whitespacesAndNewlines.contains($0) }
    }
}
