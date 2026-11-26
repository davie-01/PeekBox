import AppKit
import ObjectiveC

/// PeekBox 的界面一律不画蓝色焦点环（开启"键盘导航"后，按钮、复选框等也会取得焦点并画出焦点环）。
/// 在窗口层统一处理，而不是逐个控件设置 focusRingType：窗口中以后新增的控件同样生效。
/// - 后台服务的对话框面板：`DialogPanel.make()` 创建的面板在控件成为第一响应者时处理
/// - 预览内的弹出框：`makePopover(_:)` 创建的弹出框显示时对其窗口调用 `suppress(in:)`
/// - 设置窗口（SwiftUI）：在根视图使用 `.focusEffectDisabled()`，见 App/PeekBoxApp.swift
@MainActor
public enum FocusRing {
    private static let observationKey = UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1)

    /// 窗口内任何视图成为第一响应者时都不画焦点环。对同一窗口重复调用无副作用；观察随窗口释放
    public static func suppress(in window: NSWindow) {
        guard objc_getAssociatedObject(window, observationKey) == nil else { return }
        hide(window.firstResponder)
        let observation = window.observe(\.firstResponder, options: [.new]) { window, _ in
            MainActor.assumeIsolated { hide(window.firstResponder) }
        }
        objc_setAssociatedObject(window, observationKey, observation, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    /// 让成为第一响应者的视图不画焦点环
    static func hide(_ responder: NSResponder?) {
        guard var view = responder as? NSView else { return }
        // 输入框编辑时第一响应者是共用的字段编辑器，焦点环画在输入框本身上
        if let editor = view as? NSTextView, editor.isFieldEditor, let field = editor.delegate as? NSView {
            view = field
        }
        guard view.focusRingType != .none else { return }
        view.focusRingType = .none
        view.noteFocusRingMaskChanged()
    }
}

/// 对话框面板：控件在成为第一响应者之前就设为不画焦点环，不会闪现
class FocusRinglessPanel: NSPanel {
    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        FocusRing.hide(responder)
        return super.makeFirstResponder(responder)
    }
}
