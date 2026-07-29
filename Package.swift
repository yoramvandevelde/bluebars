// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "BlueBars",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "BlueBars",
            path: "Sources/BlueBars",
            linkerSettings: [
                .linkedFramework("CoreBluetooth"),
                .linkedFramework("AppKit"),
                .linkedFramework("ServiceManagement")
            ]
        )
    ]
)
