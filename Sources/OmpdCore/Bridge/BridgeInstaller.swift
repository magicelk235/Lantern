import Foundation
import IDEProtocol

/// Puts the ide-bridge extension where omp loads it: ompd's own copy (passed to every spawn with `-e`) and the
/// lock-mode copy in the omp agent's `extensions/` directory, which every other omp auto-discovers.
/// Both are the same file; the bridge picks its mode from the environment.
public enum BridgeInstaller {
    /// Overrides where the shipped ide-bridge.ts is read from.
    public static let sourceEnvironmentKey = "OMPD_BRIDGE_PATH"
    public static let sourceFileName = "ide-bridge.ts"
    /// Name of the lock-mode copy inside `<agentDir>/extensions/`.
    public static let globalFileName = "lantern-bridge.ts"

    /// Locate the shipped ide-bridge.ts: `$OMPD_BRIDGE_PATH`, then `<executable>/../Resources/ide-bridge.ts` (app bundle),
    /// then the repository's `bridge/ide-bridge.ts` (development builds, via `#filePath`).
    public static func locateSource() throws -> URL {
        let fileManager = FileManager.default
        if let override = ProcessInfo.processInfo.environment[sourceEnvironmentKey], !override.isEmpty {
            let url = URL(filePath: NSString(string: override).expandingTildeInPath, directoryHint: .notDirectory)
            guard isRegularFile(url, fileManager) else { throw BridgeError.sourceNotFound(searched: [url.path(percentEncoded: false)]) }
            return url
        }
        var candidates: [URL] = []
        if let executable = Bundle.main.executableURL?.resolvingSymlinksInPath() {
            candidates.append(
                executable.deletingLastPathComponent().deletingLastPathComponent()
                    .appending(path: "Resources/\(sourceFileName)", directoryHint: .notDirectory))
        }
        // <repo>/Sources/OmpdCore/Bridge/BridgeInstaller.swift -> <repo>/bridge/ide-bridge.ts
        let repository = URL(filePath: #filePath, directoryHint: .notDirectory)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        candidates.append(repository.appending(path: "bridge/\(sourceFileName)", directoryHint: .notDirectory))
        guard let found = candidates.first(where: { isRegularFile($0, fileManager) }) else {
            throw BridgeError.sourceNotFound(searched: candidates.map { $0.path(percentEncoded: false) })
        }
        return found
    }

    /// Copy to `$APP_SUPPORT/bridge/ide-bridge.ts` (atomic, only if changed) and return that path (what ompd passes to
    /// omp `-e`). Lives outside `run/`, which `prepare()` wipes.
    public static func stage(into paths: AppSupportPaths) throws -> URL {
        let directory = paths.root.appending(path: "bridge", directoryHint: .isDirectory)
        try StorageIO.createPrivateDirectory(directory)
        let target = directory.appending(path: sourceFileName, directoryHint: .notDirectory)
        try copyIfChanged(from: locateSource(), to: target, mode: 0o600)
        return target
    }

    /// Install the lock-mode copy as `<agentDir>/extensions/lantern-bridge.ts` (atomic, only if changed); idempotent.
    /// ompd calls this at startup, so the copy always matches the running daemon.
    public static func installGlobal(agentDir: URL) throws -> URL {
        let directory = agentDir.appending(path: "extensions", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appending(path: globalFileName, directoryHint: .notDirectory)
        try copyIfChanged(from: locateSource(), to: target, mode: 0o644)
        return target
    }

    /// omp's active agent directory: `$PI_CODING_AGENT_DIR`, else `~/.omp/agent` (extension-loading.md). Profiles live
    /// in `~/.omp/profiles/<name>/agent`.
    public static var defaultAgentDir: URL {
        if let dir = ProcessInfo.processInfo.environment["PI_CODING_AGENT_DIR"], !dir.isEmpty {
            return URL(filePath: NSString(string: dir).expandingTildeInPath, directoryHint: .isDirectory)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appending(path: ".omp/agent", directoryHint: .isDirectory)
    }

    private static func copyIfChanged(from source: URL, to target: URL, mode: mode_t) throws {
        let contents = try Data(contentsOf: source)
        if try StorageIO.readFileIfPresent(target) == contents { return }
        try StorageIO.writeAtomically(contents, to: target, mode: mode, durable: false)
    }

    private static func isRegularFile(_ url: URL, _ fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory) && !isDirectory.boolValue
    }
}
