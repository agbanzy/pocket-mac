// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PocketMacProbe",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../shared/PocketMacKit"),
    ],
    targets: [
        .executableTarget(
            name: "PocketMacProbe",
            dependencies: [.product(name: "PocketMacKit", package: "PocketMacKit")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
