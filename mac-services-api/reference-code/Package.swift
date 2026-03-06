// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "mac-services-api",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "mac-services-api",
            path: "Sources",
            linkerSettings: [
                .linkedFramework("EventKit"),
                .linkedFramework("Contacts"),
                .linkedFramework("Network"),
                .linkedFramework("Security"),
            ]
        )
    ]
)
