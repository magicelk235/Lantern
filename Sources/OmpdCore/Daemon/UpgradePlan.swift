import IDEProtocol
import os

/// What `daemon.upgrade` does. An in-place handover whenever nothing blocks it (Regime A: nothing restarts).
/// Otherwise the graceful restart (Regime B2): `now` at once; `whenSettled` at once when every session is settled, else
/// at the next moment all are; `auto` at once when every session is settled and the installed ompd could be started,
/// else not at all.
enum UpgradePlan: Equatable {
    case handOver
    case restartNow
    case restartWhenSettled
    case wait

    /// `handoverBlocker`: why the handover is impossible (nil: it is possible). `installedStarts`: the installed ompd
    /// answered when ompd started it. `unsettled`: the sessions that are not settled.
    static func decide(
        _ mode: DaemonUpgrade.Mode, handoverBlocker: String?, installedStarts: Bool, unsettled: [SessionKey]
    ) -> UpgradePlan {
        guard handoverBlocker != nil else { return .handOver }
        switch mode {
        case .now: return .restartNow
        case .whenSettled: return unsettled.isEmpty ? .restartNow : .restartWhenSettled
        case .auto: return unsettled.isEmpty && installedStarts ? .restartNow : .wait
        }
    }

    var outcome: DaemonUpgrade.Result.Outcome {
        switch self {
        case .handOver: .handingOver
        case .restartNow: .restarting
        case .restartWhenSettled: .restartWhenSettled
        case .wait: .busy
        }
    }
}

/// A switch read without entering the daemon's isolation (the manifest's change sink checks it on every write).
final class Flag: Sendable {
    private let state = OSAllocatedUnfairLock(initialState: false)

    var isOn: Bool { state.withLock { $0 } }

    func set(_ on: Bool) {
        state.withLock { $0 = on }
    }
}
