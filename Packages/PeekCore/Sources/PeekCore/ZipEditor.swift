import Foundation
import CLibzip
import zlib

/// ZIP 原地修改（所有写操作共用的事务）：
/// 检查可写 → 记录原包身份 → 在原包旁复制临时包（APFS 上为克隆）→ 在临时包上修改并关闭
/// → 重新打开校验 → 再次核对原包未被外部修改 → replaceItemAt 原子替换 → 旧版本移到废纸篓或删除。
/// 未修改的条目由 libzip 直接复制压缩数据，不重新压缩；加密条目原样保留。
public enum ZipEditor {
    public enum EditError: LocalizedError, Equatable {
        case notZip
        case notLocal
        case readOnly
        case duplicatePaths
        case invalidName
        case nameExists(String)
        case modifiedExternally
        case verificationFailed
        case wouldBeEmpty
        case cancelled
        case encryptedWrite
        case signedArchive
        case unsupportedInput(String)
        case sourceChanged(String)
        case insufficientSpace
        case failed(String)

        public var errorDescription: String? {
            switch self {
            case .notZip: String(localized: "只能修改 ZIP 压缩包", bundle: CoreStrings.bundle)
            case .notLocal: String(localized: "只能修改本机内置磁盘上的压缩包（iCloud、网络与外置磁盘不支持原地修改）", bundle: CoreStrings.bundle)
            case .readOnly: String(localized: "压缩包或所在文件夹不可写", bundle: CoreStrings.bundle)
            case .duplicatePaths: String(localized: "压缩包中有重复路径，为避免损坏按只读处理", bundle: CoreStrings.bundle)
            case .invalidName: String(localized: "名称不能为空，也不能包含“/”", bundle: CoreStrings.bundle)
            case .nameExists(let name): String(localized: "已存在名为“\(name)”的项目", bundle: CoreStrings.bundle)
            case .modifiedExternally: String(localized: "压缩包在修改期间被其他程序更改，已放弃本次修改", bundle: CoreStrings.bundle)
            case .verificationFailed: String(localized: "修改后的压缩包校验未通过，原压缩包未改动", bundle: CoreStrings.bundle)
            case .wouldBeEmpty: String(localized: "不能删除压缩包中的全部内容", bundle: CoreStrings.bundle)
            case .cancelled: String(localized: "已取消，原压缩包未改动", bundle: CoreStrings.bundle)
            case .encryptedWrite: String(localized: "暂不支持向加密 ZIP 添加内容", bundle: CoreStrings.bundle)
            case .signedArchive: String(localized: "含签名的归档不支持修改", bundle: CoreStrings.bundle)
            case .unsupportedInput(let name): String(localized: "不支持导入此项目（符号链接或特殊文件）：\(name)", bundle: CoreStrings.bundle)
            case .sourceChanged(let name): String(localized: "源文件在读取期间发生变化，已放弃导入：\(name)", bundle: CoreStrings.bundle)
            case .insufficientSpace: String(localized: "磁盘可用空间不足，原压缩包未改动", bundle: CoreStrings.bundle)
            case .failed(let detail): detail
            }
        }
    }

    /// 检查压缩包能否原地修改：本机内置磁盘、非 iCloud、文件与所在目录可写、libzip 能打开（排除分卷）
    public static func checkWritable(_ archive: URL) throws {
        let values = try? archive.resourceValues(forKeys: [
            .volumeIsLocalKey, .volumeIsInternalKey, .volumeIsReadOnlyKey, .isUbiquitousItemKey, .isWritableKey,
        ])
        guard values?.volumeIsLocal == true, values?.volumeIsInternal == true, values?.isUbiquitousItem != true else {
            throw EditError.notLocal
        }
        let directory = archive.deletingLastPathComponent()
        guard values?.volumeIsReadOnly != true, values?.isWritable == true,
              FileManager.default.isWritableFile(atPath: directory.path) else {
            throw EditError.readOnly
        }
        var code: Int32 = 0
        guard let handle = zip_open(archive.path, ZIP_RDONLY, &code) else { throw EditError.notZip }
        defer { zip_discard(handle) }
        let signedExtensions: Set<String> = ["jar", "apk", "aab", "ipa", "xpi", "crx"]
        guard !signedExtensions.contains(archive.pathExtension.lowercased()) else { throw EditError.signedArchive }
        let names = try rawEntries(handle).map { $0.1.lowercased() }
        guard !names.contains(where: { $0.hasPrefix("meta-inf/") && [".sf", ".rsa", ".dsa", ".ec"].contains(where: $0.hasSuffix)
            || $0.split(separator: "/").contains("_codesignature") }) else { throw EditError.signedArchive }
    }

