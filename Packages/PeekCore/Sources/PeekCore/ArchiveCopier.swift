import Foundation

/// 把归档中的条目拷到真实文件夹：在预览中把安装盘里的 App 拖到指向 /Applications 的替身上。
/// 由后台服务执行（预览扩展在沙盒中写不了目标文件夹）。
///
/// 1. 提取到目标文件夹内的隐藏暂存目录（同一卷，最后一步只是改名）；
/// 2. 继承归档的隔离属性（com.apple.quarantine），与 Finder 从挂载的镜像拷出、"归档实用工具"解压时一样，
///    下载来的 App 首次打开时仍经过 Gatekeeper 检查；
/// 3. 逐个移入目标。同名时按 resolve 的决定处理，替换时旧项目移到废纸篓。
/// 中途失败或取消时删除暂存目录，目标中不会留下不完整的项目。
public enum ArchiveCopier {
    public static func copy(reader: any ArchiveReader, archive: URL, paths: [String], to destination: URL,
                            password: String?, control: ZipWriteControl,
                            trash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) },
                            resolve: (ZipEditor.ImportConflict) throws -> ZipEditor.ConflictDecision) throws -> ZipEditor.ImportSummary {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: destination.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ArchiveError.failed(String(localized: "目标文件夹不存在：\(destination.path)", bundle: CoreStrings.bundle))
        }
        let items = try paths.map { path in
            guard let item = reader.tree.items[path] else { throw ArchiveError.entryNotFound(path) }
            return item
        }
        let total = items.reduce(Int64(0)) { sum, item in
            sum + (item.isDirectory ? reader.tree.descendantFiles(of: item.path).compactMap(\.size).saturatingSum : item.size ?? 0)
        }

        let staging = destination.appendingPathComponent(".PeekBox-copy-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: staging) }

        // 提取占 0–95%，移入占剩余部分
        var done: Int64 = 0
        for item in items {
            try control.checkCancellation()
            try reader.extract(path: item.path, to: staging.appendingPathComponent(item.name), password: password,
                               batchBytes: 32 << 20) { bytes in
                done += bytes
                control.update(total > 0 ? Double(done) / Double(total) * 0.95 : 0)
                try control.checkCancellation()
            }
        }
        Quarantine.inherit(from: archive, to: items.map { staging.appendingPathComponent($0.name) })
        try control.checkCancellation()

        var summary = ZipEditor.ImportSummary()
        var batchDecision: ZipEditor.ConflictAction?
        for (index, item) in items.enumerated() {
            let staged = staging.appendingPathComponent(item.name)
            var target = destination.appendingPathComponent(item.name)
            if exists(target) {
                let action: ZipEditor.ConflictAction
                if let batchDecision {
                    action = batchDecision
                } else {
                    let remaining = items[(index + 1)...].filter { exists(destination.appendingPathComponent($0.name)) }.count
                    var existingIsDirectory: ObjCBool = false
                    fm.fileExists(atPath: target.path, isDirectory: &existingIsDirectory)
                    let decision = try resolve(ZipEditor.ImportConflict(
                        path: item.name, incomingIsDirectory: item.isDirectory,
                        existingIsDirectory: existingIsDirectory.boolValue, remainingConflicts: remaining))
                    action = decision.action
                    if decision.applyToAll { batchDecision = action }
                }
                switch action {
                case .cancel:
                    throw ZipEditor.EditError.cancelled
                case .skip:
                    summary.skipped += 1
                    continue
                case .keepBoth:
                    target = uniqueURL(for: target)
                case .replace:
                    try trash(target)
                    summary.replaced += 1
                }
            }
            try fm.moveItem(at: staged, to: target)
            // 新增与"保留两者"计入新增，替换已在上面计数
            summary.entries += 1
            control.update(0.95 + 0.05 * Double(index + 1) / Double(items.count))
        }
        summary.added = summary.entries - summary.replaced
        return summary
    }

    /// 包括悬空的符号链接
    private static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
            || (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    /// "名称 2.app" 这样的不重名路径（与 Finder 的"保留两者"一致）
    static func uniqueURL(for url: URL) -> URL {
        let directory = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        for number in 2... {
            let name = ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)"
            let candidate = directory.appendingPathComponent(name)
            if !exists(candidate) { return candidate }
        }
        return url
    }
}
