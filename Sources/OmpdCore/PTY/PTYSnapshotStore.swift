import Darwin
import Foundation
import IDEProtocol

/// On-disk form of one PTY (`<dir>/<ptyId>.json`): enough to recreate a terminal after the daemon or the
/// machine restarted, or to continue a respawned session's screen.
struct PTYSnapshot: Codable, Equatable {
    var info: PTYInfo
    /// Serialized screen (`TerminalMirror.serialize(includePending: false)`), base64 in JSON.
    var screen: Data
    /// Environment overrides the PTY was opened with (not the merged environment); nil for session PTYs.
    var env: [String: String]?
    /// When the snapshot was taken (nil in snapshots written before it was recorded).
    var savedAt: Date?
}

/// Snapshot files: written atomically (0600 temp file, fsync, rename) since they hold terminal contents.
struct PTYSnapshotStore {
    let directory: URL

    func write(_ snapshot: PTYSnapshot) throws {
        let id = snapshot.info.ptyId
        guard Self.isValidID(id) else { throw DaemonError(.internal, "invalid PTY id for snapshot: \(id)") }
        let data = try JSONEncoder().encode(snapshot)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let final = directory.appendingPathComponent("\(id).json").path
        let temporary = directory.appendingPathComponent(".\(id).json.tmp").path
        let fd = open(temporary, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Self.error("open", temporary) }
        var written = 0
        let ok = data.withUnsafeBytes { raw -> Bool in
            while written < raw.count {
                let n = Darwin.write(fd, raw.baseAddress! + written, raw.count - written)
                if n > 0 { written += n } else if n < 0 && errno == EINTR { continue } else { return false }
            }
            return fsync(fd) == 0
        }
        let failure = ok ? nil : Self.error("write", temporary)
        close(fd)
        if let failure {
            unlink(temporary)
            throw failure
        }
        guard rename(temporary, final) == 0 else {
            let failure = Self.error("rename", final)
            unlink(temporary)
            throw failure
        }
    }

    func remove(_ id: PTYID) {
        guard Self.isValidID(id) else { return }
        unlink(directory.appendingPathComponent("\(id).json").path)
    }

    /// Every readable snapshot; unreadable or foreign files are skipped (and left in place).
    func loadAll() throws -> [PTYSnapshot] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        let decoder = JSONDecoder()
        return names.sorted().compactMap { name -> PTYSnapshot? in
            guard name.hasSuffix(".json"), !name.hasPrefix(".") else { return nil }
            guard let data = FileManager.default.contents(atPath: directory.appendingPathComponent(name).path),
                  let snapshot = try? decoder.decode(PTYSnapshot.self, from: data),
                  Self.isValidID(snapshot.info.ptyId), name == "\(snapshot.info.ptyId).json" else { return nil }
            return snapshot
        }
    }

    /// Files nothing will read again, with their bytes on disk: a snapshot whose PTY is not in `live` and whose session,
    /// if any, is not in `sessions`; a `<id>.json` that is no snapshot of that PTY (`loadAll` never reads it); and a
    /// write's temp file `.<id>.json.tmp`, left by an interrupted write (writes are synchronous: none is in flight when
    /// the pool asks). Any other file is left alone.
    func unreferenced(live: Set<PTYID>, sessions: Set<SessionKey>) -> [(url: URL, bytes: Int64)] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? []
        let decoder = JSONDecoder()
        return names.sorted().compactMap { name -> (url: URL, bytes: Int64)? in
            let url = directory.appending(path: name, directoryHint: .notDirectory)
            let bytes = { Int64((try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0) }
            if name.hasPrefix("."), name.hasSuffix(".json.tmp"), Self.isValidID(String(name.dropFirst().dropLast(".json.tmp".count))) {
                return (url, bytes())
            }
            guard name.hasSuffix(".json"), !name.hasPrefix(".") else { return nil }
            let id = String(name.dropLast(".json".count))
            guard Self.isValidID(id), !live.contains(id) else { return nil }
            if let data = FileManager.default.contents(atPath: url.path(percentEncoded: false)),
               let snapshot = try? decoder.decode(PTYSnapshot.self, from: data), snapshot.info.ptyId == id,
               let key = snapshot.info.sessionKey, sessions.contains(key)
            {
                return nil
            }
            return (url, bytes())
        }
    }

    private static func isValidID(_ id: PTYID) -> Bool {
        !id.isEmpty && !id.hasPrefix(".") && !id.contains("/") && !id.contains("\0")
    }

    /// `operation` on `path` failed with the current `errno` (kept: `ENOSPC` means the disk is full).
    private static func error(_ operation: String, _ path: String) -> StorageError {
        .system(operation: operation, path: path, code: errno)
    }
}
