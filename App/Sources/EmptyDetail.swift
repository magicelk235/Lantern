import AppKit
import SwiftUI

/// The detail area with no tab on screen: what to do first. The window of no project: the lantern, what Lantern is, and
/// Add Project…; a project's window: the lantern, the project's name, New Session, and New Terminal and Open Session…
/// under it. Under either, while no omp is where new sessions look for one, how to install it.
struct EmptyDetail: View {
    let app: AppState
    let project: String?
    /// omp is where a new session finds it; checked again whenever the app comes forward.
    @State private var ompFound = OmpLocation.isInstalled()

    var body: some View {
        VStack(spacing: 0) {
            LanternMark(height: 64)
                .padding(.bottom, 18)
            if let project {
                Text(AppState.projectName(project))
                    .font(.title2.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(project)
                    .padding(.bottom, 20)
                Button { app.newSession(in: project) } label: { ShortcutLabel(title: "New Session", shortcut: "⌘N") }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!app.connection.isConnected)
                HStack(spacing: 20) {
                    Button("New Terminal") { app.newTerminal(in: project) }
                        .disabled(!app.connection.isConnected)
                    Button("Open Session…") { app.showSessionPicker(for: project) }
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.tint)
                .padding(.top, 14)
            } else {
                Text("Lantern runs omp in your project folders and keeps its sessions going when you quit.")
                    .font(.title3)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
                    .padding(.bottom, 20)
                Button { app.addProject() } label: { ShortcutLabel(title: "Add Project…", shortcut: "⌘O") }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            }
            if !ompFound {
                OmpInstallHint()
                    .padding(.top, 36)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Chrome.canvas)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            ompFound = OmpLocation.isInstalled()
        }
    }
}

/// A button's title with the shortcut of the menu item that does the same (VoiceOver reads the title alone).
private struct ShortcutLabel: View {
    let title: String
    let shortcut: String

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .fontWeight(.medium)
            Text(shortcut)
        }
        .padding(.horizontal, 6)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
    }
}

/// No omp where new sessions look for one: how to install it, with the command to copy.
private struct OmpInstallHint: View {
    @State private var copied = false

    var body: some View {
        VStack(spacing: 8) {
            Text("Lantern can’t find omp. Install it with Homebrew:")
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Text(OmpLocation.installCommand)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Chrome.surface, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Chrome.hairline))
                Button(copied ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(OmpLocation.installCommand, forType: .string)
                    copied = true
                }
                .controlSize(.small)
                .task(id: copied) {
                    guard copied else { return }
                    try? await Task.sleep(for: .seconds(2))
                    copied = false
                }
            }
        }
        .font(.system(size: 12))
        .multilineTextAlignment(.center)
    }
}

/// Where new sessions find omp, as ompd looks for it (`OmpBinary.locate`): `$OMP_BIN`, else `omp` on `PATH`, else
/// Homebrew's link, which is all a launchd agent's minimal `PATH` leaves.
enum OmpLocation {
    /// Homebrew's formula puts omp where ompd looks for it.
    static let installCommand = "brew install can1357/tap/omp"
    private static let homebrewPath = "/opt/homebrew/bin/omp"

    static func isInstalled(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        // A configured omp that is not there is not looked past, as ompd does not.
        if let configured = environment["OMP_BIN"], !configured.isEmpty { return isExecutable(configured) }
        let onPath = (environment["PATH"] ?? "").split(separator: ":").contains { isExecutable("\($0)/omp") }
        return onPath || isExecutable(homebrewPath)
    }

    private static func isExecutable(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && !isDirectory.boolValue
            && FileManager.default.isExecutableFile(atPath: path)
    }
}

/// The lantern of the app icon (`AppIcon.icon/Assets/lantern.svg`): its π with the handle, in the icon's ember.
struct LanternMark: View {
    let height: CGFloat

    var body: some View {
        let scale = height / LanternGlyph.size.height
        LanternGlyph()
            .fill(RadialGradient(
                stops: [
                    .init(color: Color(red: 1, green: 0.914, blue: 0.722), location: 0),
                    .init(color: Color(red: 0.969, green: 0.698, blue: 0.353), location: 0.4),
                    .init(color: Color(red: 0.878, green: 0.494, blue: 0.180), location: 0.8),
                    .init(color: Color(red: 0.722, green: 0.353, blue: 0.133), location: 1),
                ],
                center: LanternGlyph.glowCenter, startRadius: 0, endRadius: LanternGlyph.glowRadius * scale))
            .frame(width: LanternGlyph.size.width * scale, height: height)
            .accessibilityHidden(true)
    }
}

/// The π of `lantern.svg` in its own 169 × 204 units: the handle, the bar, the left leg and the right leg with its
/// foot, joined into one outline.
struct LanternGlyph: Shape {
    static let size = CGSize(width: 169, height: 204)
    /// The icon's radial ember: its center, and its radius in the glyph's units.
    static let glowCenter = UnitPoint(x: 84.0 / 169, y: 118.0 / 204)
    static let glowRadius: CGFloat = 130

    func path(in rect: CGRect) -> Path {
        var handle = Path()
        handle.move(to: CGPoint(x: 54, y: 30))
        handle.addRelativeArc(center: CGPoint(x: 84, y: 30), radius: 30, startAngle: .degrees(180), delta: .degrees(180))
        handle.addLine(to: CGPoint(x: 100, y: 30))
        handle.addRelativeArc(center: CGPoint(x: 84, y: 30), radius: 16, startAngle: .zero, delta: .degrees(-180))
        handle.closeSubpath()

        // SVG grows the foot's arc to the 11 units its ends are apart from its middle.
        var foot = Path()
        foot.move(to: CGPoint(x: 116, y: 48))
        foot.addLine(to: CGPoint(x: 144, y: 48))
        foot.addLine(to: CGPoint(x: 144, y: 164))
        foot.addCurve(to: CGPoint(x: 158, y: 182), control1: CGPoint(x: 144, y: 176), control2: CGPoint(x: 150, y: 182))
        foot.addRelativeArc(center: CGPoint(x: 158, y: 193), radius: 11, startAngle: .degrees(-90), delta: .degrees(180))
        foot.addLine(to: CGPoint(x: 152, y: 204))
        foot.addCurve(to: CGPoint(x: 116, y: 166), control1: CGPoint(x: 134, y: 204), control2: CGPoint(x: 116, y: 190))
        foot.closeSubpath()

        let glyph = handle
            .union(Path(roundedRect: CGRect(x: 0, y: 28, width: 168, height: 30), cornerRadius: 10))
            .union(Path(roundedRect: CGRect(x: 24, y: 48, width: 28, height: 142), cornerRadius: 10))
            .union(foot)
        let scale = min(rect.width / Self.size.width, rect.height / Self.size.height)
        let origin = CGPoint(x: rect.midX - Self.size.width * scale / 2, y: rect.midY - Self.size.height * scale / 2)
        return glyph.applying(CGAffineTransform(translationX: origin.x, y: origin.y).scaledBy(x: scale, y: scale))
    }
}
