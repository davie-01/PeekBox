import Foundation

/// 文件夹条目与归档虚拟条目在 UI 层的统一表示。
public struct Entry: Sendable, Hashable, Identifiable {
    /// 文件夹为路径；归档条目见 ArchiveSource.entryID。
    /// 文件夹条目不另存路径字符串与 URL，用到时由共用的父目录 URL 拼出：10 万项目录可省约 50 MB
    public var id: String { archiveID ?? fileURL?.path ?? name }
    private let archiveID: String?
    public let name: String
    public let isDirectory: Bool
    public let size: Int64?
    public let modified: Date?
    public let kind: String?
    /// 仅文件夹条目有真实 URL；归档条目为 nil，不能当作 Finder 路径使用。
    public var fileURL: URL? { directoryURL?.appendingPathComponent(name, isDirectory: isDirectory) }
    /// 文件夹条目所在目录；同一次列举的条目共用同一个 URL 对象
    private let directoryURL: URL?
    /// 文件夹中的压缩包文件，可像目录一样展开
    public let isArchive: Bool
    /// 归档内条目所属的压缩包；文件系统条目为 nil
    public let archiveURL: URL?
    /// 归档内加密条目，提取前需要密码
    public let isEncrypted: Bool
    /// 归档内的包（.app 等）：在归档中是目录，按 Finder 的习惯作为一个整体显示，不展开
    public let isPackage: Bool
    /// 归档内的符号链接及其目标（引擎能读出时才有）
    public let isSymlink: Bool
    public let linkTarget: String?
    /// 以下仅文件夹条目有值（列举时一并读取）
    public let created: Date?
    public let added: Date?

    public var isExpandable: Bool { (isDirectory && !isPackage) || isArchive }
    /// 按文件夹排序与显示：包在 Finder 中按文件处理
    public var isFolderLike: Bool { isDirectory && !isPackage }

    /// 归档内条目
    public init(id: String, name: String, isDirectory: Bool, size: Int64?, modified: Date?, kind: String?,
                archiveURL: URL, isEncrypted: Bool = false, isPackage: Bool = false,
                isSymlink: Bool = false, linkTarget: String? = nil) {
        archiveID = id
        directoryURL = nil
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
        self.modified = modified
        self.kind = kind
        isArchive = false
        self.archiveURL = archiveURL
        self.isEncrypted = isEncrypted
        self.isPackage = isPackage
        self.isSymlink = isSymlink
        self.linkTarget = linkTarget
        created = nil
        added = nil
    }

    /// 文件夹中的条目
    public init(directory: URL, name: String, isDirectory: Bool, size: Int64?, modified: Date?, kind: String?,
                isArchive: Bool, created: Date?, added: Date?) {
        archiveID = nil
        directoryURL = directory
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
        self.modified = modified
        self.kind = kind
        self.isArchive = isArchive
        archiveURL = nil
        isEncrypted = false
        isPackage = false
        isSymlink = false
        linkTarget = nil
        self.created = created
        self.added = added
    }
}

public protocol EntrySource: Sendable {
    var rootURL: URL { get }
    /// parent 为 nil 时返回根层级；只列举直接子项。
    func children(of parent: Entry?) async throws -> [Entry]
    /// 某个压缩包对应的数据源（拖出与密码输入时取用）；不是本数据源管理的压缩包返回 nil。
    func archiveSource(for archive: URL) -> ArchiveSource?
}

extension EntrySource {
    public func archiveSource(for archive: URL) -> ArchiveSource? { nil }
}

extension Array where Element == Entry {
    /// Finder 风格自然排序，可选文件夹置顶。
    public func sortedForDisplay(foldersFirst: Bool) -> [Entry] {
        sorted { a, b in
            if foldersFirst, a.isFolderLike != b.isFolderLike { return a.isFolderLike }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }
}
