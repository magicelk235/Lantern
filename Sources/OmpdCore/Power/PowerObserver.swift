import Foundation
import IOKit
import IOKit.pwr_mgt
import os

/// System sleep/wake notifications: `IORegisterForSystemPower`, delivered on a private
/// dispatch queue. Sleep is acknowledged (`IOAllowPowerChange`) only after `willSleep` finished, so terminals,
/// manifest and journals are durable before the machine sleeps; macOS waits at most 30 s for the acknowledgement.
public final class PowerObserver: Sendable {
    public enum Failure: Error, CustomStringConvertible {
        case registrationFailed

        public var description: String { "IORegisterForSystemPower failed" }
    }

    // `iokit_common_msg(n)` = sys_iokit | sub_iokit_common | n; the macros do not import into Swift.
    static let canSystemSleep: UInt32 = 0xE000_0270
    static let systemWillSleep: UInt32 = 0xE000_0280
    static let systemHasPoweredOn: UInt32 = 0xE000_0300

    private let willSleep: @Sendable () async -> Void
    private let didWake: @Sendable () async -> Void
    private let queue = DispatchQueue(label: "com.omp-ide.ompd.power")
    private let registration = OSAllocatedUnfairLock<Registration?>(initialState: nil)

    private struct Registration: Sendable {
        var rootPort: io_connect_t
        var notifier: io_object_t
        /// `IONotificationPortRef` as a bit pattern (the pointer type is not `Sendable`).
        var notificationPort: UInt
    }

    /// - Parameters:
    ///   - willSleep: runs before the system is allowed to sleep.
    ///   - didWake: runs when the system has powered on again.
    public init(willSleep: @escaping @Sendable () async -> Void, didWake: @escaping @Sendable () async -> Void) {
        self.willSleep = willSleep
        self.didWake = didWake
    }

    deinit {
        stop()
    }

    public func start() throws {
        var port: IONotificationPortRef?
        var notifier: io_object_t = 0
        let rootPort = IORegisterForSystemPower(
            Unmanaged.passUnretained(self).toOpaque(), &port, powerCallback, &notifier)
        guard rootPort != 0, let port else { throw Failure.registrationFailed }
        // Recorded before the port gets its queue: the first message may need `rootPort` to be acknowledged.
        let recorded = Registration(rootPort: rootPort, notifier: notifier, notificationPort: UInt(bitPattern: port))
        registration.withLock { $0 = recorded }
        IONotificationPortSetDispatchQueue(port, queue)
    }

    public func stop() {
        guard var registration = registration.withLock({ current in defer { current = nil }; return current }) else { return }
        IODeregisterForSystemPower(&registration.notifier)
        IOServiceClose(registration.rootPort)
        IONotificationPortDestroy(OpaquePointer(bitPattern: registration.notificationPort))
    }

    fileprivate func received(_ message: UInt32, notificationID: Int) {
        switch message {
        case Self.canSystemSleep:
            allowPowerChange(notificationID)
        case Self.systemWillSleep:
            powerLog.notice("system will sleep")
            let willSleep = willSleep
            Task {
                await willSleep()
                self.allowPowerChange(notificationID)
            }
        case Self.systemHasPoweredOn:
            powerLog.notice("system woke")
            let didWake = didWake
            Task { await didWake() }
        default:
            break
        }
    }

    private func allowPowerChange(_ notificationID: Int) {
        guard let rootPort = registration.withLock({ $0?.rootPort }) else { return }
        IOAllowPowerChange(rootPort, notificationID)
    }
}

private let powerLog = Logger(subsystem: "com.omp-ide.ompd", category: "power")

private let powerCallback: IOServiceInterestCallback = { refcon, _, message, argument in
    guard let refcon else { return }
    Unmanaged<PowerObserver>.fromOpaque(refcon).takeUnretainedValue()
        .received(message, notificationID: Int(bitPattern: argument))
}
