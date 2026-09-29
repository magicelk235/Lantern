import Foundation
import IDEProtocol

/// omp's launch broker as ompd sees it: the state of a workspace's named services, and a
/// relaunch of one from the broker's own record. Every call is scoped to the workspace (the broker scope is the omp
/// cwd's realpath, which is every session's workspace).
public protocol ServiceControl: Sendable {
    /// Service name → broker state (`starting|running|ready|restarting|stopping|exited|failed`) of every service the
    /// broker records for `workspace`. Never starts a broker.
    func states(workspace: String, omp: String, environment: [String: String]) async throws -> [String: String]
    func restart(_ name: String, workspace: String, omp: String, environment: [String: String]) async throws -> ServiceRestart
}

public enum ServiceRestart: Sendable, Equatable {
    case restarted
    /// The broker has no record of the service any more (pruned 5 min after its scope went idle).
    case unknown
    case failed(String)
}

/// Broker states of a service that runs or is coming up; anything else (`stopping`, `exited`, `failed`) needs a
/// relaunch if it should run.
let liveServiceStates: Set<String> = ["starting", "running", "ready", "restarting"]

/// `ServiceControl` through omp's public CLI: `omp ps --json --dir <ws>` and `omp ps restart <name> --dir <ws>`
/// (keeps the recorded spec, mode, id and owner; no agent turn).
public struct OmpServiceControl: ServiceControl {
    public init() {}

    /// A record the broker does not supervise (it is down: `omp ps` read its `meta.json`) says nothing about the
    /// process: after a broker crash or a reboot it still reads `ready`. Any such record first gets a
    /// broker started (`omp ps info`, which spawns one; it marks dead records exited and re-adopts live detached
    /// services), then the list is read again; a record still unsupervised counts as not running.
    public func states(workspace: String, omp: String, environment: [String: String]) async throws -> [String: String] {
        var records = try await list(workspace: workspace, omp: omp, environment: environment)
        if let stale = records.first(where: { !$0.supervised }) {
            _ = try? await OmpBinary.run(
                omp, arguments: ["ps", "info", stale.name, "--dir", workspace], environment: environment, timeout: .seconds(30))
            records = try await list(workspace: workspace, omp: omp, environment: environment)
        }
        var states: [String: String] = [:]
        for record in records { states[record.name] = record.supervised ? record.state : "unsupervised" }
        return states
    }

    private func list(workspace: String, omp: String, environment: [String: String]) async throws -> [Record] {
        let (reason, status, output) = try await OmpBinary.run(
            omp, arguments: ["ps", "--json", "--dir", workspace], environment: environment, timeout: .seconds(30))
        guard reason == .exit, status == 0 else {
            throw DaemonError(.ompError, "`omp ps --json` ended with \(reason == .exit ? "exit code" : "signal") \(status)")
        }
        return try Self.parseRecords(output)
    }

    public func restart(_ name: String, workspace: String, omp: String, environment: [String: String]) async throws -> ServiceRestart {
        let (reason, status, output) = try await OmpBinary.run(
            omp, arguments: ["ps", "restart", name, "--dir", workspace], environment: environment, mergingStderr: true,
            timeout: .seconds(60))
        if reason == .exit, status == 0 { return .restarted }
        let message = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if message.hasPrefix("Unknown daemon") { return .unknown }
        return .failed(message.isEmpty ? "exit \(status)" : message)
    }

    struct Record: Equatable {
        var name: String
        var state: String
        var supervised: Bool
    }

    /// `omp ps --json`: an array of scopes, each with `daemons[] {name, state, supervised, …}`.
    static func parseRecords(_ output: String) throws -> [Record] {
        let scopes = try JSONDecoder().decode(JSONValue.self, from: Data(output.utf8))
        return (scopes.arrayValue ?? []).flatMap { scope in
            (scope["daemons"]?.arrayValue ?? []).compactMap { daemon -> Record? in
                guard let name = daemon["name"]?.stringValue else { return nil }
                return Record(
                    name: name, state: daemon["state"]?.stringValue ?? "unknown", supervised: daemon["supervised"]?.boolValue == true)
            }
        }
    }
}
