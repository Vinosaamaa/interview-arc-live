import AppKit
import SwiftUI

enum LiveEditorPalette {
    static let paper = NSColor(
        srgbRed: 252 / 255,
        green: 252 / 255,
        blue: 254 / 255,
        alpha: 1
    )
    static let ink = NSColor(
        srgbRed: 14 / 255,
        green: 17 / 255,
        blue: 30 / 255,
        alpha: 1
    )
    static let keyword = NSColor(
        srgbRed: 75 / 255,
        green: 58 / 255,
        blue: 191 / 255,
        alpha: 1
    )
    static let typeName = NSColor(
        srgbRed: 24 / 255,
        green: 35 / 255,
        blue: 89 / 255,
        alpha: 1
    )
    static let comment = NSColor(
        srgbRed: 82 / 255,
        green: 98 / 255,
        blue: 139 / 255,
        alpha: 1
    )
    static let string = NSColor(
        srgbRed: 159 / 255,
        green: 46 / 255,
        blue: 34 / 255,
        alpha: 1
    )
    static let number = NSColor(
        srgbRed: 237 / 255,
        green: 78 / 255,
        blue: 47 / 255,
        alpha: 1
    )
    static let gutter = NSColor(
        srgbRed: 224 / 255,
        green: 226 / 255,
        blue: 237 / 255,
        alpha: 1
    )
}

enum JavaSyntaxHighlighter {
    private static let keywords: Set<String> = [
        "abstract", "assert", "boolean", "break", "byte", "case", "catch",
        "char", "class", "const", "continue", "default", "do", "double",
        "else", "enum", "extends", "final", "finally", "float", "for", "goto",
        "if", "implements", "import", "instanceof", "int", "interface", "long",
        "native", "new", "package", "private", "protected", "public", "return",
        "short", "static", "strictfp", "super", "switch", "synchronized", "this",
        "throw", "throws", "transient", "try", "void", "volatile", "while",
        "true", "false", "null", "var", "record", "sealed", "permits", "yield",
        "non-sealed",
    ]

    static func highlight(_ storage: NSTextStorage) {
        let text = storage.string as NSString
        let fullRange = NSRange(location: 0, length: text.length)
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        storage.beginEditing()
        storage.setAttributes(
            [
                .font: font,
                .foregroundColor: LiveEditorPalette.ink,
            ],
            range: fullRange
        )

        apply(
            pattern: #"//.*$"#,
            options: .anchorsMatchLines,
            color: LiveEditorPalette.comment,
            in: storage,
            text: text
        )
        apply(
            pattern: #"/\*[\s\S]*?\*/"#,
            color: LiveEditorPalette.comment,
            in: storage,
            text: text
        )
        apply(
            pattern: #""(?:\\.|[^"\\])*""#,
            color: LiveEditorPalette.string,
            in: storage,
            text: text
        )
        apply(
            pattern: #"'\\.|[^']'"#,
            color: LiveEditorPalette.string,
            in: storage,
            text: text
        )
        apply(
            pattern: #"\b\d+(?:\.\d+)?\b"#,
            color: LiveEditorPalette.number,
            in: storage,
            text: text
        )
        apply(
            pattern: #"\b[A-Z][A-Za-z0-9_]*\b"#,
            color: LiveEditorPalette.typeName,
            in: storage,
            text: text
        )

        enumerateWords(in: text) { word, range in
            if keywords.contains(word) {
                storage.addAttribute(
                    .foregroundColor,
                    value: LiveEditorPalette.keyword,
                    range: range
                )
            }
        }
        storage.endEditing()
    }

