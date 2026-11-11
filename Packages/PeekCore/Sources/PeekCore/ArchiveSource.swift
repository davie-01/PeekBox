import Foundation
import UniformTypeIdentifiers

/// 压缩包数据源：ZIP 优先用 libzip，其余格式与 libzip 打不开的 ZIP（如分卷）交给 XADMaster。
/// 首次访问时打开并缓存；密码只保存在本对象内存中，预览关闭即随之释放。
public final class ArchiveSource: EntrySource {
    public let rootURL: URL
    public let showHidden: Bool

    private struct State {
        var password: String?
        /// 每次失效（invalidate、用新密码重开）递增。读取完成时只有代数未变的结果才能写入缓存：
        /// 否则旧的慢读取会在新读取之后完成，把已失效的目录树写回来
        var generation = 0
        var loading: (task: Task<any ArchiveReader, Error>, generation: Int, identity: FileIdentity?)?
        var reader: (any ArchiveReader)?
        /// 读取器对应的文件身份（开始读取前记下：读取期间被替换时宁可多刷新一次）
        var identity: FileIdentity?

        mutating func discardReader() {
            generation += 1
            loading = nil
            reader = nil
            identity = nil
        }
    }
    private let state = Locked(State())

    public init(rootURL: URL, showHidden: Bool) {
        self.rootURL = rootURL
        self.showHidden = showHidden
    }

    public var password: String? { state.value.password }

    /// 设置密码。reopen 为 true 时丢弃已打开的读取器（文件名加密的压缩包需要用新密码重新解析）；
    /// 只有内容加密时目录树不变，传 false 只更新密码。
    public func setPassword(_ password: String?, reopen: Bool = true) {
        state.withLock {
            $0.password = password
            guard reopen else { return }
            $0.discardReader()
        }
    }

    /// 压缩包被修改（如重命名）后丢弃已打开的读取器，下次访问时重新读取；保留已输入的密码
    public func invalidate() {
        state.withLock { $0.discardReader() }
    }

    /// 提取时发现密码错误：只清除密码，保留目录树
    public func forgetPassword() {
        setPassword(nil, reopen: false)
    }

    /// 验证并设置密码。已打开（仅内容加密）时试解压一个加密文件；尚未打开（文件名加密）时用该密码重新解析。
    /// 密码错误抛出 `ArchiveError.wrongPassword`，且不保留该密码。
    public func unlock(with password: String) async throws {
        if let reader = loadedReader {
            try await Task.detached(priority: .userInitiated) { try reader.verifyPassword(password) }.value
            setPassword(password, reopen: false)
            return
        }
        setPassword(password)
        do {
            _ = try await self.reader()
        } catch {
            setPassword(nil)
            throw error
        }
    }

    /// 已打开的读取器，供 File Promise 在后台队列同步取用。
    public var loadedReader: (any ArchiveReader)? { state.value.reader }

    /// 已读取的目录树之后，磁盘上的压缩包被替换、删除或改写过（尚未读取时为 false）
    public var hasChangedOnDisk: Bool {
        guard let identity = state.value.identity else { return false }
        return FileIdentity(path: rootURL.path) != identity
    }

    public func reader() async throws -> any ArchiveReader {
        let (task, generation) = state.withLock { state in
            if let loading = state.loading, loading.generation == state.generation {
                return (loading.task, loading.generation)
            }
            let url = rootURL
            let password = state.password
            let identity = FileIdentity(path: url.path)
            let task = Task.detached(priority: .userInitiated) { try Self.open(url, password: password) }
            state.loading = (task, state.generation, identity)
            return (task, state.generation)
        }
        do {
            let reader = try await task.value
            let published: Bool = state.withLock { state in
                guard state.generation == generation else { return false }
                state.reader = reader
                state.identity = state.loading?.identity
                return true
            }
            // 读取期间已失效（压缩包被修改、换了密码）：丢弃这次结果，按最新条件重新读取
            return published ? reader : try await self.reader()
        } catch {
            // 失败（如需要密码）后允许用新条件重试；只清除自己这一代的加载状态
            state.withLock { state in
                if state.generation == generation, state.loading?.generation == generation { state.loading = nil }
            }
            throw error
        }
    }

