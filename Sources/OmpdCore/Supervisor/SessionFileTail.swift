import Foundation
import IDEProtocol

/// Reads the end of an omp session JSONL (`session.md`) to learn how the omp process that wrote it ended.
enum SessionFileTail {
    /// Bytes read from the end of the file. After a stdin EOF omp appends the aborted tool results and partial reply
    /// *after* `session_exit`, so the marker is not always the last line.
    static let defaultWindow = 4 << 20

    /// `kind` (`normal`/`signal`/`fatal`/`process_exit`) of the newest `session_exit` entry in the last `window` bytes
    /// of `path`, provided it was recorded at or after `since` — an older one belongs to a previous omp run of the
    /// same session. nil when the process wrote none (SIGKILL) or the file cannot be read.
    static func sessionExitKind(path: String, recordedSince since: Date, window: Int = defaultWindow) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > UInt64(window) ? size - UInt64(window) : 0
        guard (try? handle.seek(toOffset: start)) != nil, let data = try? handle.readToEnd(), !data.isEmpty else { return nil }
        let decoder = JSONDecoder()
        var end = data.endIndex
        while end > data.startIndex {
            let newline = data[data.startIndex..<end].lastIndex(of: 0x0A)
            let lineStart = newline.map { data.index(after: $0) } ?? data.startIndex
            let line = data[lineStart..<end]
            end = newline ?? data.startIndex
            // The first line of a window that starts mid-file is partial; it cannot parse and is skipped.
            guard line.count > 2, let entry = try? decoder.decode(JSONValue.self, from: line),
                  entry["type"]?.stringValue == "custom", entry["customType"]?.stringValue == "session_exit"
            else { continue }
            let data = entry["data"]
            guard let recorded = data?["recordedAt"]?.stringValue.flatMap(parseTimestamp),
                  recorded >= since.addingTimeInterval(-0.001)
            else { return nil }
            return data?["kind"]?.stringValue
        }
        return nil
    }

    /// Returns once `path` has not changed (size and modification time) for `quietPeriod`, or after `timeout`.
    /// A one-off check at resume time, sampled every 100 ms.
    static func waitForQuiescence(path: String, quietPeriod: Duration = .seconds(1), timeout: Duration = .seconds(15)) async {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        var last = fingerprint(path)
        var stableSince = clock.now
        while clock.now < deadline, clock.now - stableSince < quietPeriod {
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            let current = fingerprint(path)
            if current != last {
                last = current
                stableSince = clock.now
            }
        }
    }

    private struct Fingerprint: Equatable {
        var size: off_t
        var seconds: Int
        var nanoseconds: Int
    }

    private static func fingerprint(_ path: String) -> Fingerprint? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return Fingerprint(size: info.st_size, seconds: info.st_mtimespec.tv_sec, nanoseconds: info.st_mtimespec.tv_nsec)
    }

    /// omp's `recordedAt` and entry `timestamp`: `2026-09-25T10:45:22.233Z`.
    static func parseTimestamp(_ text: String) -> Date? {
        if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text) { return date }
        return try? Date.ISO8601FormatStyle().parse(text)
    }
}
