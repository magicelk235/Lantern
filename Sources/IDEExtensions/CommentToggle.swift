import Foundation

/// A change to a text: `range`, in UTF-16 offsets of the text as it was before any of the changes, replaced by `text`.
public struct TextReplacement: Sendable, Equatable {
    public let range: NSRange
    public let text: String

    public init(range: NSRange, text: String) {
        self.range = range
        self.text = text
    }
}

/// The Toggle Comment command, on whole lines: line comments where the language has them, else a block comment around
/// the lines.
public enum CommentToggle {
    /// The changes that comment, or uncomment, the lines `selection` touches in `text`, and the selection after them;
    /// nil when the language has neither kind of comment. A selection that ends at the very start of a line does not
    /// touch that line.
    ///
    /// With a line comment: when every touched line that is not blank starts with the token after its indentation, the
    /// token goes, with one space after it; otherwise the token and a space are put on each of those lines, at the
    /// smallest indentation among them, so the lines keep their shape. Blank lines are left alone, unless every touched
    /// line is blank: then each gets the token, to type a comment after. With only a block comment: when the touched
    /// lines' text, without the whitespace around it, is a block comment (one that does not close before its end), its
    /// tokens go, with one space inside each; otherwise that text is put between `open ` and ` close`. On blank lines,
    /// an empty block comment goes at the end of the first, with the caret inside.
    ///
    /// The changes are in order from the last in the text to the first, so applying them in turn keeps the ranges of
    /// those still to apply right. The selection grows to take in what is put at its edges; a caret moves past what
    /// is put right where it is.
    public static func toggle(
        in text: NSString, selection: NSRange, lineComment: String?, blockComment: LanguageConfiguration.Pair?
    ) -> (edits: [TextReplacement], selection: NSRange)? {
        let start = min(max(selection.location, 0), text.length)
        let end = start + min(max(selection.length, 0), text.length - start)
        let lines = touchedLines(in: text, from: start, to: end)
        let edits: [TextReplacement]
        var caret: Int?
        if let token = lineComment, !token.isEmpty {
            edits = lineCommentEdits(token, lines: lines, in: text)
        } else if let pair = blockComment, !pair.open.isEmpty, !pair.close.isEmpty {
            let block = blockCommentEdits(pair, lines: lines, in: text)
            edits = block.edits
            caret = block.caret
        } else {
            return nil
        }
        let ordered = edits.sorted { $0.range.location > $1.range.location }
        if let caret { return (ordered, NSRange(location: caret, length: 0)) }
        if start == end {
            let location = map(start, through: ordered, movesWithInsertion: true)
            return (ordered, NSRange(location: location, length: 0))
        }
        let newStart = map(start, through: ordered, movesWithInsertion: false)
        let newEnd = map(end, through: ordered, movesWithInsertion: true)
        return (ordered, NSRange(location: newStart, length: newEnd - newStart))
    }

    /// The lines from the one holding `start` through the one holding `end`, that last one left out when the selection
    /// is not empty and ends right at its start; each without its line break.
    private static func touchedLines(in text: NSString, from start: Int, to end: Int) -> [NSRange] {
        var last = end
        if end > start, text.lineRange(for: NSRange(location: end, length: 0)).location == end { last = end - 1 }
        var lines: [NSRange] = []
        var location = start
        repeat {
            var lineStart = 0
            var lineEnd = 0
            var contentsEnd = 0
            text.getLineStart(
                &lineStart, end: &lineEnd, contentsEnd: &contentsEnd, for: NSRange(location: location, length: 0))
            lines.append(NSRange(location: lineStart, length: contentsEnd - lineStart))
            location = lineEnd
        } while location <= last && location < text.length
        return lines
    }