    private static func apply(
        pattern: String,
        options: NSRegularExpression.Options = [],
        color: NSColor,
        in storage: NSTextStorage,
        text: NSString
    ) {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            return
        }
        let fullRange = NSRange(location: 0, length: text.length)
        regex.enumerateMatches(in: text as String, options: [], range: fullRange) {
            match, _, _ in
            guard let range = match?.range, range.location != NSNotFound else { return }
            storage.addAttribute(.foregroundColor, value: color, range: range)
        }
    }

    private static func enumerateWords(
        in text: NSString,
        body: (String, NSRange) -> Void
    ) {
        let fullRange = NSRange(location: 0, length: text.length)
        text.enumerateSubstrings(
            in: fullRange,
            options: [.byWords, .substringNotRequired]
        ) { _, range, _, _ in
            let word = text.substring(with: range)
            body(word, range)
        }
    }
}

fileprivate final class LineNumberRulerView: NSRulerView {
    weak var textView: NSTextView?

    init(textView: NSTextView) {
        self.textView = textView
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 44
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        LiveEditorPalette.paper.setFill()
        rect.fill()
        LiveEditorPalette.gutter.setFill()
        NSRect(x: rect.maxX - 1, y: rect.minY, width: 1, height: rect.height).fill()

        guard let textView, let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else {
            return
        }

        let visible = textView.visibleRect
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visible, in: textContainer)
        var lineNumber = 1
        let text = textView.string as NSString
        if glyphRange.location > 0 {
            lineNumber = text.substring(to: min(glyphRange.location, text.length))
                .reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
        }

        var index = glyphRange.location
        let end = NSMaxRange(glyphRange)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: LiveEditorPalette.comment,
        ]

        while index < end {
            let lineRange = text.lineRange(for: NSRange(location: index, length: 0))
            var glyphIndex = layoutManager.glyphIndexForCharacter(at: lineRange.location)
            if glyphIndex >= layoutManager.numberOfGlyphs,
               layoutManager.numberOfGlyphs > 0 {
                glyphIndex = layoutManager.numberOfGlyphs - 1
            }
            let fragment = layoutManager.lineFragmentRect(
                forGlyphAt: glyphIndex,
                effectiveRange: nil,
                withoutAdditionalLayout: true
            )
            let y = fragment.minY - visible.origin.y + textView.textContainerInset.height
            let label = "\(lineNumber)" as NSString
            let size = label.size(withAttributes: attributes)
            label.draw(
                at: NSPoint(x: rect.maxX - size.width - 8, y: y),
                withAttributes: attributes
            )
            index = NSMaxRange(lineRange)
            lineNumber += 1
            if lineRange.length == 0 { break }
        }
    }
}

struct JavaSourceEditorView: NSViewRepresentable {
    @Binding var text: String
    var isEditable: Bool
    var onEditingChanged: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = LiveEditorPalette.paper

        let textView = NSTextView()
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textColor = LiveEditorPalette.ink
        textView.backgroundColor = LiveEditorPalette.paper
        textView.insertionPointColor = LiveEditorPalette.keyword
        textView.delegate = context.coordinator
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = true
        textView.string = text
        JavaSyntaxHighlighter.highlight(textView.textStorage ?? NSTextStorage())

        scrollView.documentView = textView
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        let ruler = LineNumberRulerView(textView: textView)
        scrollView.verticalRulerView = ruler
        context.coordinator.ruler = ruler
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.invalidateRuler),
            name: NSView.frameDidChangeNotification,
            object: textView
        )
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.invalidateRuler),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
        scrollView.contentView.postsBoundsChangedNotifications = true
        textView.postsFrameChangedNotifications = true
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? NSTextView else { return }
        textView.isEditable = isEditable
        if textView.string != text {
            let selected = textView.selectedRanges
            textView.string = text
            JavaSyntaxHighlighter.highlight(textView.textStorage ?? NSTextStorage())
            textView.selectedRanges = selected
            context.coordinator.ruler?.needsDisplay = true
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: JavaSourceEditorView
        fileprivate weak var ruler: LineNumberRulerView?

        init(parent: JavaSourceEditorView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            JavaSyntaxHighlighter.highlight(textView.textStorage ?? NSTextStorage())
            ruler?.needsDisplay = true
            parent.onEditingChanged(textView.string)
        }

        @MainActor
        @objc
        func invalidateRuler() {
            ruler?.needsDisplay = true
        }
    }
}
