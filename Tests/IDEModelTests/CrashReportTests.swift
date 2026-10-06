import Foundation
@testable import IDEModel
import Testing

@Suite struct CrashReportTests {
    @Test func onlyReportsOfOmpdAndTheAppNewerThanTheLastSeenCount() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "crash-reports-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory.appending(path: "Retired"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let lastSeen = Date(timeIntervalSince1970: 1_790_000_000)
        func report(_ name: String, at offset: TimeInterval) throws {
            let url = directory.appending(path: name)
            try Data("{}".utf8).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: lastSeen.addingTimeInterval(offset)], ofItemAtPath: url.path(percentEncoded: false))
        }
        try report("ompd-2026-10-01-140212.ips", at: 60)
        try report("Lantern-2026-10-01-150000.ips", at: 120)
        try report("ompd-2026-09-30-090000.ips", at: -60)
        try report("ompd-2026-10-01-130000.ips", at: 0)
        try report("omp-2026-10-01-140212.ips", at: 60)
        try report("ompd.cpu_resource-2026-10-01-140212.diag", at: 60)
        try report("Retired/ompd-2026-10-01-160000.ips", at: 180)

        let found = CrashReport.newer(than: lastSeen, in: directory)
        #expect(found.map(\.url.lastPathComponent) == ["Lantern-2026-10-01-150000.ips", "ompd-2026-10-01-140212.ips"])
        #expect(found.map(\.process) == ["Lantern", "ompd"])
        #expect(CrashReport.newer(than: lastSeen.addingTimeInterval(120), in: directory).isEmpty, "seen up to the newest")
        #expect(CrashReport.newer(than: .distantPast, in: directory.appending(path: "missing")).isEmpty)
    }
}
