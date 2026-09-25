import Foundation
import IDEProtocol
import IDETransport
import Observation

/// The daemon calls a `SessionViewModel` makes. `DaemonConnection` implements them over its live `IDEClient`.
@MainActor
public protocol SessionBackend: AnyObject, Sendable {
    func subscribe(_ sessionKey: SessionKey, since: Seq) async throws -> Subscribe.Result
    func snapshot(_ sessionKey: SessionKey) async throws -> SessionSnapshot.Result
    /// omp RPC passthrough; returns omp's response `data`.
    func send(_ command: JSONValue, to sessionKey: SessionKey) async throws -> JSONValue
    func respond(to requestId: String, in sessionKey: SessionKey, with response: JSONValue) async throws
}

/// One open session: its transcript and journal position, kept in step with the daemon.
///
/// On every (re)connection it sends `subscribe {since: lastSeq}` — never an omp command, so omp notices nothing.
/// Events at or below `lastSeq` repeat a replay and are ignored; a gap re-subscribes from `lastSeq` (a second gap at
/// the same seq escalates to a resync); `resync`, or a compacted range that was never seen, drops the transcript,
/// rebuilds it from `session.snapshot` and subscribes from the snapshot's seq.
@MainActor @Observable
public final class SessionViewModel: Identifiable {
    public enum SyncState: Equatable, Sendable {
        /// Not connected; resumes on the next connection.
        case detached
        /// `subscribe` sent; the replay is streaming in.
        case subscribing
        /// Replay complete; events arrive live.
        case live
        /// Rebuilding from `session.snapshot`.
        case resyncing
        /// The daemon refused to serve this session. Retried on the next connection.
        case failed(String)
    }

    public nonisolated let sessionKey: SessionKey
    public nonisolated var id: SessionKey { sessionKey }

    public private(set) var entry: SessionManifestEntry?
    public private(set) var transcript = TranscriptReducer()
    public private(set) var sync: SyncState = .detached
    /// The last failed command, shown by the composer until a command succeeds.
    public private(set) var lastError: String?
    public private(set) var isSending = false
    /// Dialogs whose answer is on its way to the daemon.
    public private(set) var answering: Set<String> = []
    /// Answers this client sent, by request id (the journal records only that a dialog was answered).
    public private(set) var sentAnswers: [String: DialogResponse] = [:]
    /// Composer text, kept per session while the app runs.
    public var draft = ""

    @ObservationIgnored private weak var backend: (any SessionBackend)?
    /// Bumped by every subscribe, resync and disconnect; completions of superseded attempts are dropped.
    @ObservationIgnored private var generation = 0
    /// The transcript was dropped for a resync that has not completed: rebuild before subscribing again.
    @ObservationIgnored private var needsSnapshot = false
    /// `lastSeq` the last gap re-subscribed from.
    @ObservationIgnored private var gapResubscribedAt: Seq?
    @ObservationIgnored private var expiryTask: Task<Void, Never>?
    @ObservationIgnored private var expiryDeadline: Date?

    public init(sessionKey: SessionKey, entry: SessionManifestEntry?, backend: any SessionBackend) {
        self.sessionKey = sessionKey
        self.entry = entry
        self.backend = backend
    }

    public var items: [TranscriptItem] { transcript.items }
    public var lastSeq: Seq { transcript.lastSeq }
    /// A run is active or background work can still wake the agent: a prompt now needs a `StreamingBehavior`.
    public var isBusy: Bool { transcript.activity != .idle }
    /// The user closed this session: omp no longer runs for it.
    public var isClosed: Bool { entry?.closedByUser == true || entry?.status == .closed }
    /// Subscribed on a live connection, so commands and answers can reach omp.
    public var isAttached: Bool { sync == .live || sync == .subscribing }

    // MARK: - Driven by DaemonConnection

    func connectionOpened() {
        if needsSnapshot { resync() } else { resubscribe() }
    }

    func connectionClosed() {
        generation += 1
        if case .failed = sync { return }
        sync = .detached
    }

    func update(entry: SessionManifestEntry) {
        if entry != self.entry { self.entry = entry }
    }

    func receive(_ record: JournalRecord) {
        switch sync {
        case .resyncing, .failed, .detached: return // the rebuild, or the next subscription, covers these
        case .subscribing, .live: break
        }
        guard record.seq > lastSeq else { return } // overlap with an earlier replay
        if record.kind == .compacted {
            // Records we never applied were collapsed into a pointer at omp's entries: only a snapshot has them now.
            resync()
            return
        }
        guard record.seq == lastSeq + 1 else {
            // During a (re)subscription the replay fills the hole; otherwise ask for it once, then rebuild.
            guard sync == .live else { return }
            if gapResubscribedAt == lastSeq { resync() } else {
                gapResubscribedAt = lastSeq
                resubscribe()
            }
            return
        }
        transcript.apply(record)
        scheduleDialogExpiry()
    }

