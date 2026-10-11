import Darwin
import Foundation

/// A file or folder in the file navigator.
public struct FileEntry: Hashable, Sendable, Identifiable {
    /// Absolute path.
    public var path: String
    public var name: String
    /// A folder, or a symlink to one.
    public var isDirectory: Bool
    /// A symlink, to a file or a folder (or dangling): Finder's alias.
    public var isSymlink: Bool
    /// A symlink to the folder holding it or a folder above: its contents would list the same folders again, forever.
    public var isLinkLoop: Bool

    public var id: String { path }

    public init(path: String, name: String, isDirectory: Bool, isSymlink: Bool = false, isLinkLoop: Bool = false) {
        self.path = path
        self.name = name
        self.isDirectory = isDirectory
        self.isSymlink = isSymlink
        self.isLinkLoop = isLinkLoop
    }
}

/// One level of a folder, as the file navigator lists it.
public enum DirectoryListing {
    /// Never listed: version-control internals, dependency and build trees, Finder metadata.
    public static let hiddenNames: Set<String> = [".git", "node_modules", ".build", ".DS_Store"]

    /// The entries of `directory`, folders first, each group in Finder order. Names in `hiddenNames` and the
    /// short-lived temp files of an editor save are left out.
    public static func entries(of directory: String) throws -> [FileEntry] {
        let names = try FileManager.default.contentsOfDirectory(atPath: directory)
        var entries: [FileEntry] = []
        entries.reserveCapacity(names.count)
        for name in names where !hiddenNames.contains(name) && !isSaveTempFile(name) {
            let path = (directory as NSString).appendingPathComponent(name)
            var info = stat()
            // `lstat` tells a symlink; for one, `stat` follows it: a link to a folder lists as a folder, a dangling one
            // as a file.
            let found = lstat(path, &info) == 0
            let isLink = found && info.st_mode & S_IFMT == S_IFLNK
            let isDirectory = found && (!isLink || stat(path, &info) == 0) && info.st_mode & S_IFMT == S_IFDIR
            entries.append(FileEntry(
                path: path, name: name, isDirectory: isDirectory, isSymlink: isLink,
                isLinkLoop: isLink && isDirectory && leadsBack(path, from: directory)))
        }
        return entries.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    /// `link`, in `directory`, resolves to `directory` or a folder that holds it, by any of the paths leading down to it:
    /// `directory` may itself be reached through links.
    static func leadsBack(_ link: String, from directory: String) -> Bool {
        guard let target = resolved(link) else { return false }
        let inside = target.hasSuffix("/") ? target : target + "/"
        var folder = directory
        while true {
            if let real = resolved(folder), real == target || real.hasPrefix(inside) { return true }
            let parent = (folder as NSString).deletingLastPathComponent
            if parent == folder || parent.isEmpty { return false }
            folder = parent
        }
    }

    private static func resolved(_ path: String) -> String? {
        guard let real = realpath(path, nil) else { return nil }
        defer { free(real) }
        return String(cString: real)
    }

    /// `.<name>.lantern-<id>.tmp`, see `TextFile.write`.
    static func isSaveTempFile(_ name: String) -> Bool {
        name.hasPrefix(".") && name.hasSuffix(".tmp") && name.contains(".lantern-")
    }
}

/// What git ignores under a folder (`.gitignore` files, `.git/info/exclude`, the global excludes file), for the
/// file navigator to dim.
public struct GitIgnoredPaths: Equatable, Sendable {
    /// Absolute paths; an ignored folder stands for everything in it.
    public private(set) var paths: Set<String>

    public static let none = GitIgnoredPaths(paths: [])

    public init(paths: Set<String>) {
        self.paths = paths
    }

    /// `path` or one of its folders up to (not including) `root` is ignored.
    public func contains(_ path: String, under root: String) -> Bool {
        guard !paths.isEmpty else { return false }
        var current = path
        while current.count > root.count {
            if paths.contains(current) { return true }
            current = (current as NSString).deletingLastPathComponent
        }
        return false
    }

    /// Asks git (`ls-files --others --ignored --exclude-standard --directory`) for the ignored entries under `root`.
    /// Empty when `root` is not in a git work tree or no git is installed (`Git.executable`).
    public static func load(in root: String) async -> GitIgnoredPaths {
        guard let data = try? await Git.output(
            ["ls-files", "--others", "--ignored", "--exclude-standard", "--directory", "-z"], in: root)
        else { return .none }
        let paths = data.split(separator: 0).map { entry in
            var relative = String(decoding: entry, as: UTF8.self)
            if relative.hasSuffix("/") { relative.removeLast() }
            return (root as NSString).appendingPathComponent(relative)
        }
        return GitIgnoredPaths(paths: Set(paths))
    }
}
