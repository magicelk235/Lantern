import Foundation
import GRDB
import IDEProtocol
import os

/// `$APP_SUPPORT/state.sqlite`: what the IDE itself owns — window layouts with their tabs, per-session UI
/// (composer draft, scroll anchor, last seq seen), per-file editor UI (selections, scroll) and hot-exit dirty buffers —
/// in SQLite (WAL) through GRDB.
///
/// - Window, session and editor UI changes are coalesced and written `debounce` after the last one, and at most
///   `maxDelay` after the first unwritten one while changes keep coming; `flush()` writes them at once. WAL makes each
///   write atomic, so a crash loses at most the unwritten changes.
/// - Dirty buffers are written synchronously in `synchronous=FULL` transactions (flushed with `F_FULLFSYNC`) and
///   mirrored to `hot-exit/<sha256(path)>` plain files: once a buffer call returns, the edit survives a crash or a
///   power loss, and also a lost or corrupt database.
/// - A database SQLite cannot use (not a database, corrupt) is moved aside to `state.sqlite.corrupt-<timestamp>` and
///   recreated, and the dirty buffers come back from their mirror files (`recovery` tells what happened).
///
/// Thread-safe: every database access runs on one serial queue, in call order. Changes still pending when the store
/// is released are dropped, as in a crash; call `flush()` first.
public final class StateStore: Sendable {
    /// The database was unusable at open and was recreated.
    public struct Recovery: Sendable, Equatable {
        /// Why SQLite could not use it.
        public var reason: String
        /// Where the unusable database file now is.
        public var movedAside: URL
        /// Paths of the dirty buffers restored from their hot-exit mirrors.
        public var restoredBuffers: [String]
    }

    public let databaseURL: URL
    public let hotExitDirectory: URL
    public let recovery: Recovery?

    private let database: DatabaseQueue
    private let debounce: Duration
    private let maxDelay: Duration
    private let queue = DispatchQueue(label: "com.omp-ide.state")
    private let pending = OSAllocatedUnfairLock(initialState: Pending())

    /// Window, session and editor UI changes not written yet.
    private struct Pending: Sendable {
        var windows: [String: WindowState] = [:]
        var sessions: [SessionKey: SessionUIState] = [:]
        var editors: [String: EditorUIState] = [:]
        /// Arrival of the oldest and of the newest unwritten change.
        var first: ContinuousClock.Instant?
        var last: ContinuousClock.Instant?
        /// A debounce timer is scheduled on `queue`.
        var armed = false

        var isEmpty: Bool { windows.isEmpty && sessions.isEmpty && editors.isEmpty }
    }

    /// Opens (creating, migrating or recovering) `paths.stateDB`, with dirty-buffer mirrors in `paths.hotExit`.
    public convenience init(
        paths: AppSupportPaths, debounce: Duration = .milliseconds(250), maxDelay: Duration = .seconds(1)
    ) throws {
        try self.init(databaseURL: paths.stateDB, hotExitDirectory: paths.hotExit, debounce: debounce, maxDelay: maxDelay)
    }

    public init(
        databaseURL: URL, hotExitDirectory: URL, debounce: Duration = .milliseconds(250), maxDelay: Duration = .seconds(1)
    ) throws {
        self.databaseURL = databaseURL
        self.hotExitDirectory = hotExitDirectory
        self.debounce = debounce
        self.maxDelay = max(maxDelay, debounce)
        try FileIO.createPrivateDirectory(databaseURL.deletingLastPathComponent())
        var recovery: Recovery?
        do {
            database = try Self.openDatabase(at: databaseURL)
        } catch let error where Self.isUnusable(error) {
            let aside = try Self.moveAside(databaseURL)
            stateLog.error(
                "state database unusable (\(String(describing: error), privacy: .public)); moved to \(aside.path(percentEncoded: false), privacy: .public), starting over"
            )
            database = try Self.openDatabase(at: databaseURL)
            recovery = Recovery(reason: String(describing: error), movedAside: aside, restoredBuffers: [])
        }
        let restored = try Self.reconcileMirrors(database, in: hotExitDirectory)
        recovery?.restoredBuffers = restored
        self.recovery = recovery
    }

    // MARK: - Windows and session UI (debounced)

    /// Window `id`'s layout, including a change not written yet.
    public func window(id: String) throws -> WindowState? {
        try queue.sync {
            if let state = pending.withLock({ $0.windows[id] }) { return state }
            return try database.read { db in try WindowRecord.fetchOne(db, key: id)?.state }
        }
    }

    /// The UI of every session that has one, including changes not written yet.
    public func sessionUIStates() throws -> [SessionKey: SessionUIState] {
        try queue.sync {
            var states: [SessionKey: SessionUIState] = [:]
            for record in try database.read({ db in try SessionUIRecord.fetchAll(db) }) {
                states[record.state.sessionKey] = record.state
            }
            for (key, state) in pending.withLock({ $0.sessions }) { states[key] = state }
            return states
        }
    }

