// swift-tools-version:5.10
import PackageDescription

var packageDependencies: [Package.Dependency] = [
    .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0")
]
var coreDependencies: [Target.Dependency] = [.product(name: "Crypto", package: "swift-crypto")]
#if !os(Windows)
packageDependencies.append(.package(url: "https://github.com/groue/GRDB.swift.git", from: "6.0.0"))
coreDependencies.append(.product(name: "GRDB", package: "GRDB.swift"))
#endif

let package = Package(
    name: "DengueCaptureCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "DengueCaptureCore", targets: ["DengueCaptureCore"])
    ],
    dependencies: packageDependencies,
    targets: [
        .target(
            name: "DengueCaptureCore",
            dependencies: coreDependencies
        ),
        .testTarget(name: "DengueCaptureCoreTests", dependencies: ["DengueCaptureCore"])
    ]
)
