import Foundation
@testable import IDEModel
import Testing

@Suite struct ManifestSettleTests {
    @Test(arguments: [
        (SessionStatus.idle, true), (.paused, true), (.closed, true), (.needsAttention, true), (.interrupted, true),
        (.starting, false), (.resuming, false), (.busy, false),
    ])
    func aRestartWaitsOnlyForOmpBeingStartedResumedOrWorking(status: SessionStatus, settled: Bool) throws {
        let manifest = SessionManifest(sessions: [manifestEntry("a", status: .idle), manifestEntry("b", status: status)])
        let settle = ManifestSettle(manifest: try IDECoding.encoder().encode(manifest))
        #expect(settle == (settled ? .settled : .unsettled(["b"])))
    }

    /// What an ompd of protocol 4 wrote: no `installedOmpVersion`, and a session left interrupted.
    @Test func anOlderOmpdsManifestIsJudged() {
        let settled = Self.protocol4Manifest(statuses: ["idle", "paused", "closed", "needs_attention", "interrupted"])
        #expect(ManifestSettle(manifest: Data(settled.utf8)) == .settled)
        let working = Self.protocol4Manifest(statuses: ["idle", "busy", "closed", "starting", "resuming"])
        #expect(ManifestSettle(manifest: Data(working.utf8)) == .unsettled(["s1", "s3", "s4"]))
        // Before `restorePolicy`, `adopted`, `spawnedAt` and `pendingContinuation`.
        let first = #"{"version":1,"sessions":[{"sessionKey":"s0","workspace":"/w","launch":{"ompPath":"/o","ompVersion":"1","extraArgs":[],"env":{}},"status":"busy","createdAt":"2026-09-01T10:00:00Z","services":[],"closedByUser":false}]}"#
        #expect(ManifestSettle(manifest: Data(first.utf8)) == .unsettled(["s0"]))
    }

    @Test func noManifestIsSettledAndOneThatDoesNotDecodeIsUnknown() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "settle-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "sessions.json")
        #expect(ManifestSettle(contentsOf: url) == .settled)

        // A status this build does not know (a newer ompd's) leaves what runs unknown, as does a torn file.
        try Data(Self.protocol4Manifest(statuses: ["idle", "compacting"]).utf8).write(to: url)
        #expect(ManifestSettle(contentsOf: url).isUnreadable)
        try Data("{\"version\":".utf8).write(to: url)
        #expect(ManifestSettle(contentsOf: url).isUnreadable)
    }

    @MainActor
    @Test func theWatchReadsTheManifestEachTimeOmpdReplacesIt() async throws {
        let folder = URL(filePath: "/tmp/settle-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "sessions.json")
        try Self.replace(url, with: Self.protocol4Manifest(statuses: ["busy"]))
        let readings = Readings()
        let watch = try #require(ManifestWatch(manifest: url) { readings.all.append($0) })

        try Self.replace(url, with: Self.protocol4Manifest(statuses: ["busy", "starting"]))
        try await eventually("the second manifest") { readings.all.last == .unsettled(["s0", "s1"]) }
        try Self.replace(url, with: Self.protocol4Manifest(statuses: ["paused", "idle"]))
        try await eventually("the settled manifest") { readings.all.last == .settled }
        withExtendedLifetime(watch) {}
    }

    @MainActor
    private final class Readings {
        var all: [ManifestSettle] = []
    }

    /// As ompd writes it (`StorageIO.writeAtomically`): a temporary file renamed over the manifest.
    private static func replace(_ url: URL, with contents: String) throws {
        let temporary = url.appendingPathExtension("tmp")
        try Data(contents.utf8).write(to: temporary)
        guard rename(temporary.path(percentEncoded: false), url.path(percentEncoded: false)) == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    /// A manifest as an ompd of protocol 4 writes it, one session per status (`s0`, `s1`, …).
    private static func protocol4Manifest(statuses: [String]) -> String {
        let sessions = statuses.enumerated().map { index, status in
            """
                {
                  "adopted" : false,
                  "closedByUser" : \(status == "closed"),
                  "createdAt" : "2026-09-29T08:00:0\(index).250Z",
                  "launch" : {
                    "env" : {

                    },
                    "extraArgs" : [

                    ],
                    "ompPath" : "/opt/homebrew/bin/omp",
                    "ompVersion" : "18.3.1"
                  },
                  "ptyId" : "pty-\(index)",
                  "services" : [

                  ],
                  "sessionFile" : "/Users/u/.omp/agent/sessions/-work-p/s\(index).jsonl",
                  "sessionKey" : "s\(index)",
                  "spawnedAt" : "2026-09-29T08:00:0\(index).500Z",
                  "status" : "\(status)",
                  "workspace" : "/Users/u/work/p"
                }
            """
        }
        return """
            {
              "restorePolicy" : {
                "main" : "ask",
                "subagents" : "auto"
              },
              "sessions" : [
            \(sessions.joined(separator: ",\n"))
              ],
              "version" : 2
            }
            """
    }
}

private extension ManifestSettle {
    var isUnreadable: Bool {
        if case .unreadable = self { return true }
        return false
    }
}
