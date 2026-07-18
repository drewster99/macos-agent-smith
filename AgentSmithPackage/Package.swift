// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "AgentSmithPackage",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "AgentSmithKit", targets: ["AgentSmithKit"])
    ],
    dependencies: [
        // Providers, model configs, and Keychain-backed API key storage. Breaking changes
        // ship as patch releases on this 0.0.x line, so a floor (not an open range) is what
        // keeps an out-of-date checkout from satisfying the build. Package.resolved locks the
        // exact commit for reproducible clones.
        .package(url: "https://github.com/drewster99/swift-llm-kit.git", from: "0.0.90"),
        // On-device semantic memory (MLX embeddings). 0.0.1 last-token pooling; 0.0.2 identifier
        // encodes the pooling scheme (re-embed detection); 0.0.3 pooling is a declared per-model
        // property + load-phase timing. See the package CHANGELOG. Package.resolved locks the commit.
        .package(url: "https://github.com/drewster99/swift-semantic-search.git", from: "0.0.3"),
        // Official Model Context Protocol Swift SDK. Provides the MCP client used to
        // talk to user-configured stdio MCP servers.
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk", .upToNextMinor(from: "0.12.1"))
    ],
    targets: [
        .target(
            name: "AgentSmithKit",
            dependencies: [
                .product(name: "SwiftLLMKit", package: "swift-llm-kit"),
                .product(name: "SemanticSearch", package: "swift-semantic-search"),
                .product(name: "MCP", package: "swift-sdk")
            ],
            path: "Sources/AgentSmithKit"
        ),
        .testTarget(
            name: "AgentSmithTests",
            dependencies: ["AgentSmithKit"],
            path: "Tests/AgentSmithTests"
        )
    ]
)
