import AppKit
import IDEModel
import IDEState
import SwiftUI

/// A terminal tab: the emulator filling the detail area, and a bar with Restart once its program ended. Close
/// Terminal (which ends the PTY) lives in the tab's menu and the Session menu.
struct TerminalDetailView: View {
    let app: AppState
    let ptyId: PTYID

    var body: some View {
        if let model = app.terminals.model(ptyId) {
            VStack(spacing: 0) {
                if case .failed(let message) = model.phase {
                    NoticeBar(systemImage: "exclamationmark.triangle", tint: .orange, title: "ompd could not attach this terminal", message: message)
                }
                TerminalPane { app.terminals.emulator(for: ptyId) }
                if model.hasExited {
                    NoticeBar(systemImage: "stop.circle", tint: .secondary, title: "The program exited", rule: .top) {
                        Button("Restart") { app.restartTerminal(ptyId) }
                            .help("Start the program again in the same folder, in this tab")
                    }
                }
            }
        } else {
            ContentUnavailableView("Terminal Closed", systemImage: "terminal", description: Text("ompd no longer has this terminal."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Chrome.canvas)
        }
    }
}

/// Hosts a tab's emulator in the detail area, inset from its edges. The emulator belongs to the tab, not to this view,
/// so it keeps its screen, scrollback and selection while other tabs are shown.
struct TerminalPane: View {
    /// Room around the emulator.
    static let insets = EdgeInsets(top: 8, leading: 10, bottom: 6, trailing: 0)

    /// The tab's emulator, made the first time the pane is shown.
    let emulator: @MainActor () -> TerminalTab

    var body: some View {
        TerminalHostView(emulator: emulator)
            .padding(Self.insets)
            .background(Chrome.canvas)
    }

    /// The points an emulator gets in a pane `size` big.
    static func emulatorSize(in size: CGSize) -> CGSize {
        CGSize(width: size.width - insets.leading - insets.trailing, height: size.height - insets.top - insets.bottom)
    }
}

struct TerminalHostView: NSViewRepresentable {
    let emulator: @MainActor () -> TerminalTab

    func makeNSView(context: Context) -> TerminalHostingView {
        TerminalHostingView(emulator: emulator())
    }

    func updateNSView(_ nsView: TerminalHostingView, context: Context) {}
}

/// Where a tab's emulator shows while the host is in a window (`TerminalTab.host(in:)`): the emulator has one view, and
/// a second window SwiftUI opens for the same project gets a host of its own until it closes again.
final class TerminalHostingView: NSView {
    private let emulator: TerminalTab
    private var closeObserver: (any NSObjectProtocol)?

    init(emulator: TerminalTab) {
        self.emulator = emulator
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopWatchingWindow()
        guard let window else {
            emulator.unhost(self)
            return
        }
        // A window that closes may keep its views: the emulator's view leaves with the window, not with the view.
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) {
            [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.stopWatchingWindow()
                self.emulator.unhost(self)
            }
        }
        emulator.host(in: self)
    }

    /// Shows the emulator's view, filling the host; typing goes to it.
    func embed(_ terminal: NSView) {
        terminal.removeFromSuperview()
        terminal.translatesAutoresizingMaskIntoConstraints = false
        addSubview(terminal)
        NSLayoutConstraint.activate([
            terminal.leadingAnchor.constraint(equalTo: leadingAnchor),
            terminal.trailingAnchor.constraint(equalTo: trailingAnchor),
            terminal.topAnchor.constraint(equalTo: topAnchor),
            terminal.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        window?.makeFirstResponder(terminal)
    }

    private func stopWatchingWindow() {
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = nil
    }
}
