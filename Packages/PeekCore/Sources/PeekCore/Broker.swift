import Foundation

/// 扩展 / 主应用 → Broker 的 XPC 协议。
@objc public protocol PeekBrokerProtocol {
    func ping(reply: @escaping @Sendable (String) -> Void)
    func openMainApp(command: String, reply: @escaping @Sendable (Bool, String?) -> Void)
    /// 沙盒扩展无法直接交给 LaunchServices 打开文件，由 Broker 代办；appPath 为空时用默认应用。
    func openFile(path: String, appPath: String?, reply: @escaping @Sendable (Bool, String?) -> Void)
    /// 写入剪贴板。沙盒扩展写文件 URL 时需要对该文件持有沙盒扩展，Broker 缓存中的文件无法满足，故由 Broker 代写。
    func copyToPasteboard(paths: [String], text: String?, reply: @escaping @Sendable (Bool, String?) -> Void)
    /// 合并写入共享设置（plist 编码的字典）。沙盒扩展对 App Group 容器只有读权限。
    func setSettings(_ data: Data, reply: @escaping @Sendable (Bool) -> Void)
    /// 在 Finder 中显示并选中
    func reveal(paths: [String], reply: @escaping @Sendable (Bool, String?) -> Void)
    /// 移到废纸篓（可在 Finder 中"放回原处"）
    func trash(paths: [String], reply: @escaping @Sendable (Bool, String?) -> Void)
    /// 把压缩包内条目提取到 Broker 的缓存目录，返回提取后的路径（用于打开、拷贝）。
    /// 密码只在本次请求中使用，不保存。
    func materialize(archivePath: String, entryPaths: [String], password: String?,
                     reply: @escaping @Sendable ([String]?, String?) -> Void)
    /// 写权限探测：在目录中依次 创建 → 原子替换 → 移到废纸篓 一个探测文件，返回每步结果。
    func probeWrite(directory: String, reply: @escaping @Sendable (Bool, String) -> Void)
    /// 以 Broker 的身份尝试读取：目录列出内容，文件打开读取。隐私保护位置未决定时会触发系统授权提示。
    func checkAccess(paths: [String], reply: @escaping @Sendable ([Bool]) -> Void)
    /// 重命名 ZIP 内的条目：后台服务弹出输入面板并执行修改。
    /// 回复 (新的归档内路径, 错误信息)；用户取消时两者都为 nil。
    func renameInArchive(archivePath: String, entryPath: String, reply: @escaping @Sendable (String?, String?) -> Void)
    /// 删除 ZIP 内的条目（目录连同后代）。回复 (是否成功, 错误信息)
    func deleteInArchive(archivePath: String, entryPaths: [String], reply: @escaping @Sendable (Bool, String?) -> Void)
    func archiveWriteStatus(archivePath: String, reply: @escaping @Sendable (String?) -> Void)
    /// 解析压缩包并回传目录树（JSON 编码的 ArchiveTree）或错误（JSON 编码的 ArchiveError）。
    /// 单独预览分卷包时沙盒扩展读不到其他卷，由后台服务代读（见 BrokerArchiveReader）
    func archiveTree(archivePath: String, password: String?, reply: @escaping @Sendable (Data?, Data?) -> Void)
    /// 把条目提取到各自的目标路径（目标须尚不存在），回复 JSON 编码的 ArchiveError，成功时为 nil
    func extractEntries(archivePath: String, entryPaths: [String], targets: [String], password: String?,
                        reply: @escaping @Sendable (Data?) -> Void)
    func createArchiveDirectory(archivePath: String, parent: String, reply: @escaping @Sendable (String?, String?) -> Void)
    /// 回复 (新增, 替换, 跳过, 是否取消, 错误信息)，数量按拖入的顶层项目计
    func addToArchive(archivePath: String, sourcePaths: [String], parent: String,
                      reply: @escaping @Sendable (Int, Int, Int, Bool, String?) -> Void)
}

public enum BrokerError: LocalizedError {
    case unavailable(String)
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let detail): String(localized: "后台服务不可用：\(detail)", bundle: CoreStrings.bundle)
        case .failed(let detail): detail
        }
    }
}

public final class BrokerClient: @unchecked Sendable {
    public static let shared = BrokerClient()

    /// 没有进行中的请求后，保留连接的时长。后台服务在所有连接断开 30 秒后退出，
    /// 而系统会把预览扩展进程缓存很久，一直持有连接会让后台服务跟着常驻
    private static let idleRelease: TimeInterval = 2

    private let lock = NSLock()
    private var connection: NSXPCConnection?
    private var inFlight = 0
    private var pendingRelease: DispatchWorkItem?

    private func currentConnection() -> NSXPCConnection {
        lock.lock()
        defer { lock.unlock() }
        if let connection { return connection }
        let new = NSXPCConnection(machServiceName: PeekShared.brokerMachService, options: [])
        new.remoteObjectInterface = NSXPCInterface(with: PeekBrokerProtocol.self)
        new.setCodeSigningRequirement(PeekShared.teamRequirement)
        new.invalidationHandler = { [weak self, weak new] in self?.reset(new) }
        new.interruptionHandler = { [weak self, weak new] in self?.reset(new) }
        new.resume()
        connection = new
        return new
    }

