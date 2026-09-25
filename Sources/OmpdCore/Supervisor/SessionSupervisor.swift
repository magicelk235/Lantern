import Darwin
import Foundation
import IDEProtocol

/// Owns one IDE session (`SessionKey`): its journal, and the `omp --mode rpc-ui` process currently serving it.
/// It spawns omp from the manifest's `LaunchSpec`, drains every frame into the journal, mirrors
/// status/pending dialogs/identity into the manifest, forwards client commands, and stops omp the graceful way
/// (stdin EOF, never SIGTERM first: signals orphan tool children).
public actor SessionSupervisor {
    public nonisolated let sessionKey: SessionKey
    public nonisolated let journal: Journal

    public enum StartMode: Sendable, Equatable {
        /// A new omp session.
        case fresh
        /// `--resume <sessionFile>` of the manifest entry; the ownership lock is taken before spawning.
        case resume
    }

    public enum StopIntent: Sendable, Equatable {
        /// The user closed the session: `closedByUser`, status `closed`, ownership released.
        case user
        /// The daemon is going away; the session resumes at its next start.
        case daemonShutdown
    }

    private let context: SupervisorContext

    // omp process
    private var process: OmpProcess?
    /// Bumped per spawn; work tied to an older process is dropped.
    private var generation = 0
    private var spawnedAt = Date.distantPast
    private var drainTask: Task<Void, Never>?
    private var bridgeEventsTask: Task<Void, Never>?
    private var startTask: Task<Void, any Error>?
    private var stopping: StopIntent?
    private var bridgeInfo: BridgeSessionInfo?

    // Session state mirrored into the manifest
    private var status: SessionStatus
    private var tracker: PendingRequestTracker
    private var deadlineTask: Task<Void, Never>?
    /// Accepted prompts without a `prompt_result` yet, by omp request id.
    private var openPrompts: [String] = []

    // Ownership
    private var lock: (any SessionLockHandle)?
    private var lockedFile: String?
    private var ownershipTask: Task<Void, any Error>?
    private var warnedNoBridgeForFirstPrompt = false

    // Drain barrier: lets a caller wait until the frames before a response are journaled.
    private var drainedResponses: Set<String> = []
    private var drainedOrder: [String] = []
    private var responseWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var draining = false

    private var journalClosed = false

    /// Frames the journal skips: the handshake and answers to pure queries. They carry no transcript content, and a
    /// `get_entries`/`get_state` answer can be megabytes (a snapshot would bloat the journal on every rebuild).
    static let unjournaledResponses: Set<String> = [
        "negotiate_protocol", "get_state", "get_entries", "get_tree", "get_messages", "get_messages_page",
        "get_subagents", "get_subagent_messages", "get_session_stats", "get_available_commands",
        "get_available_models", "get_available_thinking_levels", "get_branch_messages", "get_last_assistant_text",
        "get_login_providers", "set_subagent_subscription",
    ]
    /// Commands that rebind omp to another session file; they abort a live run (rpc.md), so never while busy.
    static let sessionSwitchingCommands: Set<String> = ["open_session", "switch_session", "new_session"]
    /// Commands that can be a session's first prompt (ensureOnDisk + ownership first).
    static let promptCommands: Set<String> = ["prompt", "abort_and_prompt"]
    private static let drainedMemory = 512

    /// Opens the session's journal. `entry` is the session's current manifest entry.
    public init(entry: SessionManifestEntry, context: SupervisorContext) throws {
        sessionKey = entry.sessionKey
        journal = try Journal(directory: context.journalDirectory, sessionKey: entry.sessionKey)
        self.context = context
        status = entry.status
        tracker = PendingRequestTracker(restoring: entry.pending)
    }

    // MARK: - Queries

    /// omp is running and not being stopped.
    public var isLive: Bool { process != nil && stopping == nil }

    public var currentStatus: SessionStatus { status }

    /// Pid of the running omp, if any.
    public var pid: Int32? {
        get async { await process?.pid }
    }

    // MARK: - Start

    /// Spawns omp and returns once the session is ready: RPC `ready`, subagent subscription, identity from
    /// `get_state`, and the bridge `hello` (or its timeout, after which the session runs without bridge features).
    /// Joins a start already in progress; a no-op while omp runs. On failure the session is `needs_attention` with
    /// a journaled notice explaining why.
    public func start(_ mode: StartMode, notice: String? = nil) async throws {
        if let startTask { return try await startTask.value }
        guard process == nil else { return }
        let task = Task { try await self.launch(mode, notice: notice) }
        startTask = task
        defer { startTask = nil }
        try await task.value
    }

    /// Hands over an ownership lock the daemon already took for `sessionFile` (adopting a session with
    /// `session.open` checks ownership before creating anything).
    public func adoptLock(_ handle: any SessionLockHandle, sessionFile: String) {
        releaseLock()
        lock = handle
        lockedFile = sessionFile
    }

    /// Regime B2: the daemon restarted and this session's omp is gone. Pending dialogs of the dead
    /// process are abandoned; the session is resumed from its file, started afresh if it never had one, or left
    /// `needs_attention` if its file vanished.
    public func restoreAfterDaemonStart() async {
        guard let entry = await context.manifest.entry(sessionKey), !entry.closedByUser else { return }
        // The manifest is authoritative for what the dead omp left pending.
        tracker = PendingRequestTracker(restoring: entry.pending)
        await abandonPending()
        do {
            if let file = entry.sessionFile, FileManager.default.fileExists(atPath: file) {
                try await start(.resume, notice: "ompd restarted; resuming the omp session from \(file).")
            } else if let file = entry.sessionFile, entry.lastSettledAt != nil {
                await journalNotice("error", "The omp session file \(file) is missing; the session cannot be resumed.")
                await setStatus(.needsAttention)
            } else {
                try await start(.fresh, notice: "ompd restarted; the session had no saved history, so a new omp session was started.")
            }
        } catch {
            supervisorLog.error("session \(self.sessionKey, privacy: .public): restore failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func launch(_ mode: StartMode, notice: String?) async throws {
        guard let entry = await context.manifest.entry(sessionKey) else {
            throw DaemonError(.noSuchSession, "no such session: \(sessionKey)")
        }
        guard Self.isDirectory(entry.workspace) else {
            await journalNotice("error", "The workspace folder \(entry.workspace) does not exist; locate it to resume the session.")
            await setStatus(.needsAttention)
            throw DaemonError(.badParams, "workspace does not exist: \(entry.workspace)")
        }
        var resumeFile: String?
        if mode == .resume {
            guard let file = entry.sessionFile, FileManager.default.fileExists(atPath: file) else {
                await journalNotice("error", "The omp session file \(entry.sessionFile ?? "(unknown)") is missing; the session cannot be resumed.")
                await setStatus(.needsAttention)
                throw DaemonError(.badParams, "session file does not exist: \(entry.sessionFile ?? "(unknown)")")
            }
            if lockedFile != file {
                do {
                    try acquireLock(sessionFile: file, sessionId: entry.sessionId)
                } catch {
                    await journalNotice("error", "Cannot resume: \(error)")
                    await setStatus(.needsAttention)
                    throw error
                }
            }
            resumeFile = file
        }

        await setStatus(mode == .resume ? .resuming : .starting, always: true)
        if let notice { await journalNotice("info", notice) }

        var environment = context.baseEnvironment
        environment.merge(entry.launch.env) { $1 }
        environment["PI_RPC_EMIT_TITLE"] = "1"
        environment.merge(await context.bridge.prepareSpawn(of: sessionKey)) { $1 }
        let process = OmpProcess(launch: OmpLaunch(
            executable: entry.launch.ompPath,
            arguments: Self.arguments(for: entry.launch, bridgeExtension: context.bridgeExtension, resume: resumeFile),
            environment: environment, currentDirectory: entry.workspace))
        generation += 1
        let generation = generation
        let spawnedAt = Date()
        do {
            _ = try await process.start(readyTimeout: context.timings.ready)
        } catch {
            await context.bridge.forget(sessionKey)
            await recordFailedStart(process, error: error)
            throw DaemonError(.ompError, "omp did not start: \(error)")
        }
        let pid = await process.pid ?? 0
        self.process = process
        self.spawnedAt = spawnedAt
        stopping = nil
        openPrompts = []
        await journalDaemon(.spawned(pid: pid, ompVersion: entry.launch.ompVersion, resumed: resumeFile != nil), durable: true)
        await context.bridge.spawned(sessionKey, pid: pid)
        draining = true
        drainTask = Task { await self.drain(process) }

        do {
            _ = try await process.send(["type": "set_subagent_subscription", "level": "events"])
        } catch {
            await journalNotice("warning", "Subagent frames are not journaled: set_subagent_subscription failed: \(error)")
        }
        var isSettled: Bool?
        do {
            let state = try await process.send(["type": "get_state"])["data"]
            isSettled = state?["isSettled"]?.boolValue
            await adoptIdentity(from: state)
        } catch {
            await journalNotice("warning", "get_state failed after start: \(error)")
        }
        do {
            let info = try await context.bridge.hello(sessionKey, timeout: context.timings.hello)
            if generation == self.generation, self.process != nil {
                bridgeInfo = info
                let events = await context.bridge.events(sessionKey)
                bridgeEventsTask = Task { await self.journalBridgeEvents(events, generation: generation) }
            }
        } catch {
            if generation == self.generation, self.process != nil {
                await journalNotice(
                    "warning",
                    "The ide-bridge extension did not connect (\(error)); agent tree, ensureOnDisk and bridge features are unavailable for this omp process.")
            }
        }
        if generation == self.generation, self.process != nil, status == .starting || status == .resuming {
            await setStatus(isSettled == false ? .busy : .settled)
        }
    }

    /// omp never became ready: journal what it printed and how it ended.
    private func recordFailedStart(_ process: OmpProcess, error: any Error) async {
        for await output in process.output {
            switch output {
            case .frame: break
            case .stderr(let text): await append(.stderr, ["text": .string(text)], durable: false)
            case .exited(let exit):
                await journalDaemon(.exited(code: exit.code, signal: exit.signal, sessionExitKind: nil), durable: true)
            }
        }
        await journalNotice("error", "omp failed to start: \(error)")
        await setStatus(.needsAttention)
    }

    static func arguments(for launch: LaunchSpec, bridgeExtension: String?, resume sessionFile: String?) -> [String] {
        var arguments = ["--mode", launch.mode]
        if let directory = launch.sessionDir { arguments += ["--session-dir", directory] }
        if let mode = launch.approvalMode { arguments += ["--approval-mode", mode] }
        if let model = launch.model { arguments += ["--model", model] }
        if let bridgeExtension { arguments += ["-e", bridgeExtension] }
        if let sessionFile { arguments += ["--resume", sessionFile] }
        return arguments + launch.extraArgs
    }

    // MARK: - Stop

    /// Graceful stop: closes omp's stdin and keeps draining until it exits (omp records
    /// `session_exit {kind:"normal"}` and kills its tool children); SIGKILL only if it is still alive after
    /// `timings.stop`. Returns once the exit is journaled.
    public func stop(_ intent: StopIntent) async {
        if let startTask { _ = try? await startTask.value }
        if intent == .user {
            // Before EOF: a daemon crash mid-close must not resume a session the user closed.
            await updateEntry { $0.closedByUser = true }
        }
        guard let process, let drainTask else {
            if intent == .user {
                releaseLock()
                await setStatus(.closed)
            }
            return
        }
        if stopping == nil || intent == .user { stopping = intent }
        await process.closeStdin()
        let deadline = context.timings.stop
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await drainTask.value }
            group.addTask {
                do { try await Task.sleep(for: deadline) } catch { return }
                await self.killStraggler(process, after: deadline)
            }
            await group.next()
            group.cancelAll()
        }
    }

    private func killStraggler(_ process: OmpProcess, after deadline: Duration) async {
        guard self.process === process else { return }
        await journalNotice("warning", "omp did not exit within \(deadline) of stdin EOF; killing it.")
        await process.signal(SIGKILL)
    }

    // MARK: - Commands

    /// omp RPC passthrough: sends `command` (any client `id` is replaced) and returns omp's response
    /// `data` (`null` when it has none). A session's first prompt is preceded by `session.ensureOnDisk` and taking
    /// ownership; session-switching commands are refused while the session is busy.
    public func command(_ command: JSONValue) async throws -> JSONValue {
        guard case .object(var fields) = command, let type = fields["type"]?.stringValue else {
            throw DaemonError(.badParams, "an omp command is a JSON object with a string \"type\"")
        }
        fields["id"] = nil
        let process = try await liveProcess()
        if Self.sessionSwitchingCommands.contains(type), status == .busy {
            throw DaemonError(.sessionBusy, "\(type) would abort the running turn; wait until the session is settled")
        }
        if Self.promptCommands.contains(type) { try await ensureOwnership() }
        let response = try await Self.mapOmpErrors { try await process.send(.object(fields)) }
        if Self.sessionSwitchingCommands.contains(type) { await refreshIdentity(process) }
        return response["data"] ?? .null
    }

    /// Answers a pending `extension_ui_request` (`extension_ui_response`) or `host_tool_call` (`host_tool_result`).
    /// `response` is the answer without `type`/`id`.
    public func respond(requestId: String, response: JSONValue) async throws {
        guard case .object(var fields) = response else {
            throw DaemonError(.badParams, "a UI response is a JSON object")
        }
        let process = try await liveProcess()
        let pending = tracker.pending
        let type: String
        if pending.hostToolCalls.contains(where: { $0.frameId == requestId }) {
            type = OmpHostReplyType.hostToolResult.rawValue
        } else if pending.uiRequests.contains(where: { $0.frameId == requestId }) {
            type = OmpHostReplyType.extensionUIResponse.rawValue
        } else {
            throw DaemonError(.badParams, "no pending UI request \(requestId) (already answered, withdrawn or expired)")
        }
        fields["type"] = .string(type)
        fields["id"] = .string(requestId)
        let frame = JSONValue.object(fields)
        try await Self.mapOmpErrors { try await process.sendNoReply(frame) }
        if tracker.observe(sentToOmp: frame) {
            await journalDaemon(.uiAnswered(requestId: requestId), durable: true)
            await pendingChanged()
        }
    }

    /// Full-state rebuild (`session.snapshot`): omp's `get_state` and `get_entries` plus the journal seq they are
    /// consistent with — every frame omp wrote before the `get_entries` answer has a seq ≤ `lastSeq`, every later
    /// one a greater seq. Not running: no state, just `lastSeq`.
    public func snapshot() async throws -> (state: JSONValue?, entries: JSONValue?, lastSeq: Seq) {
        if let startTask { _ = try? await startTask.value }
        guard let process, stopping == nil else { return (nil, nil, await journal.lastSeq) }
        let state = try await Self.mapOmpErrors { try await process.send(["type": "get_state"]) }
        let entries = try await Self.mapOmpErrors { try await process.send(["type": "get_entries"]) }
        if let id = entries.frameId { await awaitDrained(id) }
        return (state["data"], entries["data"], await journal.lastSeq)
    }

    /// After a wake from sleep: asks omp for `get_state` and journals how it answered.
    public func healthCheck() async {
        guard let process, stopping == nil else { return }
        let timeout = context.timings.healthCheck
        let started = ContinuousClock.now
        let outcome: Result<JSONValue, any Error>? = await withTaskGroup(of: Result<JSONValue, any Error>?.self) { group in
            group.addTask {
                do { return .success(try await process.send(["type": "get_state"])) } catch { return .failure(error) }
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        let elapsed = ContinuousClock.now - started
        switch outcome {
        case .success(let response)?:
            let state = response["data"]
            func flag(_ key: String) -> String {
                state?[key]?.boolValue.map { $0 ? "yes" : "no" } ?? "?"
            }
            let milliseconds = Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
            await journalNotice(
                "info",
                "Wake health check: omp answered get_state in \(milliseconds) ms (streaming: \(flag("isStreaming")), settled: \(flag("isSettled")), pending async work: \(flag("hasPendingAsyncWork"))).")
        case .failure(let error)?:
            await journalNotice("warning", "Wake health check: get_state failed: \(error)")
        case nil:
            await journalNotice("warning", "Wake health check: omp did not answer get_state within \(timeout).")
        }
    }

    // MARK: - Persistence hooks

    /// Records the journal's `lastSeq` in the manifest (sleep, shutdown).
    public func persistLastSeq() async {
        let lastSeq = await journal.lastSeq
        await updateEntry { $0.lastSeq = lastSeq }
    }

    /// Flushes the journal to stable storage.
    public func syncJournal() async {
        guard !journalClosed else { return }
        try? await journal.sync()
    }

    /// Flushes and closes the journal (daemon exit); nothing is journaled afterwards.
    public func closeJournal() async {
        guard !journalClosed else { return }
        journalClosed = true
        do {
            try await journal.close()
        } catch {
            supervisorLog.error("session \(self.sessionKey, privacy: .public): closing the journal failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Draining

    private func drain(_ process: OmpProcess) async {
        for await output in process.output {
            switch output {
            case .frame(let frame): await handle(frame)
            case .stderr(let text): await append(.stderr, ["text": .string(text)], durable: false)
            case .exited(let exit): await handleExit(exit, of: process)
            }
        }
        draining = false
        let waiters = responseWaiters
        responseWaiters = [:]
        for continuation in waiters.values.joined() { continuation.resume() }
    }

    private func handle(_ frame: JSONValue) async {
        let type = frame.frameType
        if type != OmpEventType.ready.rawValue,
           !(type == OmpEventType.response.rawValue && Self.unjournaledResponses.contains(frame["command"]?.stringValue ?? ""))
        {
            await append(.omp, frame, durable: Journal.isDurableBoundary(ompFrame: frame))
        }
        if tracker.observe(ompFrame: frame, receivedAt: Date()) { await pendingChanged() }
        switch type {
        case OmpEventType.response.rawValue:
            if let command = frame["command"]?.stringValue, Self.promptCommands.contains(command),
               frame["success"]?.boolValue == true, let id = frame.frameId,
               frame["data"]?["agentInvoked"]?.boolValue != false
            {
                openPrompts.append(id)
                await setStatus(.busy)
            }
            if let id = frame.frameId { markDrained(id) }
        case OmpEventType.agentStart.rawValue:
            await setStatus(.busy)
        case OmpEventType.promptResult.rawValue:
            if let id = frame.frameId { openPrompts.removeAll { $0 == id } }
            if frame["sessionSettled"]?.boolValue == true { await setStatus(.settled) }
        case OmpEventType.sessionSettled.rawValue:
            await setStatus(.settled, settledAt: Date())
        case OmpEventType.sessionInfoUpdate.rawValue:
            if let title = frame["title"]?.stringValue, !title.isEmpty { await setTitle(title) }
        case OmpEventType.extensionUIRequest.rawValue:
            if frame["method"]?.stringValue == "setTitle", let title = frame["title"]?.stringValue, !title.isEmpty {
                await setTitle(title)
            }
        default:
            break
        }
    }

    /// omp is gone: journal the exit (with the `session_exit` kind omp recorded, if any), complete every open
    /// prompt with a synthesized aborted `prompt_result` (omp emits none on exit), abandon pending
    /// dialogs, and settle the session's status.
    private func handleExit(_ exit: OmpExit, of process: OmpProcess) async {
        guard self.process === process else { return }
        let sessionFile = await context.manifest.entry(sessionKey)?.sessionFile ?? bridgeInfo?.sessionFile
        let exitKind = sessionFile.flatMap { SessionFileTail.sessionExitKind(path: $0, recordedSince: spawnedAt) }
        await journalDaemon(.exited(code: exit.code, signal: exit.signal, sessionExitKind: exitKind), durable: true)
        for id in openPrompts {
            await append(
                .omp, ["type": "prompt_result", "id": .string(id), "status": "aborted", "synthesized": true], durable: true)
        }
        openPrompts = []
        await abandonPending()
        bridgeEventsTask?.cancel()
        bridgeEventsTask = nil
        await context.bridge.forget(sessionKey)
        bridgeInfo = nil
        self.process = nil
        drainTask = nil
        switch stopping {
        case .user?:
            releaseLock()
            await setStatus(.closed)
        case .daemonShutdown?:
            await persistLastSeq()
        case nil:
            await journalNotice("error", "omp exited unexpectedly (\(exit)).")
            await setStatus(.interrupted)
        }
    }

    private func journalBridgeEvents(_ events: AsyncStream<JSONValue>, generation: Int) async {
        for await event in events {
            guard generation == self.generation else { return }
            await append(.bridge, event, durable: false)
        }
    }

    private func markDrained(_ id: String) {
        if let waiters = responseWaiters.removeValue(forKey: id) {
            for continuation in waiters { continuation.resume() }
            return
        }
        drainedResponses.insert(id)
        drainedOrder.append(id)
        if drainedOrder.count > Self.drainedMemory { drainedResponses.remove(drainedOrder.removeFirst()) }
    }

    /// Returns once the drain loop has processed the response frame `id` (and so everything omp wrote before it).
    private func awaitDrained(_ id: String) async {
        if drainedResponses.remove(id) != nil {
            drainedOrder.removeAll { $0 == id }
            return
        }
        guard draining else { return }
        await withCheckedContinuation { responseWaiters[id, default: []].append($0) }
    }

    // MARK: - Ownership

    private func liveProcess() async throws -> OmpProcess {
        if let startTask { _ = try? await startTask.value }
        guard let process, stopping == nil else {
            throw DaemonError(.ompError, "session \(sessionKey) has no running omp (status \(status.rawValue))")
        }
        return process
    }

    /// Before a new session's first prompt: `session.ensureOnDisk` through the bridge (the prompt would otherwise
    /// live only in memory until omp's first reply), then the ownership lock.
    private func ensureOwnership() async throws {
        guard lock == nil else { return }
        if let ownershipTask { return try await ownershipTask.value }
        let task = Task { try await self.takeOwnershipBeforeFirstPrompt() }
        ownershipTask = task
        defer { ownershipTask = nil }
        try await task.value
    }

    private func takeOwnershipBeforeFirstPrompt() async throws {
        if bridgeInfo != nil {
            do {
                _ = try await context.bridge.call(
                    sessionKey, method: "session.ensureOnDisk", params: [:], timeout: context.timings.bridgeCall)
            } catch {
                await journalNotice(
                    "warning", "session.ensureOnDisk failed before the first prompt (\(error)); it is lost if omp dies before replying.")
            }
        } else if !warnedNoBridgeForFirstPrompt {
            warnedNoBridgeForFirstPrompt = true
            await journalNotice(
                "warning", "Without the ide-bridge the first prompt is not saved before omp replies; it is lost if omp dies first.")
        }
        let entry = await context.manifest.entry(sessionKey)
        guard lock == nil, let file = entry?.sessionFile ?? bridgeInfo?.sessionFile else { return }
        do {
            try acquireLock(sessionFile: file, sessionId: entry?.sessionId ?? bridgeInfo?.sessionId)
        } catch let error as DaemonError where error.code == .sessionBusy {
            throw error
        } catch {
            await journalNotice("warning", "Could not take ownership of \(file): \(error)")
        }
    }

    private func acquireLock(sessionFile: String, sessionId: String?) throws {
        let handle = try context.locks.acquire(sessionFile: sessionFile, sessionId: sessionId, sessionKey: sessionKey)
        releaseLock()
        lock = handle
        lockedFile = sessionFile
    }

    private func releaseLock() {
        lock?.release()
        lock = nil
        lockedFile = nil
    }

    /// After `new_session`/`open_session`/`switch_session`: omp serves another file now. The manifest follows it,
    /// and so does ownership (taken now for an existing file, at the next first prompt for a new one).
    private func refreshIdentity(_ process: OmpProcess) async {
        guard let state = try? await process.send(["type": "get_state"])["data"] else { return }
        await adoptIdentity(from: state)
        guard let file = state["sessionFile"]?.stringValue, file != lockedFile else { return }
        releaseLock()
        guard FileManager.default.fileExists(atPath: file) else { return }
        do {
            try acquireLock(sessionFile: file, sessionId: state["sessionId"]?.stringValue)
        } catch {
            await journalNotice("warning", "Could not take ownership of \(file): \(error)")
        }
    }

    private func adoptIdentity(from state: JSONValue?) async {
        let file = state?["sessionFile"]?.stringValue
        let id = state?["sessionId"]?.stringValue
        let name = state?["sessionName"]?.stringValue
        await updateEntry { entry in
            if let file { entry.sessionFile = file }
            if let id { entry.sessionId = id }
            if let name, !name.isEmpty { entry.title = name }
        }
    }

    // MARK: - Manifest

    /// Journals and persists a status change. `always` journals it even when the status is unchanged (the start of
    /// every spawn is marked, so a replay shows each omp lifetime).
    private func setStatus(_ new: SessionStatus, settledAt: Date? = nil, always: Bool = false) async {
        let changed = new != status
        status = new
        if changed || always { await journalDaemon(.statusChanged(new), durable: true) }
        guard changed || always || settledAt != nil else { return }
        let lastSeq = await journal.lastSeq
        await updateEntry { entry in
            entry.status = new
            if let settledAt { entry.lastSettledAt = settledAt }
            entry.lastSeq = lastSeq
        }
    }

    private func setTitle(_ title: String) async {
        await updateEntry { $0.title = title }
    }

    private func pendingChanged() async {
        scheduleDeadline()
        let pending = tracker.pending
        await updateEntry { $0.pending = pending }
    }

    /// Every pending request of an omp that is gone can no longer be answered.
    private func abandonPending() async {
        deadlineTask?.cancel()
        deadlineTask = nil
        let abandoned = tracker.clear()
        guard !abandoned.uiRequests.isEmpty || !abandoned.hostToolCalls.isEmpty else { return }
        for request in abandoned.uiRequests + abandoned.hostToolCalls {
            if let id = request.frameId { await journalDaemon(.uiAbandoned(requestId: id), durable: true) }
        }
        await updateEntry { $0.pending = PendingRequests() }
    }

    /// One-shot timer for the earliest timed dialog: omp resolves it silently on expiry, so it leaves `pending`.
    private func scheduleDeadline() {
        deadlineTask?.cancel()
        guard let deadline = tracker.nextDeadline else {
            deadlineTask = nil
            return
        }
        deadlineTask = Task { [weak self] in
            let delay = deadline.timeIntervalSinceNow
            if delay > 0 {
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            }
            await self?.expireDialogs()
        }
    }

    private func expireDialogs() async {
        if tracker.expire(now: Date()).isEmpty {
            scheduleDeadline()
        } else {
            await pendingChanged()
        }
    }

    private func updateEntry(_ body: @escaping @Sendable (inout SessionManifestEntry) -> Void) async {
        do {
            try await context.manifest.updateEntry(sessionKey, body)
        } catch {
            supervisorLog.error("session \(self.sessionKey, privacy: .public): manifest update failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Journal

    private func append(_ kind: JournalRecord.Kind, _ payload: JSONValue, durable: Bool) async {
        guard !journalClosed, !context.readOnly.isOn else { return }
        do {
            try await journal.append(kind: kind, payload: payload, durable: durable)
        } catch StorageError.journalClosed {
            return
        } catch {
            supervisorLog.fault("session \(self.sessionKey, privacy: .public): journal append failed: \(String(describing: error), privacy: .public)")
            context.journalFailed(sessionKey, error)
        }
    }

    private func journalDaemon(_ event: DaemonEvent, durable: Bool) async {
        do {
            await append(.daemon, try JSONValue(encoding: event), durable: durable)
        } catch {
            supervisorLog.error("daemon event not encodable: \(String(describing: error), privacy: .public)")
        }
    }

    private func journalNotice(_ level: String, _ message: String) async {
        await journalDaemon(.notice(level: level, message: message), durable: false)
    }

    // MARK: - Helpers

    private static func isDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// omp failures as client-facing errors: a refused command keeps omp's message (and machine-readable code).
    private static func mapOmpErrors<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let OmpRPCError.commandFailed(command, message, response) {
            let code = response["code"]?.stringValue.map { " [\($0)]" } ?? ""
            throw DaemonError(.ompError, "\(command): \(message)\(code)")
        } catch let error as DaemonError {
            throw error
        } catch {
            throw DaemonError(.ompError, "\(error)")
        }
    }
}
