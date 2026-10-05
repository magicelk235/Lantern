import Foundation
import JSONRPC
import LanguageClient
import LanguageServerProtocol
import os

/// Why a language server is not there to answer.
public enum LanguageServerError: Error, Sendable, CustomStringConvertible {
    /// The program could not be started.
    case launchFailed(String)
    /// It did not answer `initialize`, or answered with an error.
    case initializeFailed(String)
    /// A request took longer than it may.
    case timedOut
    /// It is not running (not started, failed, ended or shutting down).
    case notRunning

    public var description: String {
        switch self {
        case .launchFailed(let reason): "could not be started: \(reason)"
        case .initializeFailed(let reason): "did not start: \(reason)"
        case .timedOut: "did not answer in time"
        case .notRunning: "is not running"
        }
    }
}

/// One language server process for one project folder, independent of omp: started with `start()`,
/// which runs the `initialize` handshake (LanguageClient's `InitializingServer`), and ended with `shutdown()`, which asks
/// it to `shutdown` and `exit` and terminates it if it does not.
///
/// Document notifications are queued (`open`, `change`, `save`, `close`, callable from any thread) and sent strictly in
/// the order they were queued, each written whole before the next: LSP's document state depends on that order. A
/// request first waits until everything queued before it was written, so it is answered against the text the editor
/// shows. Requests the server sends (configuration, progress, folders, …) are answered by `RequestAnswering` before
/// `InitializingServer` sees them: it traps on a request that arrives before `initialize` returns or after shutdown.
public actor LanguageServer {
    public enum Event: Sendable {
        /// `textDocument/publishDiagnostics`.
        case diagnostics(PublishedDiagnostics)
        /// The process ended without being asked to; `reason` says how, with its last stderr line.
        case exited(reason: String)
    }

    public nonisolated let command: LanguageServerCommand
    public nonisolated let root: String
    /// Diagnostics and the process's end, in the order they happened; finishes after `shutdown()`.
    public nonisolated let events: AsyncStream<Event>
    private nonisolated let eventSink: AsyncStream<Event>.Continuation
    private nonisolated let outbox: AsyncStream<Outgoing>
    private nonisolated let outboxSink: AsyncStream<Outgoing>.Continuation
    private let environment: [String: String]

    private enum Phase {
        case idle, starting, running, stopping, ended
    }

    private enum Outgoing: Sendable {
        case notification(ClientNotification)
        /// Resumed once everything queued before it was written.
        case barrier(CheckedContinuation<Void, Never>)
    }

    private var phase = Phase.idle
    private var process: ServerProcess?
    private var server: InitializingServer?
    private var connection: RequestAnswering?
    private var drain: Task<Void, Never>?
    private var listen: Task<Void, Never>?
    /// Resumed when the process has ended.
    private var exitWaiters: [CheckedContinuation<Void, Never>] = []
    private var hasExited = false

    /// How long the handshake, a request, and each step of shutting down may take.
    private static let initializeTimeout: Duration = .seconds(60)
    private static let requestTimeout: Duration = .seconds(15)
    private static let shutdownStep: Duration = .milliseconds(1500)

    public init(command: LanguageServerCommand, environment: [String: String], root: String) {
        self.command = command
        self.environment = environment
        self.root = root
        (events, eventSink) = AsyncStream.makeStream(of: Event.self)
        (outbox, outboxSink) = AsyncStream.makeStream(of: Outgoing.self)
    }

    // MARK: - Lifecycle

    /// Launches the server in `root` and runs the `initialize` handshake. Throws when the program cannot start or does
    /// not initialize (the process is then gone).
    public func start() async throws -> ServerFeatures {
        guard phase == .idle else { throw LanguageServerError.notRunning }
        phase = .starting
        let process: ServerProcess
        do {
            process = try ServerProcess.launch(command, environment: environment, directory: root) { [weak self] reason, status in
                Task { await self?.processEnded(reason, status) }
            }
        } catch {
            phase = .ended
            throw LanguageServerError.launchFailed(error.localizedDescription)
        }
        self.process = process
        let connection = RequestAnswering(JSONRPCServerConnection(dataChannel: process.channel), root: root)
        self.connection = connection
        let parameters = initializeParams
        let server = InitializingServer(server: connection, initializeParamsProvider: { parameters })
        self.server = server

        let response: InitializationResponse
        do {
            response = try await Self.limit(Self.initializeTimeout) { try await server.initializeIfNeeded() }
        } catch {
            let reason = process.lastError.map { "\(error) (\($0))" } ?? "\(error)"
            phase = .stopping
            await stopProcess()
            phase = .ended
            await letGo()
            throw LanguageServerError.initializeFailed(reason)
        }
        guard phase == .starting else { throw LanguageServerError.notRunning }
        phase = .running
        let events = eventSink
        listen = Task {
            for await event in server.eventSequence {
                guard case .notification(.textDocumentPublishDiagnostics(let params)) = event,
                      let path = DocumentURI.path(of: params.uri) else { continue }
                events.yield(.diagnostics(PublishedDiagnostics(path: path, version: params.version, diagnostics: params.diagnostics)))
            }
        }
        let outbox = outbox
        drain = Task {
            for await outgoing in outbox {
                switch outgoing {
                case .notification(let notification):
                    try? await server.sendNotification(notification)
                case .barrier(let continuation):
                    continuation.resume()
                }
            }
        }
        return ServerFeatures(response.capabilities, name: response.serverInfo?.name ?? command.name)
    }

    /// Asks the server to `shutdown` and `exit` once what is queued was sent, then waits for the process to end;
    /// terminates it (SIGTERM, then SIGKILL) when a step takes too long. Ends `events`.
    public func shutdown() async {
        switch phase {
        case .idle:
            phase = .ended
        case .starting, .running:
            let wasRunning = phase == .running
            phase = .stopping
            outboxSink.finish()
            if wasRunning, let server, let drain {
                _ = try? await Self.limit(Self.shutdownStep) { await drain.value }
                _ = try? await Self.limit(Self.shutdownStep) { try await server.shutdownAndExit() }
            }
            await stopProcess()
            phase = .ended
        case .stopping, .ended:
            await waitForExit()
        }
        await letGo()
    }

    /// Stops listening to a server that is gone, and ends `events`.
    private func letGo() async {
        listen?.cancel()
        listen = nil
        await connection?.stop()
        eventSink.finish()
    }

    /// Waits for the process to end on its own (after `exit`), then terminates it, then kills it.
    private func stopProcess() async {
        guard let process else { return }
        outboxSink.finish()
        for stop in [{}, process.terminate, process.kill] {
            stop()
            if await waitForExit(within: Self.shutdownStep) { return }
        }
    }

    private func processEnded(_ reason: Process.TerminationReason, _ status: Int32) async {
        hasExited = true
        for waiter in exitWaiters { waiter.resume() }
        exitWaiters.removeAll()
        // Ended while starting: `start()` fails with the handshake's error. Ended while stopping: as asked.
        guard phase == .running else { return }
        phase = .ended
        outboxSink.finish()
        let how = reason == .uncaughtSignal ? "was killed by signal \(status)" : "exited with status \(status)"
        let detail = process?.lastError.map { ": \($0)" } ?? ""
        eventSink.yield(.exited(reason: "\(command.name) \(how)\(detail)"))
        await letGo()
    }

    private func waitForExit() async {
        guard !hasExited, process != nil else { return }
        await withCheckedContinuation { exitWaiters.append($0) }
    }

    /// Whether the process ended within `duration`.
    private func waitForExit(within duration: Duration) async -> Bool {
        guard !hasExited else { return true }
        let ended = (try? await Self.limit(duration) { await self.waitForExit() }) != nil
        return ended || hasExited
    }

    // MARK: - Documents

    public nonisolated func open(_ params: DidOpenTextDocumentParams) {
        outboxSink.yield(.notification(.textDocumentDidOpen(params)))
    }

    public nonisolated func change(_ params: DidChangeTextDocumentParams) {
        outboxSink.yield(.notification(.textDocumentDidChange(params)))
    }

    public nonisolated func save(_ params: DidSaveTextDocumentParams) {
        outboxSink.yield(.notification(.textDocumentDidSave(params)))
    }

    public nonisolated func close(_ params: DidCloseTextDocumentParams) {
        outboxSink.yield(.notification(.textDocumentDidClose(params)))
    }

    // MARK: - Requests

    /// What the server shows on hover at `position` of the document at `uri`.
    public func hover(_ uri: DocumentUri, at position: Position) async throws -> [HoverBlock] {
        let server = try await ready()
        let hover = try await Self.limit(Self.requestTimeout) {
            try await server.hover(TextDocumentPositionParams(uri: uri, position: position))
        }
        return hover.map(HoverBlock.blocks(of:)) ?? []
    }

    /// Where the symbol at `position` is defined.
    public func definitions(_ uri: DocumentUri, at position: Position) async throws -> [DefinitionTarget] {
        let server = try await ready()
        let response = try await Self.limit(Self.requestTimeout) {
            try await server.definition(TextDocumentPositionParams(uri: uri, position: position))
        }
        return DefinitionTarget.targets(from: response)
    }

    /// The completions at `position`, asked for after typing `trigger` (a trigger character) or by the user (nil).
    public func completions(_ uri: DocumentUri, at position: Position, trigger: String?) async throws -> [CompletionCandidate] {
        let server = try await ready()
        let params = CompletionParams(
            uri: uri, position: position, triggerKind: trigger == nil ? .invoked : .triggerCharacter, triggerCharacter: trigger)
        let response = try await Self.limit(Self.requestTimeout) { try await server.completion(params) }
        return CompletionCandidate.candidates(from: response)
    }

    /// The server once everything queued so far was written to it.
    private func ready() async throws -> InitializingServer {
        guard phase == .running, let server else { throw LanguageServerError.notRunning }
        await withCheckedContinuation { continuation in
            // A queue that ended (the server stopping meanwhile) has nothing left to wait for.
            guard case .enqueued = outboxSink.yield(.barrier(continuation)) else { return continuation.resume() }
        }
        guard phase == .running else { throw LanguageServerError.notRunning }
        return server
    }

    // MARK: - Handshake

    private var initializeParams: InitializeParams {
        let rootURI = URL(filePath: root, directoryHint: .isDirectory).absoluteString
        let capabilities = ClientCapabilities(
            workspace: ClientCapabilities.Workspace(
                applyEdit: false, workspaceEdit: nil, didChangeConfiguration: nil, didChangeWatchedFiles: nil, symbol: nil,
                executeCommand: nil, workspaceFolders: true, configuration: false, semanticTokens: nil),
            textDocument: TextDocumentClientCapabilities(
                synchronization: TextDocumentSyncClientCapabilities(
                    dynamicRegistration: false, willSave: false, willSaveWaitUntil: false, didSave: true),
                completion: CompletionClientCapabilities(
                    dynamicRegistration: false,
                    completionItem: CompletionClientCapabilities.CompletionItem(
                        snippetSupport: false, commitCharactersSupport: false, documentationFormat: [.markdown, .plaintext],
                        deprecatedSupport: true, preselectSupport: false, insertReplaceSupport: true, labelDetailsSupport: true),
                    completionItemKind: ValueSet(valueSet: CompletionItemKind.allCases), contextSupport: true),
                hover: HoverClientCapabilities(dynamicRegistration: false, contentFormat: [.markdown, .plaintext]),
                definition: DynamicRegistrationLinkSupportClientCapabilities(dynamicRegistration: false, linkSupport: true),
                publishDiagnostics: PublishDiagnosticsClientCapabilities(versionSupport: true)),
            window: WindowClientCapabilities(workDoneProgress: false, showMessage: nil, showDocument: nil),
            general: nil, experimental: nil)
        return InitializeParams(
            processId: Int(ProcessInfo.processInfo.processIdentifier),
            clientInfo: InitializeParams.ClientInfo(name: "omp IDE"),
            locale: nil, rootPath: root, rootUri: rootURI, initializationOptions: nil, capabilities: capabilities,
            trace: nil, workspaceFolders: [WorkspaceFolder(uri: rootURI, name: (root as NSString).lastPathComponent)])
    }

    // MARK: - Time limits

    /// `operation`'s result, or `LanguageServerError.timedOut` once `duration` passed (the operation is cancelled and
    /// left to finish on its own: a JSON-RPC request ends only when its answer comes or the process does).
    private static func limit<T: Sendable>(
        _ duration: Duration, _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let outcome = OSAllocatedUnfairLock<CheckedContinuation<T, any Error>?>(initialState: nil)
        return try await withCheckedThrowingContinuation { continuation in
            outcome.withLock { $0 = continuation }
            let work = Task {
                let result: Result<T, any Error>
                do {
                    result = .success(try await operation())
                } catch {
                    result = .failure(error)
                }
                outcome.withLock { $0.take() }?.resume(with: result)
            }
            Task {
                try? await Task.sleep(for: duration)
                guard let continuation = outcome.withLock({ $0.take() }) else { return }
                work.cancel()
                continuation.resume(throwing: LanguageServerError.timedOut)
            }
        }
    }
}

