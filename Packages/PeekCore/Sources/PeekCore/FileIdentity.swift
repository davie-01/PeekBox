import Foundation

/// 文件身份：设备号 + inode + 大小 + 纳秒级修改时间。用于确认读取的仍是建立目录树时的同一版本文件
/// （被替换会换 inode，就地改写会改变大小或修改时间）。
public struct FileIdentity: Equatable, Sendable {
    let device: Int32
    let inode: UInt64
    let size: Int64
    let seconds: Int
    let nanoseconds: Int

    init(_ info: stat) {
        device = info.st_dev
        inode = UInt64(info.st_ino)
        size = Int64(info.st_size)
        seconds = info.st_mtimespec.tv_sec
        nanoseconds = info.st_mtimespec.tv_nsec
    }

    /// 已打开文件的身份
    init?(descriptor: Int32) {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { return nil }
        self.init(info)
    }

    /// 路径当前指向的文件的身份
    public init?(path: String) {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        self.init(info)
    }
}
