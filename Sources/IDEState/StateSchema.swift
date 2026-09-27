import Foundation
import GRDB
import os

let stateLog = Logger(subsystem: "com.omp-ide", category: "state")

/// Tables of `state.sqlite`. Migrations only ever get appended.
enum StateSchema {
    static let migrator: DatabaseMigrator = {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: WindowRecord.databaseTableName) { table in
                table.primaryKey("id", .text)
                table.column("frameX", .double)
                table.column("frameY", .double)
                table.column("frameWidth", .double)
                table.column("frameHeight", .double)
                table.column("sidebarWidth", .double)
                table.column("sidebarVisible", .boolean).notNull()
                // `TabLayout` as JSON: strips of `{kind, id}` tabs in order, and the selected tab.
                table.column("tabs", .text).notNull()
            }
            // Per-session composer draft, transcript scroll anchor and journal seq; dropped by `drop_session_ui`.
            try db.create(table: "session_ui") { table in
                table.primaryKey("sessionKey", .text)
                table.column("draft", .text).notNull()
                table.column("scrollAnchor", .text)
                table.column("lastSeq", .integer).notNull()
            }
            try db.create(table: DirtyBufferRecord.databaseTableName) { table in
                table.primaryKey("path", .text)
                table.column("contents", .text).notNull()
                table.column("baselineHash", .text)
                // `Date.timeIntervalSinceReferenceDate`.
                table.column("updatedAt", .double).notNull()
            }
        }
        migrator.registerMigration("editor_ui") { db in
            try db.create(table: EditorUIRecord.databaseTableName) { table in
                table.primaryKey("path", .text)
                // `[{"location": …, "length": …}, …]`.
                table.column("selections", .text).notNull()
                table.column("scrollX", .double).notNull()
                table.column("scrollY", .double).notNull()
            }
        }
        // Sessions are omp's own TUI now: omp keeps the draft and the scrollback, and there is no journal to track.
        migrator.registerMigration("drop_session_ui") { db in
            try db.drop(table: "session_ui")
        }
        migrator.registerMigration("projects") { db in
            try db.alter(table: WindowRecord.databaseTableName) { table in
                // JSON array of absolute folder paths.
                table.add(column: "projects", .text).notNull().defaults(to: "[]")
            }
        }
        return migrator
    }()
}

struct WindowRecord: FetchableRecord, PersistableRecord {
    static let databaseTableName = "window"
    var state: WindowState

    init(_ state: WindowState) { self.state = state }

    init(row: Row) throws {
        let id: String = row["id"]
        var frame: WindowFrame?
        if let x: Double = row["frameX"], let y: Double = row["frameY"], let width: Double = row["frameWidth"],
           let height: Double = row["frameHeight"] {
            frame = WindowFrame(x: x, y: y, width: width, height: height)
        }
        let json: String = row["tabs"]
        let tabs: TabLayout
        do {
            tabs = try JSONDecoder().decode(TabLayout.self, from: Data(json.utf8))
        } catch {
            stateLog.error("window \(id, privacy: .public): unreadable tabs, starting without tabs: \(String(describing: error), privacy: .public)")
            tabs = TabLayout()
        }
        let projects = (try? JSONDecoder().decode([String].self, from: Data((row["projects"] as String).utf8))) ?? []
        state = WindowState(
            id: id, frame: frame, sidebarWidth: row["sidebarWidth"], sidebarVisible: row["sidebarVisible"],
            projects: projects, tabs: tabs)
    }

    func encode(to container: inout PersistenceContainer) throws {
        container["id"] = state.id
        container["frameX"] = state.frame?.x
        container["frameY"] = state.frame?.y
        container["frameWidth"] = state.frame?.width
        container["frameHeight"] = state.frame?.height
        container["sidebarWidth"] = state.sidebarWidth
        container["sidebarVisible"] = state.sidebarVisible
        container["projects"] = String(decoding: try JSONEncoder().encode(state.projects), as: UTF8.self)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        container["tabs"] = String(decoding: try encoder.encode(state.tabs), as: UTF8.self)
    }
}

struct DirtyBufferRecord: FetchableRecord, PersistableRecord {
    static let databaseTableName = "dirty_buffer"
    var buffer: DirtyBuffer

    init(_ buffer: DirtyBuffer) { self.buffer = buffer }

    init(row: Row) throws {
        buffer = DirtyBuffer(
            path: row["path"], contents: row["contents"], baselineHash: row["baselineHash"],
            updatedAt: Date(timeIntervalSinceReferenceDate: row["updatedAt"]))
    }

    func encode(to container: inout PersistenceContainer) throws {
        container["path"] = buffer.path
        container["contents"] = buffer.contents
        container["baselineHash"] = buffer.baselineHash
        container["updatedAt"] = buffer.updatedAt.timeIntervalSinceReferenceDate
    }
}

struct EditorUIRecord: FetchableRecord, PersistableRecord {
    static let databaseTableName = "editor_ui"
    var state: EditorUIState

    init(_ state: EditorUIState) { self.state = state }

    init(row: Row) throws {
        let path: String = row["path"]
        let json: String = row["selections"]
        var selections: [EditorUIState.Selection] = []
        do {
            selections = try JSONDecoder().decode([EditorUIState.Selection].self, from: Data(json.utf8))
        } catch {
            stateLog.error("editor \(path, privacy: .private): unreadable selections, dropped: \(String(describing: error), privacy: .public)")
        }
        state = EditorUIState(path: path, selections: selections, scrollX: row["scrollX"], scrollY: row["scrollY"])
    }

    func encode(to container: inout PersistenceContainer) throws {
        container["path"] = state.path
        container["selections"] = String(decoding: try JSONEncoder().encode(state.selections), as: UTF8.self)
        container["scrollX"] = state.scrollX
        container["scrollY"] = state.scrollY
    }
}
