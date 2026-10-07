import Foundation
import IDEEditorModel
import Testing

@Suite struct TextSearchTests {
    private func regex(_ pattern: String) throws -> NSRegularExpression {
        try NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
    }

    @Test func emptyMatchesMarkEveryLineStartAndEnd() throws {
        let text = "one\ntwo\n\nthree"
        #expect(TextSearch.matches(of: try regex("^"), in: text).map(\.location) == [0, 4, 8, 9])
        #expect(TextSearch.matches(of: try regex("$"), in: text).map(\.location) == [3, 7, 8, 14])
        #expect(TextSearch.matches(of: try regex("^"), in: text).allSatisfy { $0.length == 0 })
    }

    @Test func replaceAllPrefixesAndSuffixesEveryLine() throws {
        let text = "one\ntwo\n\nthree"
        #expect(TextSearch.replacingAll(of: try regex("^"), in: text, with: "> ") == "> one\n> two\n> \n> three")
        #expect(TextSearch.replacingAll(of: try regex("$"), in: text, with: ";") == "one;\ntwo;\n;\nthree;")
        #expect(TextSearch.replacingAll(of: try regex("\\bt"), in: text, with: "T") == "one\nTwo\n\nThree")
        #expect(TextSearch.replacingAll(of: try regex("(o)(?=n)"), in: text, with: "[$1]") == "[o]ne\ntwo\n\nthree")
        #expect(TextSearch.replacingAll(of: try regex("x"), in: text, with: "y") == nil)
    }

    @Test func findNextMovesPastAnEmptyMatchItIsOn() throws {
        let matches = TextSearch.matches(of: try regex("^"), in: "a\nb\nc")
        #expect(TextSearch.next(in: matches, from: NSRange(location: 0, length: 0), wrapsAround: true) == 1)
        #expect(TextSearch.next(in: matches, from: NSRange(location: 2, length: 0), wrapsAround: true) == 2)
        #expect(TextSearch.next(in: matches, from: NSRange(location: 4, length: 0), wrapsAround: true) == 0)
        #expect(TextSearch.next(in: matches, from: NSRange(location: 4, length: 0), wrapsAround: false) == nil)
        // A caret that is not on a match goes to the one where it stands.
        #expect(TextSearch.next(in: matches, from: NSRange(location: 1, length: 0), wrapsAround: true) == 1)
        #expect(TextSearch.previous(in: matches, from: NSRange(location: 2, length: 0), wrapsAround: true) == 0)
        #expect(TextSearch.previous(in: matches, from: NSRange(location: 0, length: 0), wrapsAround: true) == 2)
    }

    @Test func findNextAfterANonEmptySelectionStartsAtItsEnd() throws {
        let matches = TextSearch.matches(of: try regex("ab"), in: "abab x ab")
        #expect(matches.map(\.location) == [0, 2, 7])
        #expect(TextSearch.next(in: matches, from: NSRange(location: 0, length: 2), wrapsAround: true) == 1)
        #expect(TextSearch.next(in: matches, from: NSRange(location: 7, length: 2), wrapsAround: true) == 0)
        #expect(TextSearch.previous(in: matches, from: NSRange(location: 7, length: 2), wrapsAround: false) == 1)
    }
}
