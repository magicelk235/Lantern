import Foundation

/// A crash report macOS wrote for this app or the ompd it runs (`~/Library/Logs/DiagnosticReports/<process>-<date>.ips`).
/// Local only: only its name, its date and its first line, the report's header, are read; nothing is sent anywhere.
public struct CrashReport: Sendable, Equatable, Identifiable {
    public var id: URL { url }
    public var url: URL
    /// `ompd` or `Lantern`.
    public var process: String
    /// When macOS wrote it, about when the process quit.
    public var date: Date

    public init(url: URL, process: String, date: Date) {
        self.url = url
        self.process = process
        self.date = date
    }

    /// The processes reported, by the prefix of their reports' names.
    public static let processes = ["ompd", "Lantern"]

    /// Where macOS writes the reports of the user's processes.
    public static var standardDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/DiagnosticReports", directoryHint: .isDirectory)
    }

    /// Whose reports are news: those of this app and of the ompd in its bundle. Another copy of Lantern (a developer's
    /// build, a beta under another bundle identifier) or another program of the same name writes reports of the same
    /// name, told apart by their header.
    public struct Owner: Sendable, Equatable {
        /// The app's bundle identifier, which the header of its reports names (`bundleID`).
        public var bundleIdentifier: String
        /// The UUIDs of the ompd executable the app runs, one per architecture: ompd is a bare tool, and the header of
        /// its reports names the UUID of the slice that ran (`slice_uuid`).
        public var ompdUUIDs: Set<UUID>

        public init(bundleIdentifier: String, ompdUUIDs: Set<UUID>) {
            self.bundleIdentifier = bundleIdentifier
            self.ompdUUIDs = ompdUUIDs
        }

        /// The app of `bundle` and the ompd in it (`Contents/MacOS/ompd`).
        public static func app(_ bundle: Bundle = .main) -> Owner {
            Owner(
                bundleIdentifier: bundle.bundleIdentifier ?? "",
                ompdUUIDs: MachOFile.uuids(ofFileAt: bundle.bundleURL.appending(path: "Contents/MacOS/ompd")))
        }

        func owns(_ header: Header, process: String) -> Bool {
            if process == "ompd" { return header.sliceUUID.flatMap(UUID.init(uuidString:)).map(ompdUUIDs.contains) ?? false }
            return header.bundleID == bundleIdentifier
        }
    }

    /// The reports in `directory` (not its subfolders) of `processes` — `ompd*.ips`, `Lantern*.ips` — that `owner`'s
    /// processes left, modified after `lastSeen`, newest first. A missing or unreadable folder has none.
    public static func newer(than lastSeen: Date, in directory: URL, of owner: Owner) -> [CrashReport] {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys))) ?? []
        return files.compactMap { url -> CrashReport? in
            let name = url.lastPathComponent
            guard name.hasSuffix(".ips"), let process = processes.first(where: { name.hasPrefix($0) }),
                  let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true,
                  let date = values.contentModificationDate, date > lastSeen,
                  let header = Header(contentsOf: url), owner.owns(header, process: process)
            else { return nil }
            return CrashReport(url: url, process: process, date: date)
        }
        .sorted { $0.date > $1.date }
    }

    /// The first line of an `.ips` report: a JSON object about the process that crashed.
    struct Header: Decodable {
        var bundleID: String?
        var sliceUUID: String?

        enum CodingKeys: String, CodingKey {
            case bundleID
            case sliceUUID = "slice_uuid"
        }

        /// nil when the file is unreadable or its first line is no header.
        init?(contentsOf url: URL) {
            guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? handle.close() }
            guard let prefix = try? handle.read(upToCount: 4096),
                  let line = prefix.split(separator: UInt8(ascii: "\n"), maxSplits: 1, omittingEmptySubsequences: false).first,
                  let header = try? JSONDecoder().decode(Header.self, from: Data(line))
            else { return nil }
            self = header
        }
    }
}

/// Reads Mach-O executables.
enum MachOFile {
    /// The `LC_UUID` of each 64-bit slice of the Mach-O file at `url`: one for a thin file, one per architecture for a
    /// universal one. Empty when the file is unreadable or not a Mach-O file.
    static func uuids(ofFileAt url: URL) -> Set<UUID> {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        func read(_ count: Int, at offset: UInt64) -> Data? {
            guard (try? handle.seek(toOffset: offset)) != nil, let data = try? handle.read(upToCount: count), data.count == count
            else { return nil }
            return data
        }
        guard let start = read(8, at: 0) else { return [] }
        // A universal file's header and architecture table are big-endian; a slice is in its own (little-endian) order.
        let slices: [UInt64]
        switch start.bigEndian(UInt32.self, at: 0) {
        case 0xCAFE_BABE, 0xCAFE_BABF:
            let wide = start.bigEndian(UInt32.self, at: 0) == 0xCAFE_BABF
            let count = Int(start.bigEndian(UInt32.self, at: 4))
            let entry = wide ? 32 : 20
            guard count < 64, let table = read(count * entry, at: 8) else { return [] }
            slices = (0..<count).map { index in
                wide ? table.bigEndian(UInt64.self, at: index * entry + 8) : UInt64(table.bigEndian(UInt32.self, at: index * entry + 8))
            }
        default:
            slices = [0]
        }
        var uuids: Set<UUID> = []
        for slice in slices {
            // mach_header_64: magic, cputype, cpusubtype, filetype, ncmds, sizeofcmds, flags, reserved.
            guard let header = read(32, at: slice), header.littleEndian(UInt32.self, at: 0) == 0xFEED_FACF else { continue }
            let size = Int(header.littleEndian(UInt32.self, at: 20))
            guard size < 1 << 24, let commands = read(size, at: slice + 32) else { continue }
            var offset = 0
            while offset + 8 <= commands.count {
                let command = commands.littleEndian(UInt32.self, at: offset)
                let length = Int(commands.littleEndian(UInt32.self, at: offset + 4))
                guard length >= 8 else { break }
                if command == 0x1B, offset + 24 <= commands.count { // LC_UUID
                    uuids.insert(UUID(uuid: commands.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset + 8, as: uuid_t.self) }))
                    break
                }
                offset += length
            }
        }
        return uuids
    }
}

private extension Data {
    func bigEndian<T: FixedWidthInteger>(_: T.Type, at offset: Int) -> T {
        T(bigEndian: withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: T.self) })
    }

    func littleEndian<T: FixedWidthInteger>(_: T.Type, at offset: Int) -> T {
        T(littleEndian: withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: T.self) })
    }
}
