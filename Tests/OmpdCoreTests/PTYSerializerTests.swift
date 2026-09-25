import Foundation
import SwiftTerm
import Testing
@testable import OmpdCore

/// Serialization round trips: a terminal fed with raw output and a fresh terminal fed with the serialized
/// screen must hold identical cells, wraps, cursor, pen and modes — and keep evolving identically.
@Suite struct PTYSerializerTests {
    @Test func attributesRoundTrip() {
        let esc = "\u{1b}["
        var text = ""
        for code in 0..<8 { text += "\(esc)\(30 + code)mF\(code)\(esc)\(40 + code)mB\(code)\(esc)0m " }
        for code in 0..<8 { text += "\(esc)\(90 + code)mBF\(esc)\(100 + code)mBB\(esc)0m " }
        text += "\r\n\(esc)38;5;202m256fg\(esc)48;5;17m256bg\(esc)0m \(esc)38;2;10;200;30mtrue\(esc)48;2;1;2;3mcolor\(esc)0m\r\n"
        text += "\(esc)1mbold\(esc)0m \(esc)2mdim\(esc)0m \(esc)3mitalic\(esc)0m \(esc)4munder\(esc)0m \(esc)4:3mcurly\(esc)0m "
        text += "\(esc)21mdouble\(esc)0m \(esc)5mblink\(esc)0m \(esc)7minverse\(esc)0m \(esc)8mhidden\(esc)0m \(esc)9mstrike\(esc)0m\r\n"
        text += "\(esc)4;58;5;196mucolor\(esc)0m \(esc)4;58;2;9;8;7mutrue\(esc)0m \(esc)1;3;4;7;38;5;33;48;2;50;60;70mall\(esc)0m\r\n"
        text += "\(esc)1;35mpen stays set"
        assertRoundTrip(text, cols: 100, rows: 8)
    }

    @Test func scrollbackAndSoftWrapsRoundTrip() {
        var text = ""
        for line in 0..<120 {
            let body = String(repeating: "abcdefghij", count: line % 7) + "|\(line)"
            text += "\u{1b}[3\(line % 8)m\(body)\u{1b}[0m\r\n"
        }
        text += "prompt$ "
        let (original, replay) = assertRoundTrip(text, cols: 40, rows: 10)
        let wrapped = (0..<rowCount(original.terminal)).filter { original.terminal.bufferLine(atRow: $0)!.isWrapped }
        #expect(wrapped.count > 50)
        #expect(rowCount(replay.terminal) > 100)
    }

    @Test func wideCombiningAndBlankCellsRoundTrip() {
        var text = "日本語テキスト e\u{301} 👍🏽 👩‍👩‍👦 ✔︎\r\n"
        text += "gap\u{1b}[10Cafter\u{1b}[44m\u{1b}[K\u{1b}[0m\r\n"             // cursor-forward gap, colored erase
        text += "\u{1b}[41m  red spaces  \u{1b}[0m\u{1b}[5C\u{1b}[42m\u{1b}[3X\u{1b}[3C\u{1b}[0mtail\r\n"
        text += String(repeating: "界", count: 25) + "\r\n"                   // wide chars wrapping at an odd column
        text += "\u{1b}]8;id=1;https://example.com/a\u{7}link\u{1b}]8;;\u{7} plain"
        assertRoundTrip(text, cols: 31, rows: 8)
    }

    @Test func pendingWrapCursorRoundTrips() {
        let (original, replay) = assertRoundTrip("first\r\n" + String(repeating: "x", count: 20), cols: 20, rows: 4)
        #expect(original.terminal.getCursorLocation().x == 20)
        original.feed(Array("Y".utf8))
        replay.feed(Array("Y".utf8))
        assertSameState(original, replay)
    }

