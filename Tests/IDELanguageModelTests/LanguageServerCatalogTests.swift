import Foundation
import IDELanguageModel
import Testing

@Suite struct LanguageServerCatalogTests {
    @Test func filesGoToTheirServerByExtension() {
        let cases: [(String, LanguageServerKind?, String?)] = [
            ("/p/Sources/App/main.swift", .swift, "swift"),
            ("/p/src/index.ts", .typescript, "typescript"),
            ("/p/src/View.TSX", .typescript, "typescriptreact"),
            ("/p/src/a.mjs", .typescript, "javascript"),
            ("/p/src/a.jsx", .typescript, "javascriptreact"),
            ("/p/tool.py", .python, "python"),
            ("/p/stubs.pyi", .python, "python"),
            ("/p/src/lib.rs", .rust, "rust"),
            ("/p/main.go", .go, "go"),
            ("/p/a.c", .clang, "c"),
            ("/p/a.h", .clang, "c"),
            ("/p/a.cpp", .clang, "cpp"),
            ("/p/a.hpp", .clang, "cpp"),
            ("/p/a.m", .clang, "objective-c"),
            ("/p/a.mm", .clang, "objective-cpp"),
            ("/p/README.md", nil, nil),
            ("/p/Makefile", nil, nil),
            ("/p/.swift", nil, nil),
        ]
        for (path, kind, languageId) in cases {
            let language = DocumentLanguage(path: path, custom: [])
            #expect(language?.server == kind.map(LanguageServerChoice.builtIn), "\(path)")
            #expect(language?.languageId == languageId, "\(path)")
        }
    }

    @Test func aServerOfTheUsersReplacesTheBuiltInOneForItsExtensionsInAnyCase() {
        let deno = CustomLanguageServer(name: "Deno", command: "deno lsp", fileExtensions: ["TS", "tsx"], languageId: "typescript")
        let markdown = CustomLanguageServer(name: "Markdown", command: "marksman server", fileExtensions: ["MD", "markdown"])
        let custom = [deno, markdown]
        let index = DocumentLanguage(path: "/p/src/index.ts", custom: custom)
        #expect(index?.server == .custom(deno))
        #expect(index?.languageId == "typescript")
        #expect(DocumentLanguage(path: "/p/src/View.TSX", custom: custom)?.server == .custom(deno))
        // Without a languageId, the files open with the first extension's, whichever extension they have.
        let readme = DocumentLanguage(path: "/p/README.markdown", custom: custom)
        #expect(readme?.server == .custom(markdown))
        #expect(readme?.languageId == "md")
        // The extensions it does not list stay with the built-in server, and a hidden file has no extension.
        let script = DocumentLanguage(path: "/p/src/a.js", custom: custom)
        #expect(script?.server == .builtIn(.typescript))
        #expect(script?.languageId == "javascript")
        #expect(DocumentLanguage(path: "/p/.md", custom: custom) == nil)
        #expect(DocumentLanguage(path: "/p/Makefile", custom: [CustomLanguageServer(command: "make-lsp", fileExtensions: [""])]) == nil)
    }

    @Test func theFirstOfTheUsersServersForAnExtensionWins() {
        let first = CustomLanguageServer(name: "A", command: "a", fileExtensions: ["py"])
        let second = CustomLanguageServer(name: "B", command: "b", fileExtensions: ["PY", "pyi"])
        #expect(DocumentLanguage(path: "/p/a.py", custom: [first, second])?.server == .custom(first))
        #expect(DocumentLanguage(path: "/p/a.py", custom: [second, first])?.server == .custom(second))
        #expect(DocumentLanguage(path: "/p/a.pyi", custom: [first, second])?.server == .custom(second))
    }

