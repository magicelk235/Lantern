import Foundation
import IDEShellEnvironment

/// The language servers built into the editor, one per program: Swift, TypeScript/JavaScript, Python,
/// Rust, Go and the C family. Each project gets its own process of each, started for the first editor of a file it
/// takes and stopped with the last. A server the user added for an extension (`CustomLanguageServer`) takes the
/// extension's files instead.
public enum LanguageServerKind: String, Sendable, Hashable, CaseIterable {
    case swift
    case typescript
    case python
    case rust
    case go
    case clang

    /// The languages it serves, for Settings.
    public var name: String {
        switch self {
        case .swift: "Swift"
        case .typescript: "TypeScript and JavaScript"
        case .python: "Python"
        case .rust: "Rust"
        case .go: "Go"
        case .clang: "C, C++ and Objective-C"
        }
    }

    /// The extensions of the files it takes, lowercase and without the dot, in alphabetical order (for Settings).
    public var fileExtensions: [String] {
        DocumentLanguage.byExtension.filter { $0.value.kind == self }.keys.sorted()
    }

    /// The programs looked for, in order of preference: one found on the login shell's `PATH` (or through `xcrun`)
    /// is the server.
    fileprivate var candidates: [Candidate] {
        switch self {
        case .swift: [.xcrun("sourcekit-lsp"), .path("sourcekit-lsp")]
        case .typescript: [.path("typescript-language-server", ["--stdio"])]
        case .python: [.path("pyright-langserver", ["--stdio"]), .path("pylsp")]
        case .rust: [.path("rust-analyzer")]
        case .go: [.path("gopls")]
        case .clang: [.path("clangd"), .xcrun("clangd")]
        }
    }

    /// The names of the programs looked for, for the status bar's note when there is none.
    public var programNames: [String] {
        var names: [String] = []
        for candidate in candidates where !names.contains(candidate.name) { names.append(candidate.name) }
        return names
    }

    /// The server command: the first candidate that resolves, either an executable `isExecutable` accepts in an
    /// absolute folder of `searchPath` (a `PATH` value), or what `xcrunFind` reports for a tool of Xcode's toolchain.
    /// `/usr/bin/sourcekit-lsp` and `/usr/bin/clangd` are passed over: they are `xcrun` trampolines, which open the
    /// "install the command line developer tools" dialog where there are none (`xcrunFind` answers for those tools).
    public func resolve(
        searchPath: String, isExecutable: (String) -> Bool, xcrunFind: (String) -> String?
    ) -> LanguageServerCommand? {
        for candidate in candidates {
            switch candidate {
            case .path(let name, let arguments):
                let executable = LanguageServerLocator.find(name, in: searchPath) {
                    !Self.trampolines.contains($0) && isExecutable($0)
                }
                if let executable { return LanguageServerCommand(executable: executable, arguments: arguments) }
            case .xcrun(let name, let arguments):
                if let executable = xcrunFind(name) {
                    return LanguageServerCommand(executable: executable, arguments: arguments)
                }
            }
        }
        return nil
    }

    /// Whether the server must not be asked for completions at `offset` of `text` (UTF-16). sourcekit-lsp (Xcode 27's)
    /// traps with "String index is out of bounds" on a completion at the very end of the text in a call's argument list
    /// that has nothing in it yet (`print(`, `print( `), whether a trigger character or the user asked. The editor closes
    /// a parenthesis only once the next character is typed, so typing a call on the last line of a file gets there.
    public func skipsCompletion(at offset: Int, in text: NSString) -> Bool {
        guard self == .swift, offset == text.length else { return false }
        var before = offset
        while before > 0, [0x20, 0x09].contains(text.character(at: before - 1)) { before -= 1 }
        return before > 0 && text.character(at: before - 1) == 0x28
    }

    private static let trampolines: Set<String> = ["/usr/bin/sourcekit-lsp", "/usr/bin/clangd"]
}

private enum Candidate {
    /// A program on the search path, with its arguments.
    case path(String, [String] = [])
    /// A tool of the active developer directory (`xcrun --find`).
    case xcrun(String, [String] = [])

    var name: String {
        switch self {
        case .path(let name, _), .xcrun(let name, _): name
        }
    }
}

/// A language server program and the arguments that make it speak LSP over stdin/stdout.
public struct LanguageServerCommand: Sendable, Hashable {
    public let executable: String
    public let arguments: [String]

    public init(executable: String, arguments: [String]) {
        self.executable = executable
        self.arguments = arguments
    }

    /// The program's name, for the status bar.
    public var name: String { (executable as NSString).lastPathComponent }
}

/// The server that takes a file: one built into the editor, or one the user added.
public enum LanguageServerChoice: Sendable, Hashable {
    case builtIn(LanguageServerKind)
    case custom(CustomLanguageServer)