    @Test func alternateScreenAndModesRoundTrip() {
        var text = ""
        for line in 0..<30 { text += "\u{1b}[32mhistory \(line)\u{1b}[0m\r\n" }
        text += "$ vim\r\n"
        text += "\u{1b}[?1049h\u{1b}[?1h\u{1b}=\u{1b}[?2004h\u{1b}[?1002h\u{1b}[?1006h\u{1b}[?1004h\u{1b}[>5u\u{1b}[?25l"
        text += "\u{1b}]2;my title\u{7}\u{1b}[H\u{1b}[44m\u{1b}[2J\u{1b}[1;1H\u{1b}[1;33mTUI top\u{1b}[0m"
        text += "\u{1b}[3;15r\u{1b}[20;5Hstatus\u{1b}[5;7H\u{1b}[31m"
        let (original, replay) = assertRoundTrip(text, cols: 50, rows: 20)
        #expect(replay.terminal.isCurrentBufferAlternate)
        #expect(replay.terminal.applicationCursor)
        #expect(replay.terminal.bracketedPasteMode)
        #expect(replay.terminal.mouseMode == .buttonEventTracking)
        #expect(replay.terminal.keyboardEnhancementFlags.rawValue == 5)
        #expect(replay.terminal.buffer.scrollTop == 2 && replay.terminal.buffer.scrollBottom == 14)
        #expect(probe(replay) == probe(original))
        #expect(probe(replay).mouseEncoding == .sgr && probe(replay).focusEvents && probe(replay).applicationKeypad)
        #expect(!probe(replay).cursorVisible)
        #expect(serializedTitle(replay) == "my title")

        // Leaving the alternate screen must reveal the same normal buffer and restore the same cursor.
        let leave = Array("\u{1b}[?1049l\u{1b}[?1l\u{1b}[<u$ next".utf8)
        original.feed(leave)
        replay.feed(leave)
        assertSameState(original, replay)
        #expect(!replay.terminal.isCurrentBufferAlternate)
    }

    @Test func inFlightSequenceIsCarriedToTheReplay() {
        for (head, tail) in [("plain \u{1b}[3", "1mRED\u{1b}[0m"), ("euro \u{e2}\u{82}", "\u{ac} sign"),
                             ("title \u{1b}]2;half", " title\u{7}after"), ("\u{1b}P$", "qm\u{1b}\\text")] {
            let original = TerminalMirror(cols: 30, rows: 5)
            original.feed(latin1(head))
            let replay = TerminalMirror(cols: 30, rows: 5)
            replay.feed([UInt8](original.serialize(includePending: true)))
            original.feed(latin1(tail))
            replay.feed(latin1(tail))
            assertSameState(original, replay)
        }
    }

    @Test func probingDoesNotDisturbTheStream() {
        // Serializing while the alternate screen is active switches buffers and probes modes inside the live
        // terminal; the terminal must continue exactly like one that was never serialized.
        let text = Array("\u{1b}[?1049h\u{1b}[?25l\u{1b}[5;5Hin alt\u{1b}[?1006h".utf8)
        let serialized = TerminalMirror(cols: 30, rows: 6)
        let untouched = TerminalMirror(cols: 30, rows: 6)
        serialized.feed(text)
        untouched.feed(text)
        _ = serialized.serialize(includePending: true)
        let more = Array("X\u{1b}[?1049lback".utf8)
        serialized.feed(more)
        untouched.feed(more)
        assertSameState(serialized, untouched)
        #expect(probe(serialized) == probe(untouched))
    }

    @Test func trackerFollowsParserStates() {
        func tracker(_ chunks: [String]) -> VTStreamTracker {
            var t = VTStreamTracker()
            for chunk in chunks { latin1(chunk).withUnsafeBufferPointer { t.consume($0) } }
            return t
        }
        #expect(tracker(["hello \u{1b}[1;31mred\u{1b}[0m"]).isClean)
        #expect(tracker(["\u{1b}[1;3"]).pendingBytes == latin1("\u{1b}[1;3"))
        #expect(tracker(["\u{1b}[1", "\n;3"]).pendingBytes == latin1("\u{1b}[1;3")) // executed C0 is not replayed
        #expect(tracker(["\u{1b}]0;ti", "tle"]).pendingBytes == latin1("\u{1b}]0;title"))
        #expect(tracker(["\u{1b}]0;title\u{1b}\\"]).isClean)
        #expect(tracker(["\u{e2}\u{82}"]).pendingBytes == [0xe2, 0x82])
        #expect(tracker(["\u{e2}\u{82}", "\u{ac}"]).isClean)
        #expect(tracker(["\u{e2}\u{1b}[m"]).isClean)                              // ESC drops a partial character
        #expect(tracker(["\u{1b}P1;2q#0;2;0;0;0#0!10~"]).state == .dcsPassthrough)
        let long = tracker(["\u{1b}]52;c;" + String(repeating: "A", count: VTStreamTracker.pendingLimit + 10)])
        #expect(long.pendingBytes == latin1("\u{1b}]9999;"))
    }

    // MARK: - Helpers

