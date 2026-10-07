// swift-tools-version:6.0

import PackageDescription

// SwiftTerm v1.20.0's library target only: no tests, tools, samples or docs. `SwiftTermBuildInfo.swift` stands in
// for the build plugin that generated it from git.
let package = Package(
    name: "SwiftTerm",
    platforms: [
        .iOS(.v14),
        .macOS(.v11),
        .tvOS(.v13),
        .visionOS(.v1)
    ],
    products: [
        .library(name: "SwiftTerm", targets: ["SwiftTerm"])
    ],
    targets: [
        .target(
            name: "SwiftTerm",
            path: "Sources/SwiftTerm",
            resources: [
                .process("Apple/Metal/Shaders.metal")
            ]
        )
    ],
    swiftLanguageModes: [.v5]
)
