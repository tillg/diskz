// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "diskz",
    platforms: [.macOS("27.0")],
    targets: [
        .target(name: "DiskzCore"),
        .executableTarget(name: "diskz", dependencies: ["DiskzCore"]),
        .testTarget(
            name: "DiskzCoreTests",
            dependencies: ["DiskzCore"],
            // Without Xcode, SwiftPM only sometimes passes the Swift Testing macro plugin path
            // ("plugin for module 'TestingMacros' not found"), so name it explicitly.
            swiftSettings: [.unsafeFlags([
                "-plugin-path", "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing",
            ])]),
    ]
)
