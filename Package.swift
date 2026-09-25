// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OmpIDE",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "IDEProtocol", targets: ["IDEProtocol"]),
        .library(name: "IDETransport", targets: ["IDETransport"]),
        .library(name: "OmpdCore", targets: ["OmpdCore"]),
        .library(name: "IDEModel", targets: ["IDEModel"]),
        .library(name: "IDEState", targets: ["IDEState"]),
        .library(name: "IDEEditorModel", targets: ["IDEEditorModel"]),
        .executable(name: "ompd", targets: ["ompd"]),
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.2.0"),
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
    ],
    targets: [
        // Daemon <-> UI wire contract (pure Codable types, shared by ompd and the app).
        .target(name: "IDEProtocol"),
        // Length-prefixed frames over a unix domain socket (NWListener/NWConnection), used by ompd and the app.
        .target(name: "IDETransport", dependencies: ["IDEProtocol"]),
        // Daemon internals: manifest, session supervisors (omp TUIs in PTYs), PTY pool, ide-bridge server, power observers.
        .target(
            name: "OmpdCore",
            dependencies: ["IDEProtocol", "IDETransport", .product(name: "SwiftTerm", package: "SwiftTerm")]
        ),
        .executableTarget(name: "ompd", dependencies: ["OmpdCore", "IDETransport"]),
        // App-side state (no AppKit/SwiftUI): daemon connection, per-session sync, transcript reducer.
        .target(name: "IDEModel", dependencies: ["IDETransport"]),
        // App-owned persistent state (no AppKit/SwiftUI): windows, tabs, per-session UI and hot-exit dirty buffers in
        // `state.sqlite`.
        .target(name: "IDEState", dependencies: ["IDEProtocol", .product(name: "GRDB", package: "GRDB.swift")]),
        // Editor logic without AppKit/SwiftUI: text file I/O with content hashes, the
        // buffer state machine (dirty, save, revert, external change, hot-exit restore), line diffs, the file navigator's
        // directory listing and FSEvents watching.
        .target(name: "IDEEditorModel", dependencies: ["IDEState"]),

        .testTarget(name: "IDEProtocolTests", dependencies: ["IDEProtocol"]),
        .testTarget(name: "IDETransportTests", dependencies: ["IDETransport"]),
        .testTarget(name: "OmpdCoreTests", dependencies: ["OmpdCore"]),
        .testTarget(name: "IDEModelTests", dependencies: ["IDEModel"], resources: [.copy("Fixtures")]),
        .testTarget(name: "IDEStateTests", dependencies: ["IDEState", .product(name: "GRDB", package: "GRDB.swift")]),
        .testTarget(name: "IDEEditorModelTests", dependencies: ["IDEEditorModel", "IDEState"]),
    ],
    swiftLanguageModes: [.v6]
)
