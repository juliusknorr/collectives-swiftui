// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Collectives",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "CollectivesCore", targets: ["CollectivesCore"]),
        .executable(name: "Collectives", targets: ["CollectivesApp"])
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-markdown.git", exact: "0.6.0")
    ],
    targets: [
        .target(name: "CollectivesCore", dependencies: [.product(name: "Markdown", package: "swift-markdown")]),
        .executableTarget(name: "CollectivesApp", dependencies: ["CollectivesCore"]),
        .testTarget(name: "CollectivesCoreTests", dependencies: ["CollectivesCore"])
    ]
)
