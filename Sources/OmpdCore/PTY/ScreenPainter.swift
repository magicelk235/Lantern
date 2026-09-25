import SwiftTerm

/// Accumulates the VT byte stream of a repaint and tracks the SGR pen / OSC 8 link of the replaying terminal,
/// so attributes are only emitted when they change.
struct VTWriter {
    var bytes: [UInt8] = []
    /// SGR state of the replaying terminal; nil = default attributes.
    private var pen: Attribute?
    /// Open OSC 8 hyperlink payload (`params;uri`), nil = none.
    private var link: String?

    init() {
        bytes.reserveCapacity(64 * 1024)
    }

    mutating func append(_ text: String) { bytes.append(contentsOf: text.utf8) }
    mutating func csi(_ body: String) { bytes.append(0x1b); bytes.append(0x5b); append(body) }
    mutating func osc(_ body: String) { bytes.append(0x1b); bytes.append(0x5d); append(body); bytes.append(0x07) }
    mutating func newline() { bytes.append(0x0d); bytes.append(0x0a) }

    var penBackgroundIsDefault: Bool { pen.map { $0.bg == .defaultColor } ?? true }

    mutating func setPen(_ attribute: Attribute) {
        if let pen {
            if pen == attribute { return }
        } else if ScreenPainter.isDefault(attribute) {
            return
        }
        if ScreenPainter.isDefault(attribute) {
            csi("0m")
            pen = nil
        } else {
            csi(ScreenPainter.sgr(attribute))
            pen = attribute
        }
    }

    mutating func resetPen() {
        if pen != nil { csi("0m"); pen = nil }
    }

    mutating func setLink(_ payload: String?) {
        guard payload != link else { return }
        osc("8;" + (payload ?? ";"))
        link = payload
    }
}

/// Serializes SwiftTerm buffers into VT sequences that rebuild them in a fresh terminal of the same size:
/// scrollback + screen lines (soft wraps preserved by printing wrapped rows to the last column), per-cell SGR
/// attributes (16/256/truecolor, bold/dim/italic/underline styles/blink/inverse/invisible/strike, underline
/// color), OSC 8 links, cursor position (including a pending wrap), scroll region, saved cursor and modes.
enum ScreenPainter {
    // MARK: Active buffer

    static func paintActiveBuffer(_ terminal: Terminal, modes: TerminalModes, cursorStyleSet: Bool, into w: inout VTWriter) {
        let cols = terminal.cols
        let rows = terminal.rows
        let screenTop = paintLines(terminal, into: &w)
        w.setLink(nil)
        let buffer = terminal.buffer

        if buffer.savedX != 0 || buffer.savedY != 0 || !isDefault(buffer.savedAttr) {
            w.csi("\(min(buffer.savedY, rows - 1) + 1);\(min(buffer.savedX, cols - 1) + 1)H")
            w.setPen(buffer.savedAttr)
            w.bytes.append(contentsOf: [0x1b, 0x37]) // DECSC
        }
        if buffer.scrollTop != 0 || buffer.scrollBottom != rows - 1 {
            w.csi("\(buffer.scrollTop + 1);\(buffer.scrollBottom + 1)r")
        }
        if modes.marginMode {
            w.csi("?69h")
            if buffer.marginLeft != 0 || buffer.marginRight != cols - 1 {
                w.csi("\(buffer.marginLeft + 1);\(buffer.marginRight + 1)s")
            }
        }
        if modes.originMode { w.csi("?6h") }

        // Cursor. x == cols means a pending wrap: re-print the last cell so the next character wraps.
        let (x, y) = terminal.getCursorLocation()
        let rowOrigin = modes.originMode ? buffer.scrollTop : 0
        let colOrigin = modes.originMode && modes.marginMode ? buffer.marginLeft : 0
        func moveCursor(row: Int, col: Int) {
            w.csi("\(max(row - rowOrigin, 0) + 1);\(max(col - colOrigin, 0) + 1)H")
        }
        if x >= cols, let line = terminal.bufferLine(atRow: screenTop + y), line.count >= cols {
            var lead = cols - 1
            if lead > 0, line[lead].width == 0, line[lead - 1].width == 2 { lead -= 1 }
            let cell = line[lead]
            moveCursor(row: y, col: lead)
            if !isNull(cell) {
                w.setLink(payload(of: cell))
                w.setPen(cell.attribute)
                w.bytes.append(contentsOf: character(of: cell, in: terminal).utf8)
                w.setLink(nil)
            }
        } else {
            moveCursor(row: y, col: min(x, cols - 1))
        }
        w.setPen(terminal.currentAttribute)

        // Modes that change how the remote side encodes input or how output is interpreted.
        if terminal.applicationCursor { w.csi("?1h") }
        if modes.applicationKeypad { w.bytes.append(contentsOf: [0x1b, 0x3d]) } // DECKPAM
        if modes.reverseVideo { w.csi("?5h") }
        if !modes.autowrap { w.csi("?7l") }
        if modes.reverseWraparound { w.csi("?45h") }
        if modes.insertMode { w.csi("4h") }
        if modes.lineFeedMode { w.csi("20h") }
        switch terminal.mouseMode {
        case .off: break
        case .x10: w.csi("?9h")
        case .vt200: w.csi("?1000h")
        case .buttonEventTracking: w.csi("?1002h")
        case .anyEvent: w.csi("?1003h")
        }
        switch modes.mouseEncoding {
        case .x10: break
        case .utf8: w.csi("?1005h")
        case .sgr: w.csi("?1006h")
        case .urxvt: w.csi("?1015h")
        case .sgrPixel: w.csi("?1016h")
        }
        if modes.focusEvents { w.csi("?1004h") }
        if !terminal.alternateScrollMode { w.csi("?1007l") }
        if terminal.bracketedPasteMode { w.csi("?2004h") }
        if modes.cursorBlink { w.csi("?12h") }
        if cursorStyleSet { w.csi("\(decscusr(terminal.options.cursorStyle)) q") }
        if !modes.cursorVisible { w.csi("?25l") }
        let keyboardFlags = terminal.keyboardEnhancementFlags.rawValue
        if keyboardFlags != 0 { w.csi(">\(keyboardFlags)u") }
    }

