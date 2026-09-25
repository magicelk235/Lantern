import Foundation
import OmpRPC
import Testing

/// `OmpProcess` against scripted stand-ins for omp, for behaviour real omp cannot be made to show on demand.
@Suite("OmpProcess with scripted children", .timeLimit(.minutes(1)))
struct OmpProcessTests {
    private static let ready = #"{"type":"ready","protocolVersion":1,"supportedProtocolVersions":[1],"maxFrameBytes":1048576}"#

    private func child(_ script: String, in directory: TemporaryDirectory) -> OmpProcess {
        OmpProcess(launch: OmpLaunch(executable: "/bin/sh", arguments: ["-c", script], currentDirectory: directory.path))
    }

    @Test func drainsStdoutWhileNobodyReadsOutput() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        // ~16 MiB: far beyond the pipe buffer, so the child only finishes if stdout is drained.
        let padding = String(repeating: "x", count: 1000)
        let process = child("printf '%s\\n' '\(Self.ready)'; yes '{\"type\":\"tick\",\"pad\":\"\(padding)\"}' | head -n 16000", in: directory)
        _ = try await process.start()
        #expect(await process.waitForExit() == OmpExit(code: 0, signal: nil))

        let output = await process.output.collect()
        #expect(output.frames.count == 16_001)
        #expect(output.last == .exited(OmpExit(code: 0, signal: nil)))
    }

    @Test func correlatesResponsesByIdWhateverTheirOrder() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        // Answers the second command first; only `type: "b"` succeeds. Then waits for stdin EOF.
        let script = """
            printf '%s\\n' '\(Self.ready)'
            reply() {
              id=$(printf '%s' "$1" | sed -n 's/.*"id":"\\([^"]*\\)".*/\\1/p')
              type=$(printf '%s' "$1" | sed -n 's/.*"type":"\\([^"]*\\)".*/\\1/p')
              if [ "$type" = b ]; then
                printf '{"id":"%s","type":"response","command":"%s","success":true,"data":{"n":2}}\\n' "$id" "$type"
              else
                printf '{"id":"%s","type":"response","command":"%s","success":false,"error":"nope","code":"E_NOPE"}\\n' "$id" "$type"
              fi
            }
            IFS= read -r first
            IFS= read -r second
            reply "$second"
            reply "$first"
            cat >/dev/null
            """
        let process = child(script, in: directory)
        let ready = try await process.start()
        #expect(ready.protocolVersion == 1) // v2 not advertised: no negotiate_protocol was written

        async let a = capture { try await process.send(["type": "a", "id": "caller-id"]) }
        async let b = capture { try await process.send(["type": "b"]) }
        let (resultA, resultB) = await (a, b)

        #expect(try resultB.get()["data"] == ["n": 2])
        guard case .failure(let error) = resultA, case .commandFailed(let command, let message, let response)? = error as? OmpRPCError else {
            Issue.record("expected commandFailed, got \(resultA)")
            return
        }
        #expect(command == "a")
        #expect(message == "nope")
        #expect(response["code"] == "E_NOPE")
        #expect(response.frameId != "caller-id")

        await process.closeStdin()
        #expect(await process.waitForExit() == OmpExit(code: 0, signal: nil))
        await #expect(throws: OmpRPCError.exited(OmpExit(code: 0, signal: nil))) {
            try await process.send(["type": "a"])
        }
    }

    @Test func pendingRequestsFailWithTheExitStatus() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let process = child("printf '%s\\n' '\(Self.ready)'; IFS= read -r line; kill -9 $$", in: directory)
        _ = try await process.start()
        await #expect(throws: OmpRPCError.exited(OmpExit(code: nil, signal: 9))) {
            try await process.send(["type": "get_state"])
        }
    }

    @Test func exitIsReportedWhileADescendantStillHoldsThePipes() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        // The background sleeper inherits stdout/stderr, so neither pipe reaches EOF when the shell exits.
        let process = child(
            "printf '%s\\n' '\(Self.ready)'; sleep 30 & printf '{\"type\":\"sleeper\",\"pid\":%d}\\n' $!; echo bye >&2; exit 3",
            in: directory
        )
        _ = try await process.start()
        let clock = ContinuousClock()
        let started = clock.now
        #expect(await process.waitForExit() == OmpExit(code: 3, signal: nil))
        #expect(clock.now - started < .seconds(10))

        let output = await process.output.collect()
        #expect(output.last == .exited(OmpExit(code: 3, signal: nil)))
        #expect(output.stderrText == "bye\n")
        let sleeper = output.frames.first { $0.frameType == "sleeper" }?["pid"]?.intValue
        #expect(sleeper != nil)
        if let sleeper { kill(Int32(sleeper), SIGKILL) }
    }

    @Test func startFailsWhenTheChildExitsBeforeReady() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let process = child("echo 'config broken' >&2; exit 7", in: directory)
        await #expect(throws: OmpRPCError.exited(OmpExit(code: 7, signal: nil))) {
            try await process.start()
        }
        let output = await process.output.collect()
        #expect(output == [.stderr("config broken\n"), .exited(OmpExit(code: 7, signal: nil))])
    }

    @Test func malformedStdoutFailsStartAndTerminatesTheChild() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let process = child("echo 'not json'; exec sleep 30", in: directory)
        await #expect(throws: OmpRPCError.self) { try await process.start() }
        #expect(await process.waitForExit().signal != nil)
        guard case .protocolViolation? = await process.protocolViolation else {
            Issue.record("expected the violation to be recorded")
            return
        }
    }

    @Test func malformedStdoutFailsPendingRequestsAndSendsSIGTERM() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let process = child("printf '%s\\n' '\(Self.ready)'; IFS= read -r line; echo '{\"type\":'; exec sleep 30", in: directory)
        _ = try await process.start()
        let result = await capture { try await process.send(["type": "get_state"]) }
        guard case .failure(let error) = result, let violation = error as? OmpRPCError, case .protocolViolation = violation else {
            Issue.record("expected a protocol violation, got \(result)")
            return
        }
        #expect(await process.waitForExit() == OmpExit(code: nil, signal: SIGTERM))
        #expect(await process.protocolViolation == violation)
        await #expect(throws: violation) { try await process.send(["type": "get_state"]) }
    }

    @Test func startTimesOutWithoutReadyAndKillsTheChild() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let process = child("exec sleep 30", in: directory)
        await #expect(throws: OmpRPCError.timeout) {
            try await process.start(readyTimeout: .milliseconds(300))
        }
        #expect(await process.waitForExit() == OmpExit(code: nil, signal: SIGKILL))
    }

    @Test func launchFailureEndsTheOutput() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let process = OmpProcess(launch: OmpLaunch(executable: directory.path + "/missing-omp", arguments: [], currentDirectory: directory.path))
        await #expect(throws: OmpRPCError.self) { try await process.start() }
        #expect(await process.output.collect() == [.exited(OmpExit(code: nil, signal: nil))])
        await #expect(throws: OmpRPCError.notRunning) { try await process.send(["type": "get_state"]) }
    }
}
