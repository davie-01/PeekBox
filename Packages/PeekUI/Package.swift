// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PeekUI",
    defaultLocalization: "en",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "PeekUI", targets: ["PeekUI"])
    ],
    dependencies: [
        .package(path: "../PeekCore")
    ],
    targets: [
        .target(name: "PeekUI", dependencies: ["PeekCore"], resources: [.process("Resources")])
    ]
)
