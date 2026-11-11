import Foundation
import PeekCore

/// 后台服务处理"打开 / 打开方式 / 拷贝"时的复用：
/// - 最近用过的压缩包读取器（最多 3 个）：此前每次请求都重新解析整个压缩包，大 7z 每点一次都要完整解析；
/// - 已提取的单个文件：同一压缩包、同一条目再次请求时，若上次的副本仍在且未被改动就直接复用，不再重复解压。
/// 压缩包以"路径 + 设备 + inode + 大小 + 纳秒级修改时间"识别，被修改或替换后自动失效。
/// 后台服务空闲约 30 秒退出，缓存随之释放。
final class MaterializeCache: @unchecked Sendable {
    struct ArchiveIdentity: Hashable {
        let path: String
        let device: Int32
        let inode: UInt64
        let size: Int64
        let modified: Int64
        let modifiedNanoseconds: Int

        init?(_ url: URL) {
            var info = stat()
            guard stat(url.path, &info) == 0 else { return nil }
            path = url.path
            device = info.st_dev
            inode = UInt64(info.st_ino)
            size = Int64(info.st_size)
            modified = Int64(info.st_mtimespec.tv_sec)
            modifiedNanoseconds = info.st_mtimespec.tv_nsec
        }
    }

    private struct ReaderKey: Hashable {
        let archive: ArchiveIdentity
        /// 文件名加密的压缩包需要密码才能解析出目录树，不同密码各自缓存
        let password: String?
    }

    /// 提取出的文件及其当时的大小与修改时间，用来判断副本是否已被改动
    private struct Extracted {
        let url: URL
        let size: Int64
        let modified: Date
    }

    private static let readerLimit = 3
    private let lock = NSLock()
    /// 最近使用的在前
    private var readers: [(key: ReaderKey, reader: any ArchiveReader)] = []
    private var extracted: [ArchiveIdentity: [String: Extracted]] = [:]

    func reader(for url: URL, identity: ArchiveIdentity?, password: String?) throws -> any ArchiveReader {
        guard let identity else { return try ArchiveSource.openReader(url, password: password) }
        let key = ReaderKey(archive: identity, password: password)
        if let hit = lock.withLock({ () -> (any ArchiveReader)? in
            guard let index = readers.firstIndex(where: { $0.key == key }) else { return nil }
            let entry = readers.remove(at: index)
            readers.insert(entry, at: 0)
            return entry.reader
        }) {
            return hit
        }
        let reader = try ArchiveSource.openReader(url, password: password)
        lock.withLock {
            // 同一路径的旧版本读取器不再有用
            readers.removeAll { $0.key.archive.path == identity.path }
            extracted = extracted.filter { $0.key.path != identity.path || $0.key == identity }
            readers.insert((key, reader), at: 0)
            if readers.count > Self.readerLimit { readers.removeLast(readers.count - Self.readerLimit) }
        }
        return reader
    }

    /// 上次提取的副本仍在且大小、修改时间未变时返回它（只复用单个文件，不复用目录）
    func reusableFile(archive: ArchiveIdentity?, entryPath: String) -> URL? {
        guard let archive, let record = lock.withLock({ extracted[archive]?[entryPath] }) else { return nil }
        guard let values = try? record.url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]),
              values.isRegularFile == true, Int64(values.fileSize ?? -1) == record.size,
              values.contentModificationDate == record.modified else {
            lock.withLock { _ = extracted[archive]?.removeValue(forKey: entryPath) }
            return nil
        }
        return record.url
    }

    func recordFile(archive: ArchiveIdentity?, entryPath: String, url: URL) {
        guard let archive,
              let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]),
              values.isRegularFile == true, let size = values.fileSize, let modified = values.contentModificationDate else { return }
        lock.withLock { extracted[archive, default: [:]][entryPath] = Extracted(url: url, size: Int64(size), modified: modified) }
    }
}