    func receive(_ resync: Resync) {
        self.resync()
    }

    private func resubscribe() {
        guard let backend else { return }
        generation += 1
        let attempt = generation
        let since = lastSeq
        sync = .subscribing
        Task {
            do {
                _ = try await backend.subscribe(sessionKey, since: since)
                guard attempt == generation else { return }
                sync = .live
            } catch {
                guard attempt == generation else { return }
                fail(error)
            }
        }
    }

    private func resync() {
        guard let backend else { return }
        generation += 1
        let attempt = generation
        needsSnapshot = true
        gapResubscribedAt = nil
        sync = .resyncing
        transcript = TranscriptReducer()
        Task {
            do {
                let snapshot = try await backend.snapshot(sessionKey)
                guard attempt == generation else { return }
                transcript.rebuild(from: snapshot)
                update(entry: snapshot.entry)
                needsSnapshot = false
                scheduleDialogExpiry()
                resubscribe()
            } catch {
                guard attempt == generation else { return }
                fail(error)
            }
        }
    }

    private func fail(_ error: any Error) {
        sync = error.isDisconnect ? .detached : .failed(error.userMessage)
    }

    /// Expires timed dialogs when their deadline passes while no record arrives to do it.
    private func scheduleDialogExpiry() {
        let deadline = transcript.nextDialogDeadline
        guard deadline != expiryDeadline else { return }
        expiryTask?.cancel()
        expiryDeadline = deadline
        guard let deadline else {
            expiryTask = nil
            return
        }
        expiryTask = Task { [weak self] in
            let delay = deadline.timeIntervalSinceNow
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled, let self else { return }
            expiryDeadline = nil
            transcript.expireDialogs(asOf: Date())
            scheduleDialogExpiry()
        }
    }

    // MARK: - Commands

    /// Sends a prompt; while busy `streamingBehavior` says whether it steers the run or follows up after it.
    /// Returns whether the daemon accepted it (else `lastError` says why).
    @discardableResult
    public func send(_ message: String, streamingBehavior: StreamingBehavior? = nil) async -> Bool {
        guard let backend else { return false }
        isSending = true
        defer { isSending = false }
        do {
            _ = try await backend.send(OmpCommands.prompt(message, streamingBehavior: streamingBehavior), to: sessionKey)
            lastError = nil
            return true
        } catch {
            lastError = error.userMessage
            return false
        }
    }

    /// Stops the run. omp holds `abort` until every pending tool approval is answered,
    /// so pending approvals are cancelled (= denied) alongside it.
    public func abort() async {
        guard let backend else { return }
        let key = sessionKey
        let abort = Task { try await backend.send(OmpCommands.abort, to: key) }
        for dialog in transcript.pendingDialogs where dialog.approval != nil {
            await respond(to: dialog.requestId, with: .cancelled)
        }
        do {
            _ = try await abort.value
            lastError = nil
        } catch {
            lastError = error.userMessage
        }
    }

    public func respond(to requestId: String, with response: DialogResponse) async {
        guard let backend, !answering.contains(requestId) else { return }
        answering.insert(requestId)
        defer { answering.remove(requestId) }
        do {
            try await backend.respond(to: requestId, in: sessionKey, with: response.json)
            sentAnswers[requestId] = response
            lastError = nil
        } catch {
            lastError = error.userMessage
        }
    }
}

extension Error {
    /// The connection is gone (or was never there); the next connection retries.
    var isDisconnect: Bool {
        switch self {
        case is CancellationError: true
        case let error as IDETransportError:
            switch error {
            case .notConnected, .connectionClosed, .connectFailed: true
            default: false
            }
        default: false
        }
    }

    /// One sentence for the UI: the daemon's own message, or what went wrong with the connection.
    public var userMessage: String {
        switch self {
        case let error as DaemonError: error.message
        case let error as IDETransportError:
            switch error {
            case .notConnected: "Not connected to ompd."
            case .connectionClosed: "The connection to ompd closed."
            case .connectFailed(let reason): "ompd is not reachable (\(reason))."
            case .protocolViolation(let reason): "ompd sent something unexpected: \(reason)"
            case .socketPathTooLong(let path): "The ompd socket path is too long: \(path)"
            default: String(describing: error)
            }
        default: localizedDescription
        }
    }
}
