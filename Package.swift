// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "health-monitor",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "health-monitor",
            path: "Sources/health-monitor"
        )
    ]
)
