import Foundation

/// 从归档提取出的文件继承归档的隔离属性（com.apple.quarantine），与"归档实用工具"解压、Finder 从挂载的镜像拷出一致：
/// 下载来的 App 经 PeekBox 拖出、打开或拷进"应用程序"后，首次打开时仍经过 Gatekeeper 检查。
///
/// 后台服务不在沙盒中，按原样复制属性值。沙盒中的预览扩展不能直接写这个属性（setxattr 返回 EPERM），
/// 改用系统的 Quarantine API：事件 ID 与归档相同，系统把来源程序记为扩展本身并加上沙盒标记，Gatekeeper 同样检查
public enum Quarantine {
    static let key = "com.apple.quarantine"

    /// 归档的隔离属性；归档未被隔离（本机创建、用户已移除）时为 nil，此时不做任何事
    /// 只读：创建后不再修改（属性字典的值为 String / Date / NSNumber）
    public struct Source: @unchecked Sendable {
        let raw: Data
        let properties: [String: Any]?

        public init?(archive: URL) {
            let length = getxattr(archive.path, Quarantine.key, nil, 0, 0, 0)
            guard length > 0 else { return nil }
            var data = Data(count: length)
            let read = data.withUnsafeMutableBytes { getxattr(archive.path, Quarantine.key, $0.baseAddress, length, 0, 0) }
            guard read == length else { return nil }
            raw = data
            properties = (try? archive.resourceValues(forKeys: [.quarantinePropertiesKey]))?.quarantineProperties
        }
    }

    /// 给提取出的项目及其全部内容（不跟随符号链接）设置归档的隔离属性
    public static func inherit(from archive: URL, to roots: [URL]) {
        guard let source = Source(archive: archive) else { return }
        for root in roots { apply(source, to: root) }
    }

    public static func apply(_ source: Source, to root: URL) {
        var paths = [root]
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue,
           (try? FileManager.default.destinationOfSymbolicLink(atPath: root.path)) == nil,
           let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) {
            for case let url as URL in enumerator { paths.append(url) }
        }
        for url in paths { set(source, on: url) }
    }

    private static func set(_ source: Source, on url: URL) {
        let result = source.raw.withUnsafeBytes {
            setxattr(url.path, key, $0.baseAddress, source.raw.count, 0, XATTR_NOFOLLOW)
        }
        guard result != 0, errno == EPERM || errno == EACCES else { return }
        // 沙盒中：Quarantine API 会跟随符号链接，链接本身不处理（目标若在提取范围内会单独处理）
        guard (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) == nil,
              let properties = source.properties else { return }
        var values = URLResourceValues()
        values.quarantineProperties = properties
        var target = url
        try? target.setResourceValues(values)
    }

    /// 读取项目的隔离属性原始值（测试与诊断用）
    public static func rawValue(of url: URL) -> Data? {
        let length = getxattr(url.path, key, nil, 0, 0, XATTR_NOFOLLOW)
        guard length > 0 else { return nil }
        var data = Data(count: length)
        let read = data.withUnsafeMutableBytes { getxattr(url.path, key, $0.baseAddress, length, 0, XATTR_NOFOLLOW) }
        return read == length ? data : nil
    }
}
