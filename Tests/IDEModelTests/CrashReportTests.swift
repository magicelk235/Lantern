import Foundation
@testable import IDEModel
import Testing

@Suite struct CrashReportTests {
    static let ompdUUID = UUID(uuidString: "4C4C447C-5555-3144-A138-DBD9C49417A3")!
    static let owner = CrashReport.Owner(bundleIdentifier: "com.magicelklabs.lantern", ompdUUIDs: [ompdUUID])

    @Test func onlyThisAppsReportsNewerThanTheLastSeenCount() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "crash-reports-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory.appending(path: "Retired"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let lastSeen = Date(timeIntervalSince1970: 1_790_000_000)
        func report(_ name: String, at offset: TimeInterval, header: String) throws {
            let url = directory.appending(path: name)
            try Data((header + "\n{\n  \"pid\" : 1\n}").utf8).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: lastSeen.addingTimeInterval(offset)], ofItemAtPath: url.path(percentEncoded: false))
        }
        let app = #"{"app_name":"Lantern","bundleID":"com.magicelklabs.lantern","slice_uuid":"0b6f1c2a-0000-4000-8000-000000000001"}"#
        let ompd = #"{"app_name":"ompd","slice_uuid":"4c4c447c-5555-3144-a138-dbd9c49417a3"}"#
        try report("ompd-2026-10-01-140212.ips", at: 60, header: ompd)
        try report("Lantern-2026-10-01-150000.ips", at: 120, header: app)
        try report("ompd-2026-09-30-090000.ips", at: -60, header: ompd)
        try report("ompd-2026-10-01-130000.ips", at: 0, header: ompd)
        try report("omp-2026-10-01-140212.ips", at: 60, header: ompd)
        try report("ompd.cpu_resource-2026-10-01-140212.diag", at: 60, header: ompd)
        try report("Retired/ompd-2026-10-01-160000.ips", at: 180, header: ompd)
        // Another copy of the app, another build of ompd, and a report that is no report.
        try report("Lantern-2026-10-01-151000.ips", at: 130, header: #"{"app_name":"Lantern","bundleID":"com.magicelklabs.lantern.qa"}"#)
        try report("ompd-2026-10-01-152000.ips", at: 140, header: #"{"app_name":"ompd","slice_uuid":"5d5d0000-5555-3144-a138-dbd9c49417a3"}"#)
        try report("Lantern-2026-10-01-153000.ips", at: 150, header: "not json")

        let found = CrashReport.newer(than: lastSeen, in: directory, of: Self.owner)
        #expect(found.map(\.url.lastPathComponent) == ["Lantern-2026-10-01-150000.ips", "ompd-2026-10-01-140212.ips"])
        #expect(found.map(\.process) == ["Lantern", "ompd"])
        #expect(CrashReport.newer(than: lastSeen.addingTimeInterval(120), in: directory, of: Self.owner).isEmpty, "seen up to the newest")
        #expect(CrashReport.newer(than: .distantPast, in: directory.appending(path: "missing"), of: Self.owner).isEmpty)
    }

    @Test func machOUUIDsOfThinAndUniversalFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "macho-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let arm = UUID(), intel = UUID()
        func little(_ value: UInt32) -> [UInt8] { withUnsafeBytes(of: value.littleEndian, Array.init) }
        func big(_ value: UInt32) -> [UInt8] { withUnsafeBytes(of: value.bigEndian, Array.init) }
        /// A 64-bit slice: its header, a symbol table command, then LC_UUID.
        func slice(_ uuid: UUID) -> [UInt8] {
            let symtab = little(0x2) + little(24) + [UInt8](repeating: 0, count: 16)
            let uuidCommand = little(0x1B) + little(24) + withUnsafeBytes(of: uuid.uuid, Array.init)
            let header = little(0xFEED_FACF) + little(0x0100_000C) + little(0) + little(2) + little(2)
                + little(UInt32(symtab.count + uuidCommand.count)) + little(0) + little(0)
            return header + symtab + uuidCommand
        }
        let thin = directory.appending(path: "thin")
        try Data(slice(arm)).write(to: thin)
        #expect(MachOFile.uuids(ofFileAt: thin) == [arm])

        var universal = big(0xCAFE_BABE) + big(2)
        universal += big(0x0100_000C) + big(0) + big(4096) + big(UInt32(slice(arm).count)) + big(12)
        universal += big(0x0100_0007) + big(3) + big(8192) + big(UInt32(slice(intel).count)) + big(12)
        universal += [UInt8](repeating: 0, count: 4096 - universal.count) + slice(arm)
        universal += [UInt8](repeating: 0, count: 8192 - universal.count) + slice(intel)
        let fat = directory.appending(path: "universal")
        try Data(universal).write(to: fat)
        #expect(MachOFile.uuids(ofFileAt: fat) == [arm, intel])

        #expect(MachOFile.uuids(ofFileAt: directory.appending(path: "missing")).isEmpty)
        #expect(!MachOFile.uuids(ofFileAt: URL(filePath: "/usr/bin/true")).isEmpty, "a real executable")
    }
}
