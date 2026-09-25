import Foundation
import GRDB
import IDEState
import Testing

@Suite struct EditorStateTests {
    @Test func editorTabsComeBackInTheirStripWithTheSelection() throws {
        let home = try TempHome()
        var tabs = TabLayout()
        tabs.open(.session("s1"), in: "/src/app")
        tabs.open(.editor(path: "/src/app/Sources/main.swift"), in: "/src/app")
        tabs.open(.editor(path: "/src/lib/README.md"), in: "/src/lib")
        tabs.select(.editor(path: "/src/app/Sources/main.swift"))
        do {
            let store = try home.store()
            store.setWindow(WindowState(id: "main", tabs: tabs))
            try store.flush()
        }
        let restored = try #require(try home.store().window(id: "main")).tabs
        #expect(restored == tabs)
        #expect(restored.selection?.editorPath == "/src/app/Sources/main.swift")
        #expect(restored.selectedSession == nil)
    }

    @Test func editorPositionsAreDebouncedLikeOtherUIAndKeptPerFile() throws {
        let home = try TempHome()
        let main = EditorUIState(
            path: "/src/app/main.swift", selections: [.init(location: 120, length: 0), .init(location: 300, length: 12)],
            scrollX: 0, scrollY: 1840.5)
        var readme = EditorUIState(path: "/src/app/README.md", selections: [.init(location: 3, length: 4)])
        do {
            let store = try home.store()
            store.setEditorUI(main)
            store.setEditorUI(readme)
            readme.scrollY = 99
            store.setEditorUI(readme)
            #expect(try store.editorUIStates() == [main.path: main, readme.path: readme])
            #expect(try home.observer().read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM editor_ui") } == 0)
            try store.flush()
        }
        #expect(try home.store().editorUIStates() == [main.path: main, readme.path: readme])
    }
}
