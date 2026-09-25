import Darwin
import Foundation
import IDEProtocol

/// Append-only per-session event journal, `<directory>/<sessionKey>.jsonl`: one `JournalRecord` per
/// line (`IDECoding` encoding), `seq` contiguous from 1, replayable to any subscriber.
///
/// Every append is a `write(2)` on one fd kept open for the journal's lifetime; only durable boundaries
/// (`isDurableBoundary(ompFrame:)`, the caller's `durable` flag) and `sync()`/`close()` flush to stable storage.
/// Its methods run on the journal's own serial dispatch queue, so blocking file I/O stays off the Swift cooperative pool.
public actor Journal {
    public nonisolated let sessionKey: SessionKey
    public nonisolated let fileURL: URL
    /// Seq of the newest record; 0 while the journal is empty.
    public private(set) var lastSeq: Seq

    private let queue: DispatchSerialQueue
    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    /// -1 once closed.
    private var fd: Int32
    /// Length of the journal's complete lines; the file size unless an append is in flight.
    private var endOffset: Int64
    private var hasUnsyncedWrites = false
    private let encoder = IDECoding.encoder()
    private let decoder = IDECoding.decoder()
    private var subscribers: [Int: AsyncStream<JournalRecord>.Continuation] = [:]
    private var nextSubscriberID = 0

    /// Flushes to stable storage performed so far (test hook for the durability policy).
    private(set) var syncCount = 0
    /// Live subscriptions still registered (test hook for unregistration).
    var subscriberCount: Int { subscribers.count }

    /// Opens (creating if needed) the session's journal. Recovers `lastSeq` by scanning back from the end of the
    /// file; a torn final line — an append cut short by a crash or power loss, with or without its newline — is
    /// truncated away before anything else is written.
    public init(directory: URL, sessionKey: SessionKey) throws {
        guard Self.isUsableFileName(sessionKey) else { throw StorageError.invalidSessionKey(sessionKey) }
        try StorageIO.createDirectory(directory)
        let url = directory.appending(path: sessionKey + ".jsonl", directoryHint: .notDirectory)
        let (fd, created) = try StorageIO.openForAppend(url)
        let recovered: (end: Int64, lastSeq: Seq)
        do {
            if created { try StorageIO.syncDirectory(directory) }
            recovered = try Self.recover(fd: fd, url: url)
        } catch {
            StorageIO.close(fd)
            throw error
        }
        self.sessionKey = sessionKey
        self.fileURL = url
        self.fd = fd
        self.endOffset = recovered.end
        self.lastSeq = recovered.lastSeq
        self.queue = DispatchSerialQueue(label: "com.omp-ide.ompd.journal.\(sessionKey)")
    }

    deinit {
        for continuation in subscribers.values { continuation.finish() }
        if fd >= 0 { StorageIO.close(fd) }
    }

    /// Frames at which omp has reached a point worth surviving power loss: turn/run completion, settle, and every
    /// request omp blocks on (so a pending dialog is never lost). Everything else — streaming deltas above all —
    /// is written without a flush, matching omp's own no-fsync session files.
    public static func isDurableBoundary(ompFrame: JSONValue) -> Bool {
        guard let type = ompFrame["type"]?.stringValue else { return false }
        return durableFrameTypes.contains(type)
    }

    private static let durableFrameTypes: Set<String> = [
        "turn_end", "agent_end", "prompt_result", "session_settled", "extension_ui_request", "host_tool_call",
    ]

    /// Appends one record (`seq = lastSeq + 1`, `ts = now`) and delivers it to live subscribers. With `durable`,
    /// the record is flushed to stable storage before it is delivered or returned. All or nothing: if the write
    /// or flush fails, the file is cut back to its previous length, `lastSeq` is unchanged and nobody sees it.
    @discardableResult
    public func append(kind: JournalRecord.Kind, payload: JSONValue, durable: Bool) throws -> JournalRecord {
        let fd = try openDescriptor()
        let record = JournalRecord(sessionKey: sessionKey, seq: lastSeq + 1, ts: Date(), kind: kind, payload: payload)
        var line = try encoder.encode(record)
        line.append(0x0A)
        do {
            try StorageIO.write(fd, line, fileURL)
            hasUnsyncedWrites = true
            if durable { try flush(fd) }
        } catch {
            do {
                try StorageIO.truncate(fd, to: endOffset, fileURL)
            } catch let rollback {
                StorageIO.log.fault(
                    "journal \(self.fileURL.path(percentEncoded: false), privacy: .public): rollback of failed append failed: \(String(describing: rollback), privacy: .public)"
                )
            }
            throw error
        }
        endOffset += Int64(line.count)
        lastSeq = record.seq
        for (id, continuation) in subscribers {
            if case .terminated = continuation.yield(record) { subscribers[id] = nil }
        }
        return record
    }

    /// Records with `seq > since`, oldest first; `[]` when `since == lastSeq`; nil when `since > lastSeq`
    /// (a seq this journal never issued). Reads backwards from the end, so the cost is proportional to the
    /// records returned, not to the journal's length.
    public func records(after since: Seq) throws -> [JournalRecord]? {
        let fd = try openDescriptor()
        guard since <= lastSeq else { return nil }
        var result: [JournalRecord] = []
        guard since < lastSeq else { return result }
        var reader = ReverseLineReader(fd: fd, url: fileURL)
        var end = endOffset
        while end > 0 {
            let line = try reader.line(endingAt: end)
            end = line.start
            let record: JournalRecord
            do {
                record = try decoder.decode(JournalRecord.self, from: line.bytes)
            } catch {
                StorageIO.log.error(
                    "journal \(self.fileURL.path(percentEncoded: false), privacy: .public): skipping undecodable line at offset \(line.start): \(String(describing: error), privacy: .public)"
                )
                continue
            }
            if record.seq <= since { break }
            result.append(record)
        }
        result.reverse()
        return result
    }

    /// Replay-then-live subscription: `replay` holds every record with `seq > since`; `live` yields every record
    /// appended afterwards. Both are taken in one actor turn, so together they are gap- and duplicate-free.
    /// nil when `since > lastSeq`. The live stream is unbounded; it ends on `close()`, and cancelling its consumer
    /// (or dropping the stream) unregisters it.
    public func subscribe(after since: Seq) throws -> (replay: [JournalRecord], live: AsyncStream<JournalRecord>)? {
        guard let replay = try records(after: since) else { return nil }
        let (live, continuation) = AsyncStream.makeStream(of: JournalRecord.self, bufferingPolicy: .unbounded)
        let id = nextSubscriberID
        nextSubscriberID += 1
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            Task { await self.unsubscribe(id) }
        }
        subscribers[id] = continuation
        return (replay, live)
    }

    /// Flushes every appended record to stable storage (no-op when nothing was written since the last flush).
    public func sync() throws {
        let fd = try openDescriptor()
        if hasUnsyncedWrites { try flush(fd) }
    }

    /// Flushes pending writes, ends every live stream and closes the file. Further calls are no-ops; any other
    /// use afterwards throws `StorageError.journalClosed`.
    public func close() throws {
        guard fd >= 0 else { return }
        let fd = self.fd
        var flushError: (any Error)?
        if hasUnsyncedWrites {
            do { try flush(fd) } catch { flushError = error }
        }
        self.fd = -1
        for continuation in subscribers.values { continuation.finish() }
        subscribers.removeAll()
        StorageIO.close(fd)
        if let flushError { throw flushError }
    }

    private func unsubscribe(_ id: Int) {
        subscribers[id] = nil
    }

    private func openDescriptor() throws -> Int32 {
        guard fd >= 0 else { throw StorageError.journalClosed(sessionKey) }
        return fd
    }

    private func flush(_ fd: Int32) throws {
        try StorageIO.fullSync(fd, fileURL)
        hasUnsyncedWrites = false
        syncCount += 1
    }

    /// A session key must be one file-name component, leaving room for the `.jsonl` suffix within NAME_MAX.
    private static func isUsableFileName(_ key: SessionKey) -> Bool {
        !key.isEmpty && key != "." && key != ".." && !key.contains("/") && !key.contains("\0")
            && key.utf8.count + ".jsonl".utf8.count <= Int(NAME_MAX)
    }

    /// Drops a torn tail and returns the end of the last intact line and its seq. Lines are only checked for being
    /// a JSON object with a numeric `seq`, so records a newer daemon wrote (unknown kinds) are never cut.
    private static func recover(fd: Int32, url: URL) throws -> (end: Int64, lastSeq: Seq) {
        let size = try StorageIO.fileSize(fd, url)
        var reader = ReverseLineReader(fd: fd, url: url)
        var end = try reader.lastNewline(before: size).map { $0 + 1 } ?? 0
        var lastSeq: Seq = 0
        let probe = JSONDecoder()
        while end > 0 {
            let line = try reader.line(endingAt: end)
            if let seq = try? probe.decode(SeqProbe.self, from: line.bytes).seq {
                lastSeq = seq
                break
            }
            end = line.start
        }
        if end < size {
            StorageIO.log.error(
                "journal \(url.path(percentEncoded: false), privacy: .public): truncating \(size - end) bytes of torn tail"
            )
            try StorageIO.truncate(fd, to: end, url)
            try StorageIO.fullSync(fd, url)
        }
        return (end, lastSeq)
    }

    private struct SeqProbe: Decodable {
        var seq: Seq
    }
}

