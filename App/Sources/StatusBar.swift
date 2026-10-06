import IDELanguageModel
import IDEModel
import IDEState
import SwiftUI

/// The line under the detail area: the workspace on screen, the link to ompd when it is not up, and the state of the
/// tab on screen (a session's status, a terminal's, the editor's problems, caret and language). The only place these
/// live.
struct StatusBar: View {
    let app: AppState
    /// The window's project; empty for the window of no project.
    let project: String

    var body: some View {
        HStack(spacing: 14) {
            if !project.isEmpty {
                let path = Self.displayPath(project)
                Text((path as NSString).abbreviatingWithTildeInPath)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .help(path)
            }
            connection
            Spacer(minLength: 8)
            if !project.isEmpty, let tab = app.selectedTab(in: project) {
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

    /// The system's own links at the root (`/tmp`, `/var`, `/etc` into `/private`), by name.
    private static let privateLinks = Set(["tmp", "var", "etc"].filter { AppState.normalized("/" + $0) == "/private/" + $0 })

    /// `path` as the user knows it: through `/tmp` rather than `/private/tmp`, where projects are keyed by their real path
    /// (`AppState.normalized`).
    static func displayPath(_ path: String) -> String {
        let components = path.split(separator: "/", maxSplits: 2)
        guard components.count >= 2, components[0] == "private", privateLinks.contains(String(components[1])) else {
            return path
        }
        return "/" + components.dropFirst().joined(separator: "/")
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
        case .versionMismatch:
            HStack(spacing: 5) {
                StatusDot(color: .orange)
                Text("ompd out of date")
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
            if let hosted = app.adoptedSession(on: ptyId) {
                SessionStatusBadge(status: hosted.status)
            } else if let model = app.terminals.model(ptyId) {
                TerminalState(phase: model.phase, hasExited: model.hasExited)
            }
        case .editor(let path):
            if let document = app.editors.document(for: path) {
                EditorState(document: document, servers: app.editors.languageServers)
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
    let servers: LanguageServers

    var body: some View {
        HStack(spacing: 14) {
            if let language = document.languageDocument {
                LanguageServerState(language: language, status: servers.statuses[language.key])
            }
            if let caret = document.caret {
                Text("Ln \(caret.line), Col \(caret.column)")
                    .modifier(JumpToLineAnchor(document: document, isAnchor: document.content == .text))
            }
            if document.isDirty {
                Text("Edited")
            }
            // A file not shown as text (binary, too large, gone) has no language to speak of.
            if document.content == .text {
                Text(document.language.id == .plainText ? "Plain Text" : document.language.tsName.capitalized)
                    .modifier(JumpToLineAnchor(document: document, isAnchor: document.caret == nil))
            }
        }
    }
}

/// Jump to Line (⌘L) hangs from the status bar's caret position, as Xcode's does; from the language while the caret's
/// line is not known.
private struct JumpToLineAnchor: ViewModifier {
    @Bindable var document: EditorDocument
    let isAnchor: Bool

    func body(content: Content) -> some View {
        content.popover(isPresented: isAnchor ? $document.isJumpingToLine : .constant(false), arrowEdge: .top) {
            JumpToLine(document: document)
        }
    }
}

/// The editor's errors and warnings from its language server, after Xcode's issue icons (nothing when there are none);
/// a quiet note when no server for the language is installed, and when the server stopped.
private struct LanguageServerState: View {
    let language: LanguageDocument
    let status: LanguageServers.Status?

    var body: some View {
        switch status {
        case .running(let name):
            let counts = language.counts
            if !counts.isEmpty {
                HStack(spacing: 8) {
                    if counts.errors > 0 {
                        HStack(spacing: 3) {
                            Image(systemName: "xmark.octagon.fill").foregroundStyle(Color(nsColor: .systemRed))
                            Text("\(counts.errors)")
                        }
                    }
                    if counts.warnings > 0 {
                        HStack(spacing: 3) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color(nsColor: .systemYellow))
                            Text("\(counts.warnings)")
                        }
                    }
                }
                .help("\(Self.describe(counts)) from \(name)")
            }
        case .unavailable(let programs):
            Text("No Language Server")
                .help("Lantern looks for \(programs.joined(separator: " or ")) on your login shell’s PATH.")
        case .failed(let reason):
            HStack(spacing: 5) {
                StatusDot(color: .orange)
                Text("Language Server Stopped")
            }
            .help(reason)
        case .starting, nil:
            EmptyView()
        }
    }

    private static func describe(_ counts: DiagnosticCounts) -> String {
        let errors = counts.errors == 1 ? "1 error" : "\(counts.errors) errors"
        let warnings = counts.warnings == 1 ? "1 warning" : "\(counts.warnings) warnings"
        switch (counts.errors, counts.warnings) {
        case (_, 0): return errors
        case (0, _): return warnings
        default: return "\(errors) and \(warnings)"
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
    /// The dot beside its word.
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
