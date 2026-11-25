// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Saguru",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "saguru", path: "Sources/saguru"),
    ]
)
