import Foundation
import GRDB
import IDEProtocol
import IDEState
import Testing

/// Rename Project…: the app's own state follows a renamed folder.
@Suite struct ProjectRenameStateTests {
    private let move = FolderMove(from: "/w/app", to: "/w/web")

    @Test func tabsOfTheFolderAndOfFoldersInsideItFollowItInPlace() {
        var layout = TabLayout()
        layout.open(.session("s1"), in: "/w/app")
        layout.open(.editor(path: "/w/app/main.swift"), in: "/w/app")
        layout.open(.terminal("p1"), in: "/w/app")
        layout.open(.editor(path: "/w/app2/notes.md"), in: "/w/app2")
        layout.open(.editor(path: "/w/app/lib/a.swift"), in: "/w/app/lib")
        layout.select(.editor(path: "/w/app/main.swift"))

        layout.moveFolder(move)

        #expect(layout.strips.map(\.workspace) == ["/w/web", "/w/app2", "/w/web/lib"])
        #expect(layout.strips[0].tabs == [.session("s1"), .editor(path: "/w/web/main.swift"), .terminal("p1")])
        // A folder whose name only starts the same way stays where it is.
        #expect(layout.strips[1].tabs == [.editor(path: "/w/app2/notes.md")])
        #expect(layout.strips[2].tabs == [.editor(path: "/w/web/lib/a.swift")])
        #expect(layout.selection == .editor(path: "/w/web/main.swift"))
        #expect(layout.strips[0].lastSelected == .editor(path: "/w/web/main.swift"))
        #expect(layout.strips[2].lastSelected == .editor(path: "/w/web/lib/a.swift"))
    }

    @Test func aStripLandingOnAFolderThatHasOneJoinsItAfterItsTabs() {
        var layout = TabLayout()
        layout.open(.session("gone"), in: "/w/web")
        layout.open(.session("s1"), in: "/w/app")
        layout.open(.editor(path: "/w/app/a.txt"), in: "/w/app")

        layout.moveFolder(move)

        #expect(layout.strips.count == 1)
        #expect(layout.strips[0].workspace == "/w/web")
        #expect(layout.strips[0].tabs == [.session("gone"), .session("s1"), .editor(path: "/w/web/a.txt")])
        #expect(layout.selection == .editor(path: "/w/web/a.txt"))
    }

    @Test func windowStateNamesTheNewPlaceOnceEach() {
        var tabs = TabLayout()
        tabs.open(.editor(path: "/w/app/a.txt"), in: "/w/app")
        var state = WindowState(
            id: "main", projects: ["/w/other", "/w/app", "/w/web", "/w/app/sub"], tabs: tabs,
            windows: ["/w/app", "/w/other", "/w/web"], frontWindow: "/w/app")

        state.moveFolder(move)

        #expect(state.projects == ["/w/other", "/w/web", "/w/web/sub"])
        #expect(state.windows == ["/w/web", "/w/other"])
        #expect(state.frontWindow == "/w/web")
        #expect(state.tabs.tabs == [.editor(path: "/w/web/a.txt")])
    }

