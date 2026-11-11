import Foundation
import PeekCore

/// NSOutlineView 的 item 必须是引用类型且身份稳定，故包一层。
@MainActor
final class BrowserNode {
    let entry: Entry
    /// nil 表示尚未加载；展开时才枚举。
    var children: [BrowserNode]?

    init(entry: Entry) {
        self.entry = entry
    }
}
