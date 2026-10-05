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
            let language = DocumentLanguage(path: path)
            #expect(language?.kind == kind, "\(path)")
            #expect(language?.languageId == languageId, "\(path)")
        }
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
}
