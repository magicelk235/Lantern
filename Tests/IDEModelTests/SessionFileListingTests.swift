import Foundation
@testable import IDEModel
import Testing

@Suite struct SessionFileListingTests {
    // MARK: - Buckets

    @Test(arguments: [
        ("/Users/u/Desktop/Projects/omp IDE", "-Desktop-Projects-omp IDE"),
        ("/Users/u", "-"),
        ("/Users/u/.omp/agent", "-.omp-agent"),
        ("/private/var/folders/x/T/tmp.VTr3", "-tmp-tmp.VTr3"),
        ("/private/var/folders/x/T", "-tmp"),
        ("/private/tmp/oi-work", "--private-tmp-oi-work--"),
        ("/", "----"),
        ("/Users/username", "--Users-username--"),
        ("/Volumes/Disk/a:b", "--Volumes-Disk-a-b--"),
        // Node's path.relative starts with ".." here, so omp takes it for outside the home folder.
        ("/Users/u/..cache", "--Users-u-..cache--"),
    ])
    func bucketsFollowOmpsEncoding(cwd: String, bucket: String) {
        #expect(SessionFileListing.bucketName(canonicalCwd: cwd, home: "/Users/u", temporaryDirectory: "/private/var/folders/x/T") == bucket)
    }

    @Test func aWorkspaceReachedThroughASymlinkListsItsRealFoldersBucket() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let real = fixture.root.appending(path: "work/real", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let link = fixture.root.appending(path: "link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let environment = ProcessInfo.processInfo.environment
        let temp = environment["TMPDIR"].map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 } ?? "/tmp"
        let bucket = SessionFileListing.bucketName(
            canonicalCwd: SessionFileListing.canonicalPath(real.path(percentEncoded: false)),
            home: SessionFileListing.canonicalPath(environment["HOME"] ?? NSHomeDirectory()),
            temporaryDirectory: SessionFileListing.canonicalPath(temp))
        try fixture.write(bucket, "2026-09-01T10-00-00-000Z_a.jsonl", lines: [header(id: "a"), user("hello")])

        let sessions = await SessionFileListing.list(workspace: link, sessionsRoot: fixture.sessions)
        #expect(sessions.map(\.id) == ["a"])
        #expect(sessions.first?.firstMessage == "hello")
    }

    // MARK: - Titles and first messages

