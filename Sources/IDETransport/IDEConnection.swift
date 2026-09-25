import Foundation

/// Server-side handle for one connected client.
///
/// `send` never blocks the daemon: it encodes the frame on the caller's thread and appends it to the connection's
/// outbound FIFO. Frames reach the client in the order `send` calls were made (for concurrent callers, in the order
/// their calls took the queue). A client that falls more than the server's `maxBacklogBytes` behind is disconnected
/// and its queued frames are dropped; it recovers by reconnecting and resubscribing with `since`.
public final class IDEConnection: Sendable, Hashable, Identifiable {
    public let id = UUID()
    let channel: FrameChannel

    init(channel: FrameChannel) {
        self.channel = channel
    }

    /// Queues `frame` for the client. No-op once the connection is closing or closed.
    ///
    /// A frame that cannot be encoded (non-finite number, over `ideMaxFrameBytes`) never becomes a silent gap: a
    /// response is replaced by an `internal` error for the same request id, and any other frame closes the connection
    /// so the client resyncs.
    public func send(_ frame: ServerFrame) {
        guard channel.isAccepting else { return }
        do {
            channel.send(try FrameCodec.encode(frame))
        } catch {
            guard case .response(let response) = frame,
                  let fallback = try? FrameCodec.encode(ServerFrame.response(Response(
                      id: response.id, error: DaemonError(.internal, "response not encodable: \(error)"))))
            else {
                transportLog.error("client \(self.id, privacy: .public): unencodable frame, closing: \(String(describing: error), privacy: .public)")
                close()
                return
            }
            channel.send(fallback)
        }
    }

    /// Closes gracefully: frames already queued are still written (within a short grace period), then the socket
    /// closes. The server calls `IDERequestHandler.connectionClosed` once every in-flight request has returned.
    public func close() {
        channel.close()
    }

    /// Bytes queued for this client that have not been written to its socket yet.
    public var backlogBytes: Int { channel.backlogBytes }

    /// Suspends until at most `limit` bytes are queued for this client, the connection closes, or the calling task is
    /// cancelled. Bulk producers (journal replay) pace themselves with this instead of tripping the slow-consumer
    /// cutoff that protects the daemon from clients that stopped reading.
    public func waitForBacklog(atMost limit: Int) async {
        await channel.waitForBacklog(atMost: limit)
    }

    public static func == (lhs: IDEConnection, rhs: IDEConnection) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
