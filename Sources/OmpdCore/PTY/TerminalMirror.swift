import Foundation
import SwiftTerm

/// Headless SwiftTerm terminal fed with every output chunk of one PTY. It is the source of the
/// serialized screen used by `pty.attach` and by snapshots. Not thread-safe: owned by `PTYPool`'s isolation.
final class TerminalMirror {
    /// Scrollback kept per PTY (lines above the visible screen).
    static let scrollbackLines = 5_000

    let terminal: Terminal
    private let delegate: MirrorDelegate
    private var tracker = VTStreamTracker()
    /// Result of the last DECRQM probe; used when the parser is mid-sequence and cannot be probed.
    private var lastModes = TerminalModes()

    /// Replies the terminal generates for queries in the stream (DA, DSR/CPR, DECRQM, kitty `CSI ? u`, …).
    var onReply: ((ArraySlice<UInt8>) -> Void)? {
        get { delegate.onReply }
        set { delegate.onReply = newValue }
    }

    init(cols: Int, rows: Int) {
        delegate = MirrorDelegate()
        let options = TerminalOptions(cols: cols, rows: rows, scrollback: Self.scrollbackLines)
        terminal = Terminal(delegate: delegate, options: options)
        terminal.silentLog = true
    }

    var cols: Int { terminal.cols }
    var rows: Int { terminal.rows }

    /// Feeds one chunk exactly as read from the PTY (the tracker must see the same chunking as the parser).
    func feed(_ bytes: UnsafeBufferPointer<UInt8>) {
        guard !bytes.isEmpty else { return }
        tracker.consume(bytes)
        terminal.feed(buffer: ArraySlice(bytes))
    }

    func feed(_ bytes: [UInt8]) {
        bytes.withUnsafeBufferPointer { feed($0) }
    }

    func resize(cols: Int, rows: Int) {
        terminal.resize(cols: cols, rows: rows)
    }

    /// VT byte stream that repaints scrollback, screen, cursor, attributes and terminal modes into a fresh
    /// terminal of `cols`×`rows`. With `includePending`, the bytes of an escape sequence or UTF-8 character that
    /// is still in flight are appended, so live output that follows continues seamlessly.
    func serialize(includePending: Bool) -> Data {
        var writer = VTWriter()
        let probing = tracker.isClean
        if probing { lastModes = probeModes() }
        let modes = lastModes

        if !delegate.title.isEmpty { writer.osc("2;" + delegate.title) }
        if !delegate.iconTitle.isEmpty { writer.osc("1;" + delegate.iconTitle) }
        if let cwd = terminal.hostCurrentDirectory { writer.osc("7;" + cwd) }

        if terminal.isCurrentBufferAlternate {
            if probing {
                // `CSI ? 47 l/h` switches buffers without clearing or moving the cursor: read the normal buffer
                // with full attributes, then switch back. Both switches force the cursor visible; restore it.
                terminal.feed(text: "\u{1b}[?47l")
                ScreenPainter.paintNormalBufferUnderAlternate(terminal, into: &writer)
                terminal.feed(text: "\u{1b}[?47h")
                if !modes.cursorVisible { terminal.feed(text: "\u{1b}[?25l") }
            } else {
                ScreenPainter.paintNormalBufferAsText(terminal, into: &writer)
            }
            writer.csi("?1049h")
            writer.csi("H")
        }
        ScreenPainter.paintActiveBuffer(terminal, modes: modes, cursorStyleSet: delegate.cursorStyleSet, into: &writer)

        if includePending { writer.bytes.append(contentsOf: tracker.pendingBytes) }
        return Data(writer.bytes)
    }

    /// Queries modes SwiftTerm keeps private via DECRQM, capturing the replies. Only valid when `tracker.isClean`.
    private func probeModes() -> TerminalModes {
        delegate.captured = []
        terminal.feed(text: TerminalModes.probeQuery)
        let replies = delegate.captured ?? []
        delegate.captured = nil
        return TerminalModes(decrqmReplies: replies)
    }
}