    public func children(of parent: Entry?) async throws -> [Entry] {
        let tree = try await reader().tree
        let parentPath = parent.map { Self.archivePath(of: $0) } ?? ""
        return (tree.children[parentPath] ?? []).compactMap { path in
            guard let item = tree.items[path] else { return nil }
            if !showHidden, item.name.hasPrefix(".") || item.name == "__MACOSX" { return nil }
            return Entry(
                id: Self.entryID(for: path),
                name: item.name,
                isDirectory: item.isDirectory,
                size: item.size,
                modified: item.modified,
                kind: Self.kind(of: item),
                archiveURL: rootURL,
                isEncrypted: item.isEncrypted
            )
        }
    }

    public func archiveSource(for archive: URL) -> ArchiveSource? {
        archive == rootURL ? self : nil
    }

    public static func entryID(for path: String) -> String { "archive:" + path }

    public static func archivePath(of entry: Entry) -> String {
        String(entry.id.dropFirst("archive:".count))
    }

    /// 供 Broker 等进程直接打开压缩包（同步，调用方负责放到后台）。
    public static func openReader(_ url: URL, password: String?) throws -> any ArchiveReader {
        try open(url, password: password)
    }

    /// 运行在沙盒中（预览扩展）。沙盒外（后台服务、测试）能直接读到所有分卷
    private static let isSandboxed = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil

    static func open(_ url: URL, password: String?) throws -> any ArchiveReader {
        do {
            return try openLocally(url, password: password)
        } catch ArchiveError.volumesUnreachable(_) where isSandboxed {
            // 单独预览分卷包：交给后台服务读取（见 BrokerArchiveReader）
            return try BrokerArchiveReader.open(url, password: password)
        }
    }

    private static func openLocally(_ url: URL, password: String?) throws -> any ArchiveReader {
        if case .part(_, let first) = VolumeInfo.detect(url) {
            throw ArchiveError.notFirstVolume(first)
        }
        var zipError: Error?
        // 分卷 ZIP 的末卷从数据中间切开，开头不是 PK，按扩展名也要交给 libzip 才能拿到多卷错误码
        if hasZipSignature(url) || url.pathExtension.lowercased() == "zip" {
            do { return try ZipArchive.open(url) } catch { zipError = error }
        }
        // 分卷包：在文件夹预览中扩展可读到其他卷，XADMaster 能正常打开；单独预览时读不到，
        // XADMaster 会报错或返回空列表
        let multiVolume = VolumeInfo.detect(url) == .first
            || (zipError as? ArchiveError) == .volumesUnreachable(url.lastPathComponent)
        // 读不到第二卷时不让 XADMaster 去试：它只能看到首卷，会把读不到数据误报成"密码不正确"，
        // 带着正确密码也解不开。直接判定其他卷不可达（沙盒中随后交给后台服务）
        if multiVolume, let second = VolumeInfo.secondVolume(of: url), !Self.isReadable(second) {
            throw ArchiveError.volumesUnreachable(url.lastPathComponent)
        }
        let archive: XADArchive
        do {
            archive = try XADArchive.open(url, password: password)
        } catch let error as ArchiveError where error == .passwordRequired || error == .wrongPassword {
            throw error
        } catch {
            if multiVolume { throw ArchiveError.volumesUnreachable(url.lastPathComponent) }
            throw zipError ?? error
        }
        if multiVolume, archive.tree.items.isEmpty {
            throw ArchiveError.volumesUnreachable(url.lastPathComponent)
        }
        return archive
    }

    private static func isReadable(_ url: URL) -> Bool {
        let descriptor = Darwin.open(url.path, O_RDONLY)
        guard descriptor >= 0 else { return false }
        close(descriptor)
        return true
    }

    private static func readSignature(_ url: URL) -> Data {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return Data() }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 4)) ?? Data()
    }

    /// 只看文件开头的签名判断是否 ZIP（不解析）：拖入等需要快速排除只读格式的场合使用
    public static func looksLikeZip(_ url: URL) -> Bool {
        hasZipSignature(url) || url.pathExtension.lowercased() == "zip"
    }

    private static func hasZipSignature(_ url: URL) -> Bool {
        let magic = readSignature(url)
        return magic.starts(with: [0x50, 0x4B]) // PK
    }

    private static func kind(of item: ArchiveTree.Item) -> String? {
        if item.isDirectory { return UTType.folder.localizedDescription }
        return UTType(filenameExtension: (item.name as NSString).pathExtension)?.localizedDescription
    }
}
