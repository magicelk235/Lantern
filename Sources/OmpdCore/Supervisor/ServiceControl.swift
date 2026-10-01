import Foundation
import IDEProtocol

/// omp's launch broker as ompd sees it: the records of a workspace's named services, and
/// `omp ps stop|kill|restart` of one of them. Every call is scoped to the workspace (the broker scope is the omp cwd's
/// realpath, which is every session's workspace).
public protocol ServiceControl: Sendable {
    /// Service name → broker state (`starting|running|ready|restarting|stopping|exited|failed`, or `unsupervised` for a
    /// record no broker could vouch for) of every service the broker records for `workspace`. A record no broker
    /// supervises gets a broker started first, which settles it.
    func states(workspace: String, omp: String, environment: [String: String]) async throws -> [String: String]
    /// Every service the broker records for `workspace`, as `omp ps --json` lists it. Never starts a broker.
    func records(workspace: String, omp: String, environment: [String: String]) async throws -> [ServiceRecord]
    /// `omp ps <command> <name>`; a restart relaunches from the broker's record (spec, mode, id and owner kept; no agent
    /// turn).
    func run(_ command: ServiceCommand, _ name: String, workspace: String, omp: String, environment: [String: String]) async throws
        -> ServiceCommandResult
}

public enum ServiceCommand: String, Sendable {
    /// Graceful: the broker stops it and kills it if it has not exited within 5 s.
    case stop
    /// The broker's stop with a 100 ms grace.
    case kill
    case restart
}

public enum ServiceCommandResult: Sendable, Equatable {
    case done
    /// The broker has no record of the service any more (pruned 5 min after its scope went idle).
    case unknown
    case failed(String)
}

/// One service of `omp ps --json`.
public struct ServiceRecord: Sendable, Equatable {
    public var name: String
    /// Broker state (`starting|running|ready|restarting|stopping|exited|failed`).
    public var state: String
    /// A broker answered for it; false when `omp ps` read the record from disk with no broker up (then a dead service
    /// that was not detached already reads `exited`).
    public var supervised: Bool
    /// `detached`, `persist` or `session` from the record's flags; nil when it has none.
    public var mode: String?
    public var pid: Int32?
    /// The command line the broker runs (the shell and the tool-level command).
    public var command: String?
    public var startedAt: Date?
    /// The omp session id that started it.
    public var owner: String?

    public init(
        name: String, state: String, supervised: Bool = true, mode: String? = nil, pid: Int32? = nil, command: String? = nil,
        startedAt: Date? = nil, owner: String? = nil
    ) {
        self.name = name
        self.state = state
        self.supervised = supervised
        self.mode = mode
        self.pid = pid
        self.command = command
        self.startedAt = startedAt
        self.owner = owner
    }
}

/// Broker states of a service that runs or is coming up; anything else (`stopping`, `exited`, `failed`) needs a
/// relaunch if it should run.
let liveServiceStates: Set<String> = ["starting", "running", "ready", "restarting"]

/// `ServiceControl` through omp's public CLI: `omp ps --json --dir <ws>` and `omp ps stop|kill|restart <name> --dir
/// <ws>`.
public struct OmpServiceControl: ServiceControl {
    public init() {}

    /// A record the broker does not supervise (it is down: `omp ps` read its `meta.json`) says nothing about the
    /// process: after a broker crash or a reboot it still reads `ready`. Any such record first gets a
    /// broker started (`omp ps info`, which spawns one; it marks dead records exited and re-adopts live detached
    /// services), then the list is read again; a record still unsupervised counts as not running.
    public func states(workspace: String, omp: String, environment: [String: String]) async throws -> [String: String] {
        var records = try await self.records(workspace: workspace, omp: omp, environment: environment)
        if let stale = records.first(where: { !$0.supervised }) {
            _ = try? await OmpBinary.run(
                omp, arguments: ["ps", "info", stale.name, "--dir", workspace], environment: environment, timeout: .seconds(30))
            records = try await self.records(workspace: workspace, omp: omp, environment: environment)
        }
        var states: [String: String] = [:]
        for record in records { states[record.name] = record.supervised ? record.state : "unsupervised" }
        return states
    }

