import Foundation
@testable import IDEModel
import IDETransport
import Testing

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct SessionViewModelTests {
    private func liveModel(_ backend: RecordingBackend) async throws -> SessionViewModel {
        let model = SessionViewModel(sessionKey: "s1", entry: manifestEntry("s1"), backend: backend)
        model.connectionOpened()
        try await eventually("subscription live") { model.sync == .live }
        return model
    }

    @Test func appliesContiguousRecordsAndIgnoresReplayOverlap() async throws {
        let backend = RecordingBackend()
        let model = try await liveModel(backend)
        #expect(backend.subscribes == [.init(sessionKey: "s1", since: 0)])

        let records = try Fixture.records("bash-approve")
        for record in records[0 ..< 20] { model.receive(record) }
        for record in records[10 ..< 30] { model.receive(record) }
        #expect(model.lastSeq == 30)
        #expect(model.transcript == reduce(records[0 ..< 30]))
        #expect(backend.subscribes.count == 1, "overlap is not a gap")
    }

    @Test func gapResubscribesFromLastSeqThenEscalatesToResync() async throws {
        let backend = RecordingBackend()
        backend.snapshotResult = try Fixture.snapshot("snapshot-eof-tool")
        let model = try await liveModel(backend)
        let records = try Fixture.records("bash-approve")

        for record in records[0 ..< 5] { model.receive(record) }
        model.receive(records[7]) // seq 8 after 5: 6 and 7 went missing
        #expect(model.lastSeq == 5)
        #expect(model.sync == .subscribing)
        model.receive(records[9]) // another gap while the replay is on its way is not a second request
        try await eventually("re-subscribed") { model.sync == .live }
        #expect(backend.subscribes.map(\.since) == [0, 5])

        for record in records[5 ..< 8] { model.receive(record) }
        #expect(model.lastSeq == 8)

        // The replay did not fill the hole at 8 either: rebuild from a snapshot instead of asking forever.
        model.receive(records[10])
        try await eventually("re-subscribed") { model.sync == .live }
        model.receive(records[10])
        try await eventually("rebuilt") { model.sync == .live && backend.snapshots == ["s1"] }
        #expect(model.lastSeq == 57)
        #expect(backend.subscribes.map(\.since) == [0, 5, 8, 57])
    }

    @Test func resyncRebuildsFromSnapshotAndResubscribesFromItsSeq() async throws {
        let backend = RecordingBackend()
        let snapshot = try Fixture.snapshot("snapshot-eof-tool")
        backend.snapshotResult = snapshot
        let model = try await liveModel(backend)
        for record in try Fixture.records("bash-approve")[0 ..< 12] { model.receive(record) }
        #expect(!model.items.isEmpty)

        model.receive(Resync(sessionKey: "s1", lastSeq: 57))
        #expect(model.sync == .resyncing)
        #expect(model.items.isEmpty, "the old view is dropped at once")
        try await eventually("rebuilt and live") { model.sync == .live }

        var expected = TranscriptReducer()
        expected.rebuild(from: snapshot)
        #expect(model.items == expected.items)
        #expect(model.lastSeq == 57)
        #expect(backend.snapshots == ["s1"])
        #expect(backend.subscribes.map(\.since) == [0, 57])

        model.receive(record(57, ["type": "agent_start"]))
        #expect(!model.isBusy, "records the snapshot already covers are ignored")
        model.receive(record(58, ["type": "agent_start"]))
        #expect(model.isBusy)
    }

    @Test func aCompactedRangeNeverSeenTriggersAResync() async throws {
        let backend = RecordingBackend()
        backend.snapshotResult = try Fixture.snapshot("snapshot-eof-tool")
        let model = try await liveModel(backend)
        model.receive(record(1, ["type": "agent_start"]))
        model.receive(record(2, ["ompEntryId": "84ef0f4a", "fromSeq": 2, "toSeq": 40], kind: .compacted))
        try await eventually("rebuilt") { model.sync == .live && backend.snapshots == ["s1"] }
        #expect(model.lastSeq == 57)
    }

    @Test func reconnectResubscribesFromLastSeqWithoutSnapshotOrOmpCommand() async throws {
        let backend = RecordingBackend()
        let model = try await liveModel(backend)
        let records = try Fixture.records("bash-approve")
        for record in records[0 ..< 30] { model.receive(record) }

        model.connectionClosed()
        #expect(model.sync == .detached)
        model.receive(records[30]) // stray frame of a dead connection
        #expect(model.lastSeq == 30)

        model.connectionOpened()
        try await eventually("live again") { model.sync == .live }
        #expect(backend.subscribes.map(\.since) == [0, 30])
        #expect(backend.snapshots.isEmpty)
        #expect(backend.commands.isEmpty, "Regime A: restoring sends no omp command")
    }

    @Test func aResyncCutShortByADisconnectFinishesOnReconnect() async throws {
        let backend = RecordingBackend()
        backend.snapshotResult = try Fixture.snapshot("snapshot-eof-tool")
        backend.snapshotFailures = [IDETransportError.connectionClosed]
        let model = try await liveModel(backend)
        model.receive(record(1, ["type": "agent_start"]))

        model.receive(Resync(sessionKey: "s1", lastSeq: 57))
        try await eventually("snapshot attempted") { backend.snapshots.count == 1 }
        model.connectionClosed()
        try await Task.sleep(for: .milliseconds(20))
        #expect(model.sync == .detached)

        model.connectionOpened()
        try await eventually("rebuilt") { model.sync == .live }
        #expect(backend.snapshots == ["s1", "s1"])
        #expect(backend.subscribes.map(\.since) == [0, 57], "never subscribes from the dropped transcript's seq")
    }

    @Test func refusedSubscriptionIsReportedAndRetriedOnReconnect() async throws {
        let backend = RefusingBackend()
        let model = SessionViewModel(sessionKey: "gone", entry: nil, backend: backend)
        model.connectionOpened()
        try await eventually("failed") { model.sync == .failed("no session gone") }
        backend.refuse = false
        model.connectionOpened()
        try await eventually("live") { model.sync == .live }
    }

    @Test func promptsSteerFollowUpAndAnswers() async throws {
        let backend = RecordingBackend()
        let model = try await liveModel(backend)

        #expect(await model.send("hello"))
        #expect(await model.send("look at the tests first", streamingBehavior: .steer))
        #expect(await model.send("then summarize", streamingBehavior: .followUp))
        #expect(backend.commands == [
            ["type": "prompt", "message": "hello"],
            ["type": "prompt", "message": "look at the tests first", "streamingBehavior": "steer"],
            ["type": "prompt", "message": "then summarize", "streamingBehavior": "followUp"],
        ])

        await model.respond(to: "r1", with: .value("Approve"))
        await model.respond(to: "r2", with: .confirmed(false))
        await model.respond(to: "r3", with: .cancelled)
        #expect(backend.responses.map(\.response) == [["value": "Approve"], ["confirmed": false], ["cancelled": true]])
        #expect(model.sentAnswers["r1"] == .value("Approve"))
        #expect(model.answering.isEmpty)
    }

    @Test func abortAlsoCancelsPendingApprovals() async throws {
        let backend = RecordingBackend()
        let model = try await liveModel(backend)
        let records = try Fixture.records("bash-approve")
        let requestIndex = try #require(records.firstIndex { $0.payload["method"]?.stringValue == "select" })
        for record in records[...requestIndex] { model.receive(record) }
        model.receive(record(records[requestIndex].seq + 1, [
            "type": "extension_ui_request", "id": "ask-1", "method": "input", "title": "Branch name?",
        ]))

        await model.abort()
        #expect(backend.commands == [["type": "abort"]])
        #expect(backend.responses == [.init(sessionKey: "s1", requestId: "158d569562c98aeb", response: ["cancelled": true])],
                "only approvals: omp withdraws other dialogs itself")
    }

    @Test func aTimedDialogExpiresWhileNothingElseArrives() async throws {
        let backend = RecordingBackend()
        let model = try await liveModel(backend)
        model.receive(record(1, ["type": "extension_ui_request", "id": "d1", "method": "confirm", "title": "Go?", "timeout": 200], at: Date()))
        #expect(model.transcript.pendingDialogCount == 1)
        try await eventually("expired", timeout: .seconds(3)) { model.items.first?.dialog?.state == .expired }
    }
}

/// Refuses subscriptions with `noSuchSession` until `refuse` is cleared.
@MainActor
private final class RefusingBackend: SessionBackend {
    var refuse = true

    func subscribe(_ sessionKey: SessionKey, since: Seq) async throws -> Subscribe.Result {
        if refuse { throw DaemonError(.noSuchSession, "no session \(sessionKey)") }
        return .init(replayedThrough: since)
    }

    func snapshot(_ sessionKey: SessionKey) async throws -> SessionSnapshot.Result {
        throw DaemonError(.noSuchSession, "no session \(sessionKey)")
    }

    func send(_ command: JSONValue, to sessionKey: SessionKey) async throws -> JSONValue { .null }

    func respond(to requestId: String, in sessionKey: SessionKey, with response: JSONValue) async throws {}
}