    @discardableResult
    private func assertRoundTrip(_ text: String, cols: Int, rows: Int, sourceLocation: SourceLocation = #_sourceLocation) -> (TerminalMirror, TerminalMirror) {
        let original = TerminalMirror(cols: cols, rows: rows)
        original.feed(Array(text.utf8))
        let replay = TerminalMirror(cols: cols, rows: rows)
        replay.feed([UInt8](original.serialize(includePending: true)))
        assertSameState(original, replay, sourceLocation: sourceLocation)
        return (original, replay)
    }
}

func rowCount(_ terminal: Terminal) -> Int {
    var count = 0
    while terminal.bufferLine(atRow: count) != nil { count += 1 }
    return count
}

/// Text of every buffer row (scrollback first), NUL cells as spaces, trailing blanks trimmed.
func bufferText(_ terminal: Terminal) -> [String] {
    (0..<rowCount(terminal)).map { row in
        let line = terminal.bufferLine(atRow: row)!
        return line.translateToString(trimRight: true, skipNullCellsFollowingWide: true) { terminal.getCharacter(for: $0) }
            .replacingOccurrences(of: "\u{0}", with: " ")
    }
}

/// Modes of a mirror as reported by its terminal (DECRQM round trip).
func probe(_ mirror: TerminalMirror) -> TerminalModes {
    let previous = mirror.onReply
    var replies: [UInt8] = []
    mirror.onReply = { replies.append(contentsOf: $0) }
    mirror.feed(Array(TerminalModes.probeQuery.utf8))
    mirror.onReply = previous
    return TerminalModes(decrqmReplies: replies)
}

private func serializedTitle(_ mirror: TerminalMirror) -> String? {
    let screen = String(decoding: mirror.serialize(includePending: false), as: UTF8.self)
    guard let start = screen.range(of: "\u{1b}]2;"), let end = screen[start.upperBound...].firstIndex(of: "\u{7}") else { return nil }
    return String(screen[start.upperBound..<end])
}

private func latin1(_ text: String) -> [UInt8] {
    text.unicodeScalars.map { UInt8(truncatingIfNeeded: $0.value) }
}

/// Every cell (text, width, attributes, payload), wrap flag, cursor, pen and the saved cursor must match.
func assertSameState(_ a: TerminalMirror, _ b: TerminalMirror, sourceLocation: SourceLocation = #_sourceLocation) {
    let ta = a.terminal
    let tb = b.terminal
    #expect(rowCount(ta) == rowCount(tb), "row count", sourceLocation: sourceLocation)
    #expect(ta.getTopVisibleRow() == rowCount(ta) - ta.rows, "screen top", sourceLocation: sourceLocation)
    #expect(bufferText(ta) == bufferText(tb), "text", sourceLocation: sourceLocation)
    var mismatches: [String] = []
    for row in 0..<min(rowCount(ta), rowCount(tb)) {
        let la = ta.bufferLine(atRow: row)!
        let lb = tb.bufferLine(atRow: row)!
        if la.isWrapped != lb.isWrapped { mismatches.append("row \(row) wrapped \(la.isWrapped) vs \(lb.isWrapped)") }
        for col in 0..<min(la.count, lb.count) {
            let ca = la[col]
            let cb = lb[col]
            let chA = ta.getCharacter(for: ca)
            let chB = tb.getCharacter(for: cb)
            if chA != chB || ca.width != cb.width || ca.attribute != cb.attribute
                || (ca.getPayload() as? String) != (cb.getPayload() as? String) {
                mismatches.append("row \(row) col \(col): \(chA.debugDescription)/\(ca.width)/\(ca.attribute) vs \(chB.debugDescription)/\(cb.width)/\(cb.attribute)")
            }
        }
    }
    #expect(mismatches.isEmpty, "\(mismatches.prefix(5))", sourceLocation: sourceLocation)
    #expect(ta.getCursorLocation() == tb.getCursorLocation(), "cursor", sourceLocation: sourceLocation)
    #expect(ta.currentAttribute == tb.currentAttribute, "pen", sourceLocation: sourceLocation)
    #expect(ta.buffer.savedX == tb.buffer.savedX && ta.buffer.savedY == tb.buffer.savedY, "saved cursor", sourceLocation: sourceLocation)
    #expect(ta.isCurrentBufferAlternate == tb.isCurrentBufferAlternate, "alternate", sourceLocation: sourceLocation)
}