    /// 改名后的归档内路径；名称不合法或与同级项目重名时抛出（供输入时即时提示）
    public static func renamedPath(in tree: ArchiveTree, path: String, newName: String) throws -> String {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else { throw EditError.invalidName }
        guard tree.items[path] != nil else { throw ArchiveError.entryNotFound(path) }
        let parent = path.split(separator: "/").dropLast().joined(separator: "/")
        let newPath = parent.isEmpty ? name : parent + "/" + name
        // 只是大小写不同的改名允许（同一条目），其余同名一律拒绝
        if newPath != path, let existing = tree.items[newPath], existing.path.lowercased() != path.lowercased() {
            throw EditError.nameExists(name)
        }
        return newPath
    }

    /// 重命名条目；目录连同全部后代一起改名。返回新路径（归档内路径）。
    @discardableResult
    public static func rename(archive: URL, path: String, to newName: String, trashOldVersion: Bool, control: ZipWriteControl? = nil) throws -> String {
        guard !newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !newName.contains("/") else {
            throw EditError.invalidName
        }
        try checkWritable(archive)
        let original = try Identity(archive)
        let tree = try ZipArchive.open(archive).tree
        let newPath = try renamedPath(in: tree, path: path, newName: newName)
        guard newPath != path else { return path }

        try transaction(archive: archive, trashOldVersion: trashOldVersion, expected: original, control: control) { handle, _ in
            var renamed = 0
            for (index, normalized, isDirectory) in try rawEntries(handle) {
                let suffix: Substring
                if normalized == path {
                    suffix = ""
                } else if normalized.hasPrefix(path + "/") {
                    suffix = normalized.dropFirst(path.count)
                } else {
                    continue
                }
                let target = newPath + suffix + (isDirectory ? "/" : "")
                guard zip_file_rename(handle, index, target, zip_flags_t(ZIP_FL_ENC_UTF_8)) == 0 else {
                    throw libzipError(handle)
                }
                renamed += 1
            }
            // 隐式目录（没有自己的条目）下至少会改到其后代；一个都没改到说明索引已变化
            guard renamed > 0 else { throw ArchiveError.entryNotFound(path) }
            return 0
        } verify: { tree, _ in
            tree.items[newPath] != nil && (path.lowercased() == newPath.lowercased() || tree.items[path] == nil)
        }
        return newPath
    }

    /// 删除条目；目录连同全部后代一起删除。返回删除的原始条目数。
    @discardableResult
    public static func delete(archive: URL, paths: [String], trashOldVersion: Bool, control: ZipWriteControl? = nil) throws -> Int {
        guard !paths.isEmpty else { return 0 }
        try checkWritable(archive)
        let original = try Identity(archive)
        let tree = try ZipArchive.open(archive).tree
        for path in paths where tree.items[path] == nil { throw ArchiveError.entryNotFound(path) }
        var deleted = 0
        try transaction(archive: archive, trashOldVersion: trashOldVersion, expected: original, control: control) { handle, _ in
            let entries = try rawEntries(handle)
            // 选中路径放进集合，每个条目只查自己与各级上层目录：O(条目数 × 目录深度)，
            // 不再逐条与全部选中路径比较（10 万条目 × 1 万选择时上界 10⁹ 次）
            let selected = Set(paths)
            let doomed = entries.filter { _, normalized, _ in isSelfOrDescendant(normalized, of: selected) }
            guard !doomed.isEmpty else { throw ArchiveError.entryNotFound(paths[0]) }
            // libzip 关闭空归档时会直接删除文件
            guard doomed.count < entries.count else { throw EditError.wouldBeEmpty }
            for (index, _, _) in doomed where zip_delete(handle, index) != 0 {
                throw libzipError(handle)
            }
            deleted = doomed.count
            return -Int64(doomed.count)
        } verify: { tree, _ in
            paths.allSatisfy { tree.items[$0] == nil }
        }
        return deleted
    }

