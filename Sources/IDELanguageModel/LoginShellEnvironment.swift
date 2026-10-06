import Foundation

/// The environment of the user's login shell, which language servers run in: they need its `PATH` to be found at all
/// and to find their own tools (`node` for typescript-language-server, `go` for gopls, a virtualenv's Python). The app
/// started from the Finder or the Dock has launchd's minimal environment instead, so it asks the shell: an interactive
/// login shell first (rc files such as `.zshrc` add to `PATH` too), then a plain login shell, each given a few seconds;
/// when neither answers, the app's own environment with the usual tool folders added to `PATH`.
public enum LoginShellEnvironment {
    public static let beginMarker = "__LANTERN_ENVIRONMENT_BEGIN__"
    public static let endMarker = "__LANTERN_ENVIRONMENT_END__"

    /// Variables about the shell itself, not the environment it sets up for programs.
    private static let shellOnly: Set<String> = ["PWD", "OLDPWD", "SHLVL", "_"]

    /// Folders added to `PATH` when no shell answers: Homebrew's, `/usr/local`'s, and those rustup, `go install`,
    /// pipx/uv and Bun put programs in.
    private static func toolFolders(home: String) -> [String] {
        ["/opt/homebrew/bin", "/usr/local/bin", home + "/.cargo/bin", home + "/go/bin", home + "/.local/bin", home + "/.bun/bin"]
    }

    /// Captures the environment (`shell` defaults to the user's login shell) starting from `base`.
    public static func capture(
        shell: String = loginShell, base: [String: String] = ProcessInfo.processInfo.environment, timeout: Duration = .seconds(5)
    ) async -> [String: String] {
        // A dumb terminal keeps prompt themes from drawing; the markers fence off whatever rc files print.
        let command = "printf '%s' '\(beginMarker)'; /usr/bin/env -0; printf '%s' '\(endMarker)'"
        var environment = base
        environment["TERM"] = "dumb"
        for flags in [["-i", "-l", "-c"], ["-l", "-c"]] {
            if let (_, output) = await CommandRunner.run(shell, flags + [command], environment: environment, timeout: timeout),
               let captured = parse(output) {
                return captured
            }
        }
        return fallback(base, home: base["HOME"] ?? NSHomeDirectory())
    }

    /// The `env -0` output between the markers, without the shell's own variables; nil when the markers or every
    /// variable are missing.
    public static func parse(_ output: Data) -> [String: String]? {
        guard let begin = output.range(of: Data(beginMarker.utf8)),
              let end = output.range(of: Data(endMarker.utf8), in: begin.upperBound..<output.endIndex) else { return nil }
        var environment: [String: String] = [:]
        for entry in output[begin.upperBound..<end.lowerBound].split(separator: 0) {
            guard let equals = entry.firstIndex(of: UInt8(ascii: "=")), equals > entry.startIndex else { continue }
            let name = String(decoding: entry[entry.startIndex..<equals], as: UTF8.self)
            guard !shellOnly.contains(name) else { continue }
            environment[name] = String(decoding: entry[(equals + 1)...], as: UTF8.self)
        }
        return environment.isEmpty ? nil : environment
    }

    /// `base` with the usual tool folders after its own `PATH` entries.
    public static func fallback(_ base: [String: String], home: String) -> [String: String] {
        var folders = (base["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init)
        for folder in toolFolders(home: home) where !folders.contains(folder) { folders.append(folder) }
        var environment = base
        environment["PATH"] = folders.joined(separator: ":")
        return environment
    }

    /// The user's login shell (`getpwuid_r`), else `$SHELL`, else zsh.
    public static var loginShell: String {
        var entry = passwd()
        var result: UnsafeMutablePointer<passwd>?
        var buffer = [CChar](repeating: 0, count: 4096)
        let shell = buffer.withUnsafeMutableBufferPointer { storage -> String? in
            guard getpwuid_r(getuid(), &entry, storage.baseAddress, storage.count, &result) == 0, result != nil,
                  let shell = entry.pw_shell, shell.pointee != 0 else { return nil }
            return String(cString: shell)
        }
        return shell ?? ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    }
}
