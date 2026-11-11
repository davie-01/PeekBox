import Foundation
import CLibzip

/// libzip 实现的 ZIP 读取：打开时读一次中央目录后关闭句柄；提取时重新打开、流式写出。
/// 目录树中的条目索引只对建立它的那一版文件有效：提取前核对文件身份，压缩包被替换或改写时拒绝提取。
public struct ZipArchive: ArchiveReader {
    private static let bufferSize = 256 * 1024

    public let archiveURL: URL
    public let tree: ArchiveTree
    /// 建立目录树时的文件身份
    let identity: FileIdentity

    public static func open(_ url: URL) throws -> ZipArchive {
        let (archive, identity) = try openHandle(url)
        defer { zip_discard(archive) }

        var tree = ArchiveTree()
        let names = ZipNameDecoder.names(archive)
        let count = zip_get_num_entries(archive, 0)
        for index in 0..<UInt64(max(count, 0)) {
            var stat = zip_stat_t()
            zip_stat_init(&stat)
            guard zip_stat_index(archive, index, zip_flags_t(ZIP_FL_ENC_RAW), &stat) == 0,
                  Int(index) < names.count, let name = names[Int(index)] else { continue }
            var size: Int64?
            if stat.valid & UInt64(ZIP_STAT_SIZE) != 0 {
                // ZIP64 的大小字段是 UInt64；超出 Int64 的值只可能来自畸形文件，直接转换会使进程崩溃
                guard let exact = Int64(exactly: stat.size) else {
                    throw ArchiveError.unsupported(String(localized: "条目大小异常，压缩包可能已损坏", bundle: CoreStrings.bundle))
                }
                size = exact
            }
            let valid = stat.valid
            tree.add(
                rawPath: name,
                isDirectory: name.hasSuffix("/"),
                entryIndex: Int(index),
                size: size,
                modified: valid & UInt64(ZIP_STAT_MTIME) != 0 && stat.mtime > 0
                    ? Date(timeIntervalSince1970: TimeInterval(stat.mtime)) : nil,
                isEncrypted: valid & UInt64(ZIP_STAT_ENCRYPTION_METHOD) != 0
                    && stat.encryption_method != UInt16(ZIP_EM_NONE)
            )
        }
        return ZipArchive(archiveURL: url, tree: tree, identity: identity)
    }

    public func extractFile(_ item: ArchiveTree.Item, to target: URL, password: String?) throws {
        try extractFiles([(item, target)], password: password)
    }

    /// 一次打开压缩包、复用同一读取缓冲区提取全部条目
    public func extractFiles(_ jobs: [(item: ArchiveTree.Item, target: URL)], password: String?) throws {
        guard !jobs.isEmpty else { return }
        let (archive, current) = try Self.openHandle(archiveURL)
        defer { zip_discard(archive) }
        // 核对的就是 libzip 将要读取的那个已打开文件，不存在核对后又被替换的空档
        guard current == identity else { throw ArchiveError.archiveChanged }
        var buffer = [UInt8](repeating: 0, count: Self.bufferSize)
        for job in jobs {
            do {
                try write(job.item, to: job.target, from: archive, password: password, buffer: &buffer)
            } catch {
                // 读或写出错时都删除写了一半的文件
                try? FileManager.default.removeItem(at: job.target)
                throw error
            }
        }
    }

    private func write(_ item: ArchiveTree.Item, to target: URL, from archive: OpaquePointer, password: String?,
                       buffer: inout [UInt8]) throws {
        guard let entryIndex = item.entryIndex else { throw ArchiveError.entryNotFound(item.path) }
        if item.isEncrypted, password == nil { throw ArchiveError.passwordRequired }

        let opened = item.isEncrypted
            ? zip_fopen_index_encrypted(archive, UInt64(entryIndex), 0, password)
            : zip_fopen_index(archive, UInt64(entryIndex), 0)
        guard let file = opened else {
            throw Self.mapError(zip_error_code_zip(zip_get_error(archive)), encrypted: item.isEncrypted,
                                message: String(cString: zip_strerror(archive)))
        }
        defer { zip_fclose(file) }

        guard FileManager.default.createFile(atPath: target.path, contents: nil) else {
            throw ArchiveError.failed(String(localized: "无法创建 \(target.lastPathComponent)", bundle: CoreStrings.bundle))
        }
        let handle = try FileHandle(forWritingTo: target)
        defer { try? handle.close() }

        while true {
            let read = buffer.withUnsafeMutableBytes { zip_fread(file, $0.baseAddress!, UInt64(Self.bufferSize)) }
            if read < 0 {
                throw Self.mapError(zip_error_code_zip(zip_file_get_error(file)), encrypted: item.isEncrypted,
                                    message: String(cString: zip_file_strerror(file)))
            }
            if read == 0 { break }
            try handle.write(contentsOf: buffer[0..<Int(read)])
        }
    }

    /// 自己打开文件并取得身份，再交给 libzip（zip_fdopen 成功后由 libzip 负责关闭描述符）
    private static func openHandle(_ url: URL) throws -> (OpaquePointer, FileIdentity) {
        let descriptor = Darwin.open(url.path, O_RDONLY)
        guard descriptor >= 0 else {
            throw ArchiveError.unsupported(String(cString: strerror(errno)))
        }
        guard let identity = FileIdentity(descriptor: descriptor) else {
            close(descriptor)
            throw ArchiveError.unsupported(String(cString: strerror(errno)))
        }
        var errorCode: Int32 = 0
        guard let archive = zip_fdopen(descriptor, ZIP_RDONLY, &errorCode) else {
            close(descriptor)
            // 分卷 ZIP：交给 XADMaster；它在沙盒中读不到其他卷时再提示用户
            if errorCode == ZIP_ER_MULTIDISK { throw ArchiveError.volumesUnreachable(url.lastPathComponent) }
            var error = zip_error_t()
            zip_error_init_with_code(&error, errorCode)
            defer { zip_error_fini(&error) }
            throw ArchiveError.unsupported(String(cString: zip_error_strerror(&error)))
        }
        return (archive, identity)
    }

    /// 传统加密的密码校验字节有约 1/256 的误判，错误密码可能读到末尾才以 CRC 错误暴露
    private static func mapError(_ code: Int32, encrypted: Bool, message: String) -> ArchiveError {
        switch code {
        case ZIP_ER_NOPASSWD: .passwordRequired
        case ZIP_ER_WRONGPASSWD: .wrongPassword
        case ZIP_ER_CRC where encrypted: .wrongPassword
        default: .failed(String(localized: "读取压缩包失败：\(message)", bundle: CoreStrings.bundle))
        }
    }
}
