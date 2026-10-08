import Dispatch
import Foundation
import IDEModel
import IDEState
import os

let appLog = Logger(subsystem: "com.magicelklabs.lantern", category: "state")

/// A write of `state.sqlite` or of a hot-exit copy failed: unsaved edits may not survive a crash.
struct StateWriteFailure: Equatable, Sendable {
    var reason: String
    /// The disk (or the user's quota) is full.
    var outOfSpace: Bool
}

/// The app's side of `state.sqlite`: what the previous run left, the latest UI of every editor, debounced
/// saving, and ordered durable writes of unsaved editor text (hot-exit). Without a usable database the app still works
/// for this run, it just does not remember it. While writes fail, `writeFailure` says why.
@MainActor @Observable
final class StatePersistence {
    /// Where `state.sqlite`, the hot-exit copies and the rename journals are.
    let paths: AppSupportPaths
    /// Why nothing is saved this run; nil when `state.sqlite` works.
    let unavailableReason: String?
    /// The window's layout when the app last ran.
    let restoredWindow: WindowState?
    /// Unsaved editor buffers the previous run left (hot-exit), by path.
    let restoredDirtyBuffers: [String: DirtyBuffer]
    /// Where each file's editor was (restored at launch, then kept current).
    @ObservationIgnored private(set) var editorUI: [String: EditorUIState]
    /// The latest write of unsaved text failed, else the latest layout write did; nil once each kind's latest write
    /// succeeded.
    private(set) var writeFailure: StateWriteFailure?
    @ObservationIgnored private var failures: [StateStore.Write: StateWriteFailure] = [:]

    private let store: StateStore?
    /// Dirty-buffer writes run here, one after the other in call order: each is durable (two `F_FULLFSYNC`s), which
    /// takes too long for the main thread.
    private let dirtyBufferQueue = DispatchQueue(label: "com.magicelklabs.lantern.hot-exit", qos: .userInitiated)

    init(paths: AppSupportPaths) {
        self.paths = paths
        var store: StateStore?
        var window: WindowState?
        var dirtyBuffers: [String: DirtyBuffer] = [:]
        var editorUI: [String: EditorUIState] = [:]
        var reason: String?
        do {
            let opened = try StateStore(paths: paths)
            if let recovery = opened.recovery {
                appLog.error(
                    "state.sqlite was unusable (\(recovery.reason, privacy: .public)); moved to \(recovery.movedAside.path(percentEncoded: false), privacy: .public); \(recovery.restoredBuffers.count) unsaved buffers restored from hot-exit copies"
                )
            }
            // A Rename Project… that a crash or a quit cut short: the stored state follows the folder if it moved.
            Self.settleRename(paths: paths, store: opened)
            window = try opened.window(id: AppState.mainWindowID)
            dirtyBuffers = Dictionary(try opened.dirtyBuffers().map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
            editorUI = try opened.editorUIStates()
            store = opened
        } catch {
            reason = String(describing: error)
            appLog.error("state.sqlite unavailable, the layout will not be remembered: \(String(describing: error), privacy: .public)")
        }
        self.store = store
        restoredWindow = window
        self.editorUI = editorUI
        restoredDirtyBuffers = dirtyBuffers
        unavailableReason = reason
        store?.setWriteObserver { [weak self] write, error in
            let failure = error.map { StateWriteFailure(reason: String(describing: $0), outOfSpace: StateStore.isOutOfSpace($0)) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.wrote(write, failure: failure) }
            }
        }
    }

    private func wrote(_ write: StateStore.Write, failure: StateWriteFailure?) {
        failures[write] = failure
        let shown = failures[.dirtyBuffer] ?? failures[.layout]
        if shown != writeFailure { writeFailure = shown }
    }

    /// Hot-exit temp files interrupted writes left (Settings › Storage).
    func abandonedMirrorWrites() -> (count: Int, bytes: Int64) {
        store?.abandonedMirrorWrites() ?? (0, 0)
    }

    func removeAbandonedMirrorWrites() -> (count: Int, bytes: Int64) {
        store?.removeAbandonedMirrorWrites() ?? (0, 0)
    }

    func save(_ window: WindowState) {
        store?.setWindow(window)
    }

    /// Remembers where the editor of `state.path` is; a real change is saved (debounced).
    func updateEditorUI(_ state: EditorUIState) {
        guard state != editorUI[state.path] else { return }
        editorUI[state.path] = state
        store?.setEditorUI(state)
    }

    /// Stores the unsaved text of an editor buffer durably, after every earlier dirty-buffer call.
    func saveDirtyBuffer(_ buffer: DirtyBuffer) {
        guard let store else { return }
        dirtyBufferQueue.async {
            do {
                try store.saveDirtyBuffer(buffer)
            } catch {
                appLog.error("saving the unsaved text of \(buffer.path, privacy: .private) failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Forgets the unsaved text of `path` (saved, reverted or discarded), after every earlier dirty-buffer call.
    func clearDirtyBuffer(path: String) {
        guard let store else { return }
        dirtyBufferQueue.async {
            do {
                try store.clearDirtyBuffer(path: path)
            } catch {
                appLog.error("forgetting the unsaved text of \(path, privacy: .private) failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// The folder `move.from` is at `move.to` now (Rename Project…): the editor state and the unsaved buffers kept for
    /// paths in it, here and in `state.sqlite` (window layouts too), name the new place. Durable when this returns,
    /// after every earlier dirty-buffer call.
    func moveFolder(_ move: FolderMove) {
        for (path, state) in editorUI {
            guard let movedPath = move.moved(path) else { continue }
            var moved = state
            moved.path = movedPath
            editorUI[path] = nil
            editorUI[movedPath] = moved
        }
        guard let store else { return }
        dirtyBufferQueue.sync {
            do {
                try store.moveFolder(move)
            } catch {
                appLog.error("moving the state of a renamed folder failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// What the app's journal of a Rename Project… (`ProjectRenameJournal`) comes to: when the folder moved, the state
    /// stored for it follows (`StateStore.moveFolder`) and the journal goes, and the move is returned; when it never
    /// will, the journal goes. While ompd may still move it, or the state cannot be moved, the journal stays.
    @discardableResult
    static func settleRename(paths: AppSupportPaths, store: StateStore?) -> FolderMove? {
        guard let journal = ProjectRenameJournal.read(at: paths.projectRenameApp) else { return nil }
        switch journal.outcome(daemonJournal: paths.projectRename) {
        case .moved(let move):
            guard let store else { return nil }
            do {
                try store.moveFolder(move)
                try ProjectRenameJournal.remove(at: paths.projectRenameApp)
                return move
            } catch {
                appLog.error("settling a project rename failed: \(String(describing: error), privacy: .public)")
                return nil
            }
        case .dropped:
            try? ProjectRenameJournal.remove(at: paths.projectRenameApp)
            return nil
        case .undecided:
            return nil
        }
    }

    /// Writes everything pending now, and returns once the dirty-buffer writes asked for so far are durable.
    func flush() {
        do {
            try store?.flush()
        } catch {
            appLog.error("saving the window state failed: \(String(describing: error), privacy: .public)")
        }
        dirtyBufferQueue.sync {}
    }
}