    // MARK: Normal buffer while the alternate screen is active

    /// Paints the normal buffer (must be the active buffer) and leaves the replay positioned so that the
    /// following `CSI ? 1049 h` saves the cursor the program will return to on leaving the alternate screen.
    static func paintNormalBufferUnderAlternate(_ terminal: Terminal, into w: inout VTWriter) {
        let cols = terminal.cols
        let rows = terminal.rows
        _ = paintLines(terminal, into: &w)
        w.setLink(nil)
        let buffer = terminal.buffer
        if buffer.scrollTop != 0 || buffer.scrollBottom != rows - 1 {
            w.csi("\(buffer.scrollTop + 1);\(buffer.scrollBottom + 1)r")
        }
        w.csi("\(min(buffer.savedY, rows - 1) + 1);\(min(buffer.savedX, cols - 1) + 1)H")
        w.setPen(buffer.savedAttr)
        let keyboardFlags = terminal.keyboardEnhancementFlags.rawValue
        if keyboardFlags != 0 { w.csi(">\(keyboardFlags)u") }
    }

    /// Fallback when the parser is mid-sequence and buffers cannot be switched: plain text of the normal buffer.
    static func paintNormalBufferAsText(_ terminal: Terminal, into w: inout VTWriter) {
        let text = String(decoding: terminal.getBufferAsData(kind: .normal), as: UTF8.self)
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.last?.isEmpty == true { lines.removeLast() }
        w.resetPen()
        for (index, line) in lines.enumerated() {
            if index > 0 { w.newline() }
            w.append(line.replacingOccurrences(of: "\u{0}", with: " "))
        }
        let screen = lines.suffix(terminal.rows)
        let lastUsed = screen.lastIndex { !$0.allSatisfy { $0 == " " || $0 == "\u{0}" } }
        let row = lastUsed.map { min($0 - screen.startIndex + 1, terminal.rows - 1) } ?? 0
        w.csi("\(row + 1);1H")
    }

    // MARK: Lines and cells

    /// Paints every line of the active buffer (scrollback first). Returns the buffer row of the screen top.
    @discardableResult
    static func paintLines(_ terminal: Terminal, into w: inout VTWriter) -> Int {
        let cols = terminal.cols
        var lines: [BufferLine] = []
        while let line = terminal.bufferLine(atRow: lines.count) { lines.append(line) }

        for (row, line) in lines.enumerated() {
            let joinedToPrevious = row > 0 && continues(line)
            let joinsNext = row + 1 < lines.count && continues(lines[row + 1])
            if row > 0 && !joinedToPrevious {
                // A line feed that scrolls fills the new row with the current background: keep it default.
                if !w.penBackgroundIsDefault { w.resetPen() }
                w.newline()
            }
            let nextStartsWide = joinsNext && lines[row + 1].count > 0 && lines[row + 1][0].width == 2
            paintCells(line, terminal: terminal, cols: cols, joinedToPrevious: joinedToPrevious, joinsNext: joinsNext,
                       nextStartsWide: nextStartsWide, into: &w)
        }
        return max(lines.count - terminal.rows, 0)
    }

    /// A soft-wrapped continuation that the replay reproduces by auto-wrapping into it.
    private static func continues(_ line: BufferLine) -> Bool {
        line.isWrapped && line.hasAnyContent()
    }

