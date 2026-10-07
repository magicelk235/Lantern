import IDEModel
import SwiftUI

/// A session's state at a glance, one vocabulary for its tab, the status bar, the Agents pane and the Projects pane:
/// red with a count while approvals or questions wait on the user; ember and lit while omp works, with how many
/// subagents run; green idle, yellow paused, orange interrupted or out of ompd's reach, red when omp could not be
/// resumed, hollow once closed; a spinner while omp starts or resumes.
enum SessionIndicator: Equatable {
    /// What waits on the user in the session's TUI, oldest first.
    case waiting([AttentionItem])
    /// The main agent works, or subagents do (`subagents` of them run).
    case working(subagents: Int)
    case starting, resuming, idle, paused, interrupted, needsAttention, closed
    /// ompd is out of reach: what the session does is not known.
    case offline

    init(_ entry: SessionManifestEntry, runtime: SessionRuntime?, connected: Bool) {
        guard connected else {
            self = .offline
            return
        }
        if let attention = runtime?.attention, !attention.isEmpty {
            self = .waiting(attention)
            return
        }
        let subagents = runtime?.runningSubagents ?? 0
        switch entry.status {
        case .busy: self = .working(subagents: subagents)
        case .idle: self = subagents > 0 ? .working(subagents: subagents) : .idle
        case .starting: self = .starting
        case .resuming: self = .resuming
        case .paused: self = .paused
        case .interrupted: self = .interrupted
        case .needsAttention: self = .needsAttention
        case .closed: self = .closed
        }
    }

    /// The status bar's words: "Working", "Waiting for approval: bash", "2 waiting for you".
    var label: String {
        switch self {
        case .waiting(let items): items.count == 1 ? items[0].waitingLine : "\(items.count) waiting for you"
        case .working: SessionStatus.busy.label
        case .offline: "Offline"
        case .starting: SessionStatus.starting.label
        case .resuming: SessionStatus.resuming.label
        case .idle: SessionStatus.idle.label
        case .paused: SessionStatus.paused.label
        case .interrupted: SessionStatus.interrupted.label
        case .needsAttention: SessionStatus.needsAttention.label
        case .closed: SessionStatus.closed.label
        }
    }

    /// The state after a session's title, for tooltips and VoiceOver: "working, 2 subagents", "asking you".
    var words: String {
        switch self {
        case .working(let subagents) where subagents > 0:
            "working, " + (subagents == 1 ? "1 subagent" : "\(subagents) subagents")
        default:
            label.prefix(1).lowercased() + label.dropFirst()
        }
    }

    /// One sentence for the status bar's tooltip.
    var explanation: String {
        switch self {
        case .waiting(let items): "omp waits for you in this tab: " + items.map(\.waitingLine).joined(separator: ", ")
        case .working(let subagents):
            subagents == 0 ? SessionStatus.busy.explanation : "omp is working; " + (subagents == 1 ? "1 subagent runs" : "\(subagents) subagents run")
        case .offline: "ompd is not reachable; the session's state shows again once it is"
        case .starting: SessionStatus.starting.explanation
        case .resuming: SessionStatus.resuming.explanation
        case .idle: SessionStatus.idle.explanation
        case .paused: SessionStatus.paused.explanation
        case .interrupted: SessionStatus.interrupted.explanation
        case .needsAttention: SessionStatus.needsAttention.explanation
        case .closed: SessionStatus.closed.explanation
        }
    }

    var isWorking: Bool {
        if case .working = self { return true }
        return false
    }

    /// The approvals and questions waiting on the user.
    var waitingCount: Int {
        if case .waiting(let items) = self { return items.count }
        return 0
    }
}

extension SessionRuntime {
    /// The subagents omp reports running, at any depth (the main agent's row follows the session instead).
    var runningSubagents: Int {
        agents.count { $0.parentId != nil && $0.status == .running }
    }
}

extension AppState {
    /// The session's state at a glance.
    func indicator(of entry: SessionManifestEntry) -> SessionIndicator {
        SessionIndicator(entry, runtime: connection.runtimes[entry.sessionKey], connected: connection.isConnected)
    }
}

/// A session's state as a mark: what waits on the user as a red count, the lit ember dot and the count of subagents
/// while omp works, a spinner while omp starts or resumes, else a status dot.
struct SessionMark: View {
    let indicator: SessionIndicator

    var body: some View {
        switch indicator {
        case .waiting(let items):
            CountBadge(count: items.count)
        case .working(let subagents):
            HStack(spacing: 4) {
                WorkingDot()
                if subagents > 0 {
                    Text(String(subagents))
                        .font(.system(size: 10, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Chrome.ember)
                }
            }
        case .starting, .resuming: ProgressView().controlSize(.mini)
        case .idle: StatusDot(color: .green)
        case .paused: StatusDot(color: .yellow)
        case .interrupted, .offline: StatusDot(color: .orange)
        case .needsAttention: StatusDot(color: .red)
        case .closed: StatusDot(color: .secondary, hollow: true)
        }
    }
}