    // MARK: - 事务

    private struct Identity: Equatable {
        let device: Int32
        let inode: UInt64
        let size: Int64
        let modified: timespec

        static func == (a: Identity, b: Identity) -> Bool {
            a.device == b.device && a.inode == b.inode && a.size == b.size
                && a.modified.tv_sec == b.modified.tv_sec && a.modified.tv_nsec == b.modified.tv_nsec
        }

        /// 同一个文件系统对象（不比较大小与时间）
        func isSameObject(as other: Identity) -> Bool {
            device == other.device && inode == other.inode
        }

        init(_ url: URL) throws {
            var info = stat()
            guard stat(url.path, &info) == 0 else { throw EditError.failed(String(cString: strerror(errno))) }
            inode = UInt64(info.st_ino)
            device = info.st_dev
            size = Int64(info.st_size)
            modified = info.st_mtimespec
        }
    }

    private static func transaction(archive: URL, trashOldVersion: Bool, expected: Identity? = nil,
                                    control: ZipWriteControl? = nil,
                                    edit: (OpaquePointer, URL) throws -> Int64,
                                    verify: (ArchiveTree, URL) throws -> Bool) throws {
        let fm = FileManager.default
        let original = try Identity(archive)
        if let expected, original != expected { throw EditError.modifiedExternally }
        try control?.checkCancellation()
        let originalCount = try entryCount(archive)
        let directory = archive.deletingLastPathComponent()
        let workspace = try ZipWriteWorkspace(archive: archive)
        let temp = workspace.archiveCopy
        var succeeded = false
        defer { workspace.cleanup(succeeded: succeeded) }

        // 同卷复制：APFS 上 copyItem 使用 clonefile，几乎不占时间与空间
        try fm.copyItem(at: archive, to: temp)
        var code: Int32 = 0
        guard let handle = zip_open(temp.path, 0, &code) else { throw EditError.notZip }
        let countChange: Int64
        do {
            if let control {
                let context = Unmanaged.passUnretained(control).toOpaque()
                guard zip_register_cancel_callback_with_state(handle, { _, context in
                    guard let context else { return 0 }
                    return Unmanaged<ZipWriteControl>.fromOpaque(context).takeUnretainedValue().isCancelled ? 1 : 0
                }, nil, context) == 0,
                zip_register_progress_callback_with_state(handle, 0.01, { _, progress, context in
                    guard let context else { return }
                    Unmanaged<ZipWriteControl>.fromOpaque(context).takeUnretainedValue().libzipProgress(progress)
                }, nil, context) == 0 else { throw libzipError(handle) }
            }
            countChange = try edit(handle, workspace.directory)
            try control?.checkCancellation()
            control?.setLibzipWork(libzipWork(handle, originalCount: originalCount))
        } catch {
            zip_discard(handle)
            if control?.isCancelled == true { throw EditError.cancelled }
            throw error
        }
        guard zip_close(handle) == 0 else {
            let error = libzipError(handle)
            zip_discard(handle)
            if control?.isCancelled == true { throw EditError.cancelled }
            throw error
        }

        // 校验：能重新打开、条目数符合预期、改动生效
        guard let edited = try? ZipArchive.open(temp), (try? entryCount(temp)) == originalCount + countChange,
              try verify(edited.tree, temp) else {
            throw EditError.verificationFailed
        }
        control?.update(0.98)
        try control?.checkCancellation()
        guard (try? Identity(archive)) == original else { throw EditError.modifiedExternally }

        // 原子替换并保留旧版本，替换成功后再处理旧版本（不"先删原包再移动"）
        let backupName = backupItemName(for: archive)
        _ = try fm.replaceItemAt(archive, withItemAt: temp, backupItemName: backupName,
                                 options: [.withoutDeletingBackupItem])
        let backup = directory.appendingPathComponent(backupName)
        if trashOldVersion {
            do {
                try fm.trashItem(at: backup, resultingItemURL: nil)
            } catch {
                // 废纸篓不可用时保留旁边的旧版本，不能静默删除恢复点。
            }
        } else {
            try? fm.removeItem(at: backup)
        }
        succeeded = true
        control?.update(1)
    }

