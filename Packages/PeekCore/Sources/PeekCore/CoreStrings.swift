import Foundation

/// PeekCore 文案所在的资源包。
/// 不用 SwiftPM 生成的 Bundle.module：后台服务是命令行工具，没有嵌入 PeekCore 的资源包，
/// Bundle.module 找不到时会直接 fatalError。这里找不到就退回主包（显示源语言文案）。
enum CoreStrings {
    private final class Marker {}

    /// 按界面语言设置选出的资源包
    static var bundle: Bundle { Localization.bundle(base) }

    private static let base: Bundle = {
        let name = "PeekCore_PeekCore.bundle"
        let candidates = [
            Bundle.main.resourceURL,
            Bundle(for: Marker.self).resourceURL,
            // 扩展与命令行工具：向上找所在主应用的 Resources
            Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources"),
            Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("Resources"),
        ]
        for case let directory? in candidates {
            if let bundle = Bundle(url: directory.appendingPathComponent(name)) { return bundle }
        }
        return .main
    }()
}
