import Foundation
import IDEProtocol
import os

/// `ManifestStore` plus change notification: every update that changes the manifest and reaches disk is published
/// to `sink` (the daemon broadcasts it to clients as `ServerFrame.sessions`), in the order the updates were applied.
public final class ManifestPublisher: Sendable {
    public let store: ManifestStore
    private let state = OSAllocatedUnfairLock(initialState: State())

    private struct State: Sendable {
        var sink: (@Sendable (SessionList) -> Void)?
        /// Stamp of the latest applied change; stamps are taken inside the store's serialized update.
        var issued: UInt64 = 0
        /// Stamp of the newest manifest handed to `sink`, so a slow publisher never overwrites a newer list.
        var published: UInt64 = 0
    }

    public init(store: ManifestStore) {
        self.store = store
    }

    /// Where changed manifests go from now on.
    public func setSink(_ sink: @escaping @Sendable (SessionList) -> Void) {
        state.withLock { $0.sink = sink }
    }

    /// `ManifestStore.update`, then publishes the result if it changed anything.
    @discardableResult
    public func update(_ body: @escaping @Sendable (inout SessionManifest) throws -> Void) async throws -> SessionManifest {
        let stamp = OSAllocatedUnfairLock<UInt64?>(initialState: nil)
        let state = state
        let manifest = try await store.update { manifest in
            let before = manifest
            try body(&manifest)
            guard manifest != before else { return }
            let issued = state.withLock { s in
                s.issued += 1
                return s.issued
            }
            stamp.withLock { $0 = issued }
        }
        if let issued = stamp.withLock({ $0 }) {
            state.withLock { s in
                guard issued > s.published else { return }
                s.published = issued
                // Under the lock: two publishers can never hand their lists to the sink out of order.
                s.sink?(SessionList(sessions: manifest.sessions))
            }
        }
        return manifest
    }

    /// Updates the entry of `key`; a no-op if there is none.
    @discardableResult
    public func updateEntry(_ key: SessionKey, _ body: @escaping @Sendable (inout SessionManifestEntry) -> Void) async throws
        -> SessionManifestEntry?
    {
        let manifest = try await update { manifest in
            guard let index = manifest.sessions.firstIndex(where: { $0.sessionKey == key }) else { return }
            body(&manifest.sessions[index])
        }
        return manifest.sessions.first { $0.sessionKey == key }
    }

    public func entry(_ key: SessionKey) async -> SessionManifestEntry? {
        await store.current.sessions.first { $0.sessionKey == key }
    }

    public var sessions: [SessionManifestEntry] {
        get async { await store.current.sessions }
    }
}
