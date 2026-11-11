import AppKit

/// 预览内的列表
final class PreviewOutlineView: NSOutlineView {
    /// 拖入 / 离开时通知控制器清空本次拖动的写入检查
    var onDraggingBoundary: (() -> Void)?
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        onDraggingBoundary?()
        return super.draggingEntered(sender)
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        super.draggingExited(sender)
        onDraggingBoundary?()
    }

    /// 不经窗口激活直接处理点击
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// 每次右键时新建菜单（参考 Folder Preview Pro 的 menuForEvent:），不在菜单跟踪期间修改同一菜单对象
    var contextMenuProvider: ((NSEvent) -> NSMenu?)?

    /// 右键点在未选中的行上时先选中该行，点在已选中的行上保持多选；点在空白处清除选择。
    /// 不调用 super：没有设置 menu 属性时 super 会清除 clickedRow，后续操作就拿不到对象
    override func menu(for event: NSEvent) -> NSMenu? {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        if row < 0 {
            deselectAll(nil)
        } else if !selectedRowIndexes.contains(row) {
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        return contextMenuProvider?(event)
    }
}

/// 工具栏按钮：同样接受首次点击
/// 预览收不到键盘输入，按钮不接收焦点：否则弹出框关闭后焦点按 Tab 顺序落到第一个按钮上，出现焦点环
final class PreviewToolbarButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { false }
}

final class PreviewPopUpButton: NSPopUpButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { false }
}
