// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "iosgpsspoof",
    // iOS is only for the RemoteAPI library, which the SpoofRemote iPhone app
    // (iPhoneRemote/) links; everything else is macOS-only.
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .executable(name: "iosgpsspoof", targets: ["iosgpsspoof"]),
        .executable(name: "iosgpsspoofer-gui", targets: ["iosgpsspooferGUI"]),
        .library(name: "RemoteAPI", targets: ["RemoteAPI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "SpooferCore"
        ),
        .target(
            name: "RemoteAPI"
        ),
        .target(
            name: "SpooferRemote",
            dependencies: ["SpooferCore", "RemoteAPI"]
        ),
        .executableTarget(
            name: "iosgpsspoof",
            dependencies: [
                "SpooferCore",
                "SpooferRemote",
                "RemoteAPI",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .executableTarget(
            name: "iosgpsspooferGUI",
            dependencies: ["SpooferCore", "SpooferRemote", "RemoteAPI"],
            path: "Sources/iosgpsspoofer-gui"
        ),
        .testTarget(
            name: "SpooferCoreTests",
            dependencies: ["SpooferCore"]
        ),
        .testTarget(
            name: "SpooferRemoteTests",
            dependencies: ["SpooferRemote", "RemoteAPI", "SpooferCore"]
        ),
    ]
)
