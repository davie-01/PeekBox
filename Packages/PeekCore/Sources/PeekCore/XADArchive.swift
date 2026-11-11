import Foundation
import XADMaster

/// XADMaster 实现的 7z / RAR / tar 系列等格式读取（进程内）。
/// 解析器不是线程安全的，提取时串行使用；解析期间持有文件句柄，随本对象释放。
public final class XADArchive: ArchiveReader, @unchecked Sendable {
    public let archiveURL: URL
    public let tree: ArchiveTree
    public let formatName: String

    /// tar.gz 等嵌套格式时，outer 是外层压缩流，parser 是内层 tar；内层依赖外层的句柄，二者都要持有
    private let outer: XADArchiveParser
    private let parser: XADArchiveParser
    private let entries: [NSDictionary]
    private let lock = NSLock()

    private init(archiveURL: URL, tree: ArchiveTree, formatName: String,
                 outer: XADArchiveParser, parser: XADArchiveParser, entries: [NSDictionary]) {
        self.archiveURL = archiveURL
        self.tree = tree
        self.formatName = formatName
        self.outer = outer
        self.parser = parser
        self.entries = entries
    }

    public static func open(_ url: URL, password: String?) throws -> XADArchive {
        var error: XADError = 0
        guard let outer = XADArchiveParser(forPath: url.path, error: &error) else {
            throw ArchiveError.unsupported(String(localized: "格式无法识别（\(error)）", bundle: CoreStrings.bundle))
        }
        var parser = outer
        var entries = try parse(outer, password: password)

        // 外层只有一个非目录条目（gzip / xz / bzip2 压缩流）时，尝试把它当作内层归档解析
        if entries.count == 1, !flag(entries[0], XADIsDirectoryKey) {
            var innerError: XADError = 0
            if let inner = XADArchiveParser(forEntryWith: entries[0] as? [AnyHashable: Any],
                                            archiveParser: outer, wantChecksum: true, error: &innerError),
               let innerEntries = try? parse(inner, password: password), !innerEntries.isEmpty {
                parser = inner
                entries = innerEntries
            }
        }

        // 文件名按整个压缩包统一判断编码：XADMaster 逐个文件名猜测，会把 tar 等格式里的 UTF-8 中文
        // 猜成 IBM866 之类。7z / RAR5 等本身以 Unicode 存放，原始字节即 UTF-8，识别结果也是 UTF-8
        let paths = entries.map { $0[XADFileNameKey as Any] as? XADPath }
        let encoding = NameEncoding.detect(paths.compactMap { $0?.data() })
        let encodingName = NameEncoding.ianaName(encoding)

        var tree = ArchiveTree()
        for (index, dict) in entries.enumerated() {
            // 资源分叉属于 macOS 元数据，不作为独立条目显示
            if flag(dict, XADIsResourceForkKey) { continue }
            guard let path = paths[index] else { continue }
            let name = (path.canDecode(withEncodingName: encodingName) ? path.string(withEncodingName: encodingName) : path.string())
                .precomposedStringWithCanonicalMapping
            tree.add(
                rawPath: name,
                isDirectory: flag(dict, XADIsDirectoryKey),
                entryIndex: index,
                size: (dict[XADFileSizeKey as Any] as? NSNumber)?.int64Value,
                modified: dict[XADLastModificationDateKey as Any] as? Date,
                isEncrypted: flag(dict, XADIsEncryptedKey),
                isSpecial: flag(dict, XADIsLinkKey) || flag(dict, XADIsHardLinkKey)
            )
        }
        return XADArchive(archiveURL: url, tree: tree, formatName: parser.formatName() ?? "",
                          outer: outer, parser: parser, entries: entries)
    }

    public func extractFile(_ item: ArchiveTree.Item, to target: URL, password: String?) throws {
        guard let index = item.entryIndex, index < entries.count else { throw ArchiveError.entryNotFound(item.path) }
        // 解析器的密码状态与解压都不是线程安全的：检查密码也必须在锁内，
        // 否则会与另一路提取的 setPassword 同时读写同一成员（拖出、检查器与验证密码可能并发）
        try lock.withLock {
            if item.isEncrypted, password == nil, !parser.hasPassword() { throw ArchiveError.passwordRequired }
            if let password {
                outer.setPassword(password)
                parser.setPassword(password)
            }
            guard let unarchiver = XADUnarchiver(for: parser) else {
                throw ArchiveError.failed(String(localized: "无法创建解压器", bundle: CoreStrings.bundle))
            }
            let error = unarchiver.extractEntry(with: entries[index] as? [AnyHashable: Any],
                                                as: target.path, forceDirectories: true)
            if error != XADNoError {
                try? FileManager.default.removeItem(at: target)
                throw Self.mapError(error, encrypted: item.isEncrypted || parser.isEncrypted())
            }
        }
    }

    private static func parse(_ parser: XADArchiveParser, password: String?) throws -> [NSDictionary] {
        let collector = EntryCollector()
        parser.setDelegate(collector)
        if let password { parser.setPassword(password) }
        let error = parser.parseWithoutExceptions()
        parser.setDelegate(nil)
        if error != XADNoError {
            // 文件名加密时缺密码或密码错误，各格式报的错误不同：RAR5 为 XADPasswordError；
            // 7z 为 XADDecrunchError，RAR4 为 XADInputError（把加密的头部当普通数据读坏了）。
            // 此时 isEncrypted() 也为 false（头部尚未解开），只能靠 archiveParserNeedsPassword: 回调
            // 或"已提供密码"来判断
            let passwordIssue = error == XADPasswordError
                || ((error == XADDecrunchError || error == XADInputError)
                    && (collector.needsPassword || parser.isEncrypted() || password != nil))
            if passwordIssue {
                throw password == nil ? ArchiveError.passwordRequired : ArchiveError.wrongPassword
            }
            throw ArchiveError.failed(String(localized: "解析失败（XAD 错误 \(error)）", bundle: CoreStrings.bundle))
        }
        return collector.entries
    }

    private static func mapError(_ error: XADError, encrypted: Bool) -> ArchiveError {
        if error == XADPasswordError { return .wrongPassword }
        if encrypted, error == XADDecrunchError || error == XADChecksumError { return .wrongPassword }
        return .failed(String(localized: "解压失败（XAD 错误 \(error)）", bundle: CoreStrings.bundle))
    }

    private static func flag(_ dict: NSDictionary, _ key: String) -> Bool {
        (dict[key as Any] as? NSNumber)?.boolValue ?? false
    }
}

private final class EntryCollector: NSObject {
    var entries: [NSDictionary] = []
    var needsPassword = false

    override func archiveParser(_ parser: XADArchiveParser!, foundEntryWith dict: [AnyHashable: Any]!) {
        entries.append(dict as NSDictionary)
    }

    override func archiveParserNeedsPassword(_ parser: XADArchiveParser!) {
        needsPassword = true
    }
}
