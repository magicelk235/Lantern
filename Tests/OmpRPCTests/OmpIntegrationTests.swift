import Foundation
import OmpRPC
import Testing

private let ompPath = try? OmpBinary.locate(explicit: nil)

/// Spawns the installed omp: `omp --mode rpc --no-ui --session-dir <tmp>` (no model calls).
@Suite(
    "OmpProcess against the real omp",
    .tags(.integration),
    .enabled(if: ompPath != nil, "omp executable not found"),
    .timeLimit(.minutes(2))
)
struct OmpIntegrationTests {
    private struct Session {
        let process: OmpProcess
        let directory: TemporaryDirectory
    }

    private func launch() throws -> Session {
        let directory = try TemporaryDirectory()
        let sessions = directory.url.appendingPathComponent("sessions").path
        let process = OmpProcess(launch: OmpLaunch(
            executable: try #require(ompPath),
            arguments: ["--mode", "rpc", "--no-ui", "--session-dir", sessions],
            currentDirectory: directory.path
        ))
        return Session(process: process, directory: directory)
    }

    @Test func negotiatesV2AnswersGetStateAndExitsCleanlyOnEOF() async throws {
        let session = try launch()
        defer { session.directory.remove() }
        let process = session.process

        let ready = try await process.start()
        #expect(ready.protocolVersion == 2)
        #expect(ready.supported.contains(2))
        #expect(ready.raw["protocolVersion"] == 1)

        let state = try await process.send(["type": .string(OmpCommandName.getState.rawValue)])
        #expect(state["command"] == "get_state")
        #expect(state["data"]?["sessionFile"]?.stringValue != nil)
        #expect(state["data"]?["isStreaming"]?.boolValue == false)

        let unknown = await capture { try await process.send(["type": "no_such_command"]) }
        guard case .failure(let error) = unknown, case .commandFailed(let command, _, let response)? = error as? OmpRPCError else {
            Issue.record("expected commandFailed, got \(unknown)")
            return
        }
        #expect(command == "no_such_command")
        #expect(response["success"] == false)

        // omp ignores answers to unknown UI requests; a malformed line would draw a `parse` failure instead.
        try await process.sendNoReply([
            "type": .string(OmpHostReplyType.extensionUIResponse.rawValue),
            "id": "no-such-request",
            "cancelled": true,
        ])
        _ = try await process.send(["type": .string(OmpCommandName.getState.rawValue)])

        await process.closeStdin()
        let output = await process.output.collect()
        #expect(await process.waitForExit() == OmpExit(code: 0, signal: nil))
        #expect(output.last == .exited(OmpExit(code: 0, signal: nil)))

        let frames = output.frames
        #expect(frames.first == ready.raw)
        #expect(frames.contains { $0.frameType == "response" && $0["command"] == "negotiate_protocol" && $0["data"]?["protocolVersion"] == 2 })
        #expect(frames.contains(state))
        #expect(!frames.contains { $0["command"] == "parse" })
    }

    /// A response of ~1.5 MB (multi-byte text) exceeds the 1 MiB physical frame limit: v2 streams it
    /// losslessly as `rpc_chunk` frames, v1 replaces it with an overflow error.
    @Test(arguments: [true, false])
    func largeResponse(negotiateV2: Bool) async throws {
        let session = try launch()
        defer { session.directory.remove() }
        let process = session.process
        let ready = try await process.start(negotiateV2: negotiateV2)
        #expect(ready.protocolVersion == (negotiateV2 ? 2 : 1))

        let content = String(repeating: "aé€😀", count: 150_000)
        let command: JSONValue = [
            "type": .string(OmpCommandName.setTodos.rawValue),
            "phases": [["id": "phase-1", "name": "Big", "tasks": [["id": "task-1", "content": .string(content), "status": "pending"]]]],
        ]
        let result = await capture { try await process.send(command) }
        if negotiateV2 {
            let tasks = try result.get()["data"]?["todoPhases"]?.arrayValue?.first?["tasks"]?.arrayValue
            #expect(tasks?.first?["content"]?.stringValue == content)
        } else {
            guard case .failure(let error) = result, case .commandFailed(let failed, _, _)? = error as? OmpRPCError else {
                Issue.record("expected the v1 overflow failure, got \(result)")
                return
            }
            #expect(failed == "set_todos")
        }
        await process.closeStdin()
        #expect(await process.waitForExit() == OmpExit(code: 0, signal: nil))
    }

    @Test func pendingRequestFailsWhenOmpIsKilled() async throws {
        let session = try launch()
        defer { session.directory.remove() }
        let process = session.process
        _ = try await process.start()

        // omp answers `bash` only when the command finishes, so the request is still pending when omp dies.
        let pending = Task { try await process.send(["type": "bash", "command": "sleep 3"]) }
        try await Task.sleep(for: .milliseconds(500))
        await process.signal(SIGKILL)

        await #expect(throws: OmpRPCError.exited(OmpExit(code: nil, signal: SIGKILL))) {
            try await pending.value
        }
        let output = await process.output.collect()
        #expect(output.last == .exited(OmpExit(code: nil, signal: SIGKILL)))
    }

    @Test func versionOfTheInstalledBinary() async throws {
        let version = try await OmpBinary.version(at: try #require(ompPath))
        #expect(version.wholeMatch(of: /\d+\.\d+\.\d+.*/) != nil)
    }
}
