// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PocketMacKit",
    platforms: [
        // Floors kept conservative so the package builds from the CLI on this host.
        // Each app project pins the real deployment target (iOS 26.5 / macOS 26.5).
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "PocketMacKit", targets: ["PocketMacKit"]),
    ],
    targets: [
        .target(
            name: "PocketMacKit",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "PocketMacKitTests",
            dependencies: ["PocketMacKit"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
