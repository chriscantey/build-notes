// swift-tools-version:5.5
import PackageDescription

let package = Package(
    name: "voice-client",
    platforms: [
        .macOS(.v12)
    ],
    targets: [
        .executableTarget(
            name: "voice-client",
            path: "Sources"
        )
    ]
)
