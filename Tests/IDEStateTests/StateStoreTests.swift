import Foundation
import GRDB
import IDEProtocol
import IDEState
import Testing

@Suite struct StateStoreTests {
    @Test func migrationsCreateTheWALSchemaOnceAndReopeningKeepsEverything() throws {
        let home = try TempHome()
        let window = WindowState(id: "main", sidebarWidth: 300)
        let editor = EditorUIState(path: "/src/app/main.swift", selections: [.init(location: 12, length: 0)], scrollY: 40)
        do {
            let store = try home.store()
            store.setWindow(window)
            store.setEditorUI(editor)
            try store.flush()
        }
        let reopened = try home.store()
        #expect(try reopened.window(id: "main") == window)
        #expect(try reopened.editorUIStates() == [editor.path: editor])
        try home.observer().read { db in
            #expect(try String.fetchOne(db, sql: "PRAGMA journal_mode") == "wal")
            #expect(try db.tableExists("window") && db.tableExists("editor_ui") && db.tableExists("dirty_buffer"))
            // Each migration ran exactly once across both opens.
            let applied = try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations")
            #expect(!applied.isEmpty && applied.count == Set(applied).count)
        }
        // Unsaved text lives here: the database and its WAL are private.
        #expect(try home.posixPermissions(of: home.paths.stateDB) == 0o600)
        #expect(try home.posixPermissions(of: URL(filePath: home.paths.stateDB.path(percentEncoded: false) + "-wal")) == 0o600)
    }

    @Test func aDatabaseFromTheChatUIKeepsItsLayoutAndLosesTheSessionDrafts() throws {
        let home = try TempHome()
        // What a build with the transcript and composer left behind: the `v1` and `editor_ui` migrations, a window whose
        // tabs include a session, and a composer draft.
        do {
            let old = try DatabaseQueue(path: home.paths.stateDB.path(percentEncoded: false))
            var migrator = DatabaseMigrator()
            migrator.registerMigration("v1") { db in
                try db.execute(sql: """
                    CREATE TABLE window (id TEXT PRIMARY KEY, frameX DOUBLE, frameY DOUBLE, frameWidth DOUBLE, frameHeight DOUBLE,
                        sidebarWidth DOUBLE, sidebarVisible BOOLEAN NOT NULL, tabs TEXT NOT NULL);
                    CREATE TABLE session_ui (sessionKey TEXT PRIMARY KEY, draft TEXT NOT NULL, scrollAnchor TEXT, lastSeq INTEGER NOT NULL);
                    CREATE TABLE dirty_buffer (path TEXT PRIMARY KEY, contents TEXT NOT NULL, baselineHash TEXT, updatedAt DOUBLE NOT NULL);
                    """)
            }
            migrator.registerMigration("editor_ui") { db in
                try db.execute(sql: """
                    CREATE TABLE editor_ui (path TEXT PRIMARY KEY, selections TEXT NOT NULL, scrollX DOUBLE NOT NULL, scrollY DOUBLE NOT NULL)
                    """)
            }
            try migrator.migrate(old)
            try old.write { db in
                try db.execute(sql: """
                    INSERT INTO window (id, sidebarWidth, sidebarVisible, tabs) VALUES ('main', 280, 1,
                        '{"selection":{"id":"s1","kind":"session"},"strips":[{"tabs":[{"id":"s1","kind":"session"}],"workspace":"/src/app"}]}');
                    INSERT INTO session_ui (sessionKey, draft, scrollAnchor, lastSeq) VALUES ('s1', 'half a thought', 'assistant:12', 40);
                    """)
            }
            try old.close()
        }

        let store = try home.store()
        let window = try #require(try store.window(id: "main"))
        #expect(window.sidebarWidth == 280)
        #expect(window.tabs.strips.map(\.tabs) == [[.session("s1")]])
        #expect(window.tabs.selectedSession == "s1")
        let draftsKept = try home.observer().read { db in try db.tableExists("session_ui") }
        #expect(!draftsKept, "omp's TUI keeps the draft now")
    }

    @Test func windowLayoutWithTabsAndSelectionRoundTrips() throws {
        let home = try TempHome()
        var tabs = TabLayout()
        tabs.open(.session("s1"), in: "/src/app")
        tabs.open(.session("s2"), in: "/src/lib")
        tabs.open(.session("s3"), in: "/src/app")
        tabs.select(.session("s2"))
        let window = WindowState(
            id: "main", frame: WindowFrame(x: 120.5, y: 64, width: 1280, height: 812.5), sidebarWidth: 312.5,
            sidebarVisible: false, tabs: tabs)
        do {
            let store = try home.store()
            store.setWindow(window)
            try store.flush()
        }
        let restored = try #require(try home.store().window(id: "main"))
        #expect(restored == window)
        #expect(restored.tabs.strips.map(\.workspace) == ["/src/app", "/src/lib"])
        #expect(restored.tabs.strips.map(\.tabs) == [[.session("s1"), .session("s3")], [.session("s2")]])
        #expect(restored.tabs.selectedSession == "s2")
        #expect(restored.tabs.selectedStrip?.workspace == "/src/lib")
    }

    @Test func changesStayPendingUntilFlushButReadsSeeThem() throws {
        let home = try TempHome()
        let store = try home.store()
        let observer = try home.observer()
        store.setEditorUI(EditorUIState(path: "/src/a.swift", scrollY: 1))
        store.setEditorUI(EditorUIState(path: "/src/a.swift", scrollY: 2))
        store.setWindow(WindowState(id: "main", sidebarVisible: false))

        #expect(try committedScroll(observer, "/src/a.swift") == nil)
        #expect(try store.editorUIStates()["/src/a.swift"]?.scrollY == 2)
        #expect(try store.window(id: "main")?.sidebarVisible == false)

        try store.flush()
        #expect(try committedScroll(observer, "/src/a.swift") == 2)
        #expect(try home.store().window(id: "main")?.sidebarVisible == false)
    }

    @Test func changesAreWrittenOnceTheDebounceElapsesWithoutAFlush() async throws {
        let home = try TempHome()
        let store = try home.store(debounce: .milliseconds(150))
        let observer = try home.observer()
        store.setEditorUI(EditorUIState(path: "/src/a.swift", scrollY: 1))
        store.setEditorUI(EditorUIState(path: "/src/a.swift", scrollY: 2))
        #expect(try committedScroll(observer, "/src/a.swift") == nil)
        try await eventually("the debounced write") { try committedScroll(observer, "/src/a.swift") == 2 }
    }

    @Test func changesThatNeverPauseAreStillWrittenWithinMaxDelay() async throws {
        let home = try TempHome()
        // A change every 40 ms: a trailing 300 ms debounce alone would never fire.
        let store = try home.store(debounce: .milliseconds(300), maxDelay: .milliseconds(600))
        let observer = try home.observer()
        let deadline = ContinuousClock.now + .seconds(5)
        var scrolled = 0.0
        while try committedScroll(observer, "/src/a.swift") == nil {
            guard ContinuousClock.now < deadline else {
                Issue.record("nothing was written while changes kept coming")
                return
            }
            scrolled += 1
            store.setEditorUI(EditorUIState(path: "/src/a.swift", scrollY: scrolled))
            try await Task.sleep(for: .milliseconds(40))
        }
    }
}