/// Walks newline-terminated lines from the end of a file towards its start, reading `StorageIO.chunkSize` chunks
/// with `pread` (the journal's fd is shared with appends; no file offset is moved).
private struct ReverseLineReader {
    private let fd: Int32
    private let url: URL
    /// Cached bytes `[chunkStart, chunkStart + chunk.count)` of the file.
    private var chunk = Data()
    private var chunkStart: Int64 = 0

    init(fd: Int32, url: URL) {
        self.fd = fd
        self.url = url
    }

    /// Offset of the last `\n` in `[0, end)`, or nil if there is none.
    mutating func lastNewline(before end: Int64) throws -> Int64? {
        var upper = end
        while upper > 0 {
            if !(upper > chunkStart && upper <= chunkStart + Int64(chunk.count)) {
                let lower = max(0, upper - Int64(StorageIO.chunkSize))
                chunk = try StorageIO.read(fd, count: Int(upper - lower), at: lower, url)
                chunkStart = lower
            }
            let limit = Int(upper - chunkStart)
            let hit: Int? = chunk.withUnsafeBytes { raw in
                var index = limit - 1
                while index >= 0 {
                    if raw[index] == 0x0A { return index }
                    index -= 1
                }
                return nil
            }
            if let hit { return chunkStart + Int64(hit) }
            upper = chunkStart
        }
        return nil
    }

    /// The line whose terminating `\n` sits at `end - 1`: its first byte's offset and its bytes without the newline.
    mutating func line(endingAt end: Int64) throws -> (start: Int64, bytes: Data) {
        let newline = end - 1
        let start = try lastNewline(before: newline).map { $0 + 1 } ?? 0
        let count = Int(newline - start)
        if start >= chunkStart, newline <= chunkStart + Int64(chunk.count) {
            let lower = Int(start - chunkStart)
            return (start, chunk.subdata(in: lower..<(lower + count)))
        }
        return (start, try StorageIO.read(fd, count: count, at: start, url))
    }
}
