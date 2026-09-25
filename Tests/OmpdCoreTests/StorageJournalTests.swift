import Foundation
import IDEProtocol
import Testing
@testable import OmpdCore

private func delta(_ i: Int) -> JSONValue {
    ["type": "message_update", "i": .number(Double(i))]
}

@Suite struct StorageJournalTests {
    @Test func seqStaysMonotonicAcrossReopen() async throws {
        let dir = try StorageTempDir()
        var appended: [JournalRecord] = []
        do {
            let journal = try Journal(directory: dir.url, sessionKey: "s1")
            for i in 1...3 { appended.append(try await journal.append(kind: .omp, payload: delta(i), durable: false)) }
            #expect(await journal.lastSeq == 3)
            try await journal.close()
        }
        let reopened = try Journal(directory: dir.url, sessionKey: "s1")
        #expect(await reopened.lastSeq == 3)
        appended.append(try await reopened.append(kind: .daemon, payload: ["notice": "resumed"], durable: true))
        #expect(appended.last?.seq == 4)

        let replayed = try #require(try await reopened.records(after: 0))
        #expect(replayed.map(\.seq) == [1, 2, 3, 4])
        // A replayed record goes out on the wire byte-identical to the live copy `append` returned.
        let encoder = IDECoding.encoder()
        #expect(try replayed.map { try encoder.encode($0) } == appended.map { try encoder.encode($0) })
    }

