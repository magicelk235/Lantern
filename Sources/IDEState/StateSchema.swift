import Foundation
import GRDB
import IDEProtocol
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
            try db.create(table: SessionUIRecord.databaseTableName) { table in
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
        state = WindowState(
            id: id, frame: frame, sidebarWidth: row["sidebarWidth"], sidebarVisible: row["sidebarVisible"], tabs: tabs)
    }

    func encode(to container: inout PersistenceContainer) throws {
        container["id"] = state.id
        container["frameX"] = state.frame?.x
        container["frameY"] = state.frame?.y
        container["frameWidth"] = state.frame?.width
        container["frameHeight"] = state.frame?.height
        container["sidebarWidth"] = state.sidebarWidth
        container["sidebarVisible"] = state.sidebarVisible
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        container["tabs"] = String(decoding: try encoder.encode(state.tabs), as: UTF8.self)
    }
}

struct SessionUIRecord: FetchableRecord, PersistableRecord {
    static let databaseTableName = "session_ui"
    var state: SessionUIState

    init(_ state: SessionUIState) { self.state = state }

    init(row: Row) throws {
        state = SessionUIState(
            sessionKey: row["sessionKey"], draft: row["draft"], scrollAnchor: row["scrollAnchor"], lastSeq: row["lastSeq"])
    }

    func encode(to container: inout PersistenceContainer) throws {
        container["sessionKey"] = state.sessionKey
        container["draft"] = state.draft
        container["scrollAnchor"] = state.scrollAnchor
        container["lastSeq"] = state.lastSeq
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
