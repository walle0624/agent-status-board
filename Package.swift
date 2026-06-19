// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "AgentStatusBoard",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "AgentStatusBoard", targets: ["AgentStatusBoard"])
    ],
    targets: [
        .executableTarget(
            name: "AgentStatusBoard",
            path: "Sources/AgentStatusBoard"
        ),
        .testTarget(
            name: "AgentStatusBoardTests",
            dependencies: ["AgentStatusBoard"],
            path: "Tests/AgentStatusBoardTests"
        )
    ]
)