    @Test func aCommandSplitsIntoWordsAsInAShell() {
        let words = { (command: String) in CustomLanguageServer(command: command).arguments }
        #expect(words("typescript-language-server --stdio") == ["typescript-language-server", "--stdio"])
        #expect(words("  gopls \t serve  ") == ["gopls", "serve"])
        #expect(words("'/Applications/My Server.app/bin/ls' --stdio") == ["/Applications/My Server.app/bin/ls", "--stdio"])
        #expect(words(#"--log="a b"c --x"#) == ["--log=a bc", "--x"])
        #expect(words(#"my\ server \"quoted\" back\\slash"#) == ["my server", "\"quoted\"", #"back\slash"#])
        // In double quotes a backslash only takes away the meaning of ", \, $ and `.
        #expect(words(#""say \"hi\" \\ \$HOME \` \n""#) == [#"say "hi" \ $HOME ` \n"#])
        #expect(words(#"'a\b "c"' 'it'\''s'"#) == [#"a\b "c""#, "it's"])
        #expect(words(#"server '' """#) == ["server", "", ""])
        #expect(words(#"trailing\"#) == [#"trailing\"#])
        #expect(words("") == [])
        #expect(words(" \t ") == [])
        // A quote left open: no command at all.
        #expect(words("'unclosed") == nil)
        #expect(words(#""unclosed"#) == nil)
        #expect(words(#""escaped close\""#) == nil)
        #expect(words("server it's") == nil)
    }

    /// Resolves the user's server with `command` against a fake file system, `/Users/me` being home: `executables` are
    /// the files that exist and may run.
    private func resolve(_ command: String, path: String, executables: Set<String>) -> LanguageServerCommand? {
        CustomLanguageServer(command: command, fileExtensions: ["vue"])
            .resolve(searchPath: path, homeDirectory: "/Users/me", isExecutable: { executables.contains($0) })
    }

