// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "DengueCaptureCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "DengueCaptureCore", targets: ["DengueCaptureCore"])
    ],
    targets: [
        .target(name: "DengueCaptureCore"),
        .testTarget(name: "DengueCaptureCoreTests", dependencies: ["DengueCaptureCore"])
    ]
)
