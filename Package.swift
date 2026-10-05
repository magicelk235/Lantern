// swift-tools-version: 6.0
import PackageDescription

/// The daemon's own code is optimized for size in release builds; Debug is unchanged.
let daemonSwiftSettings: [SwiftSetting] = [.unsafeFlags(["-Osize"], .when(configuration: .release))]

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
        .library(name: "IDELanguageModel", targets: ["IDELanguageModel"]),
        .executable(name: "ompd", targets: ["ompd"]),
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.2.0"),
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
        // The editor's language servers: ChimeHQ's LSP client, the protocol types and JSON-RPC it is
        // built on. Exact: the client's few releases change API between minor versions.
        .package(url: "https://github.com/ChimeHQ/LanguageClient", exact: "0.8.2"),
        .package(url: "https://github.com/ChimeHQ/LanguageServerProtocol", exact: "0.14.2"),
        .package(url: "https://github.com/ChimeHQ/JSONRPC", exact: "0.9.2"),
    ],
    targets: [
        // Daemon <-> UI wire contract (pure Codable types, shared by ompd and the app).
        .target(name: "IDEProtocol"),
        // Length-prefixed frames over a unix domain socket (NWListener/NWConnection), used by ompd and the app.
        .target(name: "IDETransport", dependencies: ["IDEProtocol"]),
        // Daemon internals: manifest, session supervisors (omp TUIs in PTYs), PTY pool, ide-bridge server, power observers.
        .target(
            name: "OmpdCore",
            dependencies: ["IDEProtocol", "IDETransport", .product(name: "SwiftTerm", package: "SwiftTerm")],
            swiftSettings: daemonSwiftSettings
        ),
        .executableTarget(name: "ompd", dependencies: ["OmpdCore", "IDETransport"], swiftSettings: daemonSwiftSettings),
        // App-side state (no AppKit/SwiftUI): daemon connection, session TUIs and terminals on ompd's PTYs.
        .target(name: "IDEModel", dependencies: ["IDETransport"]),
        // App-owned persistent state (no AppKit/SwiftUI): windows, tabs, editor positions and hot-exit dirty buffers in
        // `state.sqlite`.
        .target(name: "IDEState", dependencies: ["IDEProtocol", .product(name: "GRDB", package: "GRDB.swift")]),
        // Editor logic without AppKit/SwiftUI: text file I/O with content hashes, the
        // buffer state machine (dirty, save, revert, external change, hot-exit restore), line diffs, the file navigator's
        // directory listing and FSEvents watching.
        .target(name: "IDEEditorModel", dependencies: ["IDEState"]),
        // Language servers for the editor without AppKit/SwiftUI: which server takes a file and where it
        // is found on the login shell's PATH, one server process per project and language (LanguageClient over a pipe),
        // document sync in UTF-16 positions, and diagnostics, hover, definitions and completions as the editor shows them.
        .target(
            name: "IDELanguageModel",
            dependencies: [
                .product(name: "LanguageClient", package: "LanguageClient"),
                .product(name: "LanguageServerProtocol", package: "LanguageServerProtocol"),
                .product(name: "JSONRPC", package: "JSONRPC"),
            ]
        ),

        .testTarget(name: "IDEProtocolTests", dependencies: ["IDEProtocol"]),
        .testTarget(name: "IDETransportTests", dependencies: ["IDETransport"]),
        .testTarget(name: "OmpdCoreTests", dependencies: ["OmpdCore"]),
        .testTarget(name: "IDEModelTests", dependencies: ["IDEModel"]),
        .testTarget(name: "IDEStateTests", dependencies: ["IDEState", .product(name: "GRDB", package: "GRDB.swift")]),
        .testTarget(name: "IDEEditorModelTests", dependencies: ["IDEEditorModel", "IDEState"]),
        .testTarget(
            name: "IDELanguageModelTests",
            dependencies: ["IDELanguageModel", .product(name: "LanguageServerProtocol", package: "LanguageServerProtocol")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
