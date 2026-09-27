import IDEModel
import IDEState
import SwiftUI

/// A session tab: omp's own TUI in a terminal emulator, following omp from PTY to PTY. While the TUI is not
/// live, a bar under the last screen says why and offers Resume or Close Session; before the tab showed anything, a
/// placeholder does.
struct SessionTabView: View {
    let app: AppState
    let sessionKey: SessionKey

    var body: some View {
        if let session = app.connection.openSessions[sessionKey] {
            let notice = SessionNotice(
                session: session, connected: app.connection.isConnected,
                daemonMessage: app.connection.notices.last { $0.sessionKey == sessionKey }?.message)
            VStack(spacing: 0) {
                ZStack {
                    TerminalPane { app.terminals.emulator(for: session) }
                    if !session.hasScreen, let notice {
                        SessionPlaceholder(notice: notice, perform: perform)
                    }
                }
                if session.hasScreen, let notice {
                    NoticeBar(
                        systemImage: notice.systemImage, tint: notice.tint, title: notice.title, message: notice.message,
                        inProgress: notice.inProgress, rule: .top
                    ) {
                        ForEach(notice.actions, id: \.self) { action in
                            Button(action.title) { perform(action) }
                        }
                    }
                }
            }
        }
    }

    private func perform(_ action: SessionNotice.Action) {
        switch action {
        case .resume: app.resumeSession(sessionKey)
        case .closeSession: app.requestCloseSession(sessionKey)
        case .forget: app.requestForgetSession(sessionKey)
        case .closeTab: app.closeTab(.session(sessionKey))
        }
    }
}

/// Why omp's TUI is not live in a session tab, and what the user can do about it.
struct SessionNotice {
    enum Action: Hashable {
        case resume, closeSession, forget, closeTab

        var title: String {
            switch self {
            case .resume: "Resume"
            case .closeSession: "Close Session"
            case .forget: "Remove Session…"
            case .closeTab: "Close Tab"
            }
        }
    }

    var title: String
    var message: String
    var systemImage: String
    var tint: Color
    /// Something is under way that ends it by itself: a spinner instead of the icon.
    var inProgress = false
    var actions: [Action] = []

    /// nil while the TUI is live. `daemonMessage`: ompd's latest notice about the session.
    @MainActor
    init?(session: SessionTerminal, connected: Bool, daemonMessage: String?) {
        guard connected else {
            self.init(
                "Offline", "ompd is not reachable; the tab reconnects by itself. omp keeps running.", "bolt.horizontal.circle",
                .orange, inProgress: true)
            return
        }
        guard let entry = session.entry else {
            self.init("Unknown Session", "ompd does not list this session.", "questionmark.circle", .secondary, actions: [.closeTab])
            return
        }
        guard !session.isLive else { return nil }
        switch entry.status {
        case .closed:
            self.init(
                entry.closedByUser ? "Session Closed" : "omp Exited",
                entry.isResumable
                    ? "Resume starts omp again with this conversation."
                    : entry.sessionFileIsGone ? "Its session file is gone; it cannot be resumed." : "ompd has no session file to resume it from.",
                "stop.circle", .secondary, actions: entry.isResumable ? [.resume, .closeTab] : [.forget, .closeTab])
        case .interrupted:
            self.init(
                "omp Stopped Unexpectedly", "ompd is starting it again with this conversation.", "exclamationmark.triangle",
                .orange, inProgress: true)
        case .needsAttention:
            self.init(
                "omp Could Not Be Resumed", daemonMessage ?? "It stopped again right after every restart.",
                "exclamationmark.octagon", .red, actions: entry.isResumable ? [.resume, .forget] : [.forget])
        case .resuming:
            self.init("Resuming…", "ompd is starting omp again with this conversation.", "arrow.clockwise", .secondary, inProgress: true)
        case .starting:
            self.init("Starting omp…", "", "terminal", .secondary, inProgress: true)
        case .busy, .idle, .paused:
            // omp runs; its TUI is not on screen (yet).
            switch session.terminal?.phase {
            case .failed(let message):
                self.init("Could Not Show omp", message, "exclamationmark.triangle", .orange, actions: [.closeTab])
            case .gone:
                self.init("omp's Terminal Ended", "Waiting for ompd…", "terminal", .secondary, inProgress: true)
            case .attached where session.terminal?.hasExited == true:
                self.init("omp Exited", "Waiting for ompd…", "terminal", .secondary, inProgress: true)
            case .attached, .attaching, .detached, nil:
                self.init("Connecting to omp…", "", "terminal", .secondary, inProgress: true)
            }
        }
    }

    private init(
        _ title: String, _ message: String, _ systemImage: String, _ tint: Color, inProgress: Bool = false,
        actions: [Action] = []
    ) {
        self.title = title
        self.message = message
        self.systemImage = systemImage
        self.tint = tint
        self.inProgress = inProgress
        self.actions = actions
    }
}

/// The notice in place of the terminal, before the tab showed anything of the session.
private struct SessionPlaceholder: View {
    let notice: SessionNotice
    let perform: (SessionNotice.Action) -> Void

    var body: some View {
        ContentUnavailableView {
            if notice.inProgress {
                ProgressView().controlSize(.large)
                Text(notice.title)
            } else {
                Label(notice.title, systemImage: notice.systemImage)
            }
        } description: {
            if !notice.message.isEmpty { Text(notice.message) }
        } actions: {
            ForEach(notice.actions, id: \.self) { action in
                Button(action.title) { perform(action) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Chrome.canvas)
    }
}

