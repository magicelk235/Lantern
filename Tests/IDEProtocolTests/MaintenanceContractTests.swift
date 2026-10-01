import Foundation
@testable import IDEProtocol
import Testing

/// When a session's omp is older than the one installed at its pinned path: what the session tab offers to
/// restart onto.
@Suite struct OmpVersionDriftTests {
    @Test func olderFollowsSemanticVersionPrecedence() {
        let older: [(String, String)] = [
            ("18.4.4", "18.4.8"), ("18.4.9", "18.10.0"), ("17.9.9", "18.0.0"), ("18.5.0-beta.1", "18.5.0"),
            ("18.5.0-beta.2", "18.5.0-beta.10"), ("18.5.0-beta", "18.5.0-beta.1"), ("18.5.0-1", "18.5.0-alpha"),
        ]
        for (version, other) in older {
            #expect(OmpVersion.isOlder(version, than: other), "\(version) < \(other)")
            #expect(!OmpVersion.isOlder(other, than: version), "\(other) > \(version)")
        }
        let notOlder: [(String, String)] = [
            ("18.4.4", "18.4.4"), ("18.4.4+build.2", "18.4.4+build.9"), ("unknown", "18.4.8"), ("18.4", "18.4.8"),
            ("18.4.4", ""), ("v18.4.4", "18.4.8"), ("18.4.4-", "18.4.8"),
        ]
        for (version, other) in notOlder {
            #expect(!OmpVersion.isOlder(version, than: other), "\(version) vs \(other)")
        }
    }

    @Test func onlyARunningSessionOfOmpIDEOnAnOlderOmpIsOfferedTheInstalledOne() {
        var entry = SessionManifestEntry(
            sessionKey: "s1", workspace: "/w", launch: LaunchSpec(ompPath: "/opt/homebrew/bin/omp", ompVersion: "18.4.4"),
            status: .idle, createdAt: Date(timeIntervalSince1970: 1_790_000_000), installedOmpVersion: "18.4.8")
        for status in [SessionStatus.idle, .busy, .paused] {
            entry.status = status
            #expect(entry.ompUpgrade == "18.4.8", "\(status)")
        }
        for status in [SessionStatus.starting, .resuming, .interrupted, .closed, .needsAttention] {
            entry.status = status
            #expect(entry.ompUpgrade == nil, "\(status): omp is not running, its next start runs the installed one")
        }
        entry.status = .idle
        entry.adopted = true
        #expect(entry.ompUpgrade == nil, "an omp started in a terminal runs what that terminal ran")
        entry.adopted = false
        for installed in ["18.4.4", "18.4.2", nil] {
            entry.installedOmpVersion = installed
            #expect(entry.ompUpgrade == nil, "installed \(installed ?? "unknown")")
        }
    }

    @Test func entriesNoticesAndRequestsFromBeforeTheFieldsStillDecode() throws {
        let entry = try IDECoding.decoder().decode(SessionManifestEntry.self, from: Data("""
            {"sessionKey":"s1","workspace":"/w","launch":{"ompPath":"/opt/homebrew/bin/omp","ompVersion":"18.4.4","extraArgs":[],"env":{}},
             "status":"idle","createdAt":"2026-10-01T10:00:00.000Z","services":[],"closedByUser":false}
            """.utf8))
        #expect(entry.installedOmpVersion == nil && entry.ompUpgrade == nil)
        let notice = try IDECoding.decoder().decode(
            DaemonNotice.self, from: Data(#"{"level":"warning","message":"m","at":"2026-10-01T10:00:00.000Z"}"#.utf8))
        #expect(notice.topic == nil)
        let restart = try IDECoding.decoder().decode(SessionRestart.Params.self, from: Data(#"{"sessionKey":"s1"}"#.utf8))
        #expect(restart == SessionRestart.Params(sessionKey: "s1", force: false))
    }
}
