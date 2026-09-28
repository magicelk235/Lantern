import Foundation
import os

/// Who closed omp's pause gate, as the ide-bridge reports it (`pausedBy`, `pause {by}`).
public enum PauseOwner: String, Sendable {
    /// ompd (`session.pause`), because no omp IDE window was connected; ompd resumes it when one connects.
    case daemon
    /// The user: `/pause` in the session's TUI. Only they resume it, from omp's pause screen.
    case user
}

extension PauseOwner {
    /// The bridge's `paused` and `pausedBy`/`by`: nil while the gate is open; an owner it does not name is the user.
    init?(paused: Bool, by name: String?) {
        guard paused else { return nil }
        self = PauseOwner(rawValue: name ?? "") ?? .user
    }
}

/// Whether ompd wants every session paused: no omp IDE window is open — an app said its last one closed,
/// or no app with one has been connected for the grace period. The daemon flips it; supervisors also read it when a
/// bridge says hello, so an omp spawned while no window is open is paused right away.
public final class PauseDemand: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: false)

    public init() {}

    public var isOn: Bool { state.withLock { $0 } }

    /// True when this changed the demand.
    @discardableResult
    public func set(_ on: Bool) -> Bool {
        state.withLock { current in
            defer { current = on }
            return current != on
        }
    }
}
