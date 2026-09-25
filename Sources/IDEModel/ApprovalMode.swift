/// omp `--approval-mode` for new sessions (approval-mode.md). nil everywhere means "use the omp configuration".
public enum ApprovalMode: String, Sendable, CaseIterable, Identifiable {
    case alwaysAsk = "always-ask"
    case write
    case yolo

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .alwaysAsk: "Always ask"
        case .write: "Ask before running commands"
        case .yolo: "Never ask"
        }
    }

    public var explanation: String {
        switch self {
        case .alwaysAsk: "Prompts before any tool that edits files or runs commands."
        case .write: "Edits apply without asking; commands and other exec tools prompt."
        case .yolo: "Every tool runs without asking."
        }
    }
}
