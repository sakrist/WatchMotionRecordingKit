// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WatchMotionRecordingKit",
    platforms: [
        .iOS(.v18),
        .watchOS(.v11),
        .macOS(.v15),
    ],
    products: [
        .library(
            name: "WatchMotionRecordingKit",
            targets: ["WatchMotionRecordingKit"]
        ),
    ],
    targets: [
        .target(
            name: "WatchMotionRecordingKit"
        ),
        .testTarget(
            name: "WatchMotionRecordingKitTests",
            dependencies: ["WatchMotionRecordingKit"]
        ),
    ]
)
