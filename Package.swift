// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OmpIDE",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "OmpRPC", targets: ["OmpRPC"]),
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
        // omp `--mode rpc|rpc-ui` client: JSONL framing, v2 rpc_chunk reassembly, typed commands/events, process transport.
        .target(name: "OmpRPC"),
        // Daemon <-> UI wire contract (pure Codable types, shared by ompd and the app).
        .target(name: "IDEProtocol"),
        // Length-prefixed frames over a unix domain socket (NWListener/NWConnection), used by ompd and the app.
        .target(name: "IDETransport", dependencies: ["IDEProtocol"]),
        // Daemon internals: journal, manifest, supervisor, PTY pool, power observers.
        .target(
            name: "OmpdCore",
            dependencies: ["OmpRPC", "IDEProtocol", "IDETransport", .product(name: "SwiftTerm", package: "SwiftTerm")]
        ),
        .executableTarget(name: "ompd", dependencies: ["OmpdCore", "IDETransport"]),
        // App-side state (no AppKit/SwiftUI): daemon connection, session TUIs and terminals on ompd's PTYs.
        .target(name: "IDEModel", dependencies: ["IDETransport"]),
        // App-owned persistent state (no AppKit/SwiftUI): windows, tabs, editor positions and hot-exit dirty buffers in
        // `state.sqlite`.
        .target(name: "IDEState", dependencies: ["IDEProtocol", .product(name: "GRDB", package: "GRDB.swift")]),
        // Editor logic without AppKit/SwiftUI: text file I/O with content hashes, the
        // buffer state machine (dirty, save, revert, external change, hot-exit restore), line diffs, the file navigator's
        // directory listing and FSEvents watching.
        .target(name: "IDEEditorModel", dependencies: ["IDEState"]),

        .testTarget(name: "OmpRPCTests", dependencies: ["OmpRPC"], exclude: ["Fixtures"]),
        .testTarget(name: "IDEProtocolTests", dependencies: ["IDEProtocol"]),
        .testTarget(name: "IDETransportTests", dependencies: ["IDETransport"]),
        .testTarget(name: "OmpdCoreTests", dependencies: ["OmpdCore"]),
        .testTarget(name: "IDEModelTests", dependencies: ["IDEModel"]),
        .testTarget(name: "IDEStateTests", dependencies: ["IDEState", .product(name: "GRDB", package: "GRDB.swift")]),
        .testTarget(name: "IDEEditorModelTests", dependencies: ["IDEEditorModel", "IDEState"]),
    ],
    swiftLanguageModes: [.v6]
)
