import AppKit
import CodeEditTextView
import IDELanguageModel
import SwiftUI

/// What the language server says about the text under the mouse, once it rests there a moment (or at the caret,
/// Navigate › Show Quick Help): a popover under the character with the diagnostics there, then the server's hover text.
/// Moving off the character, typing, moving the caret or a click elsewhere closes it.
@MainActor
final class LanguageHover: NSResponder {
    private static let delay: Duration = .milliseconds(600)

    private weak var document: LanguageDocument?
    private weak var textView: TextView?
    private var trackingArea: NSTrackingArea?
    private var pending: Task<Void, Never>?
    private var popover: NSPopover?
    /// The character the popover is about, in the text view's coordinates.
    private var anchor = NSRect.zero

    init(document: LanguageDocument, textView: TextView) {
        self.document = document
        self.textView = textView
        super.init()
        let area = NSTrackingArea(
            rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self,
            userInfo: nil)
        textView.addTrackingArea(area)
        trackingArea = area
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// The editor lets go of its text view.
    func detach() {
        close()
        if let trackingArea { textView?.removeTrackingArea(trackingArea) }
        trackingArea = nil
    }

    func close() {
        pending?.cancel()
        pending = nil
        popover?.close()
        popover = nil
    }

    // MARK: - Mouse

    override func mouseMoved(with event: NSEvent) {
        guard let textView else { return }
        let point = textView.convert(event.locationInWindow, from: nil)
        if popover?.isShown == true {
            // Over the character it is about (with a little slack), the popover stays; anywhere else it goes.
            guard !anchor.insetBy(dx: -3, dy: -3).contains(point) else { return }
            close()
        }
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: Self.delay)
            guard !Task.isCancelled, let self, let textView = self.textView, let offset = Self.character(at: point, in: textView)
            else { return }
            await show(at: offset)
        }
    }

    override func mouseExited(with event: NSEvent) {
        pending?.cancel()
        pending = nil
        // Into the popover is fine (to select its text); out of the editor anywhere else closes it.
        if let window = popover?.contentViewController?.view.window, window.frame.contains(NSEvent.mouseLocation) { return }
        close()
    }

    /// The character under `point`, if the point is on one: not past a line's end or below the text.
    private static func character(at point: NSPoint, in textView: TextView) -> Int? {
        guard let offset = textView.layoutManager.textOffsetAtPoint(point) else { return nil }
        // The offset is the caret position nearest the point: the character after it, or the one before.
        for candidate in [offset, offset - 1] where candidate >= 0 && candidate < textView.textStorage.length {
            if let rect = textView.layoutManager.rectForOffset(candidate), rect.minX <= point.x, point.x < rect.maxX,
               rect.minY <= point.y, point.y < rect.maxY {
                return candidate
            }
        }
        return nil
    }

    // MARK: - Showing

    /// Navigate › Show Quick Help: the popover for the character at the caret.
    func showAtCaret() {
        guard let textView, let caret = textView.selectionManager.textSelections.first?.range.location else { return }
        let length = textView.textStorage.length
        // At the end of a word the caret follows the word: ask about its last character.
        let offset = caret < length && !Self.isSpace(textView, caret) ? caret : max(0, caret - 1)
        close()
        pending = Task { [weak self] in await self?.show(at: offset) }
    }

    private static func isSpace(_ textView: TextView, _ offset: Int) -> Bool {
        let unit = textView.textStorage.mutableString.character(at: offset)
        return unit == 0x20 || unit == 0x09 || unit == 0x0A || unit == 0x0D
    }

    private func show(at offset: Int) async {
        guard let document, let textView else { return }
        let diagnostics = document.diagnostics(at: offset)
        let blocks = await document.hover(at: offset)
        guard !Task.isCancelled, !(diagnostics.isEmpty && blocks.isEmpty), textView.window != nil,
              let rect = textView.layoutManager.rectForOffset(offset) else { return }
        anchor = rect
        let font = textView.font
        let content = LanguageHoverView(
            diagnostics: diagnostics, blocks: blocks, codeFont: font, width: LanguageHoverView.width(for: blocks, codeFont: font))
        let popover = NSPopover()
        popover.behavior = .semitransient
        popover.animates = false
        let host = NSHostingController(rootView: content)
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        self.popover?.close()
        self.popover = popover
        popover.show(relativeTo: rect, of: textView, preferredEdge: .maxY)
    }
}

/// The hover popover's content: the diagnostics at the character (severity icon and message), a hairline, then the
/// server's text — code in the editor's font, documentation as inline markdown, rules as hairlines. Taller content
/// scrolls.
struct LanguageHoverView: View {
    let diagnostics: [EditorDiagnostic]
    let blocks: [HoverBlock]
    let codeFont: NSFont
    let width: CGFloat

    private static let maxHeight: CGFloat = 360
    private static let padding: CGFloat = 12

    /// As wide as the longest code line needs, between 280 and 560 points; documentation wraps.
    static func width(for blocks: [HoverBlock], codeFont: NSFont) -> CGFloat {
        let widest = blocks.reduce(CGFloat(0)) { widest, block in
            guard case .code(let code) = block else { return widest }
            let lines = code.split(separator: "\n", omittingEmptySubsequences: false)
            return lines.reduce(widest) { max($0, (String($1) as NSString).size(withAttributes: [.font: codeFont]).width) }
        }
        return min(560, max(280, widest.rounded(.up) + 2 * padding))
    }

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(diagnostics.enumerated()), id: \.offset) { _, diagnostic in
                    DiagnosticRow(diagnostic: diagnostic)
                }
                if !diagnostics.isEmpty, !blocks.isEmpty { Divider() }
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    switch block {
                    case .code(let code):
                        Text(code).font(Font(codeFont))
                    case .markdown(let markdown):
                        Text(Self.inline(markdown))
                    case .plain(let text):
                        Text(text)
                    case .rule:
                        Divider()
                    }
                }
            }
            .font(.system(size: 13))
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: width - 2 * Self.padding, alignment: .leading)
            .padding(Self.padding)
        }
        .frame(width: width)
        .frame(maxHeight: Self.maxHeight)
        .fixedSize(horizontal: false, vertical: true)
    }

    private static func inline(_ markdown: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: markdown, options: options)) ?? AttributedString(markdown)
    }

    private struct DiagnosticRow: View {
        let diagnostic: EditorDiagnostic

        var body: some View {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: symbol)
                    .foregroundStyle(color)
                Text(diagnostic.message)
            }
        }

        private var symbol: String {
            switch diagnostic.severity {
            case .error: "xmark.octagon.fill"
            case .warning: "exclamationmark.triangle.fill"
            case .information, .hint: "info.circle.fill"
            }
        }

        private var color: Color {
            switch diagnostic.severity {
            case .error: Color(nsColor: .systemRed)
            case .warning: Color(nsColor: .systemYellow)
            case .information, .hint: .secondary
            }
        }
    }
}
