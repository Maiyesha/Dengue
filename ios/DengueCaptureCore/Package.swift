// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "DengueCaptureCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "DengueCaptureCore", targets: ["DengueCaptureCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0")
    ],
    targets: [
        .target(
            name: "DengueCaptureCore",
            dependencies: [.product(name: "Crypto", package: "swift-crypto")]
        ),
        .testTarget(name: "DengueCaptureCoreTests", dependencies: ["DengueCaptureCore"])
    ]
)
