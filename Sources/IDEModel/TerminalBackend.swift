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

extension DaemonConnection: TerminalBackend {
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

    /// The folder the terminal is in and its program, e.g. `omp IDE — zsh`.
    public var displayTitle: String {
        let folder = URL(filePath: cwd, directoryHint: .isDirectory).lastPathComponent
        let program = command.first.map { URL(filePath: $0).lastPathComponent } ?? ""
        switch (folder.isEmpty, program.isEmpty) {
        case (false, false): return "\(folder) — \(program)"
        case (false, true): return folder
        case (true, false): return program
        case (true, true): return "Terminal"
        }
    }
}
