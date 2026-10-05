import IDEProtocol

// What omp IDE and its menu-bar extra call a session's status and what waits for the user: one set of
// words for the status bar, the Agents pane and the menu bar.

extension SessionStatus {
    /// One word for badges.
    public var label: String {
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
    public var explanation: String {
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
    public var isInProgress: Bool { self == .busy || self == .starting || self == .resuming }
}

extension AttentionItem {
    /// What it waits on the user for, in a line: "Waiting for approval: bash", "Asking you".
    public var waitingLine: String {
        switch kind {
        case .approval: "Waiting for approval: \(toolName)"
        case .ask: "Asking you"
        }
    }
}