/// The connection `InitializingServer` talks through: client messages go to the server as they are; the server's
/// requests are answered here and never passed on, only its notifications are. omp IDE takes no part in what the
/// requests ask: no configuration (it says it has none), no workspace edits, no documents shown, no progress.
private actor RequestAnswering: ServerConnection {
    nonisolated let eventSequence: EventSequence
    private let connection: JSONRPCServerConnection
    /// Reads the server's messages; JSON-RPC's own stream never ends, so it is cancelled with `stop()`.
    private let reading: Task<Void, Never>

    init(_ connection: JSONRPCServerConnection, root: String) {
        self.connection = connection
        let (events, sink) = EventSequence.makeStream()
        eventSequence = events
        let folder = WorkspaceFolder(
            uri: URL(filePath: root, directoryHint: .isDirectory).absoluteString, name: (root as NSString).lastPathComponent)
        reading = Task {
            for await event in await connection.eventSequence {
                switch event {
                case .request(_, let request): await Self.answer(request, folder: folder)
                case .notification: sink.yield(event)
                case .error: break
                }
            }
            sink.finish()
        }
    }

    /// The server is gone: stop reading its messages.
    func stop() {
        reading.cancel()
    }

    func sendNotification(_ notification: ClientNotification) async throws {
        try await connection.sendNotification(notification)
    }

    func sendRequest<Response: Decodable & Sendable>(_ request: ClientRequest) async throws -> Response {
        try await connection.sendRequest(request)
    }

    private static func answer(_ request: ServerRequest, folder: WorkspaceFolder) async {
        switch request {
        case .workspaceConfiguration(let params, let reply):
            await reply(.success(params.items.map { _ in .null }))
        case .workspaceFolders(let reply):
            await reply(.success([folder]))
        case .workspaceApplyEdit(_, let reply):
            await reply(.success(ApplyWorkspaceEditResult(applied: false, failureReason: "omp IDE does not apply workspace edits")))
        case .clientRegisterCapability(_, let reply), .clientUnregisterCapability(_, let reply),
             .workspaceCodeLensRefresh(let reply), .workspaceSemanticTokenRefresh(let reply),
             .windowWorkDoneProgressCreate(_, let reply):
            await reply(nil)
        case .windowShowMessageRequest(_, let reply):
            await reply(.success(nil))
        case .windowShowDocument(_, let reply):
            await reply(.success(ShowDocumentResult(success: false)))
        case .custom(let method, _, let reply):
            // Refresh requests (`workspace/diagnostic/refresh`, `workspace/inlayHint/refresh`) only want an answer.
            if method.hasSuffix("/refresh") {
                await reply(.success(.null))
            } else {
                await reply(.failure(AnyJSONRPCResponseError(code: -32601, message: "omp IDE does not handle \(method)")))
            }
        }
    }
}
