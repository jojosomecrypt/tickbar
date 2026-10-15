// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "TickBar",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "TickBar", path: "Sources/TickBar")
    ]
)
