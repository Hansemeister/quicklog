// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "quicklog",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "quicklog",
            path: "Sources/quicklog",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