    public static func cleanupAbandonedTransactions() { ZipWriteWorkspace.cleanupAbandoned() }

    /// path 本身或它的某一级上层目录在集合中（"/" 分隔）
    static func isSelfOrDescendant(_ path: String, of set: Set<String>) -> Bool {
        if set.contains(path) { return true }
        var current = Substring(path)
        while let slash = current.lastIndex(of: "/") {
            current = current[..<slash]
            if !current.isEmpty, set.contains(String(current)) { return true }
        }
        return false
    }

    /// libzip 关闭时按索引顺序处理未删除的条目：新加入的条目要压缩，按原始大小计；
    /// 原有条目只复制压缩数据，比压缩快一个数量级，按压缩后大小的 1/10 计
    private static func libzipWork(_ handle: OpaquePointer, originalCount: Int64) -> [Double] {
        var weights: [Double] = []
        let count = zip_get_num_entries(handle, 0)
        for index in 0..<UInt64(max(count, 0)) {
            var stat = zip_stat_t()
            zip_stat_init(&stat)
            // 已删除的条目 stat 失败，libzip 也不会处理它
            guard zip_stat_index(handle, index, 0, &stat) == 0 else { continue }
            let isNew = Int64(index) >= originalCount
            let bytes: UInt64
            if isNew {
                bytes = stat.valid & UInt64(ZIP_STAT_SIZE) != 0 ? stat.size : 0
            } else {
                bytes = (stat.valid & UInt64(ZIP_STAT_COMP_SIZE) != 0 ? stat.comp_size : 0) / 10
            }
            weights.append(max(Double(bytes), 1))
        }
        return weights
    }

    /// 旧版本移到废纸篓后的名字，如"资料（修改前）.zip"
    private static func backupItemName(for archive: URL) -> String {
        let stem = archive.deletingPathExtension().lastPathComponent
        let ext = archive.pathExtension
        var label = String(localized: "\(stem)（修改前）", bundle: CoreStrings.bundle)
        let directory = archive.deletingLastPathComponent()
        let withExtension = { (label: String) in ext.isEmpty ? label : label + "." + ext }
        if FileManager.default.fileExists(atPath: directory.appendingPathComponent(withExtension(label)).path) {
            label += " " + UUID().uuidString.prefix(4)
        }
        return withExtension(label)
    }

    /// 原始条目：(索引, 与目录树一致的规范化路径, 是否目录条目)。有重复路径时按只读处理。
    private static func rawEntries(_ handle: OpaquePointer) throws -> [(UInt64, String, Bool)] {
        var result: [(UInt64, String, Bool)] = []
        var seen = Set<String>()
        // 与 ZipArchive 同一规则解码，路径才与目录树一致
        let names = ZipNameDecoder.names(handle)
        let count = zip_get_num_entries(handle, 0)
        for index in 0..<UInt64(max(count, 0)) {
            guard Int(index) < names.count, let name = names[Int(index)] else { continue }
            let normalized = name.split(separator: "/", omittingEmptySubsequences: true)
                .filter { $0 != "." && $0 != ".." }.joined(separator: "/")
            guard !normalized.isEmpty else { continue }
            guard seen.insert(normalized).inserted else { throw EditError.duplicatePaths }
            result.append((index, normalized, name.hasSuffix("/")))
        }
        return result
    }

    private static func entryCount(_ url: URL) throws -> Int64 {
        var code: Int32 = 0
        guard let handle = zip_open(url.path, ZIP_RDONLY, &code) else { throw EditError.notZip }
        defer { zip_discard(handle) }
        return zip_get_num_entries(handle, 0)
    }

