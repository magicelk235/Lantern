import IDEEditorModel
import IDELanguageModel
import IDEModel
import IDEState
import SwiftUI

/// The line under the detail area: the workspace on screen, "Connecting to ompd" while the app connects, and the state
/// of the tab on screen (a session's status, a terminal's, the editor's problems, caret and language). An ompd out of
/// reach or out of date is the window's banner, and the tabs it leaves without a state say Offline.
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
        .foregroundStyle(.chromeSecondary)
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

    /// While the app connects; once an attempt failed, the window's banner says why (`StatusBanners`, `OutdatedDaemonBar`).
    @ViewBuilder
    private var connection: some View {
        if case .connecting = app.connection.status {
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini)
                Text("Connecting to ompd")
            }
        }
    }
}

private struct TabState: View {
    let app: AppState
    let tab: TabKind

    var body: some View {
        switch tab {
        case .session(let key):
            if let entry = app.entry(for: key) {
                SessionStatusBadge(indicator: app.indicator(of: entry))
            }
        case .terminal(let ptyId):
            if let hosted = app.adoptedSession(on: ptyId) {
                SessionStatusBadge(indicator: app.indicator(of: hosted))
            } else if let model = app.terminals.model(ptyId) {
                TerminalState(phase: model.phase, hasExited: model.hasExited, isTranscript: app.purpose(ofTerminal: ptyId)?.isTranscript == true)
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
    /// Open Transcript's: drawn once, then done, which is no state to report.
    let isTranscript: Bool

    var body: some View {
        switch phase {
        case .attached where hasExited:
            if !isTranscript { HStack(spacing: 5) { StatusDot(color: .secondary, hollow: true); Text("Exited") } }
        case .attached:
            HStack(spacing: 5) { StatusDot(color: Chrome.green); Text("Live") }
        case .attaching:
            HStack(spacing: 5) { ProgressView().controlSize(.mini); Text("Attaching") }
        case .detached:
            HStack(spacing: 5) { StatusDot(color: Chrome.orange, hollow: true); Text("Offline") }
        case .failed(let message):
            HStack(spacing: 5) { WarningMark(); Text("Unavailable") }.help(message)
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
            if let media = document.media {
                MediaState(media: media)
            }
            if let language = document.languageDocument {
                LanguageServerState(language: language, status: servers.statuses[language.key]) { servers.restart(language.key) }
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
                Text(document.languageName)
                    .modifier(JumpToLineAnchor(document: document, isAnchor: document.caret == nil))
            }
        }
    }
}

/// What a media tab shows: "1024 × 768 · 33 KB · PNG", "0:18 · 1920 × 1080 · 868 KB · MP4", and an image's or PDF's
/// zoom.
private struct MediaState: View {
    let media: MediaViewer

    var body: some View {
        if !media.details.isEmpty {
            Text(media.details.joined(separator: " · "))
        }
        if let scale = media.scale {
            Text("\(Int((scale * 100).rounded()))%")
                .monospacedDigit()
                .help(media.fitsWindow ? "Fit to the window. View › Actual Size (⌘0) shows it at its own size." : "View › Actual Size (⌘0) toggles between its own size and fitting the window.")
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
/// a quiet note when no server for the language is installed, and when the server stopped, with Restart beside it.
private struct LanguageServerState: View {
    let language: LanguageDocument
    let status: LanguageServers.Status?
    let restart: () -> Void

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
                .help(Self.missing(programs, of: language.key.server))
        case .failed(let reason):
            HStack(spacing: 5) {
                WarningMark()
                Text("Language Server Stopped")
                    .help(reason)
                Button("Restart", action: restart)
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                    .help("Start the language server again")
            }
        case .starting, nil:
            EmptyView()
        }
    }

    /// Where Lantern looked for the server's program: on the login shell's `PATH`, or for a user's server whose command
    /// names a path, at that path.
    private static func missing(_ programs: [String], of server: LanguageServerChoice) -> String {
        guard case .custom = server else {
            return "Lantern looks for \(programs.joined(separator: " or ")) on your login shell’s PATH."
        }
        guard let program = programs.first, !program.isEmpty else {
            return "The server’s command in Settings › Languages is empty or has an unclosed quote."
        }
        guard !program.contains("/") else {
            return "No program at \(program). Settings › Languages takes a full path or a name on the PATH."
        }
        return "Lantern looks for \(program) on your login shell’s PATH (Settings › Languages)."
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

/// A session's state in words beside its mark: "Working" in ember beside the lit dot, what waits on the user (in
/// primary) beside a red dot or the interruption's triangle, a spinner while omp starts or resumes.
struct SessionStatusBadge: View {
    let indicator: SessionIndicator

    var body: some View {
        HStack(spacing: 5) {
            switch indicator {
            case .waiting: StatusDot(color: .red)
            case .working: WorkingDot()
            default: SessionMark(indicator: indicator)
            }
            Text(indicator.label)
                .foregroundStyle(word)
        }
        .help(indicator.explanation)
    }

    private var word: AnyShapeStyle {
        switch indicator {
        case .working: AnyShapeStyle(Chrome.ember)
        case .waiting, .unfinished: AnyShapeStyle(.primary)
        default: AnyShapeStyle(.chromeSecondary)
        }
    }
}
