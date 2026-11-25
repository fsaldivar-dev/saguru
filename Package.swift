// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Simuru",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "simuru", path: "Sources/simuru"),
    ]
)
