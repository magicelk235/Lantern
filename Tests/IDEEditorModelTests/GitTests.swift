import Foundation
import IDEEditorModel
import Testing

@Suite(.enabled(if: Git.executable != nil, "git is not installed"), .timeLimit(.minutes(1)))
struct GitTests {
    /// An alias that runs `script` in the shell: git lives as long as it does and prints what it prints.
    private static func shell(_ script: String) -> [String] {
        ["-c", "alias.script=!\(script)", "script"]
    }

    @Test func manyRunsAtOnceHoldNoThreadWhileGitWorks() async throws {
        // More runs than Swift's cooperative pool has threads (one per core). A run that held its thread until git
        // was done went in waves at best, and at worst starved the pool for good: every other task of the process
        // waited with it (a restored window's editor tabs, each reading HEAD, kept the app from connecting to ompd).
        let folder = try TempFolder()
        let runs = ProcessInfo.processInfo.activeProcessorCount * 4
        let arguments = Self.shell("sleep 2; echo done")
        let started = ContinuousClock.now
        let outputs = try await withThrowingTaskGroup(of: Data.self) { group in
            for _ in 0..<runs {
                group.addTask { try await Git.output(arguments, in: folder.path) }
            }
            return try await group.reduce(into: [Data]()) { $0.append($1) }
        }
        #expect(outputs.count == runs)
        #expect(outputs.allSatisfy { $0 == Data("done\n".utf8) })
        // Side by side they take about 2 s; in waves of one per core, at least 8.
        #expect(ContinuousClock.now - started < .seconds(6))
    }

    @Test func outputBeyondWhatAPipeHoldsArrivesWhole() async throws {
        let folder = try TempFolder()
        let output = try await Git.output(
            Self.shell("head -c 300000 /dev/zero | tr '\\000' a; head -c 300000 /dev/zero | tr '\\000' b >&2"), in: folder.path)
        #expect(output == Data(repeating: UInt8(ascii: "a"), count: 300_000))
    }

    @Test func aFailureCarriesGitsStatusAndWhatItPrintedOnStderr() async throws {
        let folder = try TempFolder()
        let failure = await #expect(throws: Git.Failure.self) {
            try await Git.output(["rev-parse", "--show-toplevel"], in: folder.path)
        }
        #expect(failure?.status == 128)
        #expect(failure?.stderr.contains("not a git repository") == true)
    }
}
