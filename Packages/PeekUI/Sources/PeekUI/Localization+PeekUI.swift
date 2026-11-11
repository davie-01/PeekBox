import Foundation
import PeekCore

extension Bundle {
    /// PeekUI 文案所在的资源包，按界面语言设置选择（见 PeekCore.Localization）
    static var peekUI: Bundle { Localization.bundle(.module) }
}