    public func records(workspace: String, omp: String, environment: [String: String]) async throws -> [ServiceRecord] {
        let (reason, status, output) = try await OmpBinary.run(
            omp, arguments: ["ps", "--json", "--dir", workspace], environment: environment, timeout: .seconds(30))
        guard reason == .exit, status == 0 else {
            throw DaemonError(.ompError, "`omp ps --json` ended with \(reason == .exit ? "exit code" : "signal") \(status)")
        }
        return try Self.parseRecords(output)
    }

    public func run(_ command: ServiceCommand, _ name: String, workspace: String, omp: String, environment: [String: String])
        async throws -> ServiceCommandResult
    {
        let (reason, status, output) = try await OmpBinary.run(
            omp, arguments: ["ps", command.rawValue, name, "--dir", workspace], environment: environment, mergingStderr: true,
            timeout: .seconds(60))
        if reason == .exit, status == 0 { return .done }
        let message = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if message.hasPrefix("Unknown daemon") { return .unknown }
        return .failed(message.isEmpty ? "exit \(status)" : message)
    }

    /// `omp ps --json`: an array of scopes, each with `daemons[]` (the broker's snapshot of a service, plus `command`,
    /// `cwd` and `supervised`; times in ms since the epoch).
    static func parseRecords(_ output: String) throws -> [ServiceRecord] {
        let scopes = try JSONDecoder().decode(JSONValue.self, from: Data(output.utf8))
        return (scopes.arrayValue ?? []).flatMap { scope in
            (scope["daemons"]?.arrayValue ?? []).compactMap { daemon -> ServiceRecord? in
                guard let name = daemon["name"]?.stringValue else { return nil }
                return ServiceRecord(
                    name: name, state: daemon["state"]?.stringValue ?? "unknown", supervised: daemon["supervised"]?.boolValue == true,
                    mode: mode(detached: daemon["detached"]?.boolValue, persist: daemon["persist"]?.boolValue),
                    pid: daemon["pid"]?.intValue.flatMap { Int32(exactly: $0) }, command: daemon["command"]?.stringValue,
                    startedAt: daemon["startedAt"]?.doubleValue.map { Date(timeIntervalSince1970: $0 / 1000) },
                    owner: daemon["owner"]?.stringValue)
            }
        }
    }

    /// omp's flags as `proc://<name>/mode` names them (`omp ps` shows `detached` over `persist`).
    private static func mode(detached: Bool?, persist: Bool?) -> String? {
        if detached == true { return "detached" }
        if persist == true { return "persist" }
        return detached == nil && persist == nil ? nil : "session"
    }
}

/// `services.list`: the broker's records of a workspace merged with the named services its
/// sessions recorded (`entries`, the manifest entries of that workspace). A record no broker supervises reads
/// `unsupervised`, a recorded service the broker does not know `unknown`. The session a service belongs to is the one
/// that recorded it: the broker record's owner if that session did, else one that wants it running, else the first.
/// Sorted by name.
func mergeServices(records: [ServiceRecord], entries: [SessionManifestEntry]) -> [ServiceInfo] {
    func recorder(of name: String, owner: String?) -> (entry: SessionManifestEntry, service: NamedService)? {
        let recorded = entries.compactMap { entry in entry.services.first { $0.id == name }.map { (entry: entry, service: $0) } }
        return recorded.first { owner != nil && $0.entry.sessionId == owner } ?? recorded.first { $0.service.desiredRunning }
            ?? recorded.first
    }
    var services: [String: ServiceInfo] = [:]
    for record in records {
        let recorded = recorder(of: record.name, owner: record.owner)
        services[record.name] = ServiceInfo(
            name: record.name, state: record.supervised ? record.state : "unsupervised", mode: record.mode ?? recorded?.service.mode,
            command: recorded?.service.command ?? record.command, pid: record.pid, startedAt: record.startedAt,
            sessionKey: recorded?.entry.sessionKey, desiredRunning: recorded?.service.desiredRunning ?? false)
    }
    for name in Set(entries.flatMap { $0.services.map(\.id) }) where services[name] == nil {
        guard let recorded = recorder(of: name, owner: nil) else { continue }
        services[name] = ServiceInfo(
            name: name, state: "unknown", mode: recorded.service.mode, command: recorded.service.command,
            sessionKey: recorded.entry.sessionKey, desiredRunning: recorded.service.desiredRunning)
    }
    return services.values.sorted { $0.name < $1.name }
}
