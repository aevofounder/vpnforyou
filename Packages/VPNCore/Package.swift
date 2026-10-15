// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VPNCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "VPNCore", targets: ["VPNCore"]),
        .library(name: "VPNHelperCore", targets: ["VPNHelperCore"]),
        .executable(name: "vpnforyou-helper", targets: ["VPNHelper"]),
    ],
    targets: [
        // Logic: Foundation only, builds and tests on Linux.
        .target(name: "VPNCore"),
        // Privileged helper: Unix socket and the mihomo process (Foundation + libc).
        .target(name: "VPNHelperCore", dependencies: ["VPNCore"]),
        .executableTarget(name: "VPNHelper", dependencies: ["VPNCore", "VPNHelperCore"]),
        .testTarget(name: "VPNCoreTests", dependencies: ["VPNCore"]),
        .testTarget(name: "VPNHelperCoreTests", dependencies: ["VPNCore", "VPNHelperCore"]),
    ]
)