    /// `joinsNext`: the next row continues this one, so the replay must end this row in the pending-wrap state,
    /// or — when the next row starts with a wide character that did not fit — on the last column.
    private static func paintCells(_ line: BufferLine, terminal: Terminal, cols: Int, joinedToPrevious: Bool, joinsNext: Bool,
                                   nextStartsWide: Bool, into w: inout VTWriter) {
        let width = min(line.count, cols)
        var end = width
        if !joinsNext {
            while end > 0 && !line.hasContent(index: end - 1) { end -= 1 }
        }
        // Until something is printed on a continuation row the replay is still in the pending-wrap state of
        // the previous row: blanks must be printed (a cursor movement would cancel the wrap).
        var mustPrint = joinedToPrevious
        var wrapBackground: Attribute.Color?
        var col = 0
        while col < end {
            let cell = line[col]
            let character = self.character(of: cell, in: terminal)
            if character == "\u{0}" {
                let attribute = cell.attribute
                var runEnd = col + 1
                while runEnd < end, isNull(line[runEnd]), line[runEnd].attribute == attribute { runEnd += 1 }
                let count = runEnd - col
                w.setLink(nil)
                let trailingBeforeWrap = joinsNext && runEnd == end
                if mustPrint || !isErasable(attribute) || (trailingBeforeWrap && !nextStartsWide) {
                    if mustPrint { wrapBackground = attribute.bg }
                    w.setPen(attribute)
                    w.bytes.append(contentsOf: repeatElement(0x20, count: count))
                    mustPrint = false
                } else {
                    if !isDefault(attribute) {
                        // ECH fills with the pen's background and code 0, exactly like the original erase.
                        w.setPen(attribute)
                        w.csi("\(count)X")
                    }
                    // Before a wide character that wrapped, stop on the last column: printing it wraps again.
                    let advance = trailingBeforeWrap ? count - 1 : count
                    if advance > 0 { w.csi(advance == 1 ? "C" : "\(advance)C") }
                }
                col = runEnd
                continue
            }
            if mustPrint { wrapBackground = cell.attribute.bg; mustPrint = false }
            w.setLink(payload(of: cell))
            w.setPen(cell.attribute)
            w.bytes.append(contentsOf: character.utf8)
            col += max(Int(cell.width), 1)
        }
        // Auto-wrapping into this row scrolled in a blank row filled with the first cell's background;
        // clear what the original row leaves empty.
        if let wrapBackground, wrapBackground != .defaultColor, !joinsNext, end < width {
            w.setLink(nil)
            w.resetPen()
            w.csi("K")
        }
    }

    // MARK: Attributes

    static func isNull(_ cell: CharData) -> Bool {
        cell.isSimpleRune && cell.getCharacter() == "\u{0}"
    }

    /// The cell's text; NUL for a never-written (or erased) cell.
    private static func character(of cell: CharData, in terminal: Terminal) -> Character {
        cell.isSimpleRune ? cell.getCharacter() : terminal.getCharacter(for: cell)
    }

    static func isDefault(_ a: Attribute) -> Bool {
        a.fg == .defaultColor && a.bg == .defaultColor && a.style.isEmpty && a.underlineStyle == .none && a.underlineColor == nil
    }

    /// Attributes an erase operation produces (default foreground, no style): reproducible with ECH.
    private static func isErasable(_ a: Attribute) -> Bool {
        a.fg == .defaultColor && a.style.isEmpty && a.underlineStyle == .none && a.underlineColor == nil
            && a.bg != .defaultInvertedColor
    }

    private static func payload(of cell: CharData) -> String? {
        cell.hasPayload ? cell.getPayload() as? String : nil
    }

    static func sgr(_ a: Attribute) -> String {
        var p = "0"
        let s = a.style
        if s.contains(.bold) { p += ";1" }
        if s.contains(.dim) { p += ";2" }
        if s.contains(.italic) { p += ";3" }
        if s.contains(.underline) {
            switch a.underlineStyle {
            case .none, .single: p += ";4"
            case .double: p += ";4:2"
            case .curly: p += ";4:3"
            case .dotted: p += ";4:4"
            case .dashed: p += ";4:5"
            }
        }
        if s.contains(.blink) { p += ";5" }
        if s.contains(.inverse) { p += ";7" }
        if s.contains(.invisible) { p += ";8" }
        if s.contains(.crossedOut) { p += ";9" }
        p += color(a.fg, base: 30, bright: 90, extended: 38)
        p += color(a.bg, base: 40, bright: 100, extended: 48)
        if let underline = a.underlineColor { p += color(underline, base: nil, bright: nil, extended: 58) }
        return p + "m"
    }

    private static func color(_ c: Attribute.Color, base: Int?, bright: Int?, extended: Int) -> String {
        switch c {
        case .ansi256(let code):
            if let base, code < 8 { return ";\(base + Int(code))" }
            if let bright, code < 16 { return ";\(bright + Int(code) - 8)" }
            return ";\(extended);5;\(code)"
        case .trueColor(let r, let g, let b):
            return ";\(extended);2;\(r);\(g);\(b)"
        case .defaultColor, .defaultInvertedColor:
            return ""
        }
    }

    private static func decscusr(_ style: CursorStyle) -> Int {
        switch style {
        case .blinkBlock: 1
        case .steadyBlock: 2
        case .blinkUnderline: 3
        case .steadyUnderline: 4
        case .blinkBar: 5
        case .steadyBar: 6
        }
    }
}
