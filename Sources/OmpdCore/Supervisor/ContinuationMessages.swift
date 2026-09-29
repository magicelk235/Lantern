import Foundation
import IDEProtocol

/// The model-visible messages that tell a resumed agent it was interrupted. omp keeps the
/// interrupted calls out of the resumed context, and without being told the model either redoes the
/// request (repeating a call with side effects) or claims it finished; so every message names the calls and asks for
/// their effects to be checked first.
enum ContinuationMessages {
    /// For the main agent, delivered as a user prompt (`session.prompt`). `continuedAgents` were asked to continue
    /// just before, their results reach the main agent the usual way; `leftAgents` were not.
    static func main(_ interruption: Interruption, continuedAgents: [String], leftAgents: [String]) -> String {
        var lines = [
            "[omp IDE] Your omp process ended while you were in the middle of a turn (\(interruption.cause)), and this session was resumed from its file."
        ]
        lines += pendingLines(interruption.pendingToolCalls)
        if !continuedAgents.isEmpty {
            lines.append("")
            lines.append("These subagents were interrupted too and have been asked to continue; their results will be delivered to you: \(continuedAgents.joined(separator: ", ")).")
        }
        if !leftAgents.isEmpty {
            lines.append("")
            lines.append("These subagents were interrupted and were not asked to continue: \(leftAgents.joined(separator: ", ")). Revive one with `write agent://<id>` if you still need its result.")
        }
        if interruption.evalKernelsLost {
            lines.append("")
            lines.append("Eval kernels restarted empty: variables and imports from before are gone; reload what you need.")
        }
        lines.append("")
        lines.append("Check the effects of anything that may not have completed before re-running it, re-read pending todos, and continue.")
        return lines.joined(separator: "\n")
    }

    /// For an interrupted subagent, delivered like `write agent://<id>` (`agent.message`, which revives it).
    static func agent(_ agent: InterruptedAgent, cause: String) -> String {
        var lines = ["[omp IDE] Your omp process ended (\(cause)) before you finished your assignment, and you were revived from your transcript."]
        lines += pendingLines(agent.pendingToolCalls)
        lines.append("")
        lines.append("Check the effects of anything that may not have completed before re-running it, then finish your assignment.")
        return lines.joined(separator: "\n")
    }

    /// After a wake from sleep, for a turn whose model stream stalled and was aborted.
    static let wake = "[omp IDE] The machine slept and the model stream made no progress after it woke, so your turn was aborted. Check whether your last tool calls completed, then continue where you left off."

    private static func pendingLines(_ calls: [InterruptedToolCall]) -> [String] {
        guard !calls.isEmpty else { return [] }
        return ["", "These tool calls may not have completed (they may have had side effects):"]
            + calls.map { "- \($0.toolName): \($0.summary)" }
    }
}
