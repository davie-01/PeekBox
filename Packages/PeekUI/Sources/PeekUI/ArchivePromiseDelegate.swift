import AppKit
import UniformTypeIdentifiers
import os
import PeekCore

/// File Promise 携带的条目信息。拖动开始时不解压，Finder 给出目标 URL 后才提取。
final class ArchivePromise: NSObject, Sendable {
    let path: String
    let name: String
    let reader: any ArchiveReader
    /// 提取时从这里取本次预览输入的密码
    let source: ArchiveSource

    init(path: String, name: String, reader: any ArchiveReader, source: ArchiveSource) {
        self.path = path
        self.name = name
        self.reader = reader
        self.source = source
    }
}

final class ArchivePromiseDelegate: NSObject, NSFilePromiseProviderDelegate, Sendable {
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.mars.PeekBox.promise"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 1
        return queue
    }()
    private let onFinish: @Sendable (String) -> Void
    private let log = Logger.peek("Promise")

    init(onFinish: @escaping @Sendable (String) -> Void) {
        self.onFinish = onFinish
    }

    static func provider(for promise: ArchivePromise, isDirectory: Bool,
                         delegate: ArchivePromiseDelegate) -> NSFilePromiseProvider {
        let type = isDirectory
            ? UTType.folder
            : UTType(filenameExtension: (promise.name as NSString).pathExtension) ?? .data
        let provider = NSFilePromiseProvider(fileType: type.identifier, delegate: delegate)
        provider.userInfo = promise
        return provider
    }

    @MainActor
    func filePromiseProvider(_ provider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        (provider.userInfo as? ArchivePromise)?.name ?? "Untitled"
    }

    /// 默认会在主队列写入，必须指定后台队列。
    @MainActor
    func operationQueue(for provider: NSFilePromiseProvider) -> OperationQueue {
        queue
    }

    /// 预览关闭后浏览视图可能已释放，日志由这里直接写，不依赖视图存活。
    private func report(_ message: String) {
        log.notice("\(message, privacy: .public)")
        onFinish(message)
    }

    func filePromiseProvider(_ provider: NSFilePromiseProvider, writePromiseTo url: URL,
                             completionHandler: @escaping (Error?) -> Void) {
        guard let promise = provider.userInfo as? ArchivePromise else {
            completionHandler(ArchiveError.entryNotFound("?"))
            return
        }
        let started = Date()
        report(String(localized: "开始提取 \(promise.name)", bundle: .peekUI))
        do {
            try promise.reader.extract(path: promise.path, to: url, password: promise.source.password)
            let elapsed = Int(Date().timeIntervalSince(started) * 1000)
            report(String(localized: "已提取 \(promise.name) → \(url.deletingLastPathComponent().lastPathComponent)（\(elapsed) ms）", bundle: .peekUI))
            completionHandler(nil)
        } catch ArchiveError.wrongPassword {
            promise.source.forgetPassword()
            report(String(localized: "密码不正确，请重新拖出并输入密码", bundle: .peekUI))
            completionHandler(ArchiveError.wrongPassword)
        } catch {
            report(String(localized: "提取失败：\(error.localizedDescription)", bundle: .peekUI))
            completionHandler(error)
        }
    }
}