/// Terminal modes that are not exposed by SwiftTerm's public API, as reported by DECRQM.
struct TerminalModes: Equatable {
    enum MouseEncoding: Equatable { case x10, utf8, sgr, urxvt, sgrPixel }

    var reverseVideo = false        // ?5
    var originMode = false          // ?6
    var autowrap = true             // ?7
    var cursorBlink = false         // ?12
    var cursorVisible = true        // ?25
    var reverseWraparound = false   // ?45
    var applicationKeypad = false   // ?66
    var marginMode = false          // ?69
    var focusEvents = false         // ?1004
    var mouseEncoding = MouseEncoding.x10 // ?1005 ?1006 ?1015 ?1016
    var insertMode = false          // 4
    var lineFeedMode = false        // 20

    private static let decModes = [5, 6, 7, 12, 25, 45, 66, 69, 1004, 1005, 1006, 1015, 1016]
    private static let ansiModes = [4, 20]

    static let probeQuery: String =
        decModes.map { "\u{1b}[?\($0)$p" }.joined() + ansiModes.map { "\u{1b}[\($0)$p" }.joined()

    init() {}

    /// Parses `CSI ? Ps ; Pm $ y` / `CSI Ps ; Pm $ y` replies (Pm 1 = set, 3 = permanently set).
    init(decrqmReplies bytes: [UInt8]) {
        var dec: [Int: Bool] = [:]
        var ansi: [Int: Bool] = [:]
        var i = 0
        while i + 1 < bytes.count {
            guard bytes[i] == 0x1b, bytes[i + 1] == UInt8(ascii: "[") else { i += 1; continue }
            var j = i + 2
            let isDEC = j < bytes.count && bytes[j] == UInt8(ascii: "?")
            if isDEC { j += 1 }
            var params: [Int] = [0]
            while j < bytes.count, bytes[j] == UInt8(ascii: ";") || (bytes[j] >= 0x30 && bytes[j] <= 0x39) {
                if bytes[j] == UInt8(ascii: ";") { params.append(0) } else { params[params.count - 1] = params[params.count - 1] * 10 + Int(bytes[j] - 0x30) }
                j += 1
            }
            if j + 1 < bytes.count, bytes[j] == UInt8(ascii: "$"), bytes[j + 1] == UInt8(ascii: "y"), params.count == 2 {
                let set = params[1] == 1 || params[1] == 3
                if isDEC { dec[params[0]] = set } else { ansi[params[0]] = set }
                i = j + 2
            } else {
                i = j
            }
        }
        reverseVideo = dec[5] ?? false
        originMode = dec[6] ?? false
        autowrap = dec[7] ?? true
        cursorBlink = dec[12] ?? false
        cursorVisible = dec[25] ?? true
        reverseWraparound = dec[45] ?? false
        applicationKeypad = dec[66] ?? false
        marginMode = dec[69] ?? false
        focusEvents = dec[1004] ?? false
        if dec[1006] == true { mouseEncoding = .sgr }
        else if dec[1016] == true { mouseEncoding = .sgrPixel }
        else if dec[1015] == true { mouseEncoding = .urxvt }
        else if dec[1005] == true { mouseEncoding = .utf8 }
        insertMode = ansi[4] ?? false
        lineFeedMode = ansi[20] ?? false
    }
}

/// Minimal delegate: routes query replies, records the title and whether a program changed the cursor style.
private final class MirrorDelegate: TerminalDelegate {
    var onReply: ((ArraySlice<UInt8>) -> Void)?
    /// Non-nil while probing: replies are captured instead of being routed.
    var captured: [UInt8]?
    var title = ""
    var iconTitle = ""
    var cursorStyleSet = false

    func send(source: Terminal, data: ArraySlice<UInt8>) {
        if captured != nil {
            captured!.append(contentsOf: data)
        } else {
            onReply?(data)
        }
    }

    func setTerminalTitle(source: Terminal, title: String) { self.title = title }
    func setTerminalIconTitle(source: Terminal, title: String) { iconTitle = title }
    func cursorStyleChanged(source: Terminal, newStyle: CursorStyle) { cursorStyleSet = true }
}
