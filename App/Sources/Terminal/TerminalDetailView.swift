import AppKit
import IDEModel
import IDEState
import SwiftUI

/// A terminal tab: the emulator filling the detail area, "[process exited]" with a Restart button once its program
/// ended, and Close Terminal (which ends the PTY) in the toolbar.
struct TerminalDetailView: View {
    let app: AppState
    let ptyId: PTYID
    @State private var confirmingClose = false

    var body: some View {
        if let model = app.terminals.model(ptyId) {
            VStack(spacing: 0) {
                if case .failed(let message) = model.phase {
                    Banner(systemImage: "exclamationmark.triangle", tint: .orange, title: "ompd could not attach this terminal", message: message)
                }
                TerminalPane { app.terminals.emulator(for: ptyId) }
                if model.hasExited {
                    ExitedBar { app.restartTerminal(ptyId) }
                }
            }
            .navigationTitle(app.terminals.title(for: ptyId))
            .navigationSubtitle(model.info.map { ($0.cwd as NSString).abbreviatingWithTildeInPath } ?? "")
            .toolbar {
                ToolbarItem(placement: .status) {
                    TerminalStatus(phase: model.phase, hasExited: model.hasExited)
                }
                ToolbarItem {
                    Button("Close Terminal", systemImage: "xmark.circle") {
                        if model.hasExited { app.closeTerminal(ptyId) } else { confirmingClose = true }
                    }
                    .help("End the shell and everything running in it")
                    .disabled(!app.connection.isConnected)
                }
            }
            .confirmationDialog("Close this terminal?", isPresented: $confirmingClose) {
                Button("Close Terminal", role: .destructive) { app.closeTerminal(ptyId) }
            } message: {
                Text("The shell and every program running in it are ended.")
            }
        } else {
            ContentUnavailableView("Terminal Closed", systemImage: "terminal", description: Text("ompd no longer has this terminal."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Hosts a tab's emulator in the detail area, inset from its edges. The emulator belongs to the tab, not to this view,
/// so it keeps its screen, scrollback and selection while other tabs are shown.
struct TerminalPane: View {
    /// Room around the emulator.
    static let insets = EdgeInsets(top: 4, leading: 6, bottom: 4, trailing: 0)

    /// The tab's emulator, made the first time the pane is shown.
    let emulator: @MainActor () -> TerminalTab

    var body: some View {
        TerminalHostView(emulator: emulator)
            .padding(Self.insets)
            .background(Color(nsColor: .textBackgroundColor))
    }

    /// The points an emulator gets in a pane `size` big.
    static func emulatorSize(in size: CGSize) -> CGSize {
        CGSize(width: size.width - insets.leading - insets.trailing, height: size.height - insets.top - insets.bottom)
    }
}

struct TerminalHostView: NSViewRepresentable {
    let emulator: @MainActor () -> TerminalTab

    func makeNSView(context: Context) -> TerminalHostingView {
        TerminalHostingView(terminal: emulator().view)
    }

    func updateNSView(_ nsView: TerminalHostingView, context: Context) {}
}

final class TerminalHostingView: NSView {
    private let terminal: NSView

    init(terminal: NSView) {
        self.terminal = terminal
        super.init(frame: .zero)
        terminal.removeFromSuperview()
        terminal.translatesAutoresizingMaskIntoConstraints = false
        addSubview(terminal)
        NSLayoutConstraint.activate([
            terminal.leadingAnchor.constraint(equalTo: leadingAnchor),
            terminal.trailingAnchor.constraint(equalTo: trailingAnchor),
            terminal.topAnchor.constraint(equalTo: topAnchor),
            terminal.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Typing goes to the terminal on screen.
        if let window, terminal.superview === self { window.makeFirstResponder(terminal) }
    }
}

private struct ExitedBar: View {
    let restart: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text("[process exited]")
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.secondary)
            Spacer()
            Button("Restart", systemImage: "arrow.clockwise", action: restart)
                .help("Start the program again in the same folder, in this tab")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

private struct TerminalStatus: View {
    let phase: TerminalSessionModel.Phase
    let hasExited: Bool

    var body: some View {
        switch phase {
        case .attached where hasExited:
            Label("Exited", systemImage: "stop.circle").foregroundStyle(.secondary)
        case .attached:
            Label("Live", systemImage: "terminal").foregroundStyle(.secondary)
        case .attaching:
            Label("Attaching…", systemImage: "arrow.clockwise").foregroundStyle(.secondary)
        case .detached:
            Label("Offline", systemImage: "wifi.slash").foregroundStyle(.secondary)
        case .failed(let message):
            Label("Unavailable", systemImage: "exclamationmark.triangle").foregroundStyle(.orange).help(message)
        case .gone:
            Label("Closed", systemImage: "xmark.circle").foregroundStyle(.secondary)
        }
    }
}

// MARK: - Sidebar

/// A workspace's terminals in the sidebar, selectable as their tab.
struct TerminalRows: View {
    let app: AppState
    let terminals: [PTYInfo]

    var body: some View {
        ForEach(terminals, id: \.ptyId) { info in
            TerminalRow(info: info, title: app.terminals.title(for: info.ptyId))
                .tag(TabKind.terminal(info.ptyId))
                .contextMenu {
                    Button("Close Terminal") { app.closeTerminal(info.ptyId) }
                        .disabled(!app.connection.isConnected)
                }
        }
    }
}

private struct TerminalRow: View {
    let info: PTYInfo
    let title: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "terminal")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .lineLimit(1)
                Text(info.running ? (info.cwd as NSString).abbreviatingWithTildeInPath : "exited")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }
        .opacity(info.running ? 1 : 0.55)
        .help(info.cwd)
    }
}

/// Header of a sidebar workspace that has terminals but no sessions.
struct TerminalWorkspaceHeader: View {
    let app: AppState
    let path: String

    var body: some View {
        let name = URL(filePath: path, directoryHint: .isDirectory).lastPathComponent
        Label(name.isEmpty ? path : name, systemImage: "folder")
            .help(path)
            .contextMenu {
                Button("New Terminal Here") { app.newTerminal(in: path) }
                    .disabled(!app.connection.isConnected)
            }
    }
}
