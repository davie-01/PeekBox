import AppKit
import PeekCore

extension BrowserViewController {
    struct ZipDestination {
        let source: ArchiveSource
        let url: URL
        let parent: String
    }
    /// 一次拖动期间的写入检查结果（拖入 / 离开预览区时清空，见 resetDropChecks）。
    /// 不按时间过期：悬停较久后松手时若恰好过期，会重新检查并先返回"不可放入"，导致拖入失败
    enum DropWriteCheck {
        case checking
        case checked(String?)
    }

    func resetDropChecks() {
        dropWriteChecks.removeAll()
        statusLabel.stringValue = ""
    }

    /// 真实 ZIP 文件可作为根目标；压缩包里的压缩包没有真实 URL，始终拒绝写入。
    func zipDestination(for entry: Entry?) -> ZipDestination? {
        if let entry {
            if entry.isArchive {
                guard let url = entry.fileURL, let archive = source?.archiveSource(for: url) else { return nil }
                return ZipDestination(source: archive, url: url, parent: "")
            }
            guard let url = entry.archiveURL, let archive = source?.archiveSource(for: url) else { return nil }
            let path = ArchiveSource.archivePath(of: entry)
            return ZipDestination(source: archive, url: url,
                                  parent: entry.isDirectory ? path : path.split(separator: "/").dropLast().joined(separator: "/"))
        }
        if let currentParent { return zipDestination(for: currentParent) }
        guard let archive = source as? ArchiveSource else { return nil }
        return ZipDestination(source: archive, url: archive.rootURL, parent: "")
    }

    var directoryCreationTarget: ZipDestination? {
        let nodes = selectedNodes()
        let entry = nodes.count == 1 && nodes[0].entry.isDirectory ? nodes[0].entry : currentParent
        guard let target = zipDestination(for: entry), target.source.loadedReader is ZipArchive,
              target.source.loadedReader?.tree.hasEncryptedEntries != true else { return nil }
        return target
    }

    @objc func createArchiveFolder(_ sender: Any?) {
        guard !archiveWriteInProgress, let target = directoryCreationTarget else { return }
        archiveWriteInProgress = true
        Task {
            defer { archiveWriteInProgress = false; updateToolbarState() }
            do {
                guard let path = try await BrokerClient.shared.createArchiveDirectory(target.url, parent: target.parent) else { return }
                target.source.invalidate()
                pendingSelectionID = ArchiveSource.entryID(for: path)
                flash(String(localized: "已新建文件夹", bundle: .peekUI))
                reload()
            } catch { flash(error.localizedDescription) }
        }
    }

