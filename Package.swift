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
        .executable(name: "ompd", targets: ["ompd"]),
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.2.0"),
    ],
    targets: [
        // omp `--mode rpc|rpc-ui` client: JSONL framing, v2 rpc_chunk reassembly, typed commands/events, process transport.
        .target(name: "OmpRPC"),
        // Daemon <-> UI wire contract (pure Codable types, shared by ompd and the app).
        .target(name: "IDEProtocol", dependencies: ["OmpRPC"]),
        // Length-prefixed frames over a unix domain socket (NWListener/NWConnection), used by ompd and the app.
        .target(name: "IDETransport", dependencies: ["IDEProtocol"]),
        // Daemon internals: journal, manifest, supervisor, PTY pool, power observers.
        .target(
            name: "OmpdCore",
            dependencies: ["OmpRPC", "IDEProtocol", "IDETransport", .product(name: "SwiftTerm", package: "SwiftTerm")]
        ),
        .executableTarget(name: "ompd", dependencies: ["OmpdCore"]),

        .testTarget(name: "OmpRPCTests", dependencies: ["OmpRPC"], exclude: ["Fixtures"]),
        .testTarget(name: "IDEProtocolTests", dependencies: ["IDEProtocol"]),
        .testTarget(name: "IDETransportTests", dependencies: ["IDETransport"]),
        .testTarget(name: "OmpdCoreTests", dependencies: ["OmpdCore"]),
    ],
    swiftLanguageModes: [.v6]
)
