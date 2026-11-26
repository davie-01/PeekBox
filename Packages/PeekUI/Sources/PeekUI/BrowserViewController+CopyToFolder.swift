import AppKit
import PeekCore

/// 在预览内把条目拖到镜像里指向真实文件夹的替身上（安装盘里把 App 拖到"应用程序"），与 Finder 挂载后操作一致。
/// 镜像只读，拖到其他条目上不响应。拷贝由后台服务完成（扩展在沙盒中写不了目标文件夹），见 ArchiveCopier
extension BrowserViewController {
    /// 拖出的条目以 File Promise 写入剪贴板；登记这些类型，拖回本预览时才会收到 validateDrop
    static var internalDragTypes: [NSPasteboard.PasteboardType] {
        NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
    }

    func isInternalDrag(_ info: any NSDraggingInfo) -> Bool {
        guard let source = info.draggingSource as? NSView else { return false }
        return (source === outlineView || source === collectionView) && !internalDragEntries.isEmpty
    }

    /// 替身指向的真实文件夹（绝对路径）；其他条目返回 nil
    func copyDestination(of entry: Entry?) -> URL? {
        guard let entry, entry.isSymlink, entry.archiveURL != nil,
              let target = entry.linkTarget, target.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: target, isDirectory: true)
    }

    func validateCopyToFolder(onto entry: Entry?) -> NSDragOperation {
        guard let entry, let destination = copyDestination(of: entry) else {
            statusLabel.stringValue = ""
            return []
        }
        let dragged = internalDragEntries.filter { $0.id != entry.id }
        guard !dragged.isEmpty, Set(dragged.map(\.archiveURL)) == [entry.archiveURL] else { return [] }
        let folder = FileManager.default.displayName(atPath: destination.path)
        statusLabel.stringValue = String(localized: "松开后拷贝到“\(folder)”", bundle: .peekUI)
        return .copy
    }

    func acceptCopyToFolder(onto entry: Entry?) -> Bool {
        guard validateCopyToFolder(onto: entry) == .copy, let entry, let destination = copyDestination(of: entry),
              let archiveURL = entry.archiveURL, let archive = source?.archiveSource(for: archiveURL) else { return false }
        let dragged = internalDragEntries.filter { $0.id != entry.id }
        let folder = FileManager.default.displayName(atPath: destination.path)
        flash(String(localized: "正在拷贝到“\(folder)”…", bundle: .peekUI))
        Task {
            do {
                guard let summary = try await BrokerClient.shared.copyFromArchive(
                    archiveURL, entryPaths: dragged.map(ArchiveSource.archivePath(of:)), to: destination,
                    password: archive.password) else {
                    flash(String(localized: "已取消拷贝", bundle: .peekUI))
                    return
                }
                if summary.added + summary.replaced == 0 {
                    flash(String(localized: "已跳过，未拷贝任何项目", bundle: .peekUI))
                } else {
                    flash(String(localized: "已拷贝到“\(folder)”", bundle: .peekUI))
                }
            } catch {
                flash(String(localized: "拷贝失败：\(error.localizedDescription)", bundle: .peekUI))
            }
        }
        return true
    }

    // MARK: - 记录拖出的条目

    public func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession,
                            willBeginAt screenPoint: NSPoint, forItems draggedItems: [Any]) {
        internalDragEntries = draggedItems.compactMap { ($0 as? BrowserNode)?.entry }
    }

    public func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession,
                            endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        internalDragEntries = []
    }

    public func collectionView(_ collectionView: NSCollectionView, draggingSession session: NSDraggingSession,
                               willBeginAt screenPoint: NSPoint, forItemsAt indexPaths: Set<IndexPath>) {
        internalDragEntries = indexPaths.compactMap { $0.item < roots.count ? roots[$0.item].entry : nil }
    }

    public func collectionView(_ collectionView: NSCollectionView, draggingSession session: NSDraggingSession,
                               endedAt screenPoint: NSPoint, dragOperation operation: NSDragOperation) {
        internalDragEntries = []
    }
}
