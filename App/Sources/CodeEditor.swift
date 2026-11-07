import SwiftUI
import UIKit

/// A JavaScript editor: monospaced, line numbers, syntax colours, auto-indent and a key bar above the keyboard.
struct CodeEditor: UIViewRepresentable {
    @Binding var text: String

    func makeUIView(context: Context) -> CodeTextView {
        let view = CodeTextView()
        view.delegate = context.coordinator
        view.text = text
        view.highlight()
        return view
    }

    func updateUIView(_ view: CodeTextView, context: Context) {
        context.coordinator.parent = self
        if view.text != text {
            view.text = text
            view.highlight()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: CodeEditor
        init(parent: CodeEditor) { self.parent = parent }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            (textView as? CodeTextView)?.textChanged()
        }

        /// Return keeps the current line's indentation, plus one level after `{`, `[` or `(`.
        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            guard text == "\n", let view = textView as? CodeTextView else { return true }
            let source = textView.text as NSString
            let lineStart = source.lineRange(for: NSRange(location: range.location, length: 0)).location
            let line = source.substring(with: NSRange(location: lineStart, length: range.location - lineStart))
            var indent = String(line.prefix { $0 == " " || $0 == "\t" })
            if let last = line.trimmingCharacters(in: .whitespaces).last, "{[(".contains(last) { indent += CodeTextView.indentUnit }
            // A plain newline goes through the normal path; inserting it here would call this delegate again.
            if indent.isEmpty { return true }
            view.insertText("\n" + indent)
            return false
        }
    }
}

final class CodeTextView: UITextView {
    static let indentUnit = "  "
    static let font = UIFont.mono(.body, size: 13)
    static let gutterFont = UIFont.mono(.caption2)
    /// Wide enough for four digits in the gutter font.
    private static var gutterWidth: CGFloat { ceil(("9999" as NSString).size(withAttributes: [.font: gutterFont]).width) + 8 }

    private let gutter = LineNumberGutter()
    private var highlightWork: DispatchWorkItem?

    init() {
        // TextKit 1, so the gutter can read line fragments from the layout manager.
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        super.init(frame: .zero, textContainer: container)
        font = Self.font
        backgroundColor = Theme.current.palette.ground
        autocorrectionType = .no
        autocapitalizationType = .none
        smartQuotesType = .no
        smartDashesType = .no
        smartInsertDeleteType = .no
        spellCheckingType = .no
        keyboardType = .asciiCapable
        alwaysBounceVertical = true
        keyboardDismissMode = .interactive
        textContainerInset = UIEdgeInsets(top: 8, left: Self.gutterWidth + 4, bottom: 8, right: 8)
        typingAttributes = Self.base
        gutter.textView = self
        addSubview(gutter)
        inputAccessoryView = KeyBar(target: self)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        gutter.frame = CGRect(x: contentOffset.x, y: contentOffset.y, width: Self.gutterWidth, height: bounds.height)
        gutter.setNeedsDisplay()
    }

    func textChanged() {
        gutter.setNeedsDisplay()
        highlightWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.highlight() }
        highlightWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    func insertKey(_ key: String) {
        insertText(key == "⇥" ? Self.indentUnit : key)
    }

    // MARK: Highlighting

    private static let base: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.label]

    private static let rules: [(NSRegularExpression, UIColor)] = {
        let keywords = ["async", "await", "break", "case", "catch", "class", "const", "continue", "default", "delete", "do",
                        "else", "export", "false", "finally", "for", "function", "if", "import", "in", "instanceof", "let",
                        "new", "null", "of", "return", "switch", "this", "throw", "true", "try", "typeof", "undefined",
                        "var", "void", "while", "yield"]
        func re(_ p: String, _ o: NSRegularExpression.Options = []) -> NSRegularExpression { try! NSRegularExpression(pattern: p, options: o) }
        return [
            (re("\\b(" + keywords.joined(separator: "|") + ")\\b"), .systemPink),
            (re("\\b(flow|console|crypto|base64|utf8|btoa|atob|JSON|\\$shared)\\b"), .systemTeal),
            (re("\\b(0x[0-9a-fA-F]+|\\d+(\\.\\d+)?)\\b"), .systemPurple),
            (re("\"(?:\\\\.|[^\"\\\\\\n])*\"|'(?:\\\\.|[^'\\\\\\n])*'|`(?:\\\\.|[^`\\\\])*`"), .systemRed),
            (re("//[^\\n]*|/\\*[\\s\\S]*?\\*/"), .systemGreen),
        ]
    }()

    /// Recolours the whole text; scripts are small enough that this takes well under a frame.
    func highlight() {
        let storage = textStorage
        let all = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.setAttributes(Self.base, range: all)
        let text = storage.string
        for (regex, color) in Self.rules {
            for match in regex.matches(in: text, range: all) {
                storage.addAttribute(.foregroundColor, value: color, range: match.range)
            }
        }
        storage.endEditing()
        typingAttributes = Self.base
    }
}

