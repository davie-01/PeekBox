import Foundation

/// Codable：单独预览分卷包时由后台服务代读，错误要原样传回扩展（如需要密码时弹出密码框）
public enum ArchiveError: LocalizedError, Equatable, Codable {
    case passwordRequired
    case wrongPassword
    case entryNotFound(String)
    case destinationExists(String)
    case unsupported(String)
    /// 单独预览分卷包时，沙盒扩展读不到同目录的其他卷
    case volumesUnreachable(String)
    /// 选中的是分卷中间的一卷
    case notFirstVolume(String)
    /// 建立目录树后压缩包被替换或改写，按旧索引提取会读到别的内容
    case archiveChanged
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .passwordRequired: String(localized: "需要密码", bundle: CoreStrings.bundle)
        case .wrongPassword: String(localized: "密码不正确", bundle: CoreStrings.bundle)
        case .entryNotFound(let path): String(localized: "归档内找不到：\(path)", bundle: CoreStrings.bundle)
        case .destinationExists(let name): String(localized: "目标已存在：\(name)", bundle: CoreStrings.bundle)
        case .unsupported(let detail): String(localized: "无法识别的压缩包：\(detail)", bundle: CoreStrings.bundle)
        case .volumesUnreachable(let first): String(localized: "分卷压缩包（\(first)）请在所在文件夹的预览中展开", bundle: CoreStrings.bundle)
        case .notFirstVolume(let first): String(localized: "这是分卷的一部分，请预览第一卷 \(first)", bundle: CoreStrings.bundle)
        case .archiveChanged: String(localized: "压缩包已被其他程序修改，请关闭预览后重新打开", bundle: CoreStrings.bundle)
        case .failed(let detail): detail
        }
    }
}

/// 归档条目构成的目录树。路径已规范化：无前导 /、无尾随 /，剔除 . 与 ..。
/// Codable：后台服务代读时把目录树传给扩展
public struct ArchiveTree: Sendable, Codable {
    public struct Item: Sendable, Codable {
        public let path: String
        public let name: String
        public let isDirectory: Bool
        /// 引擎内的条目序号；目录可能由文件路径推导而来，没有对应条目
        public let entryIndex: Int?
        public let size: Int64?
        public let modified: Date?
        public let isEncrypted: Bool
        /// 符号链接等特殊条目：显示但不提取
        public let isSpecial: Bool
    }

    public private(set) var items: [String: Item] = [:]
    /// 父路径 → 子路径列表；根为 ""
    public private(set) var children: [String: [String]] = [:]

    public init() {}

    public var hasEncryptedEntries: Bool { items.values.contains { $0.isEncrypted } }

    /// 按原始路径加入一个条目，自动补出缺失的上级目录。
    public mutating func add(rawPath: String, isDirectory: Bool, entryIndex: Int?, size: Int64?,
                             modified: Date?, isEncrypted: Bool, isSpecial: Bool = false) {
        let components = rawPath.split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { $0 != "." && $0 != ".." }
        guard let name = components.last else { return }
        for depth in 1..<max(components.count, 1) where items[components[0..<depth].joined(separator: "/")] == nil {
            register(Item(path: components[0..<depth].joined(separator: "/"), name: components[depth - 1],
                          isDirectory: true, entryIndex: nil, size: nil, modified: nil,
                          isEncrypted: false, isSpecial: false))
        }
        register(Item(path: components.joined(separator: "/"), name: name, isDirectory: isDirectory,
                      entryIndex: entryIndex, size: isDirectory ? nil : size, modified: modified,
                      isEncrypted: isEncrypted, isSpecial: isSpecial))
    }

    private mutating func register(_ item: Item) {
        if let existing = items[item.path] {
            // 显式目录条目覆盖推导出来的目录；重复文件路径保留首个（写入时按只读处理）
            guard existing.entryIndex == nil, item.isDirectory || !existing.isDirectory else { return }
            items[item.path] = item
            return
        }
        items[item.path] = item
        children[Self.parentPath(of: item.path), default: []].append(item.path)
    }

    /// 某目录下全部文件条目（含所有层级），用于目录提取。
    public func descendantFiles(of path: String) -> [Item] {
        var result: [Item] = []
        var stack = children[path] ?? []
        while let next = stack.popLast() {
            guard let item = items[next] else { continue }
            if item.isDirectory {
                stack.append(contentsOf: children[next] ?? [])
            } else {
                result.append(item)
            }
        }
        return result
    }

    public func descendantDirectories(of path: String) -> [Item] {
        let prefix = path + "/"
        return items.values.filter { $0.isDirectory && $0.path.hasPrefix(prefix) }
    }

    static func parentPath(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[..<slash])
    }
}

/// 一个已打开的压缩包：目录树 + 按条目提取的能力。
public protocol ArchiveReader: Sendable {
    var tree: ArchiveTree { get }
    /// 把文件条目提取为 destination（必须尚不存在）。
    func extractFile(_ item: ArchiveTree.Item, to destination: URL, password: String?) throws
    /// 批量提取。逐个调用 extractFile 时，ZIP 每个文件都要重新打开并解析中央目录（3000 个小文件约 3 秒，
    /// 随数量平方增长）；实现方可在一次打开中完成全部提取
    func extractFiles(_ jobs: [(item: ArchiveTree.Item, target: URL)], password: String?) throws
}

extension ArchiveReader {
    public func extractFiles(_ jobs: [(item: ArchiveTree.Item, target: URL)], password: String?) throws {
        for job in jobs { try extractFile(job.item, to: job.target, password: password) }
    }
}

extension ArchiveReader {
    /// 用最小的加密文件试解压一次来验证密码；没有加密文件时直接通过。
    public func verifyPassword(_ password: String) throws {
        guard let probe = tree.items.values.filter({ $0.isEncrypted && !$0.isDirectory && !$0.isSpecial })
            .min(by: { ($0.size ?? .max) < ($1.size ?? .max) }) else { return }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PeekBox-verify-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try extractFile(probe, to: directory.appendingPathComponent("probe"), password: password)
    }

    /// 提取文件或目录（目录连同全部后代）。
    public func extract(path: String, to destination: URL, password: String?) throws {
        guard let item = tree.items[path] else { throw ArchiveError.entryNotFound(path) }
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            throw ArchiveError.destinationExists(destination.lastPathComponent)
        }
        guard item.isDirectory else {
            try extractFile(item, to: destination, password: password)
            return
        }
        try fm.createDirectory(at: destination, withIntermediateDirectories: false)
        let prefix = path + "/"
        for directory in tree.descendantDirectories(of: path) {
            try fm.createDirectory(at: destination.appendingPathComponent(String(directory.path.dropFirst(prefix.count))),
                                   withIntermediateDirectories: true)
        }
        var jobs: [(item: ArchiveTree.Item, target: URL)] = []
        for file in tree.descendantFiles(of: path) where !file.isSpecial {
            // 相对路径来自已规范化的组件（无 . / ..），不会逃出 destination
            let target = destination.appendingPathComponent(String(file.path.dropFirst(prefix.count)))
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            jobs.append((file, target))
        }
        try extractFiles(jobs, password: password)
    }
}
