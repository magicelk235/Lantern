import Foundation
import GRDB
import IDEProtocol
import IDEState
import Testing

@Suite struct StateStoreTests {
    @Test func migrationsCreateTheWALSchemaOnceAndReopeningKeepsEverything() throws {
        let home = try TempHome()
        let window = WindowState(id: "main", sidebarWidth: 300)
        let session = SessionUIState(sessionKey: "s1", draft: "half a thought", scrollAnchor: "assistant:12", lastSeq: 40)
        do {
            let store = try home.store()
            store.setWindow(window)
            store.setSessionUI(session)
            try store.flush()
        }
        let reopened = try home.store()
        #expect(try reopened.window(id: "main") == window)
        #expect(try reopened.sessionUIStates() == ["s1": session])
        try home.observer().read { db in
            #expect(try String.fetchOne(db, sql: "PRAGMA journal_mode") == "wal")
            #expect(try db.tableExists("window") && db.tableExists("session_ui") && db.tableExists("dirty_buffer"))
            // Each migration ran exactly once across both opens.
            let applied = try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations")
            #expect(!applied.isEmpty && applied.count == Set(applied).count)
        }
        // Drafts live here: the database and its WAL are private.
        #expect(try home.posixPermissions(of: home.paths.stateDB) == 0o600)
        #expect(try home.posixPermissions(of: URL(filePath: home.paths.stateDB.path(percentEncoded: false) + "-wal")) == 0o600)
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
        store.setSessionUI(SessionUIState(sessionKey: "s1", draft: "a"))
        store.setSessionUI(SessionUIState(sessionKey: "s1", draft: "ab"))
        store.setWindow(WindowState(id: "main", sidebarVisible: false))

        #expect(try committedDraft(observer, "s1") == nil)
        #expect(try store.sessionUIStates()["s1"]?.draft == "ab")
        #expect(try store.window(id: "main")?.sidebarVisible == false)

        try store.flush()
        #expect(try committedDraft(observer, "s1") == "ab")
        #expect(try home.store().window(id: "main")?.sidebarVisible == false)
    }

    @Test func changesAreWrittenOnceTheDebounceElapsesWithoutAFlush() async throws {
        let home = try TempHome()
        let store = try home.store(debounce: .milliseconds(150))
        let observer = try home.observer()
        store.setSessionUI(SessionUIState(sessionKey: "s1", draft: "first"))
        store.setSessionUI(SessionUIState(sessionKey: "s1", draft: "second"))
        #expect(try committedDraft(observer, "s1") == nil)
        try await eventually("the debounced write") { try committedDraft(observer, "s1") == "second" }
    }

    @Test func changesThatNeverPauseAreStillWrittenWithinMaxDelay() async throws {
        let home = try TempHome()
        // A change every 40 ms: a trailing 300 ms debounce alone would never fire.
        let store = try home.store(debounce: .milliseconds(300), maxDelay: .milliseconds(600))
        let observer = try home.observer()
        let deadline = ContinuousClock.now + .seconds(5)
        var typed = 0
        while try committedDraft(observer, "s1") == nil {
            guard ContinuousClock.now < deadline else {
                Issue.record("nothing was written while changes kept coming")
                return
            }
            typed += 1
            store.setSessionUI(SessionUIState(sessionKey: "s1", draft: String(typed)))
            try await Task.sleep(for: .milliseconds(40))
        }
    }
}
