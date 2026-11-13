import AppKit
import BSON
import CcinnMongoKit
import SwiftUI

/// Syntax-highlighting editor for shell syntax / Extended JSON, built on NSTextView.
///
/// Highlighting comes from `SyntaxHighlighter`, which shares its tokenizer with the parser, so
/// colours always agree with what will be sent to the server.
struct CodeEditor: NSViewRepresentable {
    @Binding var text: String
    var placeholder = ""
    var isEditable = true
    /// Query-bar style: Return submits, Tab moves focus, no scroll bars.
    var isSingleLine = false
    var fontSize: CGFloat = 12
    var completions: [String] = []
    var error: SyntaxError?
    var focusOnAppear = false
    var onSubmit: (() -> Void)?
    var onHeightChange: ((CGFloat) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = !isSingleLine
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true

        let textView = CodeTextView(frame: .zero)
        textView.coordinator = context.coordinator
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.usesFindBar = !isSingleLine
        textView.isIncrementalSearchingEnabled = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 4, height: isSingleLine ? 4 : 8)
        textView.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        textView.typingAttributes = Coordinator.baseAttributes(fontSize: fontSize)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 2
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        scrollView.documentView = textView

        context.coordinator.textView = textView
        context.coordinator.apply(self)
        textView.string = text
        context.coordinator.rehighlight()
        if focusOnAppear {
            DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        coordinator.apply(self)
        guard let textView = coordinator.textView else { return }
        if textView.string != text {
            let selection = textView.selectedRanges
            coordinator.isApplyingBinding = true
            textView.string = text
            coordinator.isApplyingBinding = false
            let length = (text as NSString).length
            textView.selectedRanges = selection.map { value in
                let range = value.rangeValue
                return NSValue(range: NSRange(location: min(range.location, length), length: 0))
            }
            coordinator.rehighlight()
        } else if coordinator.lastError != error {
            coordinator.rehighlight()
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeEditor
        weak var textView: CodeTextView?
        var isApplyingBinding = false
        var lastError: SyntaxError?
        private var lastReportedHeight: CGFloat = 0

        init(_ parent: CodeEditor) {
            self.parent = parent
        }

        static func baseAttributes(fontSize: CGFloat) -> [NSAttributedString.Key: Any] {
            [.font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular), .foregroundColor: NSColor.labelColor]
        }

        func apply(_ editor: CodeEditor) {
            guard let textView else { return }
            textView.isEditable = editor.isEditable
            textView.isSelectable = true
            textView.placeholder = editor.placeholder
            textView.isSingleLine = editor.isSingleLine
            textView.extraCompletions = editor.completions
        }

        func textDidChange(_ notification: Notification) {
            guard !isApplyingBinding, let textView else { return }
            parent.text = textView.string
            rehighlight()
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertNewline(_:)), parent.isSingleLine, let onSubmit = parent.onSubmit {
                onSubmit()
                return true
            }
            if selector == #selector(NSResponder.insertTab(_:)) {
                if parent.isSingleLine {
                    textView.window?.selectNextKeyView(nil)
                } else {
                    textView.insertText("  ", replacementRange: textView.selectedRange())
                }
                return true
            }
            if selector == #selector(NSResponder.insertBacktab(_:)) {
                textView.window?.selectPreviousKeyView(nil)
                return true
            }
            return false
        }

        func textView(_ textView: NSTextView, completions words: [String], forPartialWordRange charRange: NSRange,
                      indexOfSelectedItem index: UnsafeMutablePointer<Int>?) -> [String] {
            let partial = (textView.string as NSString).substring(with: charRange)
            let candidates = partial.hasPrefix("$") ? CompletionCatalog.allOperators : parent.completions + CompletionCatalog.constructors
            let matches = candidates.filter { $0.lowercased().hasPrefix(partial.lowercased()) && $0 != partial }
            index?.pointee = matches.isEmpty ? -1 : 0
            return Array(NSOrderedSet(array: matches).array.compactMap { $0 as? String }.prefix(40))
        }

        /// Re-applies colours, the error underline and reports the content height.
        func rehighlight() {
            guard let textView, let storage = textView.textStorage else { return }
            let text = textView.string
            let length = (text as NSString).length
            lastError = parent.error
            storage.beginEditing()
            storage.setAttributes(Self.baseAttributes(fontSize: parent.fontSize), range: NSRange(location: 0, length: length))
            // Re-highlighting runs on every keystroke on the main thread; skip it for very large texts.
            if length < 150_000 {
                for span in SyntaxHighlighter.spans(for: text) {
                    let range = NSRange(location: span.range.lowerBound, length: span.range.count)
                    guard NSMaxRange(range) <= length else { continue }
                    storage.addAttribute(.foregroundColor, value: NSColor.syntaxColor(for: span.role), range: range)
                    if span.role == .operatorKey || span.role == .constructor {
                        storage.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: parent.fontSize, weight: .medium), range: range)
                    }
                }
            }
            if let error = parent.error, length > 0 {
                let location = min(max(0, error.offset), length - 1)
                let lineRange = (text as NSString).lineRange(for: NSRange(location: location, length: 0))
                let end = min(NSMaxRange(lineRange), length)
                let underline = NSRange(location: location, length: max(1, min(end - location, 24)))
                storage.addAttributes([
                    .underlineStyle: NSUnderlineStyle.thick.rawValue | NSUnderlineStyle.patternDot.rawValue,
                    .underlineColor: NSColor.systemRed,
                ], range: underline)
            }
            storage.endEditing()
            reportHeight()
        }

        func reportHeight() {
            guard let textView, let onHeightChange = parent.onHeightChange,
                  let container = textView.textContainer, let layout = textView.layoutManager else { return }
            layout.ensureLayout(for: container)
            let height = ceil(layout.usedRect(for: container).height + textView.textContainerInset.height * 2)
            guard abs(height - lastReportedHeight) > 0.5 else { return }
            lastReportedHeight = height
            DispatchQueue.main.async { onHeightChange(height) }
        }
    }
}

