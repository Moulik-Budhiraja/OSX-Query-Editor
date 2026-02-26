import AppKit
import SwiftUI

struct OXQHighlightedEditor: NSViewRepresentable {
    @Binding var text: String

    var fontSize: CGFloat = 16

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

        if textView.string != text {
            context.coordinator.applyHighlight(to: text, preserveSelection: true)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: OXQHighlightedEditor
        weak var textView: NSTextView?
        private var isApplying = false

        init(parent: OXQHighlightedEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            guard !isApplying else { return }
            let latest = textView.string
            if parent.text != latest {
                parent.text = latest
            }
            applyHighlight(to: latest, preserveSelection: true)
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
    }
}