    @Test func theStoreMovesLayoutsEditorStateAndUnsavedBuffersWithTheirMirrors() throws {
        let home = try TempHome()
        let inside = DirtyBuffer(path: "/w/app/main.swift", contents: "unsaved ✍️", baselineHash: "abc", updatedAt: Date(timeIntervalSinceReferenceDate: 1))
        let outside = DirtyBuffer(path: "/w/app2/main.swift", contents: "other", baselineHash: nil, updatedAt: Date(timeIntervalSinceReferenceDate: 2))
        var tabs = TabLayout()
        tabs.open(.editor(path: inside.path), in: "/w/app")
        do {
            let store = try home.store()
            store.setWindow(WindowState(id: "main", projects: ["/w/app"], tabs: tabs, windows: ["/w/app"], frontWindow: "/w/app"))
            store.setEditorUI(EditorUIState(path: inside.path, scrollY: 40))
            store.setEditorUI(EditorUIState(path: outside.path, scrollY: 7))
            try store.flush()
            // Still waiting for the debounce when the folder moves.
            store.setEditorUI(EditorUIState(path: "/w/app/lib/b.swift", scrollY: 12))
            try store.saveDirtyBuffer(inside)
            try store.saveDirtyBuffer(outside)

            try store.moveFolder(move)
            try store.moveFolder(move)

            #expect(try store.dirtyBuffers().map(\.path) == ["/w/app2/main.swift", "/w/web/main.swift"])
            #expect(try store.editorUIStates().keys.sorted() == ["/w/app2/main.swift", "/w/web/lib/b.swift", "/w/web/main.swift"])
            try store.flush()
        }
        #expect(!home.exists(home.mirrorURL(of: inside.path)))
        #expect(home.exists(home.mirrorURL(of: "/w/web/main.swift")))
        #expect(home.exists(home.mirrorURL(of: outside.path)))
        var moved = inside
        moved.path = "/w/web/main.swift"
        do {
            let reopened = try home.store()
            #expect(try reopened.dirtyBuffers() == [outside, moved])
            let window = try #require(try reopened.window(id: "main"))
            #expect(window.projects == ["/w/web"])
            #expect(window.windows == ["/w/web"])
            #expect(window.frontWindow == "/w/web")
            #expect(window.tabs.tabs == [.editor(path: "/w/web/main.swift")])
            let editors = try reopened.editorUIStates()
            #expect(editors["/w/web/main.swift"]?.scrollY == 40)
            #expect(editors["/w/web/lib/b.swift"]?.scrollY == 12)
            #expect(editors["/w/app2/main.swift"]?.scrollY == 7)
            #expect(editors[inside.path] == nil)
        }

        // A lost database brings back what the mirrors hold: the buffer under its new path only.
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: home.paths.stateDB.path(percentEncoded: false) + suffix)
        }
        #expect(try home.store().dirtyBuffers() == [outside, moved])
    }

    @Test func theJournalSaysWhetherTheFolderMoved() throws {
        let home = try TempHome()
        let from = home.url.appending(path: "app").path(percentEncoded: false)
        let to = home.url.appending(path: "web").path(percentEncoded: false)
        try FileManager.default.createDirectory(atPath: from, withIntermediateDirectories: true)
        let journal = ProjectRenameJournal(FolderMove(from: from, to: to))
        try journal.write(to: home.paths.projectRenameApp)
        #expect(ProjectRenameJournal.read(at: home.paths.projectRenameApp) == journal)

        // ompd is still at it: its journal is there and the folder has not moved yet.
        try Data("{}".utf8).write(to: home.paths.projectRename)
        #expect(journal.outcome(daemonJournal: home.paths.projectRename) == .undecided)
        // ompd gave up (or never started) and the folder is where it was.
        try FileManager.default.removeItem(at: home.paths.projectRename)
        #expect(journal.outcome(daemonJournal: home.paths.projectRename) == .dropped)
        // The folder moved.
        try FileManager.default.moveItem(atPath: from, toPath: to)
        #expect(journal.outcome(daemonJournal: home.paths.projectRename) == .moved(journal.move))

        try ProjectRenameJournal.remove(at: home.paths.projectRenameApp)
        #expect(ProjectRenameJournal.read(at: home.paths.projectRenameApp) == nil)
    }

    @Test func aRenameThatOnlyChangesCaseTellsWhetherItHappened() throws {
        let home = try TempHome()
        let lower = home.url.appending(path: "app").path(percentEncoded: false)
        let upper = home.url.appending(path: "App").path(percentEncoded: false)
        try FileManager.default.createDirectory(atPath: lower, withIntermediateDirectories: true)
        let journal = ProjectRenameJournal(FolderMove(from: lower, to: upper))
        #expect(journal.outcome(daemonJournal: home.paths.projectRename) == .dropped)
        try FileManager.default.moveItem(atPath: lower, toPath: upper)
        #expect(journal.outcome(daemonJournal: home.paths.projectRename) == .moved(journal.move))
    }
}
