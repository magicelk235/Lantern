import Foundation
import IDEState
import Testing

private let buffer = DirtyBuffer(
    path: "/Users/me/src/app/main.swift", contents: "unsaved\n", baselineHash: nil,
    updatedAt: Date(timeIntervalSinceReferenceDate: 780_000_000))

@Suite struct StateWriteHealthTests {
    /// A banner shows while writes fail and goes with the next one that succeeds: every write's outcome is reported.
    @Test func everyWriteReportsWhetherItReachedTheDisk() throws {
        let home = try TempHome()
        let store = try home.store()
        let outcomes = OutcomeLog()
        store.setWriteObserver { write, failure in outcomes.append(write, failed: failure != nil) }

        try FileManager.default.createDirectory(at: home.paths.hotExit, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: home.paths.hotExit.path(percentEncoded: false))
        #expect(throws: (any Error).self) { try store.saveDirtyBuffer(buffer) }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: home.paths.hotExit.path(percentEncoded: false))
        try store.saveDirtyBuffer(buffer)
        store.setWindow(WindowState(id: "main", sidebarWidth: 300))
        try store.flush()
        try store.flush() // nothing pending: no write

        #expect(outcomes.entries == [
            .init(write: .dirtyBuffer, failed: true), .init(write: .dirtyBuffer, failed: false), .init(write: .layout, failed: false),
        ])
    }

    /// Only temp files of mirror writes nobody has touched for a minute are leftovers; mirrors never are.
    @Test func onlyAbandonedMirrorWritesAreLeftovers() throws {
        let home = try TempHome()
        let store = try home.store()
        try store.saveDirtyBuffer(buffer)
        let mirror = home.mirrorURL(of: buffer.path)
        let directory = home.paths.hotExit
        let abandoned = directory.appending(path: ".\(mirror.lastPathComponent).tmp")
        let fresh = directory.appending(path: ".\(String(repeating: "a", count: 64)).tmp")
        let foreign = directory.appending(path: ".notes.tmp")
        for file in [abandoned, fresh, foreign] { try Data("partial".utf8).write(to: file) }
        let old = Date().addingTimeInterval(-120)
        for file in [abandoned, foreign, mirror] {
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: file.path(percentEncoded: false))
        }

        #expect(store.abandonedMirrorWrites().count == 1)
        #expect(store.removeAbandonedMirrorWrites().count == 1)
        #expect(!home.exists(abandoned) && home.exists(fresh) && home.exists(foreign) && home.exists(mirror))
        #expect(try store.dirtyBuffers() == [buffer])
    }
}

private final class OutcomeLog: @unchecked Sendable {
    struct Entry: Equatable {
        var write: StateStore.Write
        var failed: Bool
    }

    private let lock = NSLock()
    private var recorded: [Entry] = []

    var entries: [Entry] { lock.withLock { recorded } }

    func append(_ write: StateStore.Write, failed: Bool) {
        lock.withLock { recorded.append(Entry(write: write, failed: failed)) }
    }
}
