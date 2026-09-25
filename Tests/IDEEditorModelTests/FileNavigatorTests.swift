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
        #expect(entries[0].path == folder.file("docs"))
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
