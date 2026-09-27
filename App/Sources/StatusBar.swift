import IDEModel
import IDEState
import SwiftUI

/// The line under the detail area: the workspace on screen, the link to ompd when it is not up, and the state of the
/// tab on screen (a session's status, a terminal's, the editor's caret and language). The only place these live.
struct StatusBar: View {
    let app: AppState

    var body: some View {
        HStack(spacing: 14) {
            if let strip = app.tabs.selectedStrip {
                Text((strip.workspace as NSString).abbreviatingWithTildeInPath)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .help(strip.workspace)
            }
            connection
            Spacer(minLength: 8)
            if let tab = app.tabs.selection {
                TabState(app: app, tab: tab)
            }
        }
        .font(.system(size: 11))
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .frame(height: Chrome.statusBarHeight)
        .frame(maxWidth: .infinity)
        .background(Chrome.surface)
        .overlay(alignment: .top) { Divider() }
    }

    @ViewBuilder
    private var connection: some View {
        switch app.connection.status {
        case .connecting:
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini)
                Text("Connecting to ompd")
            }
        case .daemonUnavailable:
            HStack(spacing: 5) {
                StatusDot(color: .orange)
                Text("ompd unavailable")
            }
        case .connected:
            EmptyView()
        }
    }
}

private struct TabState: View {
    let app: AppState
    let tab: TabKind

    var body: some View {
        switch tab {
        case .session(let key):
            if let status = app.entry(for: key)?.status {
                SessionStatusBadge(status: status)
            }
        case .terminal(let ptyId):
            if let model = app.terminals.model(ptyId) {
                TerminalState(phase: model.phase, hasExited: model.hasExited)
            }
        case .editor(let path):
            if let document = app.editors.document(for: path) {
                EditorState(document: document)
            }
        }
    }
}

private struct TerminalState: View {
    let phase: TerminalSessionModel.Phase
    let hasExited: Bool

    var body: some View {
        switch phase {
        case .attached where hasExited:
            HStack(spacing: 5) { StatusDot(color: .secondary, hollow: true); Text("Exited") }
        case .attached:
            HStack(spacing: 5) { StatusDot(color: .green); Text("Live") }
        case .attaching:
            HStack(spacing: 5) { ProgressView().controlSize(.mini); Text("Attaching") }
        case .detached:
            HStack(spacing: 5) { StatusDot(color: .orange); Text("Offline") }
        case .failed(let message):
            HStack(spacing: 5) { StatusDot(color: .orange); Text("Unavailable") }.help(message)
        case .gone:
            HStack(spacing: 5) { StatusDot(color: .secondary, hollow: true); Text("Closed") }
        }
    }
}

private struct EditorState: View {
    let document: EditorDocument

    var body: some View {
        HStack(spacing: 14) {
            if let caret = document.caret {
                Text("Ln \(caret.line), Col \(caret.column)")
            }
            if document.isDirty {
                Text("Edited")
            }
            Text(document.language.id == .plainText ? "Plain Text" : document.language.tsName.capitalized)
        }
    }
}

/// A session's status: a spinner while omp works or starts, else a dot, and a word.
struct SessionStatusBadge: View {
    let status: SessionStatus

    var body: some View {
        HStack(spacing: 5) {
            if status.isInProgress {
                ProgressView().controlSize(.mini)
            } else {
                StatusDot(color: status.dotColor, hollow: status == .closed)
            }
            Text(status.label)
        }
        .help(status.explanation)
    }
}

extension SessionStatus {
    /// One word for badges.
    var label: String {
        switch self {
        case .starting: "Starting"
        case .busy: "Working"
        case .idle: "Idle"
        case .interrupted: "Interrupted"
        case .resuming: "Resuming"
        case .closed: "Closed"
        case .needsAttention: "Needs attention"
        case .paused: "Paused"
        }
    }

    /// One sentence for tooltips.
    var explanation: String {
        switch self {
        case .starting: "omp is starting"
        case .busy: "The agent is working"
        case .idle: "omp is waiting for you"
        case .interrupted: "omp stopped unexpectedly; ompd is resuming it"
        case .resuming: "omp is resuming the session"
        case .closed: "Closed: omp is not running for this session"
        case .needsAttention: "omp kept stopping; ompd gave up resuming it"
        case .paused: "Paused: the agents hold at their next step until you dismiss omp's pause screen"
        }
    }

    /// Something runs that ends the status by itself: a spinner rather than a dot.
    var isInProgress: Bool { self == .busy || self == .starting || self == .resuming }

    var dotColor: Color {
        switch self {
        case .idle: .green
        case .interrupted: .orange
        case .needsAttention: .red
        case .paused: .yellow
        case .closed, .starting, .busy, .resuming: .secondary
        }
    }
}
