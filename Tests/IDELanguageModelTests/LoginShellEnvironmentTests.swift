import Foundation
import IDELanguageModel
import Testing

@Suite struct LoginShellEnvironmentTests {
    private func output(_ entries: [String], before: String = "", after: String = "") -> Data {
        var data = Data(before.utf8)
        data.append(Data(LoginShellEnvironment.beginMarker.utf8))
        for entry in entries {
            data.append(Data(entry.utf8))
            data.append(0)
        }
        data.append(Data(LoginShellEnvironment.endMarker.utf8))
        data.append(Data(after.utf8))
        return data
    }

    @Test func theEnvironmentIsReadBetweenTheMarkersWhateverTheRcFilesPrint() throws {
        let data = output(
            ["PATH=/opt/homebrew/bin:/usr/bin", "GREETING=a=b", "MULTI=line one\nline two", "EMPTY=", "PWD=/somewhere", "SHLVL=2", "_=/usr/bin/env"],
            before: "Welcome!\n\u{1B}[1m", after: "logout\n")
        let environment = try #require(LoginShellEnvironment.parse(data))
        #expect(environment == ["PATH": "/opt/homebrew/bin:/usr/bin", "GREETING": "a=b", "MULTI": "line one\nline two", "EMPTY": ""])
    }

    @Test func outputWithoutBothMarkersIsNoEnvironment() {
        #expect(LoginShellEnvironment.parse(Data("PATH=/usr/bin\0".utf8)) == nil)
        var cut = output(["PATH=/usr/bin"])
        cut.removeLast(LoginShellEnvironment.endMarker.utf8.count)
        #expect(LoginShellEnvironment.parse(cut) == nil)
        #expect(LoginShellEnvironment.parse(output([])) == nil)
    }

    @Test func theFallbackAddsTheUsualToolFoldersToThePath() {
        let environment = LoginShellEnvironment.fallback(["PATH": "/usr/bin:/bin:/opt/homebrew/bin", "HOME": "/Users/me"], home: "/Users/me")
        let path = environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        #expect(Array(path.prefix(3)) == ["/usr/bin", "/bin", "/opt/homebrew/bin"])
        #expect(path.contains("/usr/local/bin") && path.contains("/Users/me/.cargo/bin") && path.contains("/Users/me/go/bin"))
        #expect(path.count == Set(path).count)
        #expect(environment["HOME"] == "/Users/me")
    }
}
