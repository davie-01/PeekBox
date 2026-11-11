import AppKit
import CoreServices
import ImageIO
import UniformTypeIdentifiers

/// 按需读取的文件元数据（上次打开日期、注释、标签、图片尺寸）：只在对应列显示、单元格被绘制时读取。
/// 读取在后台串行进行（Spotlight、扩展属性与图片文件头都是同步 I/O，此前在主线程读取），
/// 读取期间单元格先留空，读完后合并为一次可见行刷新。
/// 上次打开日期与注释来自 Spotlight 元数据（沙盒内不可用时显示"--"），尺寸读取图片文件头而不解码像素。
@MainActor
final class MetadataCache {
    struct Values: Sendable {
        let lastOpened: Date?
        let comment: String?
        let tags: [String]
        let pixelSize: CGSize?
    }

    /// 超过此数量时清空重来，避免长时间浏览大目录时只增不减
    private static let limit = 5_000
    private let queue = DispatchQueue(label: "com.mars.PeekBox.metadata", qos: .utility)
    private var values: [URL: Values] = [:]
    private var pending: Set<URL> = []
    private var refreshScheduled = false
    /// 有新数据读完时调用（合并为一次）
    var onUpdate: (() -> Void)?

    /// 已读取的元数据；尚未读取时在后台开始读取并返回 nil
    func values(of url: URL) -> Values? {
        if let cached = values[url] { return cached }
        guard pending.insert(url).inserted else { return nil }
        queue.async { [weak self] in
            let loaded = Self.read(url)
            Task { @MainActor in self?.store(loaded, for: url) }
        }
        return nil
    }

    /// 换预览对象时清空
    func reset() {
        values.removeAll()
        pending.removeAll()
    }

    private func store(_ loaded: Values, for url: URL) {
        guard pending.remove(url) != nil else { return }
        if values.count >= Self.limit { values.removeAll() }
        values[url] = loaded
        guard !refreshScheduled else { return }
        refreshScheduled = true
        Task { @MainActor [weak self] in
            self?.refreshScheduled = false
            self?.onUpdate?()
        }
    }

    nonisolated private static func read(_ url: URL) -> Values {
        var lastOpened: Date?
        var comment: String?
        if let item = MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL) {
            lastOpened = MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
            comment = MDItemCopyAttribute(item, kMDItemFinderComment) as? String
        }
        let tags = (try? url.resourceValues(forKeys: [.tagNamesKey]).tagNames) ?? []
        var size: CGSize?
        if let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image),
           let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
           let height = properties[kCGImagePropertyPixelHeight] as? CGFloat {
            size = CGSize(width: width, height: height)
        }
        return Values(lastOpened: lastOpened, comment: comment, tags: tags, pixelSize: size)
    }
}
