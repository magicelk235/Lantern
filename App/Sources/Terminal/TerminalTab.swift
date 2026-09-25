import AppKit
import IDEModel
import SwiftTerm

/// SwiftTerm's AppKit terminal in the system text colors, following light and dark mode.
final class OmpTerminalView: TerminalView {
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            nativeForegroundColor = .textColor
            nativeBackgroundColor = .textBackgroundColor
        }
    }

    /// Fits the emulator to the view's frame again after something else set its size (the next frame change would).
    func fitToFrame() {
        setFrameSize(frame.size)
    }
}

/// One tab's emulator: shows its endpoint — a terminal's PTY, or an omp session's TUI on whichever PTY omp runs on — and
/// sends it what the user types. Lives as long as the tab, so switching tabs keeps its screen, scrollback and selection.
///
/// Everything a TUI needs passes through SwiftTerm: Ctrl chords, Esc, Option as Meta (per tab kind, see
/// `TerminalSettings`), the kitty keyboard protocol once the program asks for it (Shift+Enter, Ctrl+Enter, ⌥Enter
/// distinct), bracketed paste, mouse reporting, true color and OSC 8 links (⌘-click opens them). OSC 52 writes go to
/// the clipboard; reads are refused.
@MainActor
final class TerminalTab {
    /// Lines kept above the screen, as many as ompd keeps (`TerminalMirror.scrollbackLines`), so a reattach shows
    /// what the view showed.
    static let scrollbackLines = 5_000

    let endpoint: any TerminalEndpoint
    let view: OmpTerminalView
    private let onSize: (TerminalSize) -> Void

    /// `onSize`: the emulator's size whenever it changes.
    init(endpoint: any TerminalEndpoint, font: NSFont, optionAsMeta: Bool, onSize: @escaping (TerminalSize) -> Void) {
        self.endpoint = endpoint
        self.onSize = onSize
        view = OmpTerminalView(frame: .zero, font: font, options: TerminalOptions(scrollback: Self.scrollbackLines))
        view.applyColors()
        view.optionAsMetaKey = optionAsMeta
        view.terminalDelegate = self
        endpoint.attach(to: self)
    }

    /// The emulator's size in cells.
    var size: TerminalSize {
        let terminal = view.getTerminal()
        return TerminalSize(cols: terminal.cols, rows: terminal.rows)
    }

    func setFont(_ font: NSFont) {
        guard view.font != font else { return }
        view.font = font
    }

    func setOptionAsMeta(_ optionAsMeta: Bool) {
        view.optionAsMetaKey = optionAsMeta
    }

    /// The tab closed: ompd stops streaming to it. The PTY keeps running.
    func close() {
        endpoint.detach()
    }
}

extension TerminalTab: TerminalDisplay {
    func reset(size: TerminalSize, screen: Data) {
        let terminal = view.getTerminal()
        // A full reset leaves the alternate screen's old contents for the next program that enters it: switch in and
        // out once (1047 clears it on the way out), so the screen repaints into a truly fresh terminal.
        view.feed(text: "\u{1b}[?1047h\u{1b}[?1047l")
        terminal.resetToInitialState()
        terminal.resize(cols: size.cols, rows: size.rows)
        view.feed(byteArray: ArraySlice(screen))
        view.fitToFrame()
    }

    func feed(_ data: Data) {
        view.feed(byteArray: ArraySlice(data))
    }
}

extension TerminalTab: @preconcurrency TerminalViewDelegate {
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        let size = TerminalSize(cols: newCols, rows: newRows)
        endpoint.resize(size)
        onSize(size)
    }

    func setTerminalTitle(source: TerminalView, title: String) {
        endpoint.programTitle = title.isEmpty ? nil : title
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        // ompd reports the shell's folder in its PTY list, which works without shell integration.
    }

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        endpoint.send(Data(data))
    }

    func scrolled(source: TerminalView, position: Double) {}

    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

    /// OSC 52 from the program (omp copying a message or a code block): onto the general pasteboard.
    func clipboardCopy(source: TerminalView, content: Data) {
        guard let text = String(data: content, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