    /// What it is called, for display: the languages a built-in server serves, the name the user gave theirs (or its
    /// program's, when they gave none).
    public var name: String {
        switch self {
        case .builtIn(let kind):
            return kind.name
        case .custom(let server):
            let name = server.name.trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { return name }
            let program = server.arguments?.first.map { ($0 as NSString).lastPathComponent } ?? ""
            return program.isEmpty ? "Untitled" : program
        }
    }

    /// The names of the programs looked for, for the status bar's note when there is none: for a user's server, its
    /// program as the command has it, and none when the command has no program (or a quote is left open).
    public var programNames: [String] {
        switch self {
        case .builtIn(let kind): kind.programNames
        case .custom(let server): server.arguments?.first.map { [$0] } ?? []
        }
    }

    /// Whether the server must not be asked for completions at `offset` of `text` (UTF-16): the case of the built-in
    /// sourcekit-lsp (`LanguageServerKind.skipsCompletion`); a user's server is always asked.
    public func skipsCompletion(at offset: Int, in text: NSString) -> Bool {
        guard case .builtIn(let kind) = self else { return false }
        return kind.skipsCompletion(at: offset, in: text)
    }
}

/// A file's language as its server knows it: the server and the `languageId` of `textDocument/didOpen`.
public struct DocumentLanguage: Sendable, Hashable {
    public let server: LanguageServerChoice
    public let languageId: String

    /// The language of the file at `path`, by its extension (any case): the first of the user's servers (`custom`, in
    /// their order) that takes the extension, otherwise the built-in one; nil for a file no server here takes.
    public init?(path: String, custom: [CustomLanguageServer]) {
        let pathExtension = (path as NSString).pathExtension.lowercased()
        if let server = custom.first(where: { $0.takes(pathExtension) }) {
            self.server = .custom(server)
            languageId = server.documentLanguageId
        } else if let language = Self.byExtension[pathExtension] {
            server = .builtIn(language.kind)
            languageId = language.languageId
        } else {
            return nil
        }
    }

    fileprivate static let byExtension: [String: (kind: LanguageServerKind, languageId: String)] = [
        "swift": (.swift, "swift"),
        "ts": (.typescript, "typescript"), "mts": (.typescript, "typescript"), "cts": (.typescript, "typescript"),
        "tsx": (.typescript, "typescriptreact"),
        "js": (.typescript, "javascript"), "mjs": (.typescript, "javascript"), "cjs": (.typescript, "javascript"),
        "jsx": (.typescript, "javascriptreact"),
        "py": (.python, "python"), "pyi": (.python, "python"),
        "rs": (.rust, "rust"),
        "go": (.go, "go"),
        "c": (.clang, "c"), "h": (.clang, "c"),
        "cc": (.clang, "cpp"), "cpp": (.clang, "cpp"), "cxx": (.clang, "cpp"), "c++": (.clang, "cpp"),
        "hh": (.clang, "cpp"), "hpp": (.clang, "cpp"), "hxx": (.clang, "cpp"), "h++": (.clang, "cpp"),
        "m": (.clang, "objective-c"), "mm": (.clang, "objective-cpp"),
    ]
}

/// Finds the program of a language server in an environment (the login shell's, `LoginShellEnvironment`).
public struct LanguageServerLocator: Sendable {
    public let environment: [String: String]

    public init(environment: [String: String]) {
        self.environment = environment
    }

    /// The command for `server`, or nil when its program is nowhere. Runs `xcrun` when a built-in server needs Xcode's
    /// toolchain: call it off the main thread.
    public func command(for server: LanguageServerChoice) -> LanguageServerCommand? {
        let searchPath = environment["PATH"] ?? ""
        switch server {
        case .builtIn(let kind):
            return kind.resolve(searchPath: searchPath, isExecutable: Self.isExecutableFile, xcrunFind: xcrunFind)
        case .custom(let custom):
            let home = environment["HOME"] ?? NSHomeDirectory()
            return custom.resolve(searchPath: searchPath, homeDirectory: home, isExecutable: Self.isExecutableFile)
        }
    }

    /// The path of `name` in the first absolute folder of `searchPath` (a `PATH` value) where `accepts` takes it.
    static func find(_ name: String, in searchPath: String, accepts: (String) -> Bool) -> String? {
        for folder in searchPath.split(separator: ":") where folder.hasPrefix("/") {
            let path = (folder.hasSuffix("/") ? String(folder) : String(folder) + "/") + name
            if accepts(path) { return path }
        }
        return nil
    }

    private static func isExecutableFile(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && !isDirectory.boolValue
            && FileManager.default.isExecutableFile(atPath: path)
    }

    /// `xcrun --find name`, only when a developer directory is set up (`xcode-select -p` succeeds and names a
    /// folder): xcrun without one asks the user to install the command line tools.
    private func xcrunFind(_ name: String) -> String? {
        guard let developer = CommandRunner.output("/usr/bin/xcode-select", ["-p"], environment: environment),
              FileManager.default.fileExists(atPath: developer),
              let path = CommandRunner.output("/usr/bin/xcrun", ["--find", name], environment: environment),
              Self.isExecutableFile(path) else { return nil }
        return path
    }
}
