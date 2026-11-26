import AppKit
import PeekCore
import UniformTypeIdentifiers

/// 归档条目的图标：应用包显示包内自带的图标，符号链接显示目标的图标并加替身角标（与 Finder 挂载后一致）
extension BrowserViewController {
    /// 按名称推断的类型图标；包（.app 等）按目录类型取图标
    func typeIcon(name: String, isDirectory: Bool) -> NSImage {
        let ext = (name as NSString).pathExtension
        let type: UTType
        if isDirectory {
            type = ArchiveSource.isPackageName(name)
                ? UTType(filenameExtension: ext, conformingTo: .directory) ?? .folder
                : .folder
        } else {
            type = UTType(filenameExtension: ext) ?? .data
        }
        return NSWorkspace.shared.icon(for: type)
    }

    /// 已读到的包图标；尚未读取时在后台开始读取，先返回 nil（显示类型图标），读完后刷新可见单元
    func bundleIcon(for entry: Entry) -> NSImage? {
        if let icon = bundleIcons[entry.id] { return icon }
        guard let archiveURL = entry.archiveURL, bundleIconLoads.insert(entry.id).inserted,
              let archive = (source as? ArchiveSource) ?? source?.archiveSource(for: archiveURL) else { return nil }
        let id = entry.id
        Task { [weak self] in
            guard let data = await archive.bundleIconData(for: entry), let image = NSImage(data: data) else { return }
            guard let self else { return }
            self.bundleIcons[id] = image
            self.refreshVisibleCells()
            // 不用 reloadItems：列表模式下图标视图的数据可能与当前层级不一致，AppKit 会抛出 NSInternalInconsistencyException。
            // 与缩略图相同，直接更新正在显示该条目的单元
            for case let item as IconItem in self.collectionView.visibleItems() where item.representedID == id {
                item.setThumbnail(image)
            }
        }
        return nil
    }

    /// 目标为本机上存在的绝对路径（如安装盘里指向 /Applications 的替身）时用目标的图标，否则按目标名称推断
    func symlinkIcon(for entry: Entry) -> NSImage {
        let base: NSImage
        if let target = entry.linkTarget, target.hasPrefix("/"), FileManager.default.fileExists(atPath: target) {
            base = NSWorkspace.shared.icon(forFile: target)
        } else if let target = entry.linkTarget, !target.isEmpty {
            base = typeIcon(name: (target as NSString).lastPathComponent, isDirectory: target.hasSuffix("/"))
        } else {
            return NSWorkspace.shared.icon(for: .aliasFile)
        }
        return Self.withAliasBadge(base)
    }

    private static let aliasBadge = NSImage(
        contentsOfFile: "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/AliasBadgeIcon.icns")

    private static func withAliasBadge(_ base: NSImage) -> NSImage {
        guard let badge = aliasBadge else { return base }
        let size = NSSize(width: 512, height: 512)
        return NSImage(size: size, flipped: false) { rect in
            base.draw(in: rect)
            badge.draw(in: rect)
            return true
        }
    }
}
