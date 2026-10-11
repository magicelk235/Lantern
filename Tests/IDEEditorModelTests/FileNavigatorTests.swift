import Foundation
import IDEEditorModel
import os
import Testing

@Suite struct FileNavigatorTests {
    @Test func listingHidesDependencyAndBuildTreesAndPutsFoldersFirstInFinderOrder() throws {
        let folder = try TempFolder()
        for name in ["b.swift", "a10.txt", "a9.txt", ".gitignore", ".DS_Store"] { try folder.write(name, "") }
        for name in ["Sources", ".git", "node_modules", ".build", "docs"] {
            try FileManager.default.createDirectory(atPath: folder.file(name), withIntermediateDirectories: true)
        }
        try FileManager.default.createSymbolicLink(atPath: folder.file("linked"), withDestinationPath: "docs")

        let entries = try DirectoryListing.entries(of: folder.path)
        #expect(entries.map(\.name) == ["docs", "linked", "Sources", ".gitignore", "a9.txt", "a10.txt", "b.swift"])
        #expect(entries.map(\.isDirectory) == [true, true, true, false, false, false, false])
        #expect(entries.map(\.isSymlink) == [false, true, false, false, false, false, false])
        #expect(entries[0].path == folder.file("docs"))
    }

    @Test func linksToFilesAndDanglingLinksListAsFilesMarkedAsLinks() throws {
        let folder = try TempFolder()
        try folder.write("a.txt", "")
        try FileManager.default.createSymbolicLink(atPath: folder.file("toA"), withDestinationPath: "a.txt")
        try FileManager.default.createSymbolicLink(atPath: folder.file("gone"), withDestinationPath: "missing.txt")

        let entries = try DirectoryListing.entries(of: folder.path)
        #expect(entries.map(\.name) == ["a.txt", "gone", "toA"])
        #expect(entries.map(\.isDirectory) == [false, false, false])
        #expect(entries.map(\.isSymlink) == [false, true, true])
        #expect(entries.map(\.isLinkLoop) == [false, false, false])
    }

    @Test func linksBackToAFolderAboveAreLoopsAndOtherLinksAreNot() throws {
        let folder = try TempFolder()
        for name in ["a/inner", "b", "elsewhere"] {
            try FileManager.default.createDirectory(atPath: folder.file(name), withIntermediateDirectories: true)
        }
        try FileManager.default.createSymbolicLink(atPath: folder.file("a/up"), withDestinationPath: "..")
        try FileManager.default.createSymbolicLink(atPath: folder.file("a/self"), withDestinationPath: ".")
        try FileManager.default.createSymbolicLink(atPath: folder.file("a/inner/top"), withDestinationPath: "../..")
        try FileManager.default.createSymbolicLink(atPath: folder.file("a/side"), withDestinationPath: "../elsewhere")
        // a/toB and b/toA lead to each other: a/toB/toA is a again.
        try FileManager.default.createSymbolicLink(atPath: folder.file("a/toB"), withDestinationPath: "../b")
        try FileManager.default.createSymbolicLink(atPath: folder.file("b/toA"), withDestinationPath: "../a")

        let loops = { (directory: String) in
            Dictionary(uniqueKeysWithValues: try DirectoryListing.entries(of: directory).map { ($0.name, $0.isLinkLoop) })
        }
        #expect(try loops(folder.file("a")) == ["inner": false, "up": true, "self": true, "side": false, "toB": false])
        #expect(try loops(folder.file("a/inner")) == ["top": true])
        #expect(try loops(folder.file("a/toB")) == ["toA": true])
        #expect(try loops(folder.file("b")) == ["toA": false])
    }

    @Test func ignoredFolderCoversEverythingInIt() {
        let ignored = GitIgnoredPaths(paths: ["/w/dist", "/w/a.log"])
        #expect(ignored.contains("/w/dist/js/app.js", under: "/w"))
        #expect(ignored.contains("/w/a.log", under: "/w"))
        #expect(!ignored.contains("/w/src/a.log", under: "/w"))
        #expect(!ignored.contains("/w", under: "/w"))
    }

    @Test func watcherReportsChangesSpelledUnderTheFolderAsGiven() async throws {
        // `/var/folders/…` is `/private/var/folders/…` underneath, which is what FSEvents reports.
        let spelled = FileManager.default.temporaryDirectory
            .appending(path: "watch-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
            .path(percentEncoded: false)
        let root = String(spelled.dropLast())
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let resolved = try #require(realpath(root, nil))
        #expect(String(cString: resolved) != root)
        free(resolved)

        let seen = OSAllocatedUnfairLock(initialState: [FileSystemWatcher.Change]())
        let watcher = try #require(FileSystemWatcher(root: root, latency: 0.05) { changes in
            seen.withLock { $0 += changes }
        })
        defer { watcher.stop() }
        let file = (root as NSString).appendingPathComponent("new.swift")
        try Data("x".utf8).write(to: URL(filePath: file))

        let deadline = ContinuousClock.now + .seconds(10)
        // A new file changes its folder's listing.
        while !seen.withLock({ $0.contains { $0.path == file && $0.structural } }) {
            guard ContinuousClock.now < deadline else {
                Issue.record("no change for \(file); saw \(seen.withLock { $0 })")
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
