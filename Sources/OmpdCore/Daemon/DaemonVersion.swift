import Foundation
import MachO

/// Version of the daemon: printed by `ompd --version` and sent as `Welcome.daemonVersion` / `daemon.status`. The ompd the
/// app embeds carries an Info.plist section (`__TEXT,__info_plist`) whose `CFBundleShortVersionString` and
/// `CFBundleVersion` every release sets, so each build reports its own (`0.1.0 (42)`), as the app does in its `hello`; a
/// `swift build` ompd has none and reports the package's. The section is read from ompd's own image: inside the app
/// bundle, `Bundle.main` is the app's.
public let ompdVersion: String = {
    guard let info = embeddedInfoPlist(), info["CFBundleIdentifier"] as? String == "com.magicelklabs.lantern.ompd",
          let short = info["CFBundleShortVersionString"] as? String, !short.isEmpty
    else { return "0.1.0" }
    guard let build = info["CFBundleVersion"] as? String, !build.isEmpty else { return short }
    return "\(short) (\(build))"
}()

/// The main executable's `__TEXT,__info_plist` section as a dictionary; nil without one.
private func embeddedInfoPlist() -> [String: Any]? {
    guard let header = _dyld_get_image_header(0) else { return nil }
    var size: UInt = 0
    let mach = UnsafeRawPointer(header).assumingMemoryBound(to: mach_header_64.self)
    guard let bytes = getsectiondata(mach, "__TEXT", "__info_plist", &size), size > 0 else { return nil }
    let data = Data(bytes: bytes, count: Int(size))
    return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
}
