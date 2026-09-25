import Foundation
import OmpRPC
import Testing

@Suite("OmpBinary")
struct OmpBinaryTests {
    @Test func locateHonoursExplicitThenOmpBinThenPath() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let explicit = try directory.script("explicit/omp", "exit 0")
        let fromEnvironment = try directory.script("env/omp", "exit 0")
        let onPath = try directory.script("second/omp", "exit 0")
        // Earlier PATH entries without a usable `omp`: a missing dir, a non-executable file, a directory.
        try FileManager.default.createDirectory(atPath: directory.path + "/first", withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: directory.path + "/first/omp", contents: Data("#!/bin/sh\n".utf8))
        try FileManager.default.createDirectory(atPath: directory.path + "/dir/omp", withIntermediateDirectories: true)
        let path = ["\(directory.path)/missing", "\(directory.path)/first", "\(directory.path)/dir", "\(directory.path)/second"].joined(separator: ":")

        let environment = ["OMP_BIN": fromEnvironment, "PATH": path]
        #expect(try OmpBinary.locate(explicit: explicit, environment: environment) == explicit)
        #expect(try OmpBinary.locate(explicit: nil, environment: environment) == fromEnvironment)
        #expect(try OmpBinary.locate(explicit: nil, environment: ["PATH": path]) == onPath)
    }

    @Test func configuredPathsThatAreNotExecutableFail() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let fallback = try directory.script("bin/omp", "exit 0")
        let environment = ["PATH": directory.path + "/bin"]
        #expect(throws: OmpRPCError.binaryNotFound(searched: [directory.path + "/nope"])) {
            try OmpBinary.locate(explicit: directory.path + "/nope", environment: environment)
        }
        #expect(throws: OmpRPCError.self) {
            try OmpBinary.locate(explicit: nil, environment: ["OMP_BIN": directory.path, "PATH": directory.path + "/bin"])
        }
        #expect(try OmpBinary.locate(explicit: "", environment: environment) == fallback)
    }

    @Test func versionReadsOmpVersionOutput() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let omp = try directory.script("omp", #"[ "$1" = --version ] && echo 'omp/19.0.2-beta.1' && echo 'noise 1.2.3' >&2"#)
        #expect(try await OmpBinary.version(at: omp) == "19.0.2-beta.1")
    }

    @Test func versionFailsOnUnexpectedOutputOrStatus() async throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let silent = try directory.script("silent", "echo 'no version here'")
        await #expect(throws: OmpRPCError.self) { try await OmpBinary.version(at: silent) }
        let failing = try directory.script("failing", "echo 'omp/1.2.3'; exit 2")
        await #expect(throws: OmpRPCError.self) { try await OmpBinary.version(at: failing) }
        let hanging = try directory.script("hanging", "exec sleep 30")
        await #expect(throws: OmpRPCError.timeout) { try await OmpBinary.version(at: hanging, timeout: .milliseconds(300)) }
    }
}
