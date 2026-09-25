import Darwin
import Foundation

/// A file or folder in the file navigator.
public struct FileEntry: Hashable, Sendable, Identifiable {
    /// Absolute path.
    public var path: String
    public var name: String
    /// A folder, or a symlink to one.
    public var isDirectory: Bool

    public var id: String { path }

    public init(path: String, name: String, isDirectory: Bool) {
        self.path = path
        self.name = name
        self.isDirectory = isDirectory
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
            // `stat` follows symlinks: a link to a folder lists as a folder, a dangling one as a file.
            let isDirectory = stat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
            entries.append(FileEntry(path: path, name: name, isDirectory: isDirectory))
        }
        return entries.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    /// `.<name>.omp-ide-<id>.tmp`, see `TextFile.write`.
    static func isSaveTempFile(_ name: String) -> Bool {
        name.hasPrefix(".") && name.hasSuffix(".tmp") && name.contains(".omp-ide-")
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
    /// Empty when `root` is not in a git work tree or no git is installed; the command line tools' `/usr/bin/git`
    /// shim is never run, so a Mac without them gets no install prompt.
    public static func load(in root: String) async -> GitIgnoredPaths {
        await Task.detached(priority: .utility) {
            guard let git = gitExecutable else { return .none }
            let process = Process()
            process.executableURL = URL(filePath: git)
            process.arguments = ["-C", root, "ls-files", "--others", "--ignored", "--exclude-standard", "--directory", "-z"]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                return .none
            }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return .none }
            let paths = data.split(separator: 0).map { entry in
                var relative = String(decoding: entry, as: UTF8.self)
                if relative.hasSuffix("/") { relative.removeLast() }
                return (root as NSString).appendingPathComponent(relative)
            }
            return GitIgnoredPaths(paths: Set(paths))
        }.value
    }

    /// The git of the active developer directory (`xcode-select -p`), else Homebrew's.
    private static let gitExecutable: String? = {
        var candidates: [String] = []
        if let developer = developerDirectory() { candidates.append(developer + "/usr/bin/git") }
        candidates += ["/opt/homebrew/bin/git", "/usr/local/bin/git"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    private static func developerDirectory() -> String? {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/xcode-select")
        process.arguments = ["-p"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }
}
