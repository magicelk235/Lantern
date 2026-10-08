import Foundation

// Renaming a project's folder (Rename Project…, and Locate Folder… for a folder moved in the Finder). Additive to
// protocol 5: an ompd from before this method answers `unknown_method`.

/// A folder renamed or moved from `from` to `to`, both absolute: where a path in it is now. Paths compare byte for byte,
/// the way the file system hands them out.
public struct FolderMove: Codable, Sendable, Hashable {
    public var from: String
    public var to: String

    public init(from: String, to: String) {
        self.from = from
        self.to = to
    }

    /// `path` after the move: `to` for `from` itself, `to` and the rest for a path inside `from`; nil for any other path.
    public func moved(_ path: String) -> String? {
        if path.utf8.elementsEqual(from.utf8) { return to }
        let prefix = from.hasSuffix("/") ? from : from + "/"
        guard path.utf8.starts(with: prefix.utf8) else { return nil }
        let rest = String(decoding: path.utf8.dropFirst(prefix.utf8.count), as: UTF8.self)
        return to.hasSuffix("/") ? to + rest : to + "/" + rest
    }

    /// `path` is `from` or inside it.
    public func contains(_ path: String) -> Bool {
        moved(path) != nil
    }

    /// The move that undoes this one.
    public var reversed: FolderMove {
        FolderMove(from: to, to: from)
    }
}

/// Rename Project…: the project's folder `from` becomes `to` and what omp and ompd keep under its path follows it. ompd
/// stops the running sessions of the folder (and of folders inside it) the graceful way, an omp in one of Lantern's
/// terminals through its ide-bridge; renames the folder (`moveFolder`; false: it is at `to` already, moved in the
/// Finder); moves omp's session files, memory bank and prompt history to the new path in every omp agent directory the
/// sessions use; points the sessions at the new folder; then resumes the ones it stopped, continuing what the stop
/// interrupted. Crash-safe: a journal lets the next ompd finish a rename a crash cut short. Refused with `badParams` when
/// the folder cannot be renamed (the message says why, in the Finder's words), `sessionBusy` while another rename runs
/// or an omp does not stop, `readOnly` while ompd cannot write its manifest.
public enum ProjectRename: DaemonMethod {
    public static let name = "project.rename"
    public struct Params: Codable, Sendable, Equatable {
        /// The project's folder as ompd names it (`realpath`).
        public var from: String
        /// Where it goes: absolute, its parent an existing folder.
        public var to: String
        /// ompd renames the folder; false when the folder is at `to` already and only what follows it moves.
        public var moveFolder: Bool

        public init(from: String, to: String, moveFolder: Bool = true) {
            self.from = from
            self.to = to
            self.moveFolder = moveFolder
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            from = try container.decode(String.self, forKey: .from)
            to = try container.decode(String.self, forKey: .to)
            moveFolder = try container.decodeIfPresent(Bool.self, forKey: .moveFolder) ?? true
        }
    }

    public struct Result: Codable, Sendable, Equatable {
        /// The folder as ompd names the project now (`realpath` of `to`).
        public var workspace: String
        /// The sessions whose omp was stopped for the rename and resumes in the renamed folder.
        public var resumed: [SessionKey]
        /// What of omp's data stayed under the old path, one sentence each for the user; empty when everything moved.
        public var notMoved: [String]

        public init(workspace: String, resumed: [SessionKey] = [], notMoved: [String] = []) {
            self.workspace = workspace
            self.resumed = resumed
            self.notMoved = notMoved
        }
    }
}
