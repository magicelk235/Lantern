import Foundation
import IDEProtocol

/// The app's journal of a Rename Project… under way, `project-rename-app.json` next to ompd's own
/// (`AppSupportPaths.projectRenameApp`): written before ompd is asked to rename the folder, removed once the app's own
/// state (window layouts, editor UI, unsaved buffers) follows the folder. A crash or a quit in between leaves it for
/// the next launch to settle (`outcome`).
public struct ProjectRenameJournal: Codable, Sendable, Equatable {
    /// The project's folder as it was, and where it goes.
    public var move: FolderMove

    public init(_ move: FolderMove) {
        self.move = move
    }

    /// What a journal left behind comes to.
    public enum Outcome: Equatable, Sendable {
        /// The folder moved: the app's state follows it.
        case moved(FolderMove)
        /// The folder never moved, and nothing will move it now: the journal goes.
        case dropped
        /// ompd's own journal is still there: it may still move the folder, so the journal stays.
        case undecided
    }

    /// The journal at `url`; nil when there is none (or it does not parse, which no write of `write` leaves).
    public static func read(at url: URL) -> ProjectRenameJournal? {
        guard let data = FileManager.default.contents(atPath: url.path(percentEncoded: false)) else { return nil }
        return try? IDECoding.decoder().decode(ProjectRenameJournal.self, from: data)
    }

    /// Writes the journal atomically and durably: once this returns it survives a crash or a power loss.
    public func write(to url: URL) throws {
        try FileIO.createPrivateDirectory(url.deletingLastPathComponent())
        try FileIO.writeAtomically(IDECoding.encoder().encode(self), to: url)
    }

    public static func remove(at url: URL) throws {
        try FileIO.removeDurably(url)
    }

    /// The folder moved when its new path is there and its old one is not; it never did when the old path is still
    /// there and ompd's journal (`daemonJournal`) is gone. Names compare exactly, so a rename that only changes case
    /// tells too.
    public func outcome(daemonJournal: URL) -> Outcome {
        let from = Self.existsExactly(move.from)
        if Self.existsExactly(move.to), !from { return .moved(move) }
        if from, !FileManager.default.fileExists(atPath: daemonJournal.path(percentEncoded: false)) { return .dropped }
        return .undecided
    }

    /// Something is at `path` under that very name, not only one that differs in case on a volume that ignores it
    /// (names compare as text: the same name in another Unicode normalization is the same name).
    static func existsExactly(_ path: String) -> Bool {
        guard FileManager.default.fileExists(atPath: path) else { return false }
        let parent = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: parent) else { return true }
        return names.contains { $0 == name }
    }
}
