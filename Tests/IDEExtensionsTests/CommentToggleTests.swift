import Foundation
import IDEExtensions
import Testing

@Suite struct CommentToggleTests {
    private static let block = LanguageConfiguration.Pair(open: "/*", close: "*/")

    /// Toggles comments on `marked`, a text with its selection marked `‹…›` or its caret `|`, and returns the text
    /// after, with the new selection marked the same way; nil when there is nothing to toggle with.
    private func toggle(
        _ marked: String, line: String? = "//", block: LanguageConfiguration.Pair? = CommentToggleTests.block
    ) -> String? {
        var text = marked
        func take(_ marker: String) -> Int? {
            guard let found = text.range(of: marker) else { return nil }
            let offset = text.utf16.distance(from: text.startIndex, to: found.lowerBound)
            text.removeSubrange(found)
            return offset
        }
        let selection: NSRange
        if let caret = take("|") {
            selection = NSRange(location: caret, length: 0)
        } else if let start = take("‹"), let end = take("›") {
            selection = NSRange(location: start, length: end - start)
        } else {
            Issue.record("no selection in \(marked)")
            return nil
        }
        guard let result = CommentToggle.toggle(
            in: text as NSString, selection: selection, lineComment: line, blockComment: block) else { return nil }
        let after = NSMutableString(string: text)
        for edit in result.edits { after.replaceCharacters(in: edit.range, with: edit.text) }
        if result.selection.length == 0 {
            after.insert("|", at: result.selection.location)
        } else {
            after.insert("›", at: NSMaxRange(result.selection))
            after.insert("‹", at: result.selection.location)
        }
        return after as String
    }

    @Test func linesAreCommentedAtTheirSmallestIndentationAndBlankLinesLeftAlone() {
        // The selection ends at the start of the last line, which it does not touch.
        #expect(toggle("‹    a\n\n  b\n›c") == "‹  //   a\n\n  // b\n›c")
        #expect(toggle("a‹\n›b") == "// a‹\n›b")
        #expect(toggle("  fo|o") == "  // fo|o")
        // A caret right where the comment goes ends up after it, as if it had been typed.
        #expect(toggle("  |foo\nbar") == "  // |foo\nbar")
    }

    @Test func linesAllCommentedAreUncommentedWithOneSpaceAfterTheToken() {
        #expect(toggle("‹  // a\n\n  //b\n    //  c›") == "‹  a\n\n  b\n     c›")
        #expect(toggle("  /|/ foo") == "  |foo")
        #expect(toggle("// x\n|") == "// x\n// |")
    }

    @Test func linesPartlyCommentedAreAllCommented() {
        #expect(toggle("‹// a\nb›") == "‹// // a\n// b›")
    }

    @Test func onlyBlankLinesGetATokenToTypeAfter() {
        #expect(toggle("  |") == "  // |")
        #expect(toggle("|", line: nil) == "/* | */")
    }

    @Test func withOnlyABlockCommentTheLinesAreWrappedAndUnwrapped() {
        #expect(toggle("‹  a\n  b›\n", line: nil) == "‹  /* a\n  b */›\n")
        #expect(toggle("  /* a */|", line: nil) == "  a|")
        #expect(toggle("/*a*/|", line: nil) == "a|")
        #expect(toggle("/* */|", line: nil) == "|")
        // Two comments with code between are not one comment: the whole is wrapped.
        #expect(toggle("/* a */ b /* c */|", line: nil) == "/* /* a */ b /* c */ */|")
        #expect(toggle("|x", line: nil, block: nil) == nil)
    }
}
