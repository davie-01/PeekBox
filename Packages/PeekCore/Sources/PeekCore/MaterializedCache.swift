import Foundation

/// 后台服务把压缩包条目提取到这里，供"打开 / 打开方式 / 拷贝"使用：
/// ~/Library/Caches/com.mars.PeekBox/Materialized/<任务 ID>/。
/// 其他应用打开的、剪贴板里放的都是这里的文件，所以不能在预览关闭时删除，而是按保留时长回收。
public enum MaterializedCache {
    public static var directory: URL {
        let caches = (try? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches")
        return caches.appendingPathComponent("com.mars.PeekBox/Materialized", isDirectory: true)
    }

    /// 新建一个任务目录
    public static func makeTaskDirectory() throws -> URL {
        let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// 删除创建时间早于保留时长的任务目录，返回删除数量
    @discardableResult
    public static func purgeExpired(retention: TimeInterval = PeekPreferences.cacheRetention) -> Int {
        let deadline = Date().addingTimeInterval(-retention)
        return remove { ($0 ?? .distantPast) < deadline }
    }

    /// 全部删除，返回未能删除的数量
    public static func removeAll() -> Int {
        let total = taskDirectories().count
        return total - remove { _ in true }
    }

    private static func taskDirectories() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey])) ?? []
    }

    private static func remove(where shouldRemove: (Date?) -> Bool) -> Int {
        var removed = 0
        for folder in taskDirectories() {
            let created = try? folder.resourceValues(forKeys: [.creationDateKey]).creationDate
            guard shouldRemove(created) else { continue }
            if (try? FileManager.default.removeItem(at: folder)) != nil { removed += 1 }
        }
        return removed
    }
}
