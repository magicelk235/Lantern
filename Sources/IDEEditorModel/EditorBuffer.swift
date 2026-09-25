import Foundation
import IDEState

/// One editor buffer measured against the file on disk: whether it has unsaved
/// edits, which version of the file they started from, and what happened to the file underneath them.
///
/// The text itself lives in the editor (an `NSTextStorage`). The buffer is told when it changes and reads it only
/// when the length alone cannot decide. Dirty means the text differs from the baseline version by content hash, so
/// undoing back to the saved text makes the buffer clean again.
public struct EditorBuffer: Equatable, Sendable {
    /// The version of the file the buffer's edits started from.
    public struct Baseline: Equatable, Sendable {
        /// Hash of that version's bytes; nil when no such file ever existed.
        public var hash: String?
        /// UTF-16 length of that version's text, when known: a text of another length differs without hashing it.
        public var utf16Count: Int?

        public init(hash: String?, utf16Count: Int?) {
            self.hash = hash
            self.utf16Count = utf16Count
        }

        public init(_ snapshot: TextSnapshot) {
            self.init(hash: snapshot.hash, utf16Count: snapshot.utf16Count)
        }
    }

    /// Why the file is not on disk as text anymore while the buffer is open.
    public enum Gone: Equatable, Sendable {
        case deleted
        /// Replaced by something the editor does not show as text.
        case unsupported(UnsupportedReason)
    }

    /// How a file opens.
    public enum Opening: Equatable, Sendable {
        /// Editable: the buffer and the text to show.
        case text(EditorBuffer, String)
        /// Nothing at the path, and no unsaved copy of it.
        case missing
        /// Not a text file the editor shows, and no unsaved copy of it.
        case unsupported(UnsupportedReason)
    }

    /// What a change on disk means for the buffer.
    public enum DiskChange: Equatable, Sendable {
        /// Nothing to do: the file is (again) the baseline version, as after the buffer's own save, it is gone
        /// already, or it could not be read.
        case none
        /// The buffer had no edits and now shows this version: a silent reload.
        case reload(TextSnapshot)
        /// The file now holds exactly the buffer's text: the edits are saved.
        case becameClean
        /// The buffer has edits and the file changed: `conflict` holds the new version until the user reloads it or
        /// keeps theirs.
        case conflict
        /// The file is gone (see `gone`); the buffer keeps its text, and saving writes it back.
        case gone
        /// The buffer had no edits and the file is no longer text the editor shows.
        case unsupported(UnsupportedReason)
    }

    /// Absolute path of the file.
    public let path: String
    public private(set) var baseline: Baseline
    public private(set) var isDirty: Bool
    /// A version of the file that appeared on disk while the buffer had edits.
    public private(set) var conflict: TextSnapshot?
    /// Set while the file is not on disk as text.
    public private(set) var gone: Gone?

    init(path: String, baseline: Baseline, isDirty: Bool) {
        self.path = path
        self.baseline = baseline
        self.isDirty = isDirty
    }

    /// Opens `path` from what is on disk now and its hot-exit copy, if any. The copy wins: its text comes back as the
    /// unsaved edits it was, whatever happened to the file meanwhile. It is clean only when the file now
    /// holds exactly that text; when the file changed since the edits started, that version is a `conflict`.
    public static func open(path: String, disk: FileContents, restored: DirtyBuffer?) -> Opening {
        guard let restored else {
            switch disk {
            case .text(let snapshot):
                return .text(EditorBuffer(path: path, baseline: Baseline(snapshot), isDirty: false), snapshot.text)
            case .missing: return .missing
            case .unsupported(let reason): return .unsupported(reason)
            }
        }
        var buffer = EditorBuffer(path: path, baseline: Baseline(hash: restored.baselineHash, utf16Count: nil), isDirty: true)
        switch disk {
        case .text(let snapshot):
            if snapshot.hash == ContentHash.of(text: restored.contents) {
                // Saved meanwhile, from here or elsewhere.
                buffer.reload(from: snapshot)
            } else if snapshot.hash == restored.baselineHash {
                buffer.baseline = Baseline(snapshot)
            } else {
                buffer.conflict = snapshot
            }
        case .missing:
            buffer.gone = .deleted
        case .unsupported(.unreadable):
            // No verdict on the file: the edits stay against their baseline.
            break
        case .unsupported(let reason):
            buffer.gone = .unsupported(reason)
        }
        return .text(buffer, restored.contents)
    }

    /// The text changed: `utf16Count` is its length and `text` reads it, called only when the length cannot decide.
    public mutating func textDidChange(utf16Count: Int, text: () -> String) {
        isDirty = differsFromBaseline(utf16Count: utf16Count, text: text)
    }

    /// The text was written to disk as `saved`.
    public mutating func didSave(_ saved: TextSnapshot) {
        reload(from: saved)
    }

    /// The buffer now shows `snapshot`, the file as read from disk (revert, or reloading a conflicting version):
    /// no edits, no conflict.
    public mutating func reload(from snapshot: TextSnapshot) {
        baseline = Baseline(snapshot)
        isDirty = false
        conflict = nil
        gone = nil
    }

    /// Keeps the edits over the conflicting version, which becomes their baseline: saving overwrites it, and it no
    /// longer counts as a change underneath.
    public mutating func keepMine(utf16Count: Int, text: () -> String) {
        guard let conflict else { return }
        baseline = Baseline(conflict)
        self.conflict = nil
        isDirty = differsFromBaseline(utf16Count: utf16Count, text: text)
    }

    /// The file on disk may have changed and now is `disk`; the buffer's text is `utf16Count` long and read by `text`.
    public mutating func diskDidChange(_ disk: FileContents, utf16Count: Int, text: () -> String) -> DiskChange {
        switch disk {
        case .unsupported(.unreadable):
            return .none
        case .text(let snapshot):
            gone = nil
            if snapshot.hash == baseline.hash {
                // The baseline again (or still): whatever changed in between is moot.
                conflict = nil
                return .none
            }
            guard isDirty else {
                reload(from: snapshot)
                return .reload(snapshot)
            }
            if snapshot.utf16Count == utf16Count, snapshot.hash == ContentHash.of(text: text()) {
                reload(from: snapshot)
                return .becameClean
            }
            conflict = snapshot
            return .conflict
        case .missing:
            guard gone != .deleted else { return .none }
            gone = .deleted
            conflict = nil
            return .gone
        case .unsupported(let reason):
            guard isDirty else { return .unsupported(reason) }
            guard gone != .unsupported(reason) else { return .none }
            gone = .unsupported(reason)
            conflict = nil
            return .gone
        }
    }

    /// The hot-exit copy of the buffer holding `contents`, its current text.
    public func hotExitCopy(contents: String, at date: Date = Date()) -> DirtyBuffer {
        DirtyBuffer(path: path, contents: contents, baselineHash: baseline.hash, updatedAt: date)
    }

    private func differsFromBaseline(utf16Count: Int, text: () -> String) -> Bool {
        guard let hash = baseline.hash else { return true }
        if let count = baseline.utf16Count, count != utf16Count { return true }
        return ContentHash.of(text: text()) != hash
    }
}