    @Test func theTitleSlotWinsOverTheHeadersTitle() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("b", "s.jsonl", lines: [
            titleSlot("Fix the build"), header(id: "s1", title: "Old title", cwd: "/work/p"),
            #"{"type":"model_change","id":"m","parentId":null,"timestamp":"2026-09-01T10:00:00.000Z","model":"x/y"}"#,
            user(blocks: ["run", "the tests"]), assistant("Done."),
        ])
        let info = try #require(SessionFileListing.list(directory: fixture.bucket("b")).first)
        #expect(info.id == "s1")
        #expect(info.cwd == "/work/p")
        #expect(info.title == "Fix the build")
        #expect(info.firstMessage == "run the tests")
        #expect(info.displayTitle == "Fix the build")
        #expect(info.created == Date(timeIntervalSince1970: 1_788_256_800))
    }

    @Test func anEmptyTitleSlotHidesTheHeadersTitle() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("b", "s.jsonl", lines: [titleSlot(""), header(id: "s1", title: "Stale"), user("first\nsecond line")])
        let info = try #require(SessionFileListing.list(directory: fixture.bucket("b")).first)
        #expect(info.title == nil)
        #expect(info.displayTitle == "first")
    }

    @Test func aLegacyHeaderFirstFileReadsTheSame() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("b", "titled.jsonl", lines: [header(id: "t", title: "Legacy title"), user("ask")])
        try fixture.write("b", "untitled.jsonl", lines: [header(id: "u"), assistant("hi"), user("the question")])
        try fixture.write("b", "empty.jsonl", lines: [header(id: "e")])
        let sessions = Dictionary(uniqueKeysWithValues: SessionFileListing.list(directory: fixture.bucket("b")).map { ($0.id, $0) })
        #expect(sessions["t"]?.title == "Legacy title")
        #expect(sessions["t"]?.firstMessage == "ask")
        #expect(sessions["u"]?.title == nil)
        #expect(sessions["u"]?.displayTitle == "the question")
        #expect(sessions["e"]?.firstMessage == nil)
        #expect(sessions["e"]?.displayTitle == "Untitled")
    }

    @Test func aFirstMessageCutOffByThePrefixIsReadFromItsText() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let long = "Plan the release:\\n" + String(repeating: "step ", count: 2000)
        try fixture.write("b", "s.jsonl", lines: [titleSlot(""), header(id: "s1"), user(long), assistant("ok")])
        let info = try #require(SessionFileListing.list(directory: fixture.bucket("b")).first)
        let first = try #require(info.firstMessage)
        #expect(first.hasPrefix("Plan the release:\nstep step"))
        #expect(first.count < 4096)
        #expect(info.displayTitle == "Plan the release:")
    }

    @Test func aCompactionSummaryTitlesAnUntitledSession() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("b", "s.jsonl", lines: [
            header(id: "s1"), user("start"),
            #"{"type":"compaction","id":"c","parentId":null,"timestamp":"2026-09-01T10:00:00.000Z","summary":"long","shortSummary":"Ported the parser","firstKeptEntryId":"x","tokensBefore":1}"#,
        ])
        let info = try #require(SessionFileListing.list(directory: fixture.bucket("b")).first)
        #expect(info.title == "Ported the parser")
    }

    // MARK: - Lifecycle status

    @Test(arguments: [
        (#"{"role":"assistant","content":[{"type":"text","text":"Done."}],"stopReason":"stop"}"#, SessionFileInfo.Status.complete),
        (#"{"role":"assistant","content":[{"type":"toolCall","id":"t","name":"bash","arguments":{}}],"stopReason":"toolUse"}"#, .interrupted),
        (#"{"role":"assistant","content":[{"type":"text","text":"cut"}],"stopReason":"length"}"#, .interrupted),
        (#"{"role":"assistant","content":[],"stopReason":"aborted"}"#, .aborted),
        (#"{"role":"assistant","content":[],"stopReason":"error","errorMessage":"overloaded"}"#, .error),
        (#"{"role":"toolResult","toolCallId":"t","toolName":"bash","content":[{"type":"text","text":"ok"}]}"#, .interrupted),
        (#"{"role":"user","content":[{"type":"text","text":"and then?"}]}"#, .pending),
        (#"{"role":"bashExecution","command":"ls","output":""}"#, .unknown),
    ])
    func theLastMessageDecidesTheStatus(message: String, status: SessionFileInfo.Status) throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("b", "s.jsonl", lines: [
            titleSlot("t"), header(id: "s1"), user("go"),
            #"{"type":"message","id":"z","parentId":null,"timestamp":"2026-09-01T10:01:00.000Z","message":\#(message)}"#,
            // Entries that are not messages after the last one do not count.
            #"{"type":"custom","id":"y","parentId":"z","timestamp":"2026-09-01T10:02:00.000Z","customType":"session_exit","data":{"reason":"quit","kind":"normal"}}"#,
        ])
        #expect(SessionFileListing.list(directory: fixture.bucket("b")).first?.status == status)
    }

    @Test func aSessionWithoutMessagesHasUnknownStatus() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write("b", "s.jsonl", lines: [titleSlot(""), header(id: "s1")])
        #expect(SessionFileListing.list(directory: fixture.bucket("b")).first?.status == .unknown)
    }

    @Test func onlyTheLast32KiBDecideTheStatusOfALargeFile() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        // The tail starts inside the long user message, then holds the whole answer.
        try fixture.write("b", "answered.jsonl", lines: [
            header(id: "answered"), user(String(repeating: "x", count: 40_000)), assistant("Done."),
        ])
        // The answer alone outgrows the tail: no whole message line is left to judge by, as in omp.
        try fixture.write("b", "long.jsonl", lines: [
            header(id: "long"), user("go"), assistant(String(repeating: "y", count: 40_000)),
        ])
        let status = Dictionary(uniqueKeysWithValues: SessionFileListing.list(directory: fixture.bucket("b")).map { ($0.id, $0.status) })
        #expect(status == ["answered": .complete, "long": .unknown])
    }

    // MARK: - What is listed

    @Test func subagentTranscriptsAndOtherFilesAreSkipped() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let main = "2026-09-25T10-08-38-294Z_01a0d809.jsonl"
        try fixture.write("b", main, lines: [titleSlot("Main"), header(id: "main"), user("go")])
        try fixture.write("b/2026-09-25T10-08-38-294Z_01a0d809", "AgentsScout.jsonl", lines: [
            titleSlot(""), header(id: "sub", parentSession: fixture.bucket("b").appending(path: main).path(percentEncoded: false)),
            user("scout"),
        ])
        try fixture.write("b", ".hidden.jsonl", lines: [header(id: "hidden")])
        try fixture.write("b", ".\(main).lock.os", lines: [])
        try fixture.write("b", "history.jsonl", lines: [#"{"prompt":"not a session"}"#])
        try fixture.write("b", "notes.txt", lines: [header(id: "txt")])
        #expect(SessionFileListing.list(directory: fixture.bucket("b")).map(\.id) == ["main"])
    }

    @Test func newestFirst() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        for (name, age) in [("old", 300.0), ("new", 10.0), ("mid", 100.0)] {
            let file = try fixture.write("b", "\(name).jsonl", lines: [header(id: name), user(name)])
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -age)], ofItemAtPath: file.path(percentEncoded: false))
        }
        #expect(SessionFileListing.list(directory: fixture.bucket("b")).map(\.id) == ["new", "mid", "old"])
    }

    @Test func searchMatchesEveryTokenInTitleOrFirstMessage() {
        let info = SessionFileInfo(
            path: "/s.jsonl", id: "s", cwd: "/w", title: "Fix the Build", firstMessage: "café crash on launch", created: nil,
            modified: Date(), size: 1, status: .complete)
        #expect(info.matches(""))
        #expect(info.matches("build cafe"))
        #expect(info.matches("  LAUNCH  "))
        #expect(!info.matches("build deploy"))
    }
}

// MARK: - Fixtures (shaped after real omp 18.4 files)

private struct Fixture {
    let root: URL
    var sessions: URL { root.appending(path: "sessions", directoryHint: .isDirectory) }

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "session-listing-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func bucket(_ name: String) -> URL { sessions.appending(path: name, directoryHint: .isDirectory) }

    @discardableResult
    func write(_ bucket: String, _ name: String, lines: [String]) throws -> URL {
        let folder = self.bucket(bucket)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: name)
        try Data(lines.map { $0 + "\n" }.joined().utf8).write(to: file)
        return file
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

/// The fixed-width (256-byte) title slot current omp files start with.
private func titleSlot(_ title: String) -> String {
    let bare = #"{"type":"title","v":1,"title":"\#(title)","updatedAt":"2026-09-01T10:00:00.000Z","pad":""}"#
    return #"{"type":"title","v":1,"title":"\#(title)","updatedAt":"2026-09-01T10:00:00.000Z","pad":"\#(String(repeating: " ", count: 255 - bare.utf8.count))"}"#
}

private func header(id: String, title: String? = nil, cwd: String = "/work/p", parentSession: String? = nil) -> String {
    var fields = [#""type":"session""#, #""version":3"#, #""id":"\#(id)""#, #""timestamp":"2026-09-01T10:00:00.000Z""#, #""cwd":"\#(cwd)""#]
    if let title { fields.append(#""title":"\#(title)""#) }
    if let parentSession { fields.append(#""parentSession":"\#(parentSession)""#) }
    return "{\(fields.joined(separator: ","))}"
}

private func user(_ text: String) -> String {
    #"{"type":"message","id":"u","parentId":null,"timestamp":"2026-09-01T10:00:01.000Z","message":{"role":"user","content":"\#(text)","timestamp":1}}"#
}

private func user(blocks: [String]) -> String {
    let content = blocks.map { #"{"type":"text","text":"\#($0)"}"# }.joined(separator: ",")
    return #"{"type":"message","id":"u","parentId":null,"timestamp":"2026-09-01T10:00:01.000Z","message":{"role":"user","content":[\#(content)],"timestamp":1}}"#
}

private func assistant(_ text: String) -> String {
    #"{"type":"message","id":"a","parentId":"u","timestamp":"2026-09-01T10:00:02.000Z","message":{"role":"assistant","content":[{"type":"text","text":"\#(text)"}],"stopReason":"stop","timestamp":2}}"#
}