    @Test func theProgramOfAUsersServerIsItsPathOrTheFirstOnThePath() {
        #expect(
            resolve("/opt/vls/bin/vls --stdio", path: "/usr/bin", executables: ["/opt/vls/bin/vls"])
                == LanguageServerCommand(executable: "/opt/vls/bin/vls", arguments: ["--stdio"]))
        #expect(resolve("/opt/vls/bin/vls", path: "/usr/bin", executables: ["/usr/bin/vls"]) == nil)
        #expect(
            resolve(#"~/My\ Tools/vls --stdio"#, path: "/usr/bin", executables: ["/Users/me/My Tools/vls", "/usr/bin/vls"])
                == LanguageServerCommand(executable: "/Users/me/My Tools/vls", arguments: ["--stdio"]))
        // The home folder's, neither a `~` folder nor the name on the PATH.
        #expect(resolve("~/bin/vls", path: "/usr/bin", executables: ["~/bin/vls", "/usr/bin/vls"]) == nil)
        #expect(
            resolve("vls 'a b'", path: "/a/bin::relative/bin:/b/bin:/c/bin", executables: ["/b/bin/vls", "/c/bin/vls", "relative/bin/vls"])
                == LanguageServerCommand(executable: "/b/bin/vls", arguments: ["a b"]))
        // A name not on the PATH, a path relative to wherever, no program, an open quote.
        #expect(resolve("vls", path: "/a/bin", executables: ["/b/bin/vls"]) == nil)
        #expect(resolve("bin/vls", path: "/p", executables: ["/p/bin/vls", "bin/vls"]) == nil)
        #expect(resolve("", path: "/a/bin", executables: ["/a/bin/"]) == nil)
        #expect(resolve("'' --stdio", path: "/a/bin", executables: ["/a/bin/"]) == nil)
        #expect(resolve("'/a/bin/vls", path: "/a/bin", executables: ["/a/bin/vls"]) == nil)
    }

    @Test func theUsersServersKeepTheirOrderInTheDefaultsAndGarbageReadsAsNone() {
        let servers = [
            CustomLanguageServer(name: "Vue", command: "vue-language-server --stdio", fileExtensions: ["vue"]),
            CustomLanguageServer(name: "Deno", command: #"deno lsp --config "a b.json""#, fileExtensions: ["ts", "tsx"], languageId: "typescript"),
        ]
        #expect(CustomLanguageServer.load(from: CustomLanguageServer.encode(servers)) == servers)
        #expect(CustomLanguageServer.load(from: nil) == [])
        #expect(CustomLanguageServer.load(from: Data()) == [])
        #expect(CustomLanguageServer.load(from: Data("not json".utf8)) == [])
        #expect(CustomLanguageServer.load(from: Data(#"{"name": "Vue"}"#.utf8)) == [])
    }

    /// Resolves `kind` against a fake file system: `executables` are the files that exist and may run.
    private func resolve(
        _ kind: LanguageServerKind, path: String, executables: Set<String>, xcrun: [String: String] = [:]
    ) -> LanguageServerCommand? {
        kind.resolve(searchPath: path, isExecutable: { executables.contains($0) }, xcrunFind: { xcrun[$0] })
    }

    @Test func thePathIsSearchedInOrderForAnExecutable() {
        let command = resolve(
            .typescript, path: "/a/bin::relative/bin:/b/bin:/c/bin",
            executables: ["/b/bin/typescript-language-server", "/c/bin/typescript-language-server", "relative/bin/typescript-language-server"])
        #expect(command == LanguageServerCommand(executable: "/b/bin/typescript-language-server", arguments: ["--stdio"]))
        #expect(resolve(.go, path: "/a/bin", executables: []) == nil)
    }

    @Test func pythonFallsBackFromPyrightToPylsp() {
        #expect(resolve(.python, path: "/x", executables: ["/x/pylsp"]) == LanguageServerCommand(executable: "/x/pylsp", arguments: []))
        #expect(
            resolve(.python, path: "/x", executables: ["/x/pylsp", "/x/pyright-langserver"])
                == LanguageServerCommand(executable: "/x/pyright-langserver", arguments: ["--stdio"]))
    }

    @Test func sourceKitLSPComesFromXcrunBeforeThePathAndNeverFromTheUsrBinTrampoline() {
        let toolchain = "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/sourcekit-lsp"
        #expect(
            resolve(.swift, path: "/opt/swift/bin", executables: ["/opt/swift/bin/sourcekit-lsp"], xcrun: ["sourcekit-lsp": toolchain])
                == LanguageServerCommand(executable: toolchain, arguments: []))
        #expect(
            resolve(.swift, path: "/usr/bin:/opt/swift/bin", executables: ["/usr/bin/sourcekit-lsp", "/opt/swift/bin/sourcekit-lsp"])
                == LanguageServerCommand(executable: "/opt/swift/bin/sourcekit-lsp", arguments: []))
        #expect(resolve(.swift, path: "/usr/bin", executables: ["/usr/bin/sourcekit-lsp"]) == nil)
    }

    @Test func clangdOnThePathWinsOverXcodesAndTheTrampolineIsSkipped() {
        let xcode = ["clangd": "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/clangd"]
        #expect(
            resolve(.clang, path: "/usr/bin:/opt/homebrew/opt/llvm/bin", executables: ["/usr/bin/clangd", "/opt/homebrew/opt/llvm/bin/clangd"], xcrun: xcode)
                == LanguageServerCommand(executable: "/opt/homebrew/opt/llvm/bin/clangd", arguments: []))
        #expect(
            resolve(.clang, path: "/usr/bin", executables: ["/usr/bin/clangd"], xcrun: xcode)
                == LanguageServerCommand(executable: xcode["clangd"]!, arguments: []))
    }

    @Test func sourceKitLSPIsNotAskedForCompletionsInAnEmptyArgumentListAtTheEndOfTheText() {
        let skips = { (server: LanguageServerChoice, text: String, offset: Int?) in
            server.skipsCompletion(at: offset ?? (text as NSString).length, in: text as NSString)
        }
        #expect(skips(.builtIn(.swift), "let a = 1\nprint(", nil))
        #expect(skips(.builtIn(.swift), "print( ", nil))
        #expect(skips(.builtIn(.swift), "add(\t ", nil))
        // Not at the end, an argument typed, or another server (a user's sourcekit-lsp too): asked as usual.
        #expect(!skips(.builtIn(.swift), "print(\n", 6))
        #expect(!skips(.builtIn(.swift), "print()", 6))
        #expect(!skips(.builtIn(.swift), "print(w", nil))
        #expect(!skips(.builtIn(.swift), "print(1, ", nil))
        #expect(!skips(.builtIn(.swift), "(", 0))
        #expect(!skips(.builtIn(.swift), "", nil))
        #expect(!skips(.builtIn(.typescript), "console.log(", nil))
        #expect(!skips(.custom(CustomLanguageServer(command: "sourcekit-lsp", fileExtensions: ["swift"])), "print(", nil))
    }
}
