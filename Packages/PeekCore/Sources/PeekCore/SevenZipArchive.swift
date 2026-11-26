import CSevenZip
import Foundation

/// 7-Zip 读取的磁盘镜像与文件系统（DMG、ISO、UDF、HFS+、APFS、FAT、NTFS、ext 等），只读。
/// 桥接层逐层打开分区与文件系统（见 SevenZipBridge/PeekSevenZip.cpp）；7-Zip 的解码器不是线程安全的，提取时串行。
public final class SevenZipArchive: ArchiveReader, @unchecked Sendable {
    public let archiveURL: URL
    public let tree: ArchiveTree
    /// 各层格式，如 "Dmg > HFS"
    public let formatName: String
    /// 单一卷时的卷名（HFS+ 卷），没有则为 nil
    public let volumeName: String?

    private let handle: OpaquePointer
    private let lock = NSLock()

    private init(archiveURL: URL, tree: ArchiveTree, formatName: String, volumeName: String?, handle: OpaquePointer) {
        self.archiveURL = archiveURL
        self.tree = tree
        self.formatName = formatName
        self.volumeName = volumeName
        self.handle = handle
    }

    deinit {
        psz_close(handle)
    }

    public static var engineVersion: String { String(cString: psz_version()) }

    public static func open(_ url: URL) throws -> SevenZipArchive {
        var status = PSZ_OK
        guard let handle = url.path.withCString({ psz_open($0, &status) }) else {
            throw openError(status)
        }
        var tree = ArchiveTree()
        var item = PSZItem()
        var partitionNumber = 0
        for index in 0..<psz_item_count(handle) where psz_item(handle, index, &item) {
            var path = String(cString: item.path).precomposedStringWithCanonicalMapping
            if item.is_raw_partition {
                // 认不出文件系统的分区：以磁盘映像文件列出，拖出后可在 Finder 中挂载
                partitionNumber += 1
                let hint = item.filesystem_hint.map { String(cString: $0) }
                path = hint.map { String(localized: "分区 \(partitionNumber)（\($0)）.img", bundle: CoreStrings.bundle) }
                    ?? String(localized: "分区 \(partitionNumber).img", bundle: CoreStrings.bundle)
            }
            let modified = item.has_mtime
                ? Date(timeIntervalSince1970: TimeInterval(item.mtime_sec) + TimeInterval(item.mtime_nsec) / 1e9)
                : nil
            tree.add(
                rawPath: path,
                isDirectory: item.is_dir,
                entryIndex: Int(index),
                size: item.has_size ? Int64(clamping: item.size) : nil,
                modified: modified,
                isEncrypted: false,
                isSpecial: item.is_symlink,
                linkTarget: item.link_target.map { String(cString: $0) }
            )
        }
        let volume = String(cString: psz_volume_name(handle))
        return SevenZipArchive(archiveURL: url, tree: tree, formatName: String(cString: psz_format(handle)),
                               volumeName: volume.isEmpty ? nil : volume, handle: handle)
    }

    private static func openError(_ status: PSZStatus) -> ArchiveError {
        switch status {
        case PSZ_ENCRYPTED:
            .failed(String(localized: "这是加密的磁盘镜像，暂不支持预览", bundle: CoreStrings.bundle))
        case PSZ_UNREADABLE:
            .failed(String(localized: "无法读取磁盘镜像", bundle: CoreStrings.bundle))
        default:
            .failed(String(localized: "无法识别的磁盘镜像格式", bundle: CoreStrings.bundle))
        }
    }

    public func extractFile(_ item: ArchiveTree.Item, to target: URL, password: String?) throws {
        try extractFiles([(item, target)], password: password)
    }

    /// 一次调用提取全部文件：同一卷内 7-Zip 按序号顺序解码，DMG 的压缩块不必反复解压
    public func extractFiles(_ jobs: [(item: ArchiveTree.Item, target: URL)], password: String?) throws {
        var indices: [UInt32] = []
        var targets: [String] = []
        for job in jobs {
            guard let index = job.item.entryIndex else { throw ArchiveError.entryNotFound(job.item.path) }
            indices.append(UInt32(index))
            targets.append(job.target.path)
        }
        guard !indices.isEmpty else { return }
        try lock.withLock {
            var error: UnsafeMutablePointer<CChar>?
            let pointers = targets.map { strdup($0) }
            defer { pointers.forEach { free($0) } }
            let constPointers = pointers.map { UnsafePointer($0) }
            let result = indices.withUnsafeBufferPointer { indexBuffer in
                constPointers.withUnsafeBufferPointer { targetBuffer in
                    psz_extract(handle, indexBuffer.baseAddress, targetBuffer.baseAddress,
                                UInt32(indexBuffer.count), &error)
                }
            }
            guard result != PSZ_OK else { return }
            let detail = error.map { String(cString: $0) }
            psz_free(error)
            let name = detail.map { ($0 as NSString).lastPathComponent } ?? ""
            switch result {
            case PSZ_WRITE_FAILED:
                throw ArchiveError.failed(String(localized: "无法写入：\(name)", bundle: CoreStrings.bundle))
            case PSZ_UNSUPPORTED_METHOD:
                throw ArchiveError.failed(String(localized: "不支持的压缩方法", bundle: CoreStrings.bundle))
            default:
                throw ArchiveError.failed(String(localized: "磁盘镜像数据损坏，无法提取", bundle: CoreStrings.bundle))
            }
        }
    }
}

/// 交给 7-Zip 读取的磁盘镜像：按扩展名或签名判断，不解析
enum DiskImage {
    static let extensions: Set<String> = [
        "dmg", "img", "iso", "cdr", "toast", "smi", "udf",
        "hfs", "hfsx", "apfs", "ntfs", "fat", "ext", "ext2", "ext3", "ext4", "squashfs", "cramfs",
        "vhd", "vhdx", "vmdk", "qcow", "qcow2", "vdi",
    ]

    static func matches(_ url: URL) -> Bool {
        extensions.contains(url.pathExtension.lowercased()) || hasSignature(url)
    }

    /// DMG 的 koly 尾部（倒数 512 字节处）或 ISO 9660 / UDF 的卷描述符（32 KB 处）
    private static func hasSignature(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        if let end = try? handle.seekToEnd(), end >= 512 {
            try? handle.seek(toOffset: end - 512)
            if let koly = try? handle.read(upToCount: 4), koly == Data("koly".utf8) { return true }
        }
        try? handle.seek(toOffset: 32769)
        if let descriptor = try? handle.read(upToCount: 5),
           descriptor == Data("CD001".utf8) || descriptor == Data("BEA01".utf8) {
            return true
        }
        return false
    }
}
