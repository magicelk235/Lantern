import CryptoKit
import Foundation
import GRDB
import IDEProtocol
import IDEState

/// A fresh `$APP_SUPPORT` under the temp dir, removed when released.
final class TempHome: Sendable {
    let url: URL
    let paths: AppSupportPaths

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appending(path: "idestate-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        paths = AppSupportPaths(root: url)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    /// A store whose debounce never fires during a test unless asked to.
    func store(debounce: Duration = .seconds(3600), maxDelay: Duration = .seconds(3600)) throws -> StateStore {
        try StateStore(paths: paths, debounce: debounce, maxDelay: maxDelay)
    }

    /// A plain connection to `state.sqlite`, to see what is committed independently of the store.
    func observer() throws -> DatabaseQueue {
        try DatabaseQueue(path: paths.stateDB.path(percentEncoded: false))
    }

    /// `hot-exit/<sha256(path)>`.
    func mirrorURL(of path: String) -> URL {
        let name = SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
        return paths.hotExit.appending(path: name, directoryHint: .notDirectory)
    }

    func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }

    func posixPermissions(of url: URL) throws -> Int {
        try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))[.posixPermissions] as? Int ?? -1
    }
}

/// The committed vertical scroll position of the editor of `path`, or nil when no row is committed.
func committedScroll(_ observer: DatabaseQueue, _ path: String) throws -> Double? {
    try observer.read { db in
        try Double.fetchOne(db, sql: "SELECT scrollY FROM editor_ui WHERE path = ?", arguments: [path])
    }
}

struct TimedOut: Error, CustomStringConvertible {
    let what: String
    var description: String { "timed out waiting for \(what)" }
}

/// Polls `condition` until it holds.
func eventually(_ what: String, timeout: Duration = .seconds(10), _ condition: () throws -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while try !condition() {
        guard ContinuousClock.now < deadline else { throw TimedOut(what: what) }
        try await Task.sleep(for: .milliseconds(20))
    }
}
