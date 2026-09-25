/// Command `type`s accepted on omp's stdin (`RpcCommand` in omp 18.3.1 `rpc-types.ts`). omp answers
/// each with a `response` frame; `OmpProcess.send` correlates it. Failure responses to unparseable
/// input use the pseudo-command `"parse"`, which is not listed because it cannot be sent.
public enum OmpCommandName: String, Sendable, CaseIterable, Codable {
    // Prompting
    case prompt
    case steer
    case followUp = "follow_up"
    case abort
    case abortAndPrompt = "abort_and_prompt"
    case newSession = "new_session"
    case openSession = "open_session"
    // Protocol
    case negotiateProtocol = "negotiate_protocol"
    // State
    case getState = "get_state"
    case setFastMode = "set_fast_mode"
    case getAvailableCommands = "get_available_commands"
    case getEntries = "get_entries"
    case getTree = "get_tree"
    case setTodos = "set_todos"
    case setHostTools = "set_host_tools"
    case setHostURISchemes = "set_host_uri_schemes"
    case setSubagentSubscription = "set_subagent_subscription"
    case setEventFilter = "set_event_filter"
    case getSubagents = "get_subagents"
    case getSubagentMessages = "get_subagent_messages"
    // Model
    case setModel = "set_model"
    case cycleModel = "cycle_model"
    case getAvailableModels = "get_available_models"
    // Thinking
    case setThinkingLevel = "set_thinking_level"
    case cycleThinkingLevel = "cycle_thinking_level"
    case getAvailableThinkingLevels = "get_available_thinking_levels"
    // Queue modes
    case setSteeringMode = "set_steering_mode"
    case setFollowUpMode = "set_follow_up_mode"
    case setInterruptMode = "set_interrupt_mode"
    // Compaction
    case compact
    case setAutoCompaction = "set_auto_compaction"
    // Retry
    case setAutoRetry = "set_auto_retry"
    case abortRetry = "abort_retry"
    // Bash
    case bash
    case abortBash = "abort_bash"
    // Session
    case getSessionStats = "get_session_stats"
    case exportHTML = "export_html"
    case switchSession = "switch_session"
    case branch
    case getBranchMessages = "get_branch_messages"
    case getLastAssistantText = "get_last_assistant_text"
    case setSessionName = "set_session_name"
    case handoff
    // Messages
    case getMessages = "get_messages"
    case getMessagesPage = "get_messages_page"
    // Login
    case getLoginProviders = "get_login_providers"
    case login
}

/// Frames the host writes to stdin to answer omp's requests. omp sends no `response` for these;
/// write them with `OmpProcess.sendNoReply`.
public enum OmpHostReplyType: String, Sendable, CaseIterable, Codable {
    /// Answers an `extension_ui_request` (`value`, `confirmed`, or `cancelled`).
    case extensionUIResponse = "extension_ui_response"
    /// Progress for a `host_tool_call`.
    case hostToolUpdate = "host_tool_update"
    /// Completes a `host_tool_call`.
    case hostToolResult = "host_tool_result"
    /// Completes a `host_uri_request`.
    case hostURIResult = "host_uri_result"
}

/// `type`s of the frames omp writes to stdout (omp 18.3.1). Unknown types can appear in newer omp
/// versions; `OmpEventType(rawValue:)` returns nil for them.
public enum OmpEventType: String, Sendable, CaseIterable, Codable {
    // Transport
    case ready
    case response
    /// Protocol-v2 fragment; `RPCFrameDecoder` reassembles these, so `OmpProcess.output` never carries them.
    case rpcChunk = "rpc_chunk"
    /// Replaces a frame that exceeded the transport limit.
    case rpcFrameError = "rpc_frame_error"

    // Session events (`AgentSessionEvent`; the only frames `set_event_filter` can suppress)
    case agentStart = "agent_start"
    case agentEnd = "agent_end"
    case turnStart = "turn_start"
    case turnEnd = "turn_end"
    case messageStart = "message_start"
    case messageUpdate = "message_update"
    case messageEnd = "message_end"
    case toolExecutionStart = "tool_execution_start"
    case toolExecutionUpdate = "tool_execution_update"
    case toolStreamUpdate = "tool_stream_update"
    case toolExecutionEnd = "tool_execution_end"
    case autoCompactionStart = "auto_compaction_start"
    case autoCompactionEnd = "auto_compaction_end"
    case autoRetryStart = "auto_retry_start"
    case autoRetryEnd = "auto_retry_end"
    case retryFallbackApplied = "retry_fallback_applied"
    case retryFallbackSucceeded = "retry_fallback_succeeded"
    case modelChanged = "model_changed"
    case thinkingLevelChanged = "thinking_level_changed"
    case ttsrTriggered = "ttsr_triggered"
    case todoReminder = "todo_reminder"
    case todoAutoClear = "todo_auto_clear"
    case ircMessage = "irc_message"
    case notice
    case goalUpdated = "goal_updated"
    case advisorCostChanged = "advisor_cost_changed"
    case advisorYielded = "advisor_yielded"
    case configWarningsChanged = "config_warnings_changed"

    // Requests the host answers (see `OmpHostReplyType`)
    case extensionUIRequest = "extension_ui_request"
    case hostToolCall = "host_tool_call"
    case hostToolCancel = "host_tool_cancel"
    case hostURIRequest = "host_uri_request"
    case hostURICancel = "host_uri_cancel"

    // Everything else
    case extensionError = "extension_error"
    case availableCommandsUpdate = "available_commands_update"
    case promptResult = "prompt_result"
    case sessionSettled = "session_settled"
    case subagentLifecycle = "subagent_lifecycle"
    case subagentProgress = "subagent_progress"
    case subagentEvent = "subagent_event"
    case commandOutput = "command_output"
    case sessionInfoUpdate = "session_info_update"
    case configUpdate = "config_update"
}

public extension JSONValue {
    /// The frame's `type` discriminator.
    var frameType: String? { self["type"]?.stringValue }
    /// The frame's `id`: the request id on `response`/`prompt_result`, the request id to answer on
    /// `extension_ui_request`/`host_tool_call`/`host_uri_request`.
    var frameId: String? { self["id"]?.stringValue }
}
