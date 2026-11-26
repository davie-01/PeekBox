// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PeekCore",
    defaultLocalization: "en",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "PeekCore", targets: ["PeekCore"])
    ],
    targets: [
        // 以下由 Scripts/build-libzip.sh、Scripts/build-xadmaster.sh、Scripts/build-7zip.sh 生成，不提交仓库
        .binaryTarget(name: "CLibzip", path: "Vendor/libzip.xcframework"),
        .binaryTarget(name: "CSevenZip", path: "Vendor/CSevenZip.xcframework"),
        .binaryTarget(name: "XADMaster", path: "Vendor/XADMaster.xcframework"),
        .binaryTarget(name: "UniversalDetector", path: "Vendor/UniversalDetector.xcframework"),
        .target(name: "PeekCore", dependencies: ["CLibzip", "CSevenZip", "XADMaster", "UniversalDetector"],
                resources: [.process("Resources")]),
        // Fixtures：libarchive 测试集中的 RAR 样本（文件名加密，密码 password），本机无法生成 RAR
        .testTarget(name: "PeekCoreTests", dependencies: ["PeekCore"], resources: [.copy("Fixtures")])
    ]
)
