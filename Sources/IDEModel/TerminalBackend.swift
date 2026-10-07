import Foundation
import IDEProtocol
import IDETransport

/// The daemon calls terminals make. `DaemonConnection` implements them over its live `IDEClient`; while it
/// has none they throw `IDETransportError.notConnected`.
@MainActor
public protocol TerminalBackend: AnyObject, Sendable {
    func openPTY(_ params: PTYOpen.Params) async throws -> PTYInfo
    func attachPTY(_ ptyId: PTYID) async throws -> PTYAttach.Result
    func detachPTY(_ ptyId: PTYID) async throws
    func writePTY(_ ptyId: PTYID, data: Data) async throws
    func resizePTY(_ ptyId: PTYID, size: TerminalSize) async throws
    func closePTY(_ ptyId: PTYID) async throws
    func listPTYs() async throws -> [PTYInfo]
}

extension DaemonConnection {
    public func openPTY(_ params: PTYOpen.Params) async throws -> PTYInfo {
        try await connectedClient().call(PTYOpen.self, params)
    }

    public func attachPTY(_ ptyId: PTYID) async throws -> PTYAttach.Result {
        try await connectedClient().call(PTYAttach.self, .init(ptyId: ptyId))
    }

    public func detachPTY(_ ptyId: PTYID) async throws {
        _ = try await connectedClient().call(PTYDetach.self, .init(ptyId: ptyId))
    }

    public func writePTY(_ ptyId: PTYID, data: Data) async throws {
        _ = try await connectedClient().call(PTYWrite.self, .init(ptyId: ptyId, data: data))
    }

    public func resizePTY(_ ptyId: PTYID, size: TerminalSize) async throws {
        _ = try await connectedClient().call(PTYResize.self, .init(ptyId: ptyId, cols: size.cols, rows: size.rows))
    }

    public func closePTY(_ ptyId: PTYID) async throws {
        _ = try await connectedClient().call(PTYClose.self, .init(ptyId: ptyId))
    }

    public func listPTYs() async throws -> [PTYInfo] {
        try await connectedClient().call(PTYList.self, Empty()).ptys
    }

    /// What runs in the foreground of the PTY's terminal besides its program (`PTYProcesses`): what closing it ends.
    public func ptyProcesses(_ ptyId: PTYID) async throws -> [String] {
        try await connectedClient().call(PTYProcesses.self, .init(ptyId: ptyId)).processes
    }
}

/// A terminal's size in character cells.
public struct TerminalSize: Hashable, Sendable {
    public var cols: Int
    public var rows: Int

    public init(cols: Int, rows: Int) {
        self.cols = cols
        self.rows = rows
    }

    /// What a new terminal starts with before a view measured itself.
    public static let standard = TerminalSize(cols: 80, rows: 24)

    /// Within what ompd accepts (1...1000 columns, 1...500 rows).
    public var clamped: TerminalSize {
        TerminalSize(cols: min(max(cols, 1), 1000), rows: min(max(rows, 1), 500))
    }
}

extension PTYInfo {
    public var size: TerminalSize { TerminalSize(cols: cols, rows: rows) }

    /// What runs in the terminal, after the folder it is in unless that is `workspace`, the project's own, which the
    /// window's tab names already: "zsh", "docs — zsh".
    public func displayTitle(in workspace: String?) -> String {
        let folder = cwd == workspace ? "" : URL(filePath: cwd, directoryHint: .isDirectory).lastPathComponent
        let program = command.first.map { URL(filePath: $0).lastPathComponent } ?? ""
        switch (folder.isEmpty, program.isEmpty) {
        case (false, false): return "\(folder) — \(program)"
        case (false, true): return folder
        case (true, false): return program
        case (true, true): return "Terminal"
        }
    }

    /// omp's arguments when the terminal runs omp: itself, or through the login shell the way Lantern starts it when it
    /// knows no omp (`shell -l -c "'omp' 'render' …"`, each word in single quotes).
    public var ompArguments: [String]? {
        guard let first = command.first else { return nil }
        if URL(filePath: first).lastPathComponent == "omp" { return Array(command.dropFirst()) }
        guard command.count == 4, command[1] == "-l", command[2] == "-c", let words = Self.quotedWords(command[3]),
              words.first == "omp"
        else { return nil }
        return Array(words.dropFirst())
    }

    /// The words of `script` when it is nothing but single-quoted words (an embedded quote written `'\''`), else nil.
    static func quotedWords(_ script: String) -> [String]? {
        var words: [String] = []
        var word: String?
        var quoted = false
        var escaped = false
        for character in script {
            if quoted {
                if character == "'" { quoted = false } else { word?.append(character) }
            } else if escaped {
                word = (word ?? "") + String(character)
                escaped = false
            } else if character == "'" {
                quoted = true
                word = word ?? ""
            } else if character == "\\" {
                escaped = true
            } else if character == " " {
                if let finished = word { words.append(finished) }
                word = nil
            } else {
                return nil
            }
        }
        guard !quoted, !escaped else { return nil }
        if let word { words.append(word) }
        return words
    }
}