    private static func lineCommentEdits(_ token: String, lines: [NSRange], in text: NSString) -> [TextReplacement] {
        let indents = lines.map { indentation(of: $0, in: text) }
        let content = lines.indices.filter { indents[$0] < lines[$0].length }
        guard !content.isEmpty else {
            return lines.map { TextReplacement(range: NSRange(location: NSMaxRange($0), length: 0), text: token + " ") }
        }
        let tokenLength = (token as NSString).length
        let isCommented = content.allSatisfy { line in
            let start = lines[line].location + indents[line]
            let rest = NSRange(location: start, length: NSMaxRange(lines[line]) - start)
            return contains(token, in: text, rest, .anchored)
        }
        if isCommented {
            return content.map { line in
                let tokenStart = lines[line].location + indents[line]
                let afterToken = tokenStart + tokenLength
                let space = afterToken < NSMaxRange(lines[line]) && text.character(at: afterToken) == 0x20 ? 1 : 0
                return TextReplacement(range: NSRange(location: tokenStart, length: tokenLength + space), text: "")
            }
        }
        let column = content.map { indents[$0] }.min() ?? 0
        return content.map { line in
            TextReplacement(range: NSRange(location: lines[line].location + column, length: 0), text: token + " ")
        }
    }

    /// The changes for a block comment, and where the caret goes when that is not simply where the selection was.
    private static func blockCommentEdits(
        _ pair: LanguageConfiguration.Pair, lines: [NSRange], in text: NSString
    ) -> (edits: [TextReplacement], caret: Int?) {
        let first = lines[0].location
        let last = NSMaxRange(lines[lines.count - 1])
        var contentStart = first
        while contentStart < last, isWhitespace(text.character(at: contentStart)) { contentStart += 1 }
        let openLength = (pair.open as NSString).length
        guard contentStart < last else {
            let end = NSMaxRange(lines[0])
            let empty = TextReplacement(range: NSRange(location: end, length: 0), text: "\(pair.open)  \(pair.close)")
            return ([empty], end + openLength + 1)
        }
        var contentEnd = last
        while isWhitespace(text.character(at: contentEnd - 1)) { contentEnd -= 1 }
        let content = NSRange(location: contentStart, length: contentEnd - contentStart)
        let closeLength = (pair.close as NSString).length
        let inside = NSRange(location: contentStart + openLength, length: content.length - openLength - closeLength)
        if content.length >= openLength + closeLength, contains(pair.open, in: text, content, .anchored),
           contains(pair.close, in: text, content, [.anchored, .backwards]), !contains(pair.close, in: text, inside) {
            var openEnd = contentStart + openLength
            var closeStart = contentEnd - closeLength
            if openEnd < closeStart, text.character(at: openEnd) == 0x20 { openEnd += 1 }
            if closeStart > openEnd, text.character(at: closeStart - 1) == 0x20 { closeStart -= 1 }
            return ([
                TextReplacement(range: NSRange(location: contentStart, length: openEnd - contentStart), text: ""),
                TextReplacement(range: NSRange(location: closeStart, length: contentEnd - closeStart), text: ""),
            ], nil)
        }
        return ([
            TextReplacement(range: NSRange(location: contentStart, length: 0), text: pair.open + " "),
            TextReplacement(range: NSRange(location: contentEnd, length: 0), text: " " + pair.close),
        ], nil)
    }

    /// The length of the spaces and tabs `line` starts with.
    private static func indentation(of line: NSRange, in text: NSString) -> Int {
        var length = 0
        while length < line.length, [0x20, 0x09].contains(text.character(at: line.location + length)) { length += 1 }
        return length
    }

    /// Whether `token` is in `range` of `text`, character for character, where `options` say (`.anchored`: at its
    /// start; with `.backwards`, at its end).
    private static func contains(
        _ token: String, in text: NSString, _ range: NSRange, _ options: NSString.CompareOptions = []
    ) -> Bool {
        text.range(of: token, options: options.union(.literal), range: range).location != NSNotFound
    }

    private static func isWhitespace(_ unit: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(unit) else { return false }
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
    }

    /// Where `position` is once `edits` are made: moved by the changes before it, to the start of a removal it was
    /// inside, and past an insertion right at it when `movesWithInsertion`.
    private static func map(_ position: Int, through edits: [TextReplacement], movesWithInsertion: Bool) -> Int {
        var mapped = position
        for edit in edits {
            let start = edit.range.location
            let inserted = (edit.text as NSString).length
            if edit.range.length == 0 {
                if start < position || (start == position && movesWithInsertion) { mapped += inserted }
            } else if NSMaxRange(edit.range) <= position {
                mapped += inserted - edit.range.length
            } else if start < position {
                mapped -= position - start
            }
        }
        return mapped
    }
}
