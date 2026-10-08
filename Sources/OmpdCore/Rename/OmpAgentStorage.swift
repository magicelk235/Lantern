import Darwin
import Foundation
import IDEProtocol

/// Where omp 18 keeps what it stores per project folder, for the environment an omp runs with: its agent directory
/// (`PI_CODING_AGENT_DIR`, else `~/<PI_CONFIG_DIR or .omp>/agent`, a profile's `…/profiles/<name>/agent` under
/// `OMP_PROFILE`), the XDG base directories omp prefers when they hold an `omp` folder, and the home and temporary
/// folders omp names session folders by (`dirs.ts`, `session-paths.ts`).
struct OmpAgentStorage: Codable, Sendable, Hashable {
    var agentDir: String
    /// `<data>/sessions`: a folder of session files per cwd (`OmpPaths.sessionDirectoryName`).
    var sessions: String
    /// `<state>/memories`: Mnemopi's database and its banks (`mnemopi/banks/<bank>`) unless `mnemopi.dbPath` moves them.
    var memories: String
    /// `<state>/terminal-sessions`: per terminal, the cwd and session file `omp --continue` picks up there.
    var terminalSessions: String
    /// `<state>/custom-session-files`: session files kept outside `sessions`, by path hash.
    var customSessionFiles: String
    /// `<data>/history.db`: the prompt history, with each prompt's cwd.
    var historyDB: String
    /// `<cache>/cache/composer.db`: the prompt's status line drawn at startup, per cwd.
    var composerDB: String
    /// Canonical home and temporary folders, which session folders are named relative to.
    var home: String
    var temporaryDirectory: String

    init(environment: [String: String]) {
        func value(_ key: String) -> String? {
            environment[key].flatMap { $0.isEmpty ? nil : $0 }
        }
        let home = value("HOME") ?? NSHomeDirectory()
        var configRoot = (home as NSString).appendingPathComponent(value("PI_CONFIG_DIR") ?? ".omp")
        let profile = Self.profile(value("OMP_PROFILE") ?? value("PI_PROFILE"))
        if let profile { configRoot = (configRoot as NSString).appendingPathComponent("profiles/\(profile)") }
        let defaultAgentDir = (configRoot as NSString).appendingPathComponent("agent")
        let agentDir: String =
            if profile == nil, let override = value("PI_CODING_AGENT_DIR") {
                Self.absolute(NSString(string: override).expandingTildeInPath)
            } else {
                defaultAgentDir
            }
        // omp prefers `$XDG_<KIND>_HOME/omp` (a profile's folder under it) when it exists, for the default agent dir only.
        func base(_ variable: String) -> String {
            guard agentDir == defaultAgentDir, let xdg = value(variable) else { return agentDir }
            var folder = (xdg as NSString).appendingPathComponent("omp")
            if let profile { folder = (folder as NSString).appendingPathComponent("profiles/\(profile)") }
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: folder, isDirectory: &isDirectory) && isDirectory.boolValue ? folder : agentDir
        }
        let data = base("XDG_DATA_HOME")
        let state = base("XDG_STATE_HOME")
        let cache = base("XDG_CACHE_HOME")
        self.agentDir = agentDir
        sessions = (data as NSString).appendingPathComponent("sessions")
        historyDB = (data as NSString).appendingPathComponent("history.db")
        memories = (state as NSString).appendingPathComponent("memories")
        terminalSessions = (state as NSString).appendingPathComponent("terminal-sessions")
        customSessionFiles = (state as NSString).appendingPathComponent("custom-session-files")
        composerDB = (cache as NSString).appendingPathComponent("cache/composer.db")
        self.home = Self.canonical(home)
        let temporary = value("TMPDIR") ?? value("TMP") ?? value("TEMP") ?? "/tmp"
        temporaryDirectory = Self.canonical(temporary)
    }

    /// The folder holding the session files of `canonicalCwd` (a `realpath`).
    func sessionDirectory(canonicalCwd: String) -> String {
        (sessions as NSString).appendingPathComponent(
            OmpPaths.sessionDirectoryName(canonicalCwd: canonicalCwd, home: home, temporaryDirectory: temporaryDirectory))
    }

    /// Mnemopi's banks: next to its database, `mnemopi.dbPath` when set.
    func memoryBanks(databasePath: String?) -> String {
        let database = databasePath.map(Self.absolute) ?? (memories as NSString).appendingPathComponent("mnemopi/mnemopi.db")
        return ((database as NSString).deletingLastPathComponent as NSString).appendingPathComponent("banks")
    }

    /// omp's profile name: none for an empty, `default` or invalid one (omp then uses the default agent dir).
    private static func profile(_ name: String?) -> String? {
        guard let name = name?.trimmingCharacters(in: .whitespaces), !name.isEmpty, name != "default", name != ".", name != "..",
              !name.hasSuffix("."), name.utf8.count <= 64,
              let first = name.unicodeScalars.first, first.isASCII, CharacterSet.alphanumerics.contains(first)
        else { return nil }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789._-")
        return name.unicodeScalars.allSatisfy({ $0.isASCII && allowed.contains($0) }) ? name : nil
    }

    /// Node's `path.resolve`: `.`, `..` and repeated slashes resolved without touching the disk (unlike
    /// `standardizingPath`, which also drops `/private`).
    static func absolute(_ path: String) -> String {
        let full = path.hasPrefix("/") ? path : FileManager.default.currentDirectoryPath + "/" + path
        var components: [Substring] = []
        for component in full.split(separator: "/") where component != "." {
            if component == ".." { _ = components.popLast() } else { components.append(component) }
        }
        return "/" + components.joined(separator: "/")
    }

    /// `realpath`, else the path resolved as `absolute` does.
    static func canonical(_ path: String) -> String {
        if let real = realpath(path, nil) {
            defer { free(real) }
            return String(cString: real)
        }
        return absolute(path)
    }
}
