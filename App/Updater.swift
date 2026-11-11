import Foundation
import Sparkle

/// Sparkle 更新：只在用户点击"检查更新…"时联网。
@MainActor
final class Updater: NSObject, SPUUpdaterDelegate {
    static let shared = Updater()

    /// 开发测试时用 `defaults write com.mars.PeekBox PeekBoxFeedURL <地址>` 覆盖 Info.plist 中的 SUFeedURL
    nonisolated private static let feedOverrideKey = "PeekBoxFeedURL"

    private lazy var controller = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        UserDefaults.standard.string(forKey: Self.feedOverrideKey)
    }
}
