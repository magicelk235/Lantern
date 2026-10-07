import Darwin
import Foundation
import os
import Testing
@testable import OmpdCore

@Suite struct ChildReaperTests {
    /// Children that exit at once used to be lost now and then (an exit between the registration handler's check and
    /// the kqueue registration produced no event), leaving a zombie and a terminal that never stopped running.
    @Test func everyChildThatExitsAtOnceIsReaped() async throws {
        let count = 1000
        let reaped = OSAllocatedUnfairLock<Set<pid_t>>(initialState: [])
        var reapers: [ChildReaper] = []
        for index in 0..<count {
            var pid: pid_t = 0
            let argv: [UnsafeMutablePointer<CChar>?] = [strdup("/bin/sh"), strdup("-c"), strdup("exit 0"), nil]
            defer { argv.forEach { free($0) } }
            #expect(posix_spawn(&pid, "/bin/sh", nil, nil, argv, environ) == 0)
            // Spread the registrations over the child's exit.
            if index % 3 == 1 { usleep(UInt32(index % 2000)) }
            let child = pid
            reapers.append(ChildReaper(pid: child) { _ in _ = reaped.withLock { $0.insert(child) } })
        }
        let deadline = ContinuousClock.now + .seconds(10)
        while reaped.withLock({ $0.count }) < count, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let lost = reapers.filter { !$0.isReaped }.map(\.pid)
        for pid in lost { var status: Int32 = 0; _ = waitpid(pid, &status, 0) }
        #expect(lost.isEmpty, "never reaped: \(lost)")
    }
}