    /// Where each file's editor was, by path, including changes not written yet.
    public func editorUIStates() throws -> [String: EditorUIState] {
        try queue.sync {
            var states: [String: EditorUIState] = [:]
            for record in try database.read({ db in try EditorUIRecord.fetchAll(db) }) {
                states[record.state.path] = record.state
            }
            for (path, state) in pending.withLock({ $0.editors }) { states[path] = state }
            return states
        }
    }

    /// Replaces window `state.id`'s layout, written after the debounce or by `flush()`.
    public func setWindow(_ state: WindowState) {
        record { $0.windows[state.id] = state }
    }

    /// Replaces the UI of session `state.sessionKey`, written after the debounce or by `flush()`.
    public func setSessionUI(_ state: SessionUIState) {
        record { $0.sessions[state.sessionKey] = state }
    }

    /// Replaces where the editor of `state.path` is, written after the debounce or by `flush()`.
    public func setEditorUI(_ state: EditorUIState) {
        record { $0.editors[state.path] = state }
    }

    /// Writes every pending change now and returns once it is committed. On failure the changes stay pending.
    public func flush() throws {
        try queue.sync { try writePending() }
    }

    private func record(_ change: @Sendable (inout Pending) -> Void) {
        let now = ContinuousClock.now
        let arm = pending.withLock { pending -> Bool in
            change(&pending)
            if pending.first == nil { pending.first = now }
            pending.last = now
            guard !pending.armed else { return false }
            pending.armed = true
            return true
        }
        if arm { armTimer(after: debounce) }
    }

    private func armTimer(after delay: Duration) {
        let seconds = Double(delay.components.seconds) + Double(delay.components.attoseconds) / 1e18
        // Weak: a store released with changes pending drops them, like a crash would.
        queue.asyncAfter(deadline: .now() + seconds) { [weak self] in self?.timerFired() }
    }

