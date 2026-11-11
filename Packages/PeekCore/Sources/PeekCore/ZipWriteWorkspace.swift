import Foundation

/// 记录原包旁的未提交临时包；暂存内容与日志在同一任务目录中，崩溃后可回收。
final class ZipWriteWorkspace {
    static var root: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.mars.PeekBox/Transactions", isDirectory: true)
    }

    let directory: URL
    let archiveCopy: URL

    init(archive: URL, root: URL = ZipWriteWorkspace.root) throws {
        let id = UUID().uuidString
        directory = root.appendingPathComponent(id, isDirectory: true)
        archiveCopy = archive.deletingLastPathComponent().appendingPathComponent(".peekbox-transaction-\(id).zip")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        do {
            let data = try PropertyListEncoder().encode(["archive": archive.path])
            try data.write(to: directory.appendingPathComponent("archive.plist"), options: .atomic)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    /// 成功提交时 libzip 已把临时输出改名为最终文件，不会留下 .part，无需遍历原包所在目录
    /// （目录有大量文件时每次写入都要多列举一遍）；失败时才查找残留
    func cleanup(succeeded: Bool) {
        if succeeded {
            try? FileManager.default.removeItem(at: archiveCopy)
        } else {
            Self.removeCopies(of: archiveCopy)
        }
        try? FileManager.default.removeItem(at: directory)
    }

    private static func removeCopies(of archiveCopy: URL) {
        let fm = FileManager.default
        try? fm.removeItem(at: archiveCopy)
        // libzip 在 zip_close 中还会生成 “归档名.六位随机数.part”，崩溃时同样需要回收。
        for url in (try? fm.contentsOfDirectory(at: archiveCopy.deletingLastPathComponent(), includingPropertiesForKeys: nil)) ?? [] {
            let prefix = archiveCopy.lastPathComponent + "."
            guard url.lastPathComponent.hasPrefix(prefix), url.pathExtension == "part" else { continue }
            let suffix = url.lastPathComponent.dropFirst(prefix.count).dropLast(5)
            guard suffix.count == 6, suffix.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { continue }
            try? fm.removeItem(at: url)
        }
    }

    /// 仅在 Broker 接受写任务前调用；绝不删除日志中的原压缩包。
    static func cleanupAbandoned(root: URL = root) {
        let fm = FileManager.default
        for directory in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            let id = directory.lastPathComponent
            guard UUID(uuidString: id) != nil else { continue }
            if let data = try? Data(contentsOf: directory.appendingPathComponent("archive.plist")),
               let record = try? PropertyListDecoder().decode([String: String].self, from: data),
               let path = record["archive"], path.hasPrefix("/") {
                let temporary = URL(fileURLWithPath: path).deletingLastPathComponent()
                    .appendingPathComponent(".peekbox-transaction-\(id).zip")
                removeCopies(of: temporary)
            }
            try? fm.removeItem(at: directory)
        }
    }
}
