// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DeadboltCore",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "DeadboltCore", targets: ["DeadboltCore"]),
    ],
    dependencies: [
        // Argon2id only. Everything else is CryptoKit.
        .package(url: "https://github.com/jedisct1/swift-sodium.git", exact: "0.11.0"),
    ],
    targets: [
        .target(
            name: "DeadboltCore",
            dependencies: [.product(name: "Sodium", package: "swift-sodium")],
            resources: [.copy("Resources/bip39-english.txt")]
        ),
        .testTarget(name: "DeadboltCoreTests", dependencies: ["DeadboltCore"]),
    ]
)