    private func droppedURLs(_ info: any NSDraggingInfo) -> [URL] {
        // File Promise 只有实际放下后才有数据，首版仅接受真实文件 URL。
        let source = info.draggingSource as AnyObject?
        guard source !== outlineView, source !== collectionView,
              let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]) as? [URL] else { return [] }
        return urls.filter(\.isFileURL)
    }

    private func validateImport(_ info: any NSDraggingInfo, target: ZipDestination?) -> NSDragOperation {
        guard !archiveWriteInProgress, !droppedURLs(info).isEmpty else { return [] }
        guard let target else {
            statusLabel.stringValue = String(localized: "只能拖入真实 ZIP 压缩包，嵌套压缩包只读", bundle: .peekUI)
            return []
        }
        // 本次拖动中已有结论（包括打开失败）就直接使用，不重复解析
        if case .checked(let message?) = dropWriteChecks[target.url] {
            statusLabel.stringValue = message
            return []
        }
        guard let reader = target.source.loadedReader else {
            // 7z、RAR 等只读格式只看签名就拒绝，不为悬停而完整解析整个压缩包
            guard ArchiveSource.looksLikeZip(target.url) else {
                statusLabel.stringValue = String(localized: "此压缩包只读，不支持拖入", bundle: .peekUI)
                return []
            }
            if !loadingDropArchives.contains(target.url) {
                loadingDropArchives.insert(target.url)
                Task {
                    do {
                        _ = try await target.source.reader()
                    } catch {
                        // 记住失败原因，本次拖动内不再重试
                        dropWriteChecks[target.url] = .checked(error.localizedDescription)
                    }
                    loadingDropArchives.remove(target.url)
                }
            }
            statusLabel.stringValue = String(localized: "正在检查压缩包…", bundle: .peekUI)
            return []
        }
        guard reader is ZipArchive else {
            statusLabel.stringValue = String(localized: "此压缩包只读，不支持拖入", bundle: .peekUI)
            return []
        }
        if case .checked(let message) = dropWriteChecks[target.url] {
            if let message { statusLabel.stringValue = message; return [] }
            let path = target.parent.isEmpty ? "/" : "/" + target.parent + "/"
            statusLabel.stringValue = String(localized: "复制到 \(target.url.lastPathComponent) 内的 \(path)", bundle: .peekUI)
            return .copy
        }
        if case .checking = dropWriteChecks[target.url] { return [] }
        dropWriteChecks[target.url] = .checking
        Task {
            do {
                let message = try await BrokerClient.shared.archiveWriteStatus(target.url)
                dropWriteChecks[target.url] = .checked(message)
            } catch { dropWriteChecks[target.url] = .checked(error.localizedDescription) }
        }
        statusLabel.stringValue = String(localized: "正在检查写入权限…", bundle: .peekUI)
        return []
    }

    private func acceptImport(_ info: any NSDraggingInfo, target: ZipDestination?) -> Bool {
        guard let target, validateImport(info, target: target) == .copy else { return false }
        let urls = droppedURLs(info)
        guard !urls.isEmpty else { return false }
        archiveWriteInProgress = true
        flash(String(localized: "正在向 ZIP 复制文件…", bundle: .peekUI))
        Task {
            defer { archiveWriteInProgress = false; dropWriteChecks.removeAll(); updateToolbarState() }
            do {
                guard let summary = try await BrokerClient.shared.addToArchive(target.url, sources: urls, parent: target.parent) else {
                    flash(String(localized: "已取消，压缩包未改动", bundle: .peekUI))
                    return
                }
                flash(Self.importMessage(summary))
                // 全部跳过时压缩包没有变化，不必重新读取
                if summary.added + summary.replaced > 0 {
                    target.source.invalidate()
                    reload()
                }
            } catch { flash(error.localizedDescription) }
        }
        return true
    }

    /// 按实际结果描述导入：新增 / 替换 / 跳过分别计数（按拖入的顶层项目）
    static func importMessage(_ summary: ZipEditor.ImportSummary) -> String {
        var parts: [String] = []
        if summary.added > 0 { parts.append(String(localized: "已复制 \(summary.added) 项", bundle: .peekUI)) }
        if summary.replaced > 0 { parts.append(String(localized: "已替换 \(summary.replaced) 项", bundle: .peekUI)) }
        if summary.skipped > 0 { parts.append(String(localized: "跳过 \(summary.skipped) 项", bundle: .peekUI)) }
        if summary.added + summary.replaced == 0 { return String(localized: "已跳过，压缩包未改动", bundle: .peekUI) }
        return parts.joined(separator: String(localized: "，", bundle: .peekUI))
    }

    public func outlineView(_ outlineView: NSOutlineView, validateDrop info: any NSDraggingInfo,
                            proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        let node = item as? BrowserNode
        if isInternalDrag(info) {
            let operation = validateCopyToFolder(onto: node?.entry)
            if operation == .copy { outlineView.setDropItem(node, dropChildIndex: NSOutlineViewDropOnItemIndex) }
            return operation
        }
        let target = zipDestination(for: node?.entry)
        let operation = validateImport(info, target: target)
        if operation == .copy { outlineView.setDropItem(node, dropChildIndex: NSOutlineViewDropOnItemIndex) }
        return operation
    }

    public func outlineView(_ outlineView: NSOutlineView, acceptDrop info: any NSDraggingInfo,
                            item: Any?, childIndex: Int) -> Bool {
        if isInternalDrag(info) { return acceptCopyToFolder(onto: (item as? BrowserNode)?.entry) }
        return acceptImport(info, target: zipDestination(for: (item as? BrowserNode)?.entry))
    }

    public func collectionView(_ collectionView: NSCollectionView, validateDrop info: any NSDraggingInfo,
                                proposedIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
                                dropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>) -> NSDragOperation {
        let point = collectionView.convert(info.draggingLocation, from: nil)
        let path = collectionView.indexPathForItem(at: point)
        let entry = path.flatMap { $0.item < roots.count ? roots[$0.item].entry : nil }
        if isInternalDrag(info) {
            let operation = validateCopyToFolder(onto: entry)
            if operation == .copy, let path { proposedIndexPath.pointee = path as NSIndexPath; dropOperation.pointee = .on }
            return operation
        }
        let operation = validateImport(info, target: zipDestination(for: entry))
        if operation == .copy {
            if let path { proposedIndexPath.pointee = path as NSIndexPath; dropOperation.pointee = .on }
            else { proposedIndexPath.pointee = IndexPath(item: roots.count, section: 0) as NSIndexPath; dropOperation.pointee = .before }
        }
        return operation
    }

    public func collectionView(_ collectionView: NSCollectionView, acceptDrop info: any NSDraggingInfo,
                                indexPath: IndexPath, dropOperation: NSCollectionView.DropOperation) -> Bool {
        let entry = dropOperation == .on && indexPath.item < roots.count ? roots[indexPath.item].entry : nil
        if isInternalDrag(info) { return acceptCopyToFolder(onto: entry) }
        return acceptImport(info, target: zipDestination(for: entry))
    }
}
