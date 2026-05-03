// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HurleyRecordingKit",
    platforms: [
        .iOS(.v18),
        .watchOS(.v11),
        .macOS(.v15),
    ],
    products: [
        .library(
            name: "HurleyRecordingKit",
            targets: ["HurleyRecordingKit"]
        ),
    ],
    targets: [
        .target(
            name: "HurleyRecordingKit"
        ),
        .testTarget(
            name: "HurleyRecordingKitTests",
            dependencies: ["HurleyRecordingKit"]
        ),
    ]
)
