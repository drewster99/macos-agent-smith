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
        // Local path dependency during development of the built-in providers / agent-centric
        // settings work. Revert to a versioned git dependency before release.
        .package(path: "../../swift-llm-kit"),
        // Local path dependency during the MLX embedding migration. Will switch to
        // a versioned git dependency on https://github.com/drewster99/swift-semantic-search
        // once the package is stable.
        .package(path: "../../swift-semantic-search"),
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
