// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "iosgpsspoof",
    // iOS is only for the RemoteAPI and PhoneOnlyCore libraries, which the
    // SpoofRemote iPhone app (iPhoneRemote/) links; everything else is macOS-only.
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .executable(name: "iosgpsspoof", targets: ["iosgpsspoof"]),
        .executable(name: "iosgpsspoofer-gui", targets: ["iosgpsspooferGUI"]),
        .library(name: "RemoteAPI", targets: ["RemoteAPI"]),
        .library(name: "PhoneOnlyCore", targets: ["PhoneOnlyCore"]),
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
        // The iPhone-only mode's rules that need no iPhone: the pairing file's
        // format, which tunnel to try, what an error means. The Mac writes the
        // file and SpoofRemote reads it, so both link this.
        .target(
            name: "PhoneOnlyCore"
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
            name: "PhoneOnlyCoreTests",
            dependencies: ["PhoneOnlyCore"]
        ),
        .testTarget(
            name: "SpooferRemoteTests",
            dependencies: ["SpooferRemote", "RemoteAPI"]
        ),
    ]
)
