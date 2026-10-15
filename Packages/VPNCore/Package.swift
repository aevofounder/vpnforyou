// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VPNCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "VPNCore", targets: ["VPNCore"]),
    ],
    targets: [
        .target(name: "VPNCore"),
        .testTarget(name: "VPNCoreTests", dependencies: ["VPNCore"]),
    ]
)