    /// On `queue`. Writes once `debounce` passed without a change, or `maxDelay` since the oldest unwritten one.
    private func timerFired() {
        let now = ContinuousClock.now
        let (debounce, maxDelay) = (debounce, maxDelay)
        let wait = pending.withLock { pending -> Duration? in
            guard let first = pending.first, let last = pending.last else {
                pending.armed = false
                return nil
            }
            let due = min(last + debounce, first + maxDelay)
            guard now >= due else { return due - now }
            pending.armed = false
            return nil
        }
        if let wait {
            armTimer(after: wait)
            return
        }
        do {
            try writePending()
        } catch {
            stateLog.error("writing window and session state failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// On `queue`.
    private func writePending() throws {
        let batch = pending.withLock { pending -> Pending in
            let batch = pending
            pending.windows = [:]
            pending.sessions = [:]
            pending.editors = [:]
            pending.first = nil
            pending.last = nil
            return batch
        }
        guard !batch.isEmpty else { return }
        do {
            try database.write { db in
                for state in batch.windows.values { try WindowRecord(state).upsert(db) }
                for state in batch.sessions.values { try SessionUIRecord(state).upsert(db) }
                for state in batch.editors.values { try EditorUIRecord(state).upsert(db) }
            }
        } catch {
            // Newer changes that came in meanwhile win; the rest waits for the next write.
            pending.withLock { pending in
                pending.windows.merge(batch.windows) { newer, _ in newer }
                pending.sessions.merge(batch.sessions) { newer, _ in newer }
                pending.editors.merge(batch.editors) { newer, _ in newer }
                if let first = batch.first { pending.first = min(pending.first ?? first, first) }
                if pending.last == nil { pending.last = batch.last }
            }
            throw error
        }
    }

    // MARK: - Dirty buffers (synchronous, durable)

    /// Stores `buffer`, replacing the one for its path, then its hot-exit mirror. When this returns the edit is on
    /// stable storage. Takes a few milliseconds (two `F_FULLFSYNC`s): call it off the main thread.
    public func saveDirtyBuffer(_ buffer: DirtyBuffer) throws {
        try queue.sync {
            try writeDurably { db in try DirtyBufferRecord(buffer).upsert(db) }
            try HotExitMirror.write(buffer, in: hotExitDirectory)
        }
    }

    /// Forgets the dirty buffer of `path` (saved or reverted). The mirror goes first: a crash in between leaves the
    /// row, restored as a dirty buffer, never a mirror that would come back after the database is lost.
    public func clearDirtyBuffer(path: String) throws {
        try queue.sync {
            try HotExitMirror.remove(path: path, in: hotExitDirectory)
            try writeDurably { db in _ = try DirtyBufferRecord.deleteOne(db, key: path) }
        }
    }

    /// Every dirty buffer, by path.
    public func dirtyBuffers() throws -> [DirtyBuffer] {
        try queue.sync {
            try database.read { db in try DirtyBufferRecord.order(Column("path")).fetchAll(db) }.map(\.buffer)
        }
    }

    /// One transaction under `synchronous=FULL`: the WAL is flushed to stable storage before the commit returns.
    private func writeDurably(_ updates: (Database) throws -> Void) throws {
        try database.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA synchronous = FULL")
            defer { try? db.execute(sql: "PRAGMA synchronous = NORMAL") }
            try db.inTransaction {
                try updates(db)
                return .commit
            }
        }
    }

    // MARK: - Opening

    private struct FailedIntegrityCheck: Error, CustomStringConvertible {
        var problems: [String]
        var description: String { "integrity check failed: \(problems.joined(separator: "; "))" }
    }

    private static func openDatabase(at url: URL) throws -> DatabaseQueue {
        var configuration = Configuration()
        configuration.label = "state.sqlite"
        // WAL, where GRDB also sets `synchronous=NORMAL`: commits are atomic and survive an app crash without a flush;
        // dirty buffers switch to FULL per transaction. Whenever SQLite does flush, it uses F_FULLFSYNC.
        configuration.journalMode = .wal
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA fullfsync = ON; PRAGMA checkpoint_fullfsync = ON")
        }
        // Drafts and unsaved buffers are private (0600); SQLite gives `-wal` and `-shm` the database file's mode.
        try FileIO.makePrivate(url, create: true)
        for suffix in ["-wal", "-shm"] {
            try FileIO.makePrivate(URL(filePath: url.path(percentEncoded: false) + suffix), create: false)
        }
        let database = try DatabaseQueue(path: url.path(percentEncoded: false), configuration: configuration)
        do {
            let problems = try database.read { db in try String.fetchAll(db, sql: "PRAGMA quick_check") }
            guard problems == ["ok"] else { throw FailedIntegrityCheck(problems: problems) }
            try StateSchema.migrator.migrate(database)
        } catch {
            try? database.close()
            throw error
        }
        return database
    }

    private static func isUnusable(_ error: any Error) -> Bool {
        if error is FailedIntegrityCheck { return true }
        guard let error = error as? DatabaseError else { return false }
        return error.resultCode == .SQLITE_CORRUPT || error.resultCode == .SQLITE_NOTADB
    }

    /// Renames the database and its `-wal`/`-shm` files to `<name>.corrupt-<timestamp>[-n]` (kept for the user, never
    /// overwritten) and returns the new database path.
    private static func moveAside(_ url: URL) throws -> URL {
        let stamp = Date().formatted(
            Date.ISO8601FormatStyle(
                dateSeparator: .omitted, dateTimeSeparator: .standard, timeSeparator: .omitted,
                includingFractionalSeconds: true, timeZone: .gmt))
        let directory = url.deletingLastPathComponent()
        let files = ["", "-wal", "-shm"].map { suffix in
            directory.appending(path: url.lastPathComponent + suffix, directoryHint: .notDirectory)
        }
        for attempt in 1... {
            let base = "\(url.lastPathComponent).corrupt-\(stamp)" + (attempt == 1 ? "" : "-\(attempt)")
            let targets = ["", "-wal", "-shm"].map { suffix in
                directory.appending(path: base + suffix, directoryHint: .notDirectory)
            }
            guard !targets.contains(where: { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) })
            else { continue }
            for (file, target) in zip(files, targets) where FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) {
                try FileManager.default.moveItem(at: file, to: target)
            }
            return targets[0]
        }
        preconditionFailure("unreachable: 1... never ends")
    }

    /// Puts dirty buffers and mirrors back in step after a crash or a lost database. Buffer writes put the row before
    /// the mirror and removals take the mirror first, so a mirror without a row means the database was lost: it is
    /// imported. A row whose mirror is missing or stale gets it rewritten (the database wins).
    private static func reconcileMirrors(_ database: DatabaseQueue, in directory: URL) throws -> [String] {
        let mirrors = HotExitMirror.loadAll(in: directory)
        let rows = try database.read { db in try DirtyBufferRecord.fetchAll(db) }.map(\.buffer)
        let stored = Set(rows.map(\.path))
        let orphans = mirrors.filter { !stored.contains($0.path) }
        if !orphans.isEmpty {
            try database.write { db in
                for buffer in orphans { try DirtyBufferRecord(buffer).insert(db) }
            }
        }
        let mirrored = Dictionary(mirrors.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        for row in rows where mirrored[row.path] != row {
            do {
                try HotExitMirror.write(row, in: directory)
            } catch {
                stateLog.error("rewriting the hot-exit mirror of \(row.path, privacy: .private) failed: \(String(describing: error), privacy: .public)")
            }
        }
        return orphans.map(\.path)
    }
}