/// NSTextView with editor conveniences: bracket pairing, auto-indent, `$`-aware completion,
/// placeholder drawing, and Command-Return to submit.
final class CodeTextView: NSTextView {
    weak var coordinator: CodeEditor.Coordinator?
    var placeholder = "" {
        didSet { if placeholder != oldValue { needsDisplay = true } }
    }
    var isSingleLine = false
    var extraCompletions: [String] = []

    private static let pairs: [String: String] = ["{": "}", "[": "]", "(": ")", "\"": "\"", "'": "'"]
    private static let closers: Set<String> = ["}", "]", ")", "\"", "'"]

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor.placeholderTextColor,
        ]
        let origin = NSPoint(x: textContainerOrigin.x + (textContainer?.lineFragmentPadding ?? 0), y: textContainerOrigin.y)
        (placeholder as NSString).draw(at: origin, withAttributes: attributes)
    }

    override func becomeFirstResponder() -> Bool {
        needsDisplay = true
        return super.becomeFirstResponder()
    }

    override func keyDown(with event: NSEvent) {
        // Command-Return submits from multi-line editors too.
        if event.keyCode == 36, event.modifierFlags.contains(.command), let submit = coordinator?.parent.onSubmit {
            submit()
            return
        }
        super.keyDown(with: event)
    }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        guard isEditable, let typed = insertString as? String, typed.count == 1 else {
            super.insertText(insertString, replacementRange: replacementRange)
            return
        }
        let selection = selectedRange()
        let text = string as NSString
        let nextCharacter = selection.location < text.length ? text.substring(with: NSRange(location: selection.location, length: 1)) : ""

        // Typing a closer that is already there just steps over it.
        if Self.closers.contains(typed), nextCharacter == typed, selection.length == 0 {
            setSelectedRange(NSRange(location: selection.location + 1, length: 0))
            return
        }
        if let closer = Self.pairs[typed], selection.length == 0, shouldAutoPair(typed, next: nextCharacter, text: text, at: selection.location) {
            super.insertText(typed + closer, replacementRange: replacementRange)
            setSelectedRange(NSRange(location: selection.location + 1, length: 0))
            return
        }
        super.insertText(insertString, replacementRange: replacementRange)
        if typed == "$" { complete(nil) }
    }

    private func shouldAutoPair(_ opener: String, next: String, text: NSString, at location: Int) -> Bool {
        let nextIsBoundary = next.isEmpty || next.rangeOfCharacter(from: .whitespacesAndNewlines) != nil || Self.closers.contains(next) || next == "," || next == ":"
        guard nextIsBoundary else { return false }
        if opener == "\"" || opener == "'" {
            // Don't pair after a word character (e.g. typing an apostrophe in text).
            guard location > 0 else { return true }
            let previous = text.substring(with: NSRange(location: location - 1, length: 1))
            return previous.rangeOfCharacter(from: .alphanumerics) == nil
        }
        return true
    }

    override func deleteBackward(_ sender: Any?) {
        let selection = selectedRange()
        let text = string as NSString
        if selection.length == 0, selection.location > 0, selection.location < text.length {
            let previous = text.substring(with: NSRange(location: selection.location - 1, length: 1))
            let next = text.substring(with: NSRange(location: selection.location, length: 1))
            if let closer = Self.pairs[previous], closer == next {
                insertText("", replacementRange: NSRange(location: selection.location - 1, length: 2))
                return
            }
        }
        super.deleteBackward(sender)
    }

    override func insertNewline(_ sender: Any?) {
        guard !isSingleLine || coordinator?.parent.onSubmit == nil else {
            super.insertNewline(sender)
            return
        }
        let text = string as NSString
        let location = selectedRange().location
        let lineRange = text.lineRange(for: NSRange(location: location, length: 0))
        let line = text.substring(with: NSRange(location: lineRange.location, length: location - lineRange.location))
        let indentation = String(line.prefix { $0 == " " || $0 == "\t" })
        let previous = location > 0 ? text.substring(with: NSRange(location: location - 1, length: 1)) : ""
        let next = location < text.length ? text.substring(with: NSRange(location: location, length: 1)) : ""
        if previous == "{" || previous == "[" {
            if (previous == "{" && next == "}") || (previous == "[" && next == "]") {
                insertText("\n" + indentation + "  " + "\n" + indentation, replacementRange: selectedRange())
                setSelectedRange(NSRange(location: location + 1 + indentation.utf16.count + 2, length: 0))
            } else {
                insertText("\n" + indentation + "  ", replacementRange: selectedRange())
            }
            return
        }
        insertText("\n" + indentation, replacementRange: selectedRange())
    }

    override var rangeForUserCompletion: NSRange {
        let text = string as NSString
        let end = selectedRange().location
        var start = end
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "$_."))
        while start > 0 {
            let character = text.character(at: start - 1)
            guard let scalar = UnicodeScalar(character), allowed.contains(scalar) else { break }
            start -= 1
        }
        return NSRange(location: start, length: end - start)
    }
}

/// CodeEditor that grows with its content between `minHeight` and `maxHeight`.
struct AutoSizingCodeEditor: View {
    @Binding var text: String
    var placeholder = ""
    var completions: [String] = []
    var error: SyntaxError?
    var minHeight: CGFloat = 24
    var maxHeight: CGFloat = 160
    var isSingleLine = true
    var focusOnAppear = false
    var onSubmit: (() -> Void)?

    @State private var contentHeight: CGFloat = 24

    var body: some View {
        CodeEditor(text: $text, placeholder: placeholder, isSingleLine: isSingleLine, completions: completions,
                   error: error, focusOnAppear: focusOnAppear, onSubmit: onSubmit,
                   onHeightChange: { contentHeight = $0 })
            .frame(height: min(max(contentHeight, minHeight), maxHeight))
    }
}
