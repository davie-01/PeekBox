import AppKit
import QuickLookUI
import os
import PeekCore
import PeekUI

final class PreviewViewController: NSViewController, QLPreviewingController {
    private let browser = BrowserViewController(mode: .folder)

    /// 固定的预览尺寸（等于 Quick Look 默认尺寸）。参考 Dirscope / PeekX / espia：根视图以非零尺寸创建，
    /// preferredContentSize 始终返回同一值；尺寸一旦改变，宿主与远程视图几何不一致，预览会无法点击
    private static let contentSize = NSSize(width: 800, height: 600)

    override var preferredContentSize: NSSize {
        get { Self.contentSize }
        set { super.preferredContentSize = Self.contentSize }
    }

    override func loadView() {
        let root = NSView(frame: NSRect(origin: .zero, size: Self.contentSize))
        addChild(browser)
        browser.view.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(browser.view)
        NSLayoutConstraint.activate([
            browser.view.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            browser.view.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            browser.view.topAnchor.constraint(equalTo: root.topAnchor),
            browser.view.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
    }

    func preparePreviewOfFile(at url: URL) async throws {
        Logger.peek("FolderPreview").notice("prepare \(url.path, privacy: .public)")
        browser.load(source: FolderSource(rootURL: url, showHidden: PeekPreferences.showHiddenFiles))
    }
}
