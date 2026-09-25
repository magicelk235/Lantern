import Foundation
import IDEProtocol
import Testing
@testable import OmpdCore

@Suite struct StorageAppSupportPathsTests {
    @Test func prepareMakesAPrivateLayoutAndResetsOnlyRun() throws {
        let dir = try StorageTempDir()
        let paths = AppSupportPaths(root: dir.url.appending(path: "omp-ide", directoryHint: .isDirectory))
        try paths.prepare()
        for directory in [paths.root, paths.run, paths.ptySnapshots, paths.hotExit] {
            #expect(try dir.posixPermissions(of: directory) == 0o700, "\(directory.lastPathComponent)")
        }

        // Leftovers of the previous daemon run, plus user data that must survive it.
        try Data("stale".utf8).write(to: paths.socket)
        let snapshot = paths.ptySnapshots.appending(path: "p.json")
        try Data("{}\n".utf8).write(to: snapshot)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: paths.ptySnapshots.path(percentEncoded: false)
        )

        try paths.prepare()
        #expect(!FileManager.default.fileExists(atPath: paths.socket.path(percentEncoded: false)))
        #expect(try Data(contentsOf: snapshot) == Data("{}\n".utf8))
        #expect(try dir.posixPermissions(of: paths.ptySnapshots) == 0o700)
    }

    @Test func tokenIsPrivateAndStableUntilTheNextRun() throws {
        let dir = try StorageTempDir()
        let paths = AppSupportPaths(root: dir.url)
        try paths.prepare()
        let token = try paths.loadOrCreateToken()
        #expect(token.utf8.count == 64 && token.allSatisfy(\.isHexDigit))
        #expect(try dir.posixPermissions(of: paths.token) == 0o600)
        #expect(try paths.loadOrCreateToken() == token)

        try paths.prepare()
        #expect(try paths.loadOrCreateToken() != token)
    }
}
