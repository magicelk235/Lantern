import Foundation
import IDEExtensions
import Testing

@Suite struct ExtensionStoreTests {
    /// A `.vsix` of `files` (paths in the package, as `extension/package.json`) zipped with `ditto`.
    private func package(_ folder: TempFolder, named name: String, _ files: [String: String]) throws -> URL {
        for (path, text) in files {
            try folder.write("\(name)/\(path)", text)
        }
        let source = folder.url.appending(path: name).path(percentEncoded: false)
        let archive = folder.url.appending(path: "\(name).vsix")
        let ditto = try Process.run(
            URL(filePath: "/usr/bin/ditto"), arguments: ["-c", "-k", source, archive.path(percentEncoded: false)])
        ditto.waitUntilExit()
        #expect(ditto.terminationStatus == 0)
        return archive
    }

    private func manifest(version: String, contributes: String) -> String {
        #"""
        { "name": "sample", "publisher": "Someone", "displayName": "Sample Theme", "version": "\#(version)",
          "contributes": \#(contributes) }
        """#
    }

    private func contents(of folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false)).sorted()
    }

    @Test func anInstallReplacesTheVersionThereAndAnUninstallRemovesIt() throws {
        let folder = try TempFolder()
        let store = ExtensionStore(folder: folder.url.appending(path: "extensions", directoryHint: .isDirectory))
        let theme = ##"{ "colors": { "editor.background": "#101010" }, "tokenColors": [] }"##
        let first = try package(folder, named: "v1", [
            "extension/package.json": manifest(version: "1.0.0", contributes: #"""
            { "themes": [{ "label": "Sample", "uiTheme": "vs-dark", "path": "./themes/sample.json" }],
              "snippets": [{ "language": "swift", "path": "./snippets/old.json" }] }
            """#),
            "extension/themes/sample.json": theme,
            "extension/snippets/old.json": #"{ "Old": { "prefix": "old", "body": "old()" } }"#,
            "extension.vsixmanifest": "<PackageManifest/>",
            "[Content_Types].xml": "<Types/>",
        ])
        let installed = try store.install(vsix: first)
        #expect(installed.id == "someone.sample")
        #expect(installed.version == "1.0.0")
        #expect(installed.folder.lastPathComponent == "someone.sample")
        #expect(try ColorTheme.load(#require(installed.themes.first)).background == RGBA(hex: "#101010"))
        #expect(try SnippetFile.load(#require(installed.snippets.first).path).map(\.name) == ["Old"])

        // The new version takes the old one's place, and the old one's files go with it.
        let second = try package(folder, named: "v2", [
            "extension/package.json": manifest(version: "2.0.0", contributes: #"""
            { "themes": [{ "label": "Sample", "uiTheme": "vs-dark", "path": "./themes/sample.json" }] }
            """#),
            "extension/themes/sample.json": theme,
        ])
        let updated = try store.install(vsix: second)
        #expect(updated.version == "2.0.0")
        #expect(try contents(of: updated.folder) == ["package.json", "themes"])

        // A folder without a manifest is not listed, and nothing of the installs is left behind.
        let broken = store.folder.appending(path: "broken", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: false)
        #expect(store.installed().map { "\($0.id) \($0.version)" } == ["someone.sample 2.0.0"])
        #expect(try contents(of: store.folder) == ["broken", "someone.sample"])

        try store.uninstall(id: "someone.sample")
        #expect(store.installed().isEmpty)
        #expect(try contents(of: store.folder) == ["broken"])
        try store.uninstall(id: "someone.sample")
        try store.uninstall(id: "../\(folder.url.lastPathComponent)")
        #expect(FileManager.default.fileExists(atPath: folder.url.path(percentEncoded: false)))
    }

    @Test func packagesWithNothingToUseOrNoManifestAreRefusedAndLeaveNothing() throws {
        let folder = try TempFolder()
        let store = ExtensionStore(folder: folder.url.appending(path: "extensions", directoryHint: .isDirectory))
        let commands = try package(folder, named: "commands", [
            "extension/package.json": manifest(version: "1.0.0", contributes: #"{ "commands": [] }"#),
        ])
        #expect(throws: ExtensionError.nothingUsable("Sample Theme")) { try store.install(vsix: commands) }
        let noManifest = try package(folder, named: "readme", ["readme.md": "hello"])
        #expect(throws: ExtensionError.notAnExtension) { try store.install(vsix: noManifest) }
        let notAZip = try folder.write("fake.vsix", "not a zip")
        #expect(throws: ExtensionError.unreadable("fake.vsix")) { try store.install(vsix: notAZip) }
        #expect(try contents(of: store.folder).isEmpty)
        #expect(store.installed().isEmpty)
    }
}
