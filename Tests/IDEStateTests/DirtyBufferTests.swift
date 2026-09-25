import Foundation
import GRDB
import IDEState
import Testing

private let edited = DirtyBuffer(
    path: "/Users/me/src/app/main.swift", contents: "import Foundation\n\nprint(\"unsaved ✍️\")\n",
    baselineHash: "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08",
    updatedAt: Date(timeIntervalSinceReferenceDate: 780_000_000.123_456))
private let untitled = DirtyBuffer(
    path: "/Users/me/src/app/notes.md", contents: "# Not on disk yet", baselineHash: nil,
    updatedAt: Date(timeIntervalSinceReferenceDate: 780_000_100.5))

@Suite struct DirtyBufferTests {
    @Test func bufferWriteIsCommittedOnReturnWhileOtherChangesStillWaitForAFlush() throws {
        let home = try TempHome()
        do {
            let store = try home.store()
            store.setWindow(WindowState(id: "main", sidebarWidth: 300))
            try store.saveDirtyBuffer(edited)
            // No flush: the process dies here.
        }
        let reopened = try home.store()
        #expect(try reopened.dirtyBuffers() == [edited])
        #expect(try reopened.window(id: "main") == nil)
    }

    @Test func savingAgainReplacesTheBufferAndClearingForgetsItAndItsMirror() throws {
        let home = try TempHome()
        do {
            let store = try home.store()
            try store.saveDirtyBuffer(edited)
            try store.saveDirtyBuffer(untitled)
            var newer = edited
            newer.contents += "// more\n"
            newer.updatedAt += 60
            try store.saveDirtyBuffer(newer)
            #expect(try store.dirtyBuffers() == [newer, untitled])

            try store.clearDirtyBuffer(path: edited.path)
            try store.clearDirtyBuffer(path: "/never/saved")
            #expect(try store.dirtyBuffers() == [untitled])
            #expect(!home.exists(home.mirrorURL(of: edited.path)))
            #expect(home.exists(home.mirrorURL(of: untitled.path)))
        }
        // Nothing brings the cleared buffer back, not even a lost database.
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: home.paths.stateDB.path(percentEncoded: false) + suffix)
        }
        #expect(try home.store().dirtyBuffers() == [untitled])
    }

    @Test func mirrorIsAPrivatePlainFileWithTheTextAfterAOneLineHeader() throws {
        let home = try TempHome()
        try home.store().saveDirtyBuffer(edited)
        let mirror = home.mirrorURL(of: edited.path)
        let data = try Data(contentsOf: mirror)
        let newline = try #require(data.firstIndex(of: UInt8(ascii: "\n")))
        let header = try #require(try JSONSerialization.jsonObject(with: data[..<newline]) as? [String: Any])
        #expect(header["path"] as? String == edited.path)
        #expect(header["baselineHash"] as? String == edited.baselineHash)
        #expect(String(decoding: data[data.index(after: newline)...], as: UTF8.self) == edited.contents)
        #expect(try home.posixPermissions(of: mirror) == 0o600)
        #expect(try home.posixPermissions(of: home.paths.hotExit) == 0o700)
    }

    @Test func corruptDatabaseIsMovedAsideAndDirtyBuffersComeBackFromMirrors() throws {
        let home = try TempHome()
        do {
            let store = try home.store()
            try store.saveDirtyBuffer(edited)
            try store.saveDirtyBuffer(untitled)
            store.setWindow(WindowState(id: "main", sidebarWidth: 300))
            try store.flush()
        }
        let garbage = Data((0..<16_384).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        try garbage.write(to: home.paths.stateDB)
        for suffix in ["-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: home.paths.stateDB.path(percentEncoded: false) + suffix)
        }

        let recovered = try home.store()
        let recovery = try #require(recovered.recovery)
        #expect(recovery.restoredBuffers.sorted() == [edited.path, untitled.path])
        #expect(try recovered.dirtyBuffers() == [edited, untitled])
        #expect(try recovered.window(id: "main") == nil)
        #expect(try Data(contentsOf: recovery.movedAside) == garbage)
        #expect(recovery.movedAside.lastPathComponent.hasPrefix("state.sqlite.corrupt-"))
        // The recreated database holds the buffers again.
        let reopened = try home.store()
        #expect(reopened.recovery == nil)
        #expect(try reopened.dirtyBuffers() == [edited, untitled])
    }

    @Test func databaseWithDamagedPagesIsRecoveredToo() throws {
        let home = try TempHome()
        do {
            let store = try home.store()
            try store.saveDirtyBuffer(edited)
            store.setWindow(WindowState(id: "main", sidebarWidth: 300))
            try store.flush()
        }
        // Closing the last connection checkpointed the WAL into the main file (Apple's SQLite keeps it, empty); keep
        // the header page, wreck the rest.
        let wal = home.paths.stateDB.path(percentEncoded: false) + "-wal"
        #expect((try? FileManager.default.attributesOfItem(atPath: wal)[.size] as? Int) ?? 0 == 0)
        var bytes = try Data(contentsOf: home.paths.stateDB)
        let pageSize = 4096
        try #require(bytes.count > pageSize)
        bytes.replaceSubrange(pageSize..., with: Data(repeating: 0xA5, count: bytes.count - pageSize))
        try bytes.write(to: home.paths.stateDB)

        let recovered = try home.store()
        #expect(recovered.recovery != nil)
        #expect(try recovered.dirtyBuffers() == [edited])
    }

    @Test func lostDatabaseFallsBackToMirrors() throws {
        let home = try TempHome()
        try home.store().saveDirtyBuffer(untitled)
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: home.paths.stateDB.path(percentEncoded: false) + suffix)
        }
        let reopened = try home.store()
        #expect(reopened.recovery == nil)
        #expect(try reopened.dirtyBuffers() == [untitled])
    }

    @Test func databaseWinsOverAStaleMirrorWhichIsThenRewritten() throws {
        let home = try TempHome()
        var newer = edited
        newer.contents = "print(\"newer\")\n"
        newer.updatedAt += 5
        let mirror = home.mirrorURL(of: edited.path)
        do {
            let store = try home.store()
            try store.saveDirtyBuffer(edited)
            let stale = try Data(contentsOf: mirror)
            try store.saveDirtyBuffer(newer)
            // A crash between the row commit and the mirror rename leaves the previous mirror.
            try stale.write(to: mirror)
        }
        let reopened = try home.store()
        #expect(try reopened.dirtyBuffers() == [newer])
        #expect(try String(decoding: Data(contentsOf: mirror), as: UTF8.self).hasSuffix("\n" + newer.contents))
    }
}
