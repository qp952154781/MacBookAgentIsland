// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentIsland",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "IslandCore", targets: ["IslandCore"]),
        .executable(name: "AgentIsland", targets: ["AgentIsland"])
    ],
    targets: [
        .target(name: "IslandCore", path: "Sources/IslandCore"),
        .executableTarget(name: "AgentIsland", dependencies: ["IslandCore"], path: "Sources/AgentIsland"),
        .testTarget(name: "IslandCoreTests", dependencies: ["IslandCore", "AgentIsland"], resources: [.copy("Fixtures")])
    ],
    swiftLanguageModes: [.v6]
)
