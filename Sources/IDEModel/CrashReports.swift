import Foundation

/// A crash report macOS wrote for ompd or omp IDE (`~/Library/Logs/DiagnosticReports/<process>-<date>.ips`). Local only:
/// only its name and modification date are read; nothing is parsed or sent anywhere.
public struct CrashReport: Sendable, Equatable, Identifiable {
    public var id: URL { url }
    public var url: URL
    /// `ompd` or `omp IDE`.
    public var process: String
    /// When macOS wrote it, about when the process quit.
    public var date: Date

    public init(url: URL, process: String, date: Date) {
        self.url = url
        self.process = process
        self.date = date
    }

    /// The processes reported, by the prefix of their reports' names.
    public static let processes = ["ompd", "omp IDE"]

    /// Where macOS writes the reports of the user's processes.
    public static var standardDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Logs/DiagnosticReports", directoryHint: .isDirectory)
    }

    /// The reports in `directory` (not its subfolders) of `processes` — `ompd*.ips`, `omp IDE*.ips` — modified after
    /// `lastSeen`, newest first. A missing or unreadable folder has none.
    public static func newer(than lastSeen: Date, in directory: URL) -> [CrashReport] {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys))) ?? []
        return files.compactMap { url -> CrashReport? in
            let name = url.lastPathComponent
            guard name.hasSuffix(".ips"), let process = processes.first(where: { name.hasPrefix($0) }),
                  let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true,
                  let date = values.contentModificationDate, date > lastSeen
            else { return nil }
            return CrashReport(url: url, process: process, date: date)
        }
        .sorted { $0.date > $1.date }
    }
}