    @Test(arguments: [
        Array(#"{"kind":"omp","payload":{"type":"message_upd"#.utf8),  // append cut short mid-line
        [UInt8](repeating: 0, count: 300),  // file grew but the data block never landed
        [UInt8](repeating: 0, count: 300) + [0x0A],  // same, with the newline's block persisted
    ])
    func tornTailIsTruncatedOnOpen(tail: [UInt8]) async throws {
        let dir = try StorageTempDir()
        let file: URL
        do {
            let journal = try Journal(directory: dir.url, sessionKey: "torn")
            for i in 1...2 { try await journal.append(kind: .omp, payload: delta(i), durable: false) }
            file = journal.fileURL
            try await journal.close()
        }
        let intactSize = try dir.size(of: file)
        try dir.appendRaw(tail, to: file)

        let journal = try Journal(directory: dir.url, sessionKey: "torn")
        #expect(await journal.lastSeq == 2)
        #expect(try dir.size(of: file) == intactSize)
        try await journal.append(kind: .omp, payload: delta(3), durable: false)
        #expect(try await journal.records(after: 0)?.map(\.seq) == [1, 2, 3])
    }

    @Test func linesLongerThanTheReadChunkReplayAndRecover() async throws {
        let dir = try StorageTempDir()
        let big = String(repeating: "x", count: 3 * StorageIO.chunkSize + 17)
        do {
            let journal = try Journal(directory: dir.url, sessionKey: "big")
            try await journal.append(kind: .omp, payload: delta(1), durable: false)
            try await journal.append(kind: .omp, payload: ["text": .string(big)], durable: false)
            try await journal.append(kind: .omp, payload: delta(3), durable: false)
            try await journal.append(kind: .omp, payload: ["text": .string(big)], durable: false)
            try await journal.close()
            try dir.appendRaw(Array(#"{"kind":"omp","payload":{"text":"\#(big)"#.utf8), to: journal.fileURL)
        }
        let journal = try Journal(directory: dir.url, sessionKey: "big")
        #expect(await journal.lastSeq == 4)
        let all = try #require(try await journal.records(after: 0))
        #expect(all.map(\.seq) == [1, 2, 3, 4])
        #expect(all.map { $0.payload["text"]?.stringValue } == [nil, big, nil, big])
        #expect(try await journal.records(after: 3)?.map(\.seq) == [4])
    }

    @Test func recordsAfterBoundaries() async throws {
        let dir = try StorageTempDir()
        let journal = try Journal(directory: dir.url, sessionKey: "b")
        #expect(try await journal.records(after: 0) == [])
        #expect(try await journal.records(after: 1) == nil)
        for i in 1...5 { try await journal.append(kind: .omp, payload: delta(i), durable: false) }
        #expect(try await journal.records(after: 0)?.map(\.seq) == [1, 2, 3, 4, 5])
        #expect(try await journal.records(after: 3)?.map(\.seq) == [4, 5])
        #expect(try await journal.records(after: 5) == [])
        #expect(try await journal.records(after: 6) == nil)
        #expect(try await journal.subscribe(after: 6) == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func subscribeReplayThenLiveIsContiguousUnderConcurrentAppends() async throws {
        let dir = try StorageTempDir()
        let journal = try Journal(directory: dir.url, sessionKey: "sub")
        let total: Seq = 3_000
        let writer = Task {
            for i in 1...Int(total) {
                try await journal.append(kind: .omp, payload: delta(i), durable: false)
                if i.isMultiple(of: 16) { await Task.yield() }
            }
        }
        var sinces: [Seq] = []
        try await withThrowingTaskGroup(of: (since: Seq, seqs: [Seq]).self) { group in
            for k in 1...24 {
                // Spread the subscriptions over the whole run.
                while await journal.lastSeq < Seq(k) * (total / 30) { await Task.yield() }
                let since = await journal.lastSeq
                let subscription = try #require(try await journal.subscribe(after: since))
                sinces.append(since)
                group.addTask {
                    var seqs = subscription.replay.map(\.seq)
                    if (seqs.last ?? since) < total {
                        for await record in subscription.live {
                            seqs.append(record.seq)
                            if record.seq == total { break }
                        }
                    }
                    return (since, seqs)
                }
            }
            for try await (since, seqs) in group {
                #expect(seqs == Array(since + 1 ..< total + 1), "subscription after \(since)")
            }
        }
        try await writer.value
        #expect(sinces.contains { $0 > 0 && $0 < total }, "no subscription landed mid-stream")
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellingTheLiveConsumerUnregistersIt() async throws {
        let dir = try StorageTempDir()
        let journal = try Journal(directory: dir.url, sessionKey: "cancel")
        let subscription = try #require(try await journal.subscribe(after: 0))
        #expect(await journal.subscriberCount == 1)
        let consumer = Task {
            for await _ in subscription.live {}
        }
        try await journal.append(kind: .omp, payload: delta(1), durable: false)
        consumer.cancel()
        await consumer.value
        // Unregistration hops back onto the journal asynchronously.
        while await journal.subscriberCount > 0 { try await Task.sleep(for: .milliseconds(1)) }
        try await journal.append(kind: .omp, payload: delta(2), durable: false)
        #expect(await journal.subscriberCount == 0)
    }

    @Test(.timeLimit(.minutes(1)))
    func closeEndsLiveStreamsAndRejectsFurtherUse() async throws {
        let dir = try StorageTempDir()
        let journal = try Journal(directory: dir.url, sessionKey: "close")
        let subscription = try #require(try await journal.subscribe(after: 0))
        let consumer = Task {
            var seqs: [Seq] = []
            for await record in subscription.live { seqs.append(record.seq) }
            return seqs
        }
        try await journal.append(kind: .omp, payload: delta(1), durable: false)
        try await journal.append(kind: .omp, payload: delta(2), durable: false)
        try await journal.close()
        #expect(await consumer.value == [1, 2])
        await #expect(throws: StorageError.journalClosed("close")) {
            try await journal.append(kind: .omp, payload: delta(3), durable: false)
        }
        try await journal.close()
    }

    @Test func onlyDurableAppendsSyncAndCloseFlushesTheRest() async throws {
        let dir = try StorageTempDir()
        let journal = try Journal(directory: dir.url, sessionKey: "durable")
        try await journal.append(kind: .omp, payload: delta(1), durable: false)
        #expect(await journal.syncCount == 0)
        try await journal.append(kind: .omp, payload: ["type": "turn_end"], durable: true)
        #expect(await journal.syncCount == 1)
        try await journal.sync()  // nothing written since the durable append
        #expect(await journal.syncCount == 1)
        try await journal.append(kind: .omp, payload: delta(3), durable: false)
        try await journal.sync()
        #expect(await journal.syncCount == 2)
        try await journal.append(kind: .omp, payload: delta(4), durable: false)
        try await journal.close()
        #expect(await journal.syncCount == 3)
    }

    @Test func durableBoundariesAreCompletionSettleAndBlockingRequests() {
        for type in ["turn_end", "agent_end", "prompt_result", "session_settled", "extension_ui_request", "host_tool_call"] {
            #expect(Journal.isDurableBoundary(ompFrame: ["type": .string(type)]), "\(type)")
        }
        let notBoundaries: [JSONValue] = [
            ["type": "message_update"], ["type": "tool_execution_update"], ["type": "host_tool_cancel"], ["id": "1"], "turn_end",
        ]
        for frame in notBoundaries {
            #expect(!Journal.isDurableBoundary(ompFrame: frame), "\(frame)")
        }
    }

    @Test(arguments: ["", ".", "..", "../escape", "a/b", "nul\u{0}key", String(repeating: "k", count: 250)])
    func sessionKeysThatAreNotOneFileNameAreRejected(key: String) throws {
        let dir = try StorageTempDir()
        #expect(throws: StorageError.invalidSessionKey(key)) {
            try Journal(directory: dir.url, sessionKey: key)
        }
    }
}
