import Foundation

/// Why an extension could not be installed or read, in sentences for an alert.
public enum ExtensionError: Error, LocalizedError, Equatable {
    /// The package has no `extension/package.json`: it is not a VS Code extension.
    case notAnExtension
    /// The extension, by its display name, has no color theme, snippets or language.
    case nothingUsable(String)
    /// A file, by name, could not be read or is not what it should be.
    case unreadable(String)

    public var errorDescription: String? {
        switch self {
        case .notAnExtension: "This is not a VS Code extension: it has no extension/package.json."
        case .nothingUsable(let name):
            "“\(name)” has no color themes, snippets or language settings that Lantern can use."
        case .unreadable(let name): "“\(name)” could not be read."
        }
    }
}

/// The extensions folder: a folder per extension named by its identifier, holding what the package's `extension`
/// folder held (so `<folder>/<id>/package.json`).
public struct ExtensionStore: Sendable {
    public let folder: URL

    public init(folder: URL) {
        self.folder = folder
    }

    /// The extensions in the folder, by display name; a folder without a manifest that reads is passed over. Reads the
    /// disk: call it off the main thread.
    public func installed() -> [InstalledExtension] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        return entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .compactMap { try? ExtensionManifest.read(folder: $0) }
            .sorted {
                switch $0.displayName.localizedStandardCompare($1.displayName) {
                case .orderedAscending: true
                case .orderedDescending: false
                case .orderedSame: $0.id < $1.id
                }
            }
    }

    /// Installs the extension package (a `.vsix`, a zip archive) at `vsix`, in place of the version already there, and
    /// returns it as installed. The package is unpacked with `ditto` into a hidden folder inside the extensions folder,
    /// so its `extension` folder can then be moved into place, replacing the old one in a single step; the hidden
    /// folder goes whatever happens. Throws `ExtensionError.unreadable` when the file is not an archive,
    /// `.notAnExtension` when it has no `extension/package.json`, and `.nothingUsable` when the extension has nothing
    /// the editor uses (`contributesAnything`). Blocks while unpacking: call it off the main thread.
    public func install(vsix: URL) throws -> InstalledExtension {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let staging = folder.appending(path: ".install-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: staging) }
        guard Self.unzip(vsix, into: staging) else { throw ExtensionError.unreadable(vsix.lastPathComponent) }
        let unpacked = staging.appending(path: "extension", directoryHint: .isDirectory)
        let manifest = try ExtensionManifest.read(folder: unpacked)
        guard manifest.contributesAnything else { throw ExtensionError.nothingUsable(manifest.displayName) }
        let destination = folder.appending(path: manifest.id, directoryHint: .isDirectory)
        if fileManager.fileExists(atPath: destination.path(percentEncoded: false)) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: unpacked)
        } else {
            try fileManager.moveItem(at: unpacked, to: destination)
        }
        return try ExtensionManifest.read(folder: destination)
    }

    /// Removes the extension `id` (an `InstalledExtension.id`); nothing happens when it is not installed. Its folder
    /// is first moved aside under a hidden name, so it never lies half deleted where `installed()` looks.
    public func uninstall(id: String) throws {
        guard !id.isEmpty, !id.contains("/"), !id.hasPrefix(".") else { return }
        let fileManager = FileManager.default
        let installed = folder.appending(path: id, directoryHint: .isDirectory)
        guard fileManager.fileExists(atPath: installed.path(percentEncoded: false)) else { return }
        let removed = folder.appending(path: ".uninstall-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fileManager.moveItem(at: installed, to: removed)
        try? fileManager.removeItem(at: removed)
    }

    /// Extracts the zip archive `archive` into `destination` with `ditto`, as Finder does; false when ditto fails.
    private static func unzip(_ archive: URL, into destination: URL) -> Bool {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archive.path(percentEncoded: false), destination.path(percentEncoded: false)]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return false
        }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}
