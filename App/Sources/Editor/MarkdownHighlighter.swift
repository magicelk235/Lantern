import AppKit
import CodeEditLanguages
// The protocol's completion handlers are `@MainActor` without `@Sendable` (the module builds in Swift 5 mode), which
// Swift 6 cannot spell; the import lets these witnesses match.
@preconcurrency import CodeEditSourceEditor
import CodeEditTextView
import SwiftTreeSitter

/// The editor's highlighting: tree-sitter's for most languages, `MarkdownHighlighter` for Markdown. The text view
/// controller keeps the providers it was made with, so this one picks which to forward to whenever the language is
/// set (the file opened, or a rename gave it another extension).
@MainActor
final class EditorHighlighting: HighlightProviding {
    private var current: any HighlightProviding = TreeSitterClient()

    func setUp(textView: TextView, codeLanguage: CodeLanguage) {
        let markdown = codeLanguage.id == .markdown
        if markdown != (current is MarkdownHighlighter) {
            current = markdown ? MarkdownHighlighter() : TreeSitterClient()
        }
        current.setUp(textView: textView, codeLanguage: codeLanguage)
    }

    func willApplyEdit(textView: TextView, range: NSRange) {
        current.willApplyEdit(textView: textView, range: range)
    }

    func applyEdit(
        textView: TextView, range: NSRange, delta: Int, completion: @escaping @MainActor (Result<IndexSet, Error>) -> Void
    ) {
        current.applyEdit(textView: textView, range: range, delta: delta, completion: completion)
    }

    func queryHighlightsFor(
        textView: TextView, range: NSRange, completion: @escaping @MainActor (Result<[HighlightRange], Error>) -> Void
    ) {
        current.queryHighlightsFor(textView: textView, range: range, completion: completion)
    }
}

/// Markdown's highlighting. CodeEditLanguages' Markdown grammars name what they find `text.title`, `text.literal`,
/// `text.uri` and the like, which CodeEditSourceEditor has no colors for, so its tree-sitter client leaves Markdown
/// plain. This parses the text with the same block and inline grammars and queries it with names the theme knows:
/// headings and strong text as keywords (bold), code as strings, link text as variables and addresses as types,
/// emphasis as attributes, and the list, quote and rule marks as comments.
@MainActor
final class MarkdownHighlighter: HighlightProviding {
    private static let blockPatterns = """
        (atx_heading) @keyword
        (setext_heading) @keyword
        [(indented_code_block) (fenced_code_block)] @string
        [(list_marker_plus) (list_marker_minus) (list_marker_star) (list_marker_dot) (list_marker_parenthesis)
         (thematic_break) (block_quote_marker)] @comment
        (link_destination) @type
        (link_label) @variable
        (link_title) @string
        """
    private static let inlinePatterns = """
        (code_span) @string
        (strong_emphasis) @keyword
        (emphasis) @type_alternate
        [(link_text) (image_description) (link_label)] @variable
        [(link_destination) (uri_autolink)] @type
        """

    private let blockParser = Parser()
    private let inlineParser = Parser()
    private var blockQuery: Query?
    private var inlineQuery: Query?
    /// Finds the paragraphs and headings the inline grammar parses.
    private var inlineNodesQuery: Query?
    /// The highlights of the whole text, in order and without overlaps, as of the last parse.
    private var highlights: [HighlightRange] = []

    func setUp(textView: TextView, codeLanguage: CodeLanguage) {
        if let block = CodeLanguage.markdown.language, let inline = CodeLanguage.markdownInline.language {
            try? blockParser.setLanguage(block)
            try? inlineParser.setLanguage(inline)
            blockQuery = try? Query(language: block, data: Data(Self.blockPatterns.utf8))
            inlineNodesQuery = try? Query(language: block, data: Data("(inline) @inline".utf8))
            inlineQuery = try? Query(language: inline, data: Data(Self.inlinePatterns.utf8))
        }
        parse(textView.string)
    }

    /// The text is parsed again whole (Markdown files are small), and any of it may look different now: a fence
    /// opened turns the rest into code.
    func applyEdit(
        textView: TextView, range: NSRange, delta: Int, completion: @escaping @MainActor (Result<IndexSet, Error>) -> Void
    ) {
        parse(textView.string)
        completion(.success(IndexSet(integersIn: 0 ..< textView.textStorage.length)))
    }

    func queryHighlightsFor(
        textView: TextView, range: NSRange, completion: @escaping @MainActor (Result<[HighlightRange], Error>) -> Void
    ) {
        completion(.success(highlights.compactMap { highlight in
            let clipped = NSIntersectionRange(highlight.range, range)
            return clipped.length > 0 ? HighlightRange(range: clipped, capture: highlight.capture) : nil
        }))
    }

    /// Parses `text` with the block grammar, then its paragraphs and headings with the inline one.
    private func parse(_ text: String) {
        guard let blockQuery, let inlineQuery, let inlineNodesQuery, let blockTree = blockParser.parse(text) else {
            highlights = []
            return
        }
        var found = captures(of: blockQuery, in: blockTree)
        var inlines: [TSRange] = []
        let cursor = inlineNodesQuery.execute(in: blockTree)
        while let match = cursor.next() {
            inlines += match.captures.map(\.node.tsRange)
        }
        if !inlines.isEmpty {
            inlineParser.includedRanges = inlines
            if let inlineTree = inlineParser.parse(text) { found += captures(of: inlineQuery, in: inlineTree) }
        }
        // Outer spans first where two start together; a span inside one already taken keeps the outer one's look.
        found.sort {
            $0.range.location != $1.range.location ? $0.range.location < $1.range.location : $0.range.length > $1.range.length
        }
        var flat: [HighlightRange] = []
        var end = 0
        for highlight in found where highlight.range.location >= end && highlight.range.length > 0 {
            flat.append(highlight)
            end = NSMaxRange(highlight.range)
        }
        highlights = flat
    }

    private func captures(of query: Query, in tree: MutableTree) -> [HighlightRange] {
        var result: [HighlightRange] = []
        let cursor = query.execute(in: tree)
        while let match = cursor.next() {
            for capture in match.captures {
                result.append(HighlightRange(range: capture.node.range, capture: CaptureName.fromString(capture.name)))
            }
        }
        return result
    }
}