    /// 只清除出错的那个连接：它的回调可能在新连接建立之后才到
    private func reset(_ ended: NSXPCConnection?) {
        lock.lock()
        if connection === ended { connection = nil }
        lock.unlock()
    }

    private func beginRequest() {
        lock.lock()
        inFlight += 1
        pendingRelease?.cancel()
        pendingRelease = nil
        lock.unlock()
    }

    private func endRequest() {
        lock.lock()
        defer { lock.unlock() }
        inFlight -= 1
        guard inFlight == 0 else { return }
        let release = DispatchWorkItem { [weak self] in self?.releaseIfIdle() }
        pendingRelease = release
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Self.idleRelease, execute: release)
    }

    private func releaseIfIdle() {
        lock.lock()
        guard inFlight == 0, let idle = connection else {
            lock.unlock()
            return
        }
        connection = nil
        pendingRelease = nil
        lock.unlock()
        idle.invalidate()
    }

    /// 包装一次 XPC 调用：错误回调与正常回复只会生效其中一个。
    private func call<T: Sendable>(
        _ body: @escaping (PeekBrokerProtocol, @escaping @Sendable (Result<T, Error>) -> Void) -> Void
    ) async throws -> T {
        beginRequest()
        defer { endRequest() }
        return try await withCheckedThrowingContinuation { continuation in
            let once = ResumeOnce(continuation)
            let proxy = currentConnection().remoteObjectProxyWithErrorHandler { error in
                once.resume(.failure(BrokerError.unavailable(error.localizedDescription)))
            }
            guard let broker = proxy as? PeekBrokerProtocol else {
                once.resume(.failure(BrokerError.unavailable(String(localized: "代理类型不匹配", bundle: CoreStrings.bundle))))
                return
            }
            body(broker) { once.resume($0) }
        }
    }

    public func ping() async throws -> String {
        try await call { broker, done in
            broker.ping { done(.success($0)) }
        }
    }

    public func openFile(_ url: URL, with app: URL? = nil) async throws {
        let _: Bool = try await call { broker, done in
            broker.openFile(path: url.path, appPath: app?.path) { ok, message in
                done(ok ? .success(true) : .failure(BrokerError.failed(message ?? String(localized: "打开文件失败", bundle: CoreStrings.bundle))))
            }
        }
    }

    public func copy(_ urls: [URL]) async throws {
        try await copyToPasteboard(paths: urls.map(\.path), text: nil)
    }

    public func copy(text: String) async throws {
        try await copyToPasteboard(paths: [], text: text)
    }

    private func copyToPasteboard(paths: [String], text: String?) async throws {
        let _: Bool = try await call { broker, done in
            broker.copyToPasteboard(paths: paths, text: text) { ok, message in
                done(ok ? .success(true) : .failure(BrokerError.failed(message ?? String(localized: "写入剪贴板失败", bundle: CoreStrings.bundle))))
            }
        }
    }

    public func setSettings(_ data: Data) async throws {
        let _: Bool = try await call { broker, done in
            broker.setSettings(data) { ok in
                done(ok ? .success(true) : .failure(BrokerError.failed(String(localized: "写入设置失败", bundle: CoreStrings.bundle))))
            }
        }
    }

    public func reveal(_ urls: [URL]) async throws {
        let _: Bool = try await call { broker, done in
            broker.reveal(paths: urls.map(\.path)) { ok, message in
                done(ok ? .success(true) : .failure(BrokerError.failed(message ?? String(localized: "无法在 Finder 中显示", bundle: CoreStrings.bundle))))
            }
        }
    }

    public func trash(_ urls: [URL]) async throws {
        let _: Bool = try await call { broker, done in
            broker.trash(paths: urls.map(\.path)) { ok, message in
                done(ok ? .success(true) : .failure(BrokerError.failed(message ?? String(localized: "移到废纸篓失败", bundle: CoreStrings.bundle))))
            }
        }
    }

    public func materialize(archive: URL, entryPaths: [String], password: String?) async throws -> [URL] {
        try await call { broker, done in
            broker.materialize(archivePath: archive.path, entryPaths: entryPaths, password: password) { paths, message in
                if let paths {
                    done(.success(paths.map { URL(fileURLWithPath: $0) }))
                } else {
                    done(.failure(BrokerError.failed(message ?? String(localized: "提取失败", bundle: CoreStrings.bundle))))
                }
            }
        }
    }

    public func probeWrite(directory: URL) async throws -> String {
        try await call { broker, done in
            broker.probeWrite(directory: directory.path) { ok, detail in
                done(ok ? .success(detail) : .failure(BrokerError.failed(detail)))
            }
        }
    }

    public func checkAccess(_ urls: [URL]) async throws -> [Bool] {
        try await call { broker, done in
            broker.checkAccess(paths: urls.map(\.path)) { done(.success($0)) }
        }
    }

    /// 返回新的归档内路径；用户取消时返回 nil
    public func renameInArchive(_ archive: URL, entryPath: String) async throws -> String? {
        try await call { broker, done in
            broker.renameInArchive(archivePath: archive.path, entryPath: entryPath) { newPath, message in
                if let message { done(.failure(BrokerError.failed(message))) } else { done(.success(newPath)) }
            }
        }
    }

    public func deleteInArchive(_ archive: URL, entryPaths: [String]) async throws {
        let _: Bool = try await call { broker, done in
            broker.deleteInArchive(archivePath: archive.path, entryPaths: entryPaths) { ok, message in
                done(ok ? .success(true) : .failure(BrokerError.failed(message ?? String(localized: "删除失败", bundle: CoreStrings.bundle))))
            }
        }
    }

    /// 同步调用：供同步接口（ArchiveReader）在后台线程使用。回复在方法返回前送达，不占用 Swift 并发的线程
    private func callSync<T: Sendable>(
        _ body: (PeekBrokerProtocol, @escaping @Sendable (Result<T, Error>) -> Void) -> Void
    ) throws -> T {
        beginRequest()
        defer { endRequest() }
        let result = SyncResult<T>()
        let proxy = currentConnection().synchronousRemoteObjectProxyWithErrorHandler { error in
            result.value = .failure(BrokerError.unavailable(error.localizedDescription))
        }
        guard let broker = proxy as? PeekBrokerProtocol else {
            throw BrokerError.unavailable(String(localized: "代理类型不匹配", bundle: CoreStrings.bundle))
        }
        body(broker) { result.value = $0 }
        return try result.value.get()
    }

    private static func decodeError(_ data: Data?) -> Error? {
        guard let data else { return nil }
        return (try? JSONDecoder().decode(ArchiveError.self, from: data))
            ?? BrokerError.failed(String(localized: "提取失败", bundle: CoreStrings.bundle))
    }

    public func archiveTree(_ archive: URL, password: String?) throws -> ArchiveTree {
        try callSync { broker, done in
            broker.archiveTree(archivePath: archive.path, password: password) { tree, error in
                if let error = Self.decodeError(error) { return done(.failure(error)) }
                do {
                    done(.success(try JSONDecoder().decode(ArchiveTree.self, from: tree ?? Data())))
                } catch {
                    done(.failure(error))
                }
            }
        }
    }

    public func extractEntries(_ archive: URL, jobs: [(path: String, target: URL)], password: String?) throws {
        let _: Bool = try callSync { broker, done in
            broker.extractEntries(archivePath: archive.path, entryPaths: jobs.map(\.path), targets: jobs.map(\.target.path),
                                  password: password) { error in
                done(Self.decodeError(error).map { .failure($0) } ?? .success(true))
            }
        }
    }

    public func archiveWriteStatus(_ archive: URL) async throws -> String? {
        try await call { broker, done in
            broker.archiveWriteStatus(archivePath: archive.path) { done(.success($0)) }
        }
    }

    public func createArchiveDirectory(_ archive: URL, parent: String) async throws -> String? {
        try await call { broker, done in
            broker.createArchiveDirectory(archivePath: archive.path, parent: parent) { path, message in
                if let message { done(.failure(BrokerError.failed(message))) } else { done(.success(path)) }
            }
        }
    }

    /// 返回导入结果；nil 表示用户取消。具体冲突与进度在 Broker 的非激活面板中处理。
    public func addToArchive(_ archive: URL, sources: [URL], parent: String) async throws -> ZipEditor.ImportSummary? {
        try await call { broker, done in
            broker.addToArchive(archivePath: archive.path, sourcePaths: sources.map(\.path), parent: parent) { added, replaced, skipped, cancelled, message in
                if let message {
                    done(.failure(BrokerError.failed(message)))
                } else if cancelled {
                    done(.success(nil))
                } else {
                    var summary = ZipEditor.ImportSummary()
                    summary.added = added
                    summary.replaced = replaced
                    summary.skipped = skipped
                    done(.success(summary))
                }
            }
        }
    }

    public func openMainApp(_ command: MainAppCommand) async throws {
        let _: Bool = try await call { broker, done in
            broker.openMainApp(command: command.rawValue) { ok, message in
                done(ok ? .success(true) : .failure(BrokerError.failed(message ?? String(localized: "打开主应用失败", bundle: CoreStrings.bundle))))
            }
        }
    }
}

/// 同步 XPC 调用的结果：回复或错误回调在 synchronousRemoteObjectProxy 的方法返回前写入，之后才读取
private final class SyncResult<T: Sendable>: @unchecked Sendable {
    var value: Result<T, Error> = .failure(BrokerError.unavailable(String(localized: "没有回复", bundle: CoreStrings.bundle)))
}

private final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    func resume(_ result: Result<T, Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: result)
    }
}