    private static func libzipError(_ handle: OpaquePointer) -> Error {
        if zip_error_code_zip(zip_get_error(handle)) == ZIP_ER_EXISTS { return EditError.nameExists("") }
        return EditError.failed(String(localized: "写入压缩包失败：\(String(cString: zip_strerror(handle)))", bundle: CoreStrings.bundle))
    }
}

extension ZipEditor {
    public enum ConflictAction: Sendable { case replace, skip, keepBoth, cancel }
    public struct ConflictDecision: Sendable {
        public let action: ConflictAction
        public let applyToAll: Bool
        public init(_ action: ConflictAction, applyToAll: Bool = false) {
            self.action = action
            self.applyToAll = applyToAll
        }
    }
    public struct ImportConflict: Sendable {
        public let path: String
        public let incomingIsDirectory: Bool
        public let existingIsDirectory: Bool
        /// 本批中排在后面、同样会重名的顶层项目数；为 0 时"应用到全部"没有意义
        public let remainingConflicts: Int

        public init(path: String, incomingIsDirectory: Bool, existingIsDirectory: Bool, remainingConflicts: Int) {
            self.path = path
            self.incomingIsDirectory = incomingIsDirectory
            self.existingIsDirectory = existingIsDirectory
            self.remainingConflicts = remainingConflicts
        }
    }

    /// 一次导入的结果（按拖入的顶层项目计数）；entries 为实际写入的条目数（含目录内的后代）
    public struct ImportSummary: Sendable {
        public var added = 0
        public var replaced = 0
        public var skipped = 0
        public var entries = 0
    }

    private struct ImportEntry {
        let source: URL
        let path: String
        let isDirectory: Bool
        let identity: Identity
        let mode: UInt32
    }

    /// 添加内容仍限未加密 ZIP；现有加密条目的删除/改名规则保持原样。
    public static func checkAdditions(_ archive: URL) throws {
        try checkWritable(archive)
        guard try !ZipArchive.open(archive).tree.hasEncryptedEntries else { throw EditError.encryptedWrite }
    }

    public static func newFolderPath(in tree: ArchiveTree, parent: String, name: String) throws -> String {
        try SiblingNames(tree: tree, parent: parent).folderPath(for: name)
    }

    /// 某一层已有项目的查重集合（Unicode 规范化 + 忽略大小写，规则同 collisionKey）。
    /// 新建文件夹面板每输入一个字都要校验：弹窗时建立一次，之后每次查询为常数时间，
    /// 不再扫描整个压缩包的全部条目（10 万条目时每次约 37 ms）。提交时仍按最新压缩包重新校验
    public struct SiblingNames: Sendable {
        let parent: String
        let keys: Set<String>

        public init(tree: ArchiveTree, parent: String) throws {
            try ZipEditor.validateParent(parent, in: tree)
            self.parent = parent
            keys = Set((tree.children[parent] ?? []).compactMap { tree.items[$0]?.name }.map(ZipEditor.collisionKey))
        }

        public func folderPath(for name: String) throws -> String {
            let name = try ZipEditor.validatedName(name)
            guard !keys.contains(ZipEditor.collisionKey(name)) else { throw EditError.nameExists(name) }
            return parent.isEmpty ? name : parent + "/" + name
        }
    }

    @discardableResult
    public static func createDirectory(archive: URL, parent: String, name: String,
                                       control: ZipWriteControl? = nil) throws -> String {
        try checkAdditions(archive)
        let original = try Identity(archive)
        let path = try newFolderPath(in: ZipArchive.open(archive).tree, parent: parent, name: name)
        try transaction(archive: archive, trashOldVersion: false, expected: original, control: control) { handle, _ in
            guard zip_dir_add(handle, path + "/", zip_flags_t(ZIP_FL_ENC_UTF_8)) >= 0 else {
                throw libzipError(handle)
            }
            return 1
        } verify: { tree, _ in tree.items[path]?.isDirectory == true }
        return path
    }

