import Foundation
import IDEProtocol
import Testing
@testable import OmpdCore

private func manifestEntry(_ key: SessionKey) -> SessionManifestEntry {
    SessionManifestEntry(
        sessionKey: key,
        workspace: "/Users/me/src/\(key)",
        sessionFile: "/Users/me/.omp/agent/sessions/-src-\(key)/2026-09-25_\(key).jsonl",
        launch: LaunchSpec(ompPath: "/opt/homebrew/bin/omp", ompVersion: "18.3.1", approvalMode: "always-ask"),
        status: .busy,
        ptyId: "pty-\(key)",
        createdAt: Date(timeIntervalSince1970: 1_790_000_000),
        lastActiveAt: Date(timeIntervalSince1970: 1_790_000_100.25),
        services: [NamedService(id: "web", mode: "session", command: "bun dev")]
    )
}

@Suite struct StorageManifestTests {
    @Test func missingManifestLoadsEmpty() async throws {
        let dir = try StorageTempDir()
        let store = ManifestStore(url: dir.url.appending(path: "sessions.json"))
        #expect(try await store.load() == SessionManifest())
    }

    @Test func updateIsPersistedPrivatelyAndReloads() async throws {
        let dir = try StorageTempDir()
        let url = dir.url.appending(path: "sessions.json")
        let store = ManifestStore(url: url)
        try await store.load()
        let written = try await store.update { $0.sessions.append(manifestEntry("a")) }
        #expect(written.sessions.map(\.sessionKey) == ["a"])
        #expect(await store.current == written)
        #expect(try dir.posixPermissions(of: url) == 0o600)
        #expect(try await ManifestStore(url: url).load() == written)
    }

    @Test func interruptedWriteKeepsThePreviousManifestAndItsTempFileIsIgnored() async throws {
        let dir = try StorageTempDir()
        let url = dir.url.appending(path: "sessions.json")
        try await ManifestStore(url: url).update { $0.sessions.append(manifestEntry("a")) }
        // Crash after the temp file was half written, before the rename.
        let temporary = dir.url.appending(path: "sessions.json.tmp")
        try Data(#"{"sessions":[{"sessionKey":"b","#.utf8).write(to: temporary)

        let restarted = ManifestStore(url: url)
        #expect(try await restarted.load().sessions.map(\.sessionKey) == ["a"])
        try await restarted.update { $0.sessions.append(manifestEntry("b")) }
        #expect(try await ManifestStore(url: url).load().sessions.map(\.sessionKey) == ["a", "b"])
        #expect(!FileManager.default.fileExists(atPath: temporary.path(percentEncoded: false)))
    }

    @Test func corruptManifestIsMovedAsideAndLoadsEmpty() async throws {
        let dir = try StorageTempDir()
        let url = dir.url.appending(path: "sessions.json")
        let garbage = Data(#"{"version":1,"sessions":[{"sessionKey":"#.utf8)
        try garbage.write(to: url)

        let store = ManifestStore(url: url)
        #expect(try await store.load() == SessionManifest())
        #expect(!FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))
        let asides = try FileManager.default.contentsOfDirectory(atPath: dir.url.path(percentEncoded: false))
            .filter { $0.hasPrefix("sessions.json.corrupt-") }
        #expect(asides.count == 1)
        #expect(try Data(contentsOf: dir.url.appending(path: try #require(asides.first))) == garbage)

        try await store.update { $0.sessions.append(manifestEntry("a")) }
        #expect(try await ManifestStore(url: url).load().sessions.map(\.sessionKey) == ["a"])
    }

    @Test func updateBeforeLoadBuildsOnWhatIsOnDisk() async throws {
        let dir = try StorageTempDir()
        let url = dir.url.appending(path: "sessions.json")
        try await ManifestStore(url: url).update { $0.sessions.append(manifestEntry("a")) }
        let updated = try await ManifestStore(url: url).update { $0.sessions.append(manifestEntry("b")) }
        #expect(updated.sessions.map(\.sessionKey) == ["a", "b"])
    }

    /// A manifest written before sessions could be adopted (no `adopted` key) loads with the field false.
    @Test func manifestWithoutAdoptedLoadsAsNotAdopted() async throws {
        let dir = try StorageTempDir()
        let url = dir.url.appending(path: "sessions.json")
        var expected = manifestEntry("a")
        expected.adopted = true
        let written = expected
        try await ManifestStore(url: url).update { $0.sessions.append(written) }
        var json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var sessions = try #require(json["sessions"] as? [[String: Any]])
        #expect(sessions[0]["adopted"] as? Bool == true)
        sessions[0]["adopted"] = nil
        json["sessions"] = sessions
        try JSONSerialization.data(withJSONObject: json).write(to: url)

        let loaded = try await ManifestStore(url: url).load()
        expected.adopted = false
        #expect(loaded.sessions == [expected])
    }

    @Test func failedUpdateChangesNeitherMemoryNorDisk() async throws {
        struct Refused: Error {}
        let dir = try StorageTempDir()
        let url = dir.url.appending(path: "sessions.json")
        let store = ManifestStore(url: url)
        try await store.update { $0.sessions.append(manifestEntry("a")) }
        let before = try Data(contentsOf: url)
        await #expect(throws: Refused.self) {
            try await store.update {
                $0.sessions.removeAll()
                throw Refused()
            }
        }
        #expect(await store.current.sessions.map(\.sessionKey) == ["a"])
        #expect(try Data(contentsOf: url) == before)
    }
}
