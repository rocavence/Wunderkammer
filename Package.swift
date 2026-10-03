// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "Wunderkammer",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "Wunderkammer",
            path: "Sources/Wunderkammer"
        ),
        .testTarget(
            name: "WunderkammerTests",
            dependencies: ["Wunderkammer"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
