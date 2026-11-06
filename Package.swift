// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Collectives",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "CollectivesCore", targets: ["CollectivesCore"]),
        .executable(name: "Collectives", targets: ["CollectivesApp"]),
        .executable(name: "TextCollaborationSmoke", targets: ["TextCollaborationSmoke"])
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-markdown.git", exact: "0.6.0")
    ],
    targets: [
        .target(name: "CollectivesCore", dependencies: [.product(name: "Markdown", package: "swift-markdown")]),
        .executableTarget(name: "CollectivesApp", dependencies: ["CollectivesCore"]),
        .executableTarget(name: "TextCollaborationSmoke", dependencies: ["CollectivesCore"],
                          path: "dev/text-collaboration",
                          exclude: ["README.md", "build.py", "compose.yaml", "run.sh", "runtime.mjs", "text.lock.json", "test_build.py"],
                          sources: ["Smoke.swift"]),
        .testTarget(name: "CollectivesCoreTests", dependencies: ["CollectivesCore"]),
        .testTarget(name: "CollectivesAppTests", dependencies: ["CollectivesApp"])
    ]
)
