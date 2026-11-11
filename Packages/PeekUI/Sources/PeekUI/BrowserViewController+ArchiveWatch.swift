import Foundation
import PeekCore

/// 监视一个文件被替换、删除或改写。只占一个 kqueue 事件源，不轮询；对象释放即停止。
/// 事件源绑定在打开时的那个文件上：文件被原子替换后不会再收到新文件的事件，需要重新创建
final class FileChangeWatcher {
    let url: URL
    private let source: DispatchSourceFileSystemObject

    init?(url: URL, handler: @escaping @MainActor () -> Void) {
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        self.url = url
        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.delete, .rename, .write, .extend, .revoke], queue: .main)
        source.setEventHandler { MainActor.assumeIsolated { handler() } }
        source.setCancelHandler { close(descriptor) }
        source.resume()
    }

    deinit {
        source.cancel()
    }
}

extension BrowserViewController {
    /// 当前显示内容所在的压缩包（真实文件；压缩包里的压缩包没有文件可监视）
    private var displayedArchive: ArchiveSource? {
        guard let parent = currentParent else { return source as? ArchiveSource }
        guard let url = parent.isArchive ? parent.fileURL : parent.archiveURL else { return nil }
        return source?.archiveSource(for: url)
    }

    /// 本窗口发起的写入完成后会自行重新读取；但写入期间关闭预览再打开，新窗口收不到那次写入的结果，
    /// 其他程序修改压缩包也一样。所以显示压缩包内容时监视该文件，变化后重新读取
    func watchDisplayedArchive() {
        let url = displayedArchive?.rootURL
        guard archiveWatcher?.url != url else { return }
        archiveWatcher = url.flatMap { FileChangeWatcher(url: $0) { [weak self] in self?.archiveFileChanged() } }
    }

    private func archiveFileChanged() {
        // 写入提交是原子替换，事件源仍指向旧文件：放弃它，稍后按路径重新监视
        archiveWatcher = nil
        archiveChangeCheck?.cancel()
        archiveChangeCheck = Task { [weak self] in
            // 其他程序就地改写会连续触发事件，等安静下来再读取，避免读到写了一半的文件
            try? await Task.sleep(for: .milliseconds(500))
            guard let self, !Task.isCancelled else { return }
            // 本窗口的写入已经刷新过时文件身份一致，不重复读取
            if let archive = displayedArchive, archive.hasChangedOnDisk {
                archive.invalidate()
                reload()
            } else {
                watchDisplayedArchive()
            }
        }
    }
}
