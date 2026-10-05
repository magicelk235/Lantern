import Foundation
import IDELanguageModel
import LanguageServerProtocol
import Testing

@Suite struct LineTableTests {
    @Test func linesBreakAfterLFCRLFAndALoneCR() {
        let text = "a\nb\r\nc\rd" as NSString
        let lines = LineTable(text)
        #expect(lines.lineCount == 4)
        #expect((0..<4).map(lines.lineStart) == [0, 2, 5, 7])
        // The CR of a CRLF is still on its line: past the line's text.
        #expect(lines.position(at: 3) == Position(line: 1, character: 1))
        #expect(lines.position(at: 4) == Position(line: 1, character: 2))
        #expect(lines.position(at: 7) == Position(line: 3, character: 0))
        #expect(lines.position(at: text.length) == Position(line: 3, character: 1))
    }

    @Test func aTrailingBreakStartsAnEmptyLastLine() {
        let lines = LineTable("x\n" as NSString)
        #expect(lines.lineCount == 2)
        #expect(lines.position(at: 2) == Position(line: 1, character: 0))
        #expect(LineTable("" as NSString).lineCount == 1)
        #expect(LineTable("" as NSString).position(at: 0) == Position(line: 0, character: 0))
    }

    @Test func charactersAreUTF16CodeUnits() {
        let text = "😀x\naé😀b" as NSString
        let lines = LineTable(text)
        #expect(lines.position(at: 2) == Position(line: 0, character: 2))
        // a, é, the two halves of 😀, then b.
        #expect(lines.position(at: 8) == Position(line: 1, character: 4))
        #expect(lines.offset(at: Position(line: 1, character: 4), in: text) == 8)
    }

    @Test func positionsPastALineEndAtItsTextNotItsBreak() {
        let text = "ab\r\ncd" as NSString
        let lines = LineTable(text)
        #expect(lines.offset(at: Position(line: 0, character: 99), in: text) == 2)
        #expect(lines.offset(at: Position(line: 1, character: 99), in: text) == 6)
        #expect(lines.offset(at: Position(line: 9, character: 0), in: text) == 6)
        #expect(lines.offset(at: Position(line: 1, character: -3), in: text) == 4)
    }

    @Test func rangesConvertBothWays() {
        let text = "let a = 1\nlet bb = 22\n" as NSString
        let lines = LineTable(text)
        let range = NSRange(location: 14, length: 2)
        let lsp = lines.lspRange(of: range)
        #expect(lsp == LSPRange(start: Position(line: 1, character: 4), end: Position(line: 1, character: 6)))
        #expect(lines.range(of: lsp, in: text) == range)
        // An end before the start is the start.
        let backwards = LSPRange(start: Position(line: 1, character: 2), end: Position(line: 0, character: 1))
        #expect(lines.range(of: backwards, in: text) == NSRange(location: 12, length: 0))
    }

    @Test func editsThatSplitOrJoinACRLFMoveTheLineStarts() {
        var text = NSMutableString(string: "a\r\nb")
        var lines = LineTable(text)
        // A character between CR and LF: two line breaks.
        text.replaceCharacters(in: NSRange(location: 2, length: 0), with: "x")
        lines.replace(NSRange(location: 2, length: 0), newLength: 1, in: text)
        #expect(lines == LineTable(text))
        #expect((0..<lines.lineCount).map(lines.lineStart) == [0, 2, 4])

        text = NSMutableString(string: "a\r\nb")
        lines = LineTable(text)
        // Removing the LF leaves a lone CR, still a break.
        text.replaceCharacters(in: NSRange(location: 2, length: 1), with: "")
        lines.replace(NSRange(location: 2, length: 1), newLength: 0, in: text)
        #expect((0..<lines.lineCount).map(lines.lineStart) == [0, 2])

        text = NSMutableString(string: "a\rb")
        lines = LineTable(text)
        // An LF typed after a lone CR joins it into one CRLF break.
        text.replaceCharacters(in: NSRange(location: 2, length: 0), with: "\n")
        lines.replace(NSRange(location: 2, length: 0), newLength: 1, in: text)
        #expect((0..<lines.lineCount).map(lines.lineStart) == [0, 3])
    }

    @Test func incrementalEditsMatchATableBuiltFromScratch() {
        var random = SplitMix(seed: 0x1D3)
        let pieces = ["a", "bc", "\n", "\r", "\r\n", "é", "😀", "\n\n", "x\ry"]
        let text = NSMutableString(string: "")
        var lines = LineTable(text)
        for _ in 0..<3000 {
            let length = text.length
            let start = Int(random.next() % UInt64(length + 1))
            let removed = length == start ? 0 : Int(random.next() % UInt64(min(6, length - start) + 1))
            let inserted = random.next() % 3 == 0 ? "" : pieces[Int(random.next() % UInt64(pieces.count))]
            let range = NSRange(location: start, length: removed)
            text.replaceCharacters(in: range, with: inserted)
            lines.replace(range, newLength: (inserted as NSString).length, in: text)
            #expect(lines == LineTable(text), "after replacing \(range) with \(inserted.debugDescription) in \(String(text).debugDescription)")
            if lines != LineTable(text) { return }
        }
    }
}

/// A seeded generator, so a failing edit sequence repeats.
struct SplitMix: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
