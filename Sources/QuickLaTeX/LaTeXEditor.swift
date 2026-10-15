import SwiftUI
import AppKit

/// NSTextView tuned for typing LaTeX: no smart quotes/dashes/replacement/spellcheck, monospaced.
final class QLTextView: NSTextView {
    var onEscape: (() -> Void)?
    var isMainEditor = false

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        isRichText = false
        importsGraphics = false
        usesFontPanel = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // The shared NSColorPanel (opened by the SwiftUI ColorPicker) sends changeColor:/changeFont: down the
    // responder chain. A plain-text LaTeX editor must ignore them, otherwise picking a colour recolours the text.
    override func changeColor(_ sender: Any?) {}
    override func changeFont(_ sender: Any?) {}
    override func changeAttributes(_ sender: Any?) {}
    override func changeDocumentBackgroundColor(_ sender: Any?) {}

    override func cancelOperation(_ sender: Any?) {
        if let f = onEscape { f() } else { super.cancelOperation(sender) }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, !hasMarkedText(), let f = onEscape {
            f()
            return
        }
        super.keyDown(with: event)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if isMainEditor, let w = window {
            DispatchQueue.main.async { w.makeFirstResponder(self) }
        }
    }
}

struct LaTeXEditor: NSViewRepresentable {
    @Binding var text: String
    var isMain = false
    var onEscape: (() -> Void)?

    /// The main editor, so the global hotkey can focus it.
    static weak var mainTextView: QLTextView?

    /// Always the normal label colour (dynamic: follows light/dark appearance) in the editor font.
    static let baseAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedSystemFont(ofSize: 14, weight: .regular),
        .foregroundColor: NSColor.textColor,
    ]

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)

        let tv = QLTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200), textContainer: container)
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]

        tv.font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        tv.textColor = .textColor
        tv.backgroundColor = .textBackgroundColor
        tv.drawsBackground = true
        tv.textContainerInset = NSSize(width: 6, height: 6)
        tv.isRichText = false
        tv.importsGraphics = false
        tv.usesFontPanel = false
        tv.usesRuler = false
        tv.allowsUndo = true
        tv.usesFindBar = true

        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.isGrammarCheckingEnabled = false
        tv.isAutomaticDataDetectionEnabled = false
        tv.isAutomaticLinkDetectionEnabled = false
        tv.isAutomaticTextCompletionEnabled = false
        tv.smartInsertDeleteEnabled = false
        tv.inlinePredictionType = .no
        if #available(macOS 15.0, *) { tv.writingToolsBehavior = .none }

        tv.isMainEditor = isMain
        tv.onEscape = onEscape
        tv.delegate = context.coordinator
        tv.string = text
        tv.typingAttributes = LaTeXEditor.baseAttributes
        if isMain { LaTeXEditor.mainTextView = tv }

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor
        scroll.documentView = tv
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let tv = scroll.documentView as? QLTextView else { return }
        tv.onEscape = onEscape
        if tv.string != text {
            let sel = tv.selectedRange()
            tv.string = text
            tv.typingAttributes = LaTeXEditor.baseAttributes
            let len = (text as NSString).length
            tv.setSelectedRange(NSRange(location: min(sel.location, len), length: 0))
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: LaTeXEditor
        init(_ p: LaTeXEditor) { parent = p }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            let s = tv.string
            if parent.text != s { parent.text = s }
        }
    }
}