/// Line numbers drawn beside the visible lines; it covers only the visible part of the text view.
private final class LineNumberGutter: UIView {
    weak var textView: CodeTextView?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = Theme.current.palette.card
        isUserInteractionEnabled = false
        contentMode = .redraw
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func draw(_ rect: CGRect) {
        guard let tv = textView else { return }
        let layout = tv.layoutManager
        let text = tv.text as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: CodeTextView.gutterFont, .foregroundColor: UIColor.secondaryLabel,
        ]
        let top = tv.contentOffset.y, inset = tv.textContainerInset.top
        let visible = CGRect(x: 0, y: top - inset, width: tv.bounds.width, height: tv.bounds.height)
        let glyphs = layout.glyphRange(forBoundingRect: visible, in: tv.textContainer)
        // Count the lines before the first visible character once, then number forward.
        let firstChar = layout.characterIndexForGlyph(at: glyphs.location)
        var line = 1
        text.enumerateSubstrings(in: NSRange(location: 0, length: firstChar), options: [.byLines, .substringNotRequired]) { _, _, _, _ in line += 1 }
        if firstChar > 0, text.character(at: firstChar - 1) != 10 { line -= 1 }
        func draw(_ n: Int, at y: CGFloat, height: CGFloat) {
            let label = "\(n)" as NSString
            let size = label.size(withAttributes: attrs)
            label.draw(at: CGPoint(x: bounds.width - size.width - 6, y: y - top + inset + (height - size.height) / 2), withAttributes: attrs)
        }
        layout.enumerateLineFragments(forGlyphRange: glyphs) { fragment, _, _, range, _ in
            let c = layout.characterIndexForGlyph(at: range.location)
            if c == 0 || text.character(at: c - 1) == 10 {
                draw(line, at: fragment.minY, height: fragment.height)
                line += 1
            }
        }
        let extra = layout.extraLineFragmentRect
        if !extra.isEmpty, extra.maxY >= visible.minY { draw(line, at: extra.minY, height: extra.height) }
    }
}

/// Keys that are slow to reach on the iOS keyboard.
private final class KeyBar: UIInputView {
    private weak var target: CodeTextView?
    private static let keys = ["⇥", "{", "}", "(", ")", "[", "]", ";", "\"", "'", "=", ".", ":", ",", "$", "!", "&", "|", "+", "<", ">", "/"]

    init(target: CodeTextView) {
        self.target = target
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: 44), inputViewStyle: .keyboard)
        allowsSelfSizing = true
        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        let stack = UIStackView()
        stack.spacing = 6
        for key in Self.keys {
            var config = UIButton.Configuration.gray()
            config.title = key
            config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12)
            config.titleTextAttributesTransformer = .themed(.mono(.body, weight: .medium, size: 16))
            let button = UIButton(configuration: config, primaryAction: UIAction { [weak self] _ in self?.target?.insertKey(key) })
            if key == "⇥" { button.accessibilityLabel = "Tab" }
            stack.addArrangedSubview(button)
        }
        var done = UIButton.Configuration.plain()
        done.title = "Done"
        done.titleTextAttributesTransformer = .themed(.app(.body, weight: .semibold))
        let doneButton = UIButton(configuration: done, primaryAction: UIAction { [weak self] _ in self?.target?.resignFirstResponder() })
        scroll.addSubview(stack)
        addSubview(scroll)
        addSubview(doneButton)
        for v in [scroll, stack, doneButton] as [UIView] { v.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 44),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.trailingAnchor.constraint(equalTo: doneButton.leadingAnchor),
            doneButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            doneButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: scroll.frameLayoutGuide.centerYAnchor),
            stack.heightAnchor.constraint(equalToConstant: 34),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}
