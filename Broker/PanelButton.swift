import AppKit

/// 后台服务面板里的按钮。面板不激活应用（Finder 仍在前台），面板本身也往往不是当前窗口：
/// 系统按钮默认把第一次点击用来激活窗口而不触发动作，要点第二下才有反应（如写入中点"取消"像没反应）
final class PanelButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