    /// 固定清单 → 逐个询问顶层冲突 → 暂存输入 → 单次原子提交。目录替换包含整个原目录。
    @discardableResult
    public static func addFiles(archive: URL, sources: [URL], parent: String,
                                trashOldVersion: Bool, control: ZipWriteControl = ZipWriteControl(),
                                resolve: (ImportConflict) throws -> ConflictDecision) throws -> ImportSummary {
        try checkAdditions(archive)
        let original = try Identity(archive)
        let tree = try ZipArchive.open(archive).tree
        try validateParent(parent, in: tree)
        guard Set(tree.items.keys.map(collisionKey)).count == tree.items.count else { throw EditError.duplicatePaths }
        var occupied = Dictionary(uniqueKeysWithValues: tree.items.map { (collisionKey($0.key), (path: $0.key, isDirectory: $0.value.isDirectory)) })
        var planned: [ImportEntry] = []
        var removed = Set<String>()
        var batchDecision: ConflictAction?
        // 去掉被其他来源包含的子项（父目录已整体导入）。按路径集合逐级查上层目录，不两两比较
        let unique = Array(Set(sources.map { $0.standardizedFileURL })).sorted { $0.path < $1.path }
        let sourcePaths = Set(unique.map(\.path))
        let roots = unique.filter { url in
            let parent = (url.path as NSString).deletingLastPathComponent
            return parent == url.path || !isSelfOrDescendant(parent, of: sourcePaths)
        }
        var summary = ImportSummary()
        // 预先算出各顶层项目是否与现有内容重名，用于告诉用户后面还有几个冲突
        let conflicting = roots.map { root in
            let name = root.lastPathComponent
            return occupied[collisionKey(parent.isEmpty ? name : parent + "/" + name)] != nil
        }
        for (rootIndex, source) in roots.enumerated() {
            try control.checkCancellation()
            var info = stat()
            guard lstat(source.path, &info) == 0 else { throw EditError.sourceChanged(source.lastPathComponent) }
            let directory = info.st_mode & S_IFMT == S_IFDIR
            guard directory || info.st_mode & S_IFMT == S_IFREG else { throw EditError.unsupportedInput(source.lastPathComponent) }
            _ = try validatedName(source.lastPathComponent)
            let name = source.lastPathComponent
            var target = parent.isEmpty ? name : parent + "/" + name
            if let found = occupied[collisionKey(target)] {
                let existing = found.path
                let action: ConflictAction
                if let batchDecision { action = batchDecision } else {
                    let remaining = conflicting[(rootIndex + 1)...].filter { $0 }.count
                    let decision = try resolve(ImportConflict(path: existing, incomingIsDirectory: directory,
                                                              existingIsDirectory: found.isDirectory,
                                                              remainingConflicts: remaining))
                    action = decision.action
                    if decision.applyToAll { batchDecision = action }
                }
                try control.checkCancellation()
                switch action {
                case .cancel: throw EditError.cancelled
                case .skip:
                    summary.skipped += 1
                    continue
                case .replace:
                    summary.replaced += 1
                    for (key, value) in occupied where value.path == existing || value.path.hasPrefix(existing + "/") {
                        if tree.items[value.path] != nil { removed.insert(value.path) }
                        occupied.removeValue(forKey: key)
                    }
                    planned.removeAll { $0.path == existing || $0.path.hasPrefix(existing + "/") }
                case .keepBoth:
                    summary.added += 1
                    let stem = directory ? name : (name as NSString).deletingPathExtension
                    let ext = directory ? "" : (name as NSString).pathExtension
                    var suffix = 2
                    repeat {
                        let alternate = ext.isEmpty ? "\(stem) \(suffix)" : "\(stem) \(suffix).\(ext)"
                        target = parent.isEmpty ? alternate : parent + "/" + alternate
                        suffix += 1
                    } while occupied[collisionKey(target)] != nil
                }
            } else {
                summary.added += 1
            }
            func collect(_ url: URL, path: String, depth: Int) throws {
                try control.checkCancellation()
                guard depth < 256, planned.count < 1_000_000 else { throw EditError.unsupportedInput(url.lastPathComponent) }
                var metadata = stat()
                guard lstat(url.path, &metadata) == 0 else { throw EditError.sourceChanged(url.lastPathComponent) }
                let isDirectory = metadata.st_mode & S_IFMT == S_IFDIR
                guard isDirectory || metadata.st_mode & S_IFMT == S_IFREG else { throw EditError.unsupportedInput(url.lastPathComponent) }
                if UInt64(metadata.st_ino) == original.inode && metadata.st_dev == original.device {
                    // 不能把目标包本身（包括硬链接）递归导入自身。
                    throw EditError.unsupportedInput(url.lastPathComponent)
                }
                guard occupied[collisionKey(path)] == nil else {
                    throw EditError.nameExists(path)
                }
                planned.append(ImportEntry(source: url, path: path, isDirectory: isDirectory,
                                           identity: try Identity(url), mode: UInt32(metadata.st_mode)))
                occupied[collisionKey(path)] = (path: path, isDirectory: isDirectory)
                if isDirectory {
                    for child in try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
                        .sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                        _ = try validatedName(child.lastPathComponent)
                        try collect(child, path: path + "/" + child.lastPathComponent, depth: depth + 1)
                    }
                }
            }
            try collect(source, path: target, depth: 0)
        }
        guard !planned.isEmpty else { return summary }
        summary.entries = planned.count
        var inputSize: Int64 = 0
        for entry in planned where !entry.isDirectory {
            let (total, overflow) = inputSize.addingReportingOverflow(entry.identity.size)
            guard !overflow else { throw EditError.insufficientSpace }
            inputSize = total
        }
        let (base, overflow) = original.size.addingReportingOverflow(inputSize)
        guard !overflow, base <= (Int64.max - 16_777_216) / 2 else { throw EditError.insufficientSpace }
        var volume = statfs()
        if statfs(archive.path, &volume) == 0 {
            let available = UInt64(volume.f_bavail) * UInt64(volume.f_bsize)
            if available < UInt64(base * 2 + 16_777_216) { throw EditError.insufficientSpace }
        }
        var checksums: [String: (UInt32, Int64)] = [:]
        // 暂存阶段占进度条前 8%，按字节计（见 ZipWriteControl 的分段说明）
        let totalBytes = max(inputSize, 1)
        var stagedBytes: Int64 = 0
        try transaction(archive: archive, trashOldVersion: trashOldVersion && !removed.isEmpty,
                        expected: original, control: control) { handle, stage in
            let oldEntries = try rawEntries(handle)
            let deleting = oldEntries.filter { removed.contains($0.1) }
            for (index, _, _) in deleting {
                guard zip_delete(handle, index) == 0 else { throw libzipError(handle) }
            }
            for (offset, entry) in planned.enumerated() {
                try control.checkCancellation()
                let index: Int64
                if entry.isDirectory {
                    // 目录只核对是否仍是同一个目录：Finder 浏览时会写入 .DS_Store，目录的修改时间随之变化。
                    // 目录中的文件各自在暂存时核对大小、时间与内容。
                    guard try Identity(entry.source).isSameObject(as: entry.identity) else {
                        throw EditError.sourceChanged(entry.source.lastPathComponent)
                    }
                    index = zip_dir_add(handle, entry.path + "/", zip_flags_t(ZIP_FL_ENC_UTF_8))
                } else {
                    let snapshot = stage.appendingPathComponent("input-\(offset)")
                    let base = stagedBytes
                    checksums[entry.path] = try stageInput(entry, to: snapshot, control: control) { copied in
                        control.update(0.08 * Double(base + copied) / Double(totalBytes))
                    }
                    stagedBytes += entry.identity.size
                    guard let source = zip_source_file(handle, snapshot.path, 0, -1) else { throw libzipError(handle) }
                    index = zip_file_add(handle, entry.path, source, zip_flags_t(ZIP_FL_ENC_UTF_8))
                    if index < 0 { zip_source_free(source) }
                }
                guard index >= 0 else { throw libzipError(handle) }
                guard zip_file_set_mtime(handle, UInt64(index), entry.identity.modified.tv_sec, 0) == 0,
                      zip_file_set_external_attributes(handle, UInt64(index), 0, UInt8(ZIP_OPSYS_UNIX), entry.mode << 16) == 0 else {
                    throw libzipError(handle)
                }
            }
            return Int64(planned.count - deleting.count)
        } verify: { result, temp in
            guard planned.allSatisfy({ result.items[$0.path]?.isDirectory == $0.isDirectory }) else { return false }
            var code: Int32 = 0
            guard let handle = zip_open(temp.path, ZIP_RDONLY, &code) else { return false }
            defer { zip_discard(handle) }
            // 校验阶段占 95–98%，按读回的字节推进
            let verifyTotal = Double(max(checksums.values.reduce(0) { $0 + $1.1 }, 1))
            var verified: Int64 = 0
            for (path, checksum) in checksums {
                try control.checkCancellation()
                guard let index = result.items[path]?.entryIndex,
                      let file = zip_fopen_index(handle, UInt64(index), 0) else { return false }
                defer { zip_fclose(file) }
                var buffer = [UInt8](repeating: 0, count: 262_144)
                var size: Int64 = 0
                var crc: uLong = 0
                while true {
                    try control.checkCancellation()
                    let count = buffer.withUnsafeMutableBytes { zip_fread(file, $0.baseAddress!, UInt64($0.count)) }
                    guard count >= 0 else { return false }
                    if count == 0 { break }
                    size += count
                    verified += count
                    control.update(0.95 + 0.03 * Double(verified) / verifyTotal)
                    crc = buffer.withUnsafeBufferPointer { crc32(crc, $0.baseAddress, UInt32(count)) }
                }
                guard size == checksum.1, UInt32(crc) == checksum.0 else { return false }
            }
            return true
        }
        return summary
    }

    private static func collisionKey(_ path: String) -> String { path.precomposedStringWithCanonicalMapping.lowercased() }

    private static func validatedName(_ raw: String) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\\"), !name.contains("\0") else {
            throw EditError.invalidName
        }
        return name
    }

    private static func validateParent(_ parent: String, in tree: ArchiveTree) throws {
        guard parent.isEmpty || tree.items[parent]?.isDirectory == true else { throw ArchiveError.entryNotFound(parent) }
        guard parent.split(separator: "/").allSatisfy({ $0 != "." && $0 != ".." && !$0.contains("\0") }) else {
            throw EditError.invalidName
        }
    }

    private static func stageInput(_ entry: ImportEntry, to target: URL, control: ZipWriteControl,
                                   progress: (Int64) -> Void) throws -> (UInt32, Int64) {
        guard try Identity(entry.source) == entry.identity else { throw EditError.sourceChanged(entry.source.lastPathComponent) }
        let descriptor = open(entry.source.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw EditError.sourceChanged(entry.source.lastPathComponent) }
        let input = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? input.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              UInt64(info.st_ino) == entry.identity.inode else { throw EditError.sourceChanged(entry.source.lastPathComponent) }
        guard FileManager.default.createFile(atPath: target.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw EditError.failed(String(cString: strerror(errno)))
        }
        let output = try FileHandle(forWritingTo: target)
        defer { try? output.close() }
        var size: Int64 = 0
        var crc: uLong = 0
        // 每块在各自的自动释放池里读写：read(upToCount:) 返回的数据块由自动释放池持有，
        // 不逐块清空时整个文件会留在内存里直到导入结束（导入 1.9 GB 文件时后台服务占用 1.9 GB）
        while try autoreleasepool(invoking: { () throws -> Bool in
            guard let data = try input.read(upToCount: 262_144), !data.isEmpty else { return false }
            try control.checkCancellation()
            size += Int64(data.count)
            guard size <= entry.identity.size else { throw EditError.sourceChanged(entry.source.lastPathComponent) }
            crc = data.withUnsafeBytes { crc32(crc, $0.bindMemory(to: UInt8.self).baseAddress, UInt32($0.count)) }
            try output.write(contentsOf: data)
            progress(size)
            return true
        }) {}
        guard size == entry.identity.size, try Identity(entry.source) == entry.identity else {
            throw EditError.sourceChanged(entry.source.lastPathComponent)
        }
        return (UInt32(crc), size)
    }
}
