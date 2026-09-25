import Darwin
import Foundation
import IDEProtocol
import Testing
@testable import OmpdCore

@Suite struct BridgeInstallerTests {
    private func identity(_ url: URL) -> (ino_t, Int) {
        var info = stat()
        guard lstat(url.path(percentEncoded: false), &info) == 0 else { return (0, -1) }
        return (info.st_ino, info.st_mtimespec.tv_nsec + info.st_mtimespec.tv_sec * 1_000_000_000)
    }

    @Test func stagedAndGlobalCopiesMatchTheShippedBridgeAndAreRewrittenOnlyWhenStale() throws {
        let dir = try StorageTempDir()
        let shipped = try Data(contentsOf: BridgeInstaller.locateSource())
        #expect(String(decoding: shipped, as: UTF8.self).contains("OMP_IDE_BRIDGE_SOCK"))

        let paths = AppSupportPaths(root: dir.url.appending(path: "home", directoryHint: .isDirectory))
        let staged = try BridgeInstaller.stage(into: paths)
        #expect(staged == paths.root.appending(path: "bridge/ide-bridge.ts", directoryHint: .notDirectory))
        #expect(try Data(contentsOf: staged) == shipped)
        let first = identity(staged)
        #expect(try BridgeInstaller.stage(into: paths) == staged)
        #expect(identity(staged) == first)

        try Data("// stale bridge\n".utf8).write(to: staged)
        _ = try BridgeInstaller.stage(into: paths)
        #expect(try Data(contentsOf: staged) == shipped)

        let agentDir = dir.url.appending(path: "agent", directoryHint: .isDirectory)
        let global = try BridgeInstaller.installGlobal(agentDir: agentDir)
        #expect(global == agentDir.appending(path: "extensions/omp-ide-bridge.ts", directoryHint: .notDirectory))
        #expect(try Data(contentsOf: global) == shipped)
        let installed = identity(global)
        _ = try BridgeInstaller.installGlobal(agentDir: agentDir)
        #expect(identity(global) == installed)
    }
}
