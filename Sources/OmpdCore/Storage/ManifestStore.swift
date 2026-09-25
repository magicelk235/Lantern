import Foundation
import IDEProtocol

/// Owner of `$APP_SUPPORT/sessions.json`. Every write replaces the file atomically and durably
/// (temp file + `F_FULLFSYNC` + `rename(2)` + directory flush), so a crash or power loss leaves either the previous
/// or the new manifest, never a torn one.
public actor ManifestStore {
    public nonisolated let url: URL
    /// The manifest as last loaded or written. Empty until `load()` (which `update` performs on first use).
    public private(set) var current = SessionManifest()

    private var loaded = false
    private let encoder: JSONEncoder = {
        let encoder = IDECoding.encoder()
        encoder.outputFormatting.insert(.prettyPrinted)
        return encoder
    }()
    private let queue = DispatchSerialQueue(label: "com.omp-ide.ompd.manifest")
    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    public init(url: URL) {
        self.url = url
    }

    /// Reads the manifest from disk. A missing file is an empty manifest. A file that does not decode is moved
    /// aside to `sessions.json.corrupt-<timestamp>` (kept for the user, never overwritten) and an empty manifest
    /// is returned. A leftover `sessions.json.tmp` from an interrupted write is ignored.
    @discardableResult
    public func load() throws -> SessionManifest {
        if let data = try StorageIO.readFileIfPresent(url) {
            do {
                current = try IDECoding.decoder().decode(SessionManifest.self, from: data)
            } catch {
                let aside = try moveAside()
                StorageIO.log.error(
                    "manifest \(StorageIO.displayPath(self.url), privacy: .public) is unreadable (\(String(describing: error), privacy: .public)); moved to \(StorageIO.displayPath(aside), privacy: .public), starting empty"
                )
                current = SessionManifest()
            }
        } else {
            current = SessionManifest()
        }
        loaded = true
        return current
    }

    /// Applies `body` to the current manifest and persists the result before returning it. If `body` throws or
    /// the write fails, neither the file nor `current` changes. An update that changes nothing writes nothing.
    @discardableResult
    public func update(_ body: @Sendable (inout SessionManifest) throws -> Void) throws -> SessionManifest {
        if !loaded { try load() }
        var next = current
        try body(&next)
        guard next != current else { return current }
        try StorageIO.writeAtomically(try encoder.encode(next), to: url, durable: true)
        current = next
        return next
    }

    private func moveAside() throws -> URL {
        let stamp = Date().formatted(
            Date.ISO8601FormatStyle(
                dateSeparator: .omitted, dateTimeSeparator: .standard, timeSeparator: .omitted,
                includingFractionalSeconds: true, timeZone: .gmt
            )
        )
        let directory = url.deletingLastPathComponent()
        let base = "\(url.lastPathComponent).corrupt-\(stamp)"
        var attempt = 1
        while true {
            let name = attempt == 1 ? base : "\(base)-\(attempt)"
            let destination = directory.appending(path: name, directoryHint: .notDirectory)
            do {
                try FileManager.default.moveItem(at: url, to: destination)
                return destination
            } catch CocoaError.fileWriteFileExists where attempt < 100 {
                attempt += 1
            }
        }
    }
}
