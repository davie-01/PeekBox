import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import PeekCore

/// 检查器的后台加载：图片缩小解码、文本只读开头部分、压缩包条目提取到临时目录
enum InspectorLoader {
    enum Kind: Sendable {
        case image, pdf, text, other
    }

    enum Content: @unchecked Sendable {
        case image(CGImage, pixelSize: CGSize?)
        case text(String, truncated: Bool)
        case none
    }

    /// 文本只读开头这么多字节
    static let textLimit = 256 * 1024
    /// 图片显示的最大边长（像素）
    static let imageMaxPixels = 1600
    /// 压缩包内条目超过这个大小不提取预览
    static let extractLimit: Int64 = 64 * 1024 * 1024

    static func kind(ofName name: String) -> Kind {
        let ext = (name as NSString).pathExtension
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else { return .other }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .pdf) { return .pdf }
        if type.conforms(to: .text) || type.conforms(to: .sourceCode) || type.conforms(to: .propertyList) { return .text }
        return .other
    }

    /// 按类型加载；无扩展名或未知类型时嗅探开头字节，像文本就按文本显示
    static func load(_ url: URL, kind: Kind) -> Content {
        switch kind {
        case .image:
            return loadImage(url) ?? .none
        case .pdf:
            return loadPDF(url) ?? .none
        case .text:
            return loadText(url) ?? .none
        case .other:
            guard let head = try? readHead(url, limit: 4096), looksLikeText(head) else { return .none }
            return loadText(url) ?? .none
        }
    }

    private static var tempRoot: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("PeekBox-inspector", isDirectory: true)
    }

    static func extract(_ item: ArchiveTree.Item, from reader: any ArchiveReader, password: String?) throws -> URL {
        let directory = tempRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            let destination = directory.appendingPathComponent((item.path as NSString).lastPathComponent)
            try reader.extractFile(item, to: destination, password: password)
            return destination
        } catch {
            // 提取失败（密码错误、读写出错）时不留下任务目录
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    /// 清理上次预览遗留的提取目录（预览被系统直接结束时来不及清理）；只删 10 分钟以前的，不影响正在使用的
    static func purgeStale() {
        let fm = FileManager.default
        let deadline = Date().addingTimeInterval(-600)
        for directory in (try? fm.contentsOfDirectory(at: tempRoot, includingPropertiesForKeys: [.creationDateKey])) ?? [] {
            let created = (try? directory.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            if created < deadline { try? fm.removeItem(at: directory) }
        }
    }


    private static func loadImage(_ url: URL) -> Content? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        var pixelSize: CGSize?
        if let width = properties?[kCGImagePropertyPixelWidth] as? Int,
           let height = properties?[kCGImagePropertyPixelHeight] as? Int {
            pixelSize = CGSize(width: width, height: height)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: imageMaxPixels,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return .image(image, pixelSize: pixelSize)
    }

    /// 第一页按显示尺寸渲染，不依赖系统缩略图服务
    private static func loadPDF(_ url: URL) -> Content? {
        guard let page = PDFDocument(url: url)?.page(at: 0) else { return nil }
        let bounds = page.bounds(for: .cropBox)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = CGFloat(imageMaxPixels) / max(bounds.width, bounds.height)
        let size = NSSize(width: bounds.width * scale, height: bounds.height * scale)
        let image = page.thumbnail(of: size, for: .cropBox)
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return .image(cgImage, pixelSize: nil)
    }

    private static func loadText(_ url: URL) -> Content? {
        guard let data = try? readHead(url, limit: textLimit + 1) else { return nil }
        let truncated = data.count > textLimit
        let head = data.prefix(textLimit)
        return .text(decode(head, truncated: truncated), truncated: truncated)
    }

    private static func readHead(_ url: URL, limit: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try handle.read(upToCount: limit) ?? Data()
    }

    /// UTF-8 优先（截断处可能切断多字节字符，最多回退 3 字节），其次 GB18030，最后按 UTF-8 容错解码
    private static func decode(_ data: Data, truncated: Bool) -> String {
        for drop in 0...(truncated ? 3 : 0) where data.count >= drop {
            if let text = String(data: data.dropLast(drop), encoding: .utf8) { return text }
        }
        let gb = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        if let text = String(data: data, encoding: gb) { return text }
        return String(decoding: data, as: UTF8.self)
    }

    /// 没有 NUL 且能按 UTF-8 解码（允许末尾截断）
    private static func looksLikeText(_ data: Data) -> Bool {
        guard !data.isEmpty, !data.contains(0) else { return false }
        return (0...3).contains { data.count >= $0 && String(data: data.dropLast($0), encoding: .utf8) != nil }
    }
}

/// 检查器的后台工作：串行执行，同时只解码 / 提取一项；排队中的请求在真正开始前若已被新的选择取代就直接丢弃。
/// （ImageIO / PDF 解码与提取都是同步调用，开始后无法中途打断，只能在开始前拦下）
final class InspectorWorker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.mars.PeekBox.inspector", qos: .userInitiated)
    private let lock = NSLock()
    private var latest = 0

    /// 标记最新的请求代号，之前排队的请求将被丢弃
    func supersede(with generation: Int) {
        lock.withLock { latest = generation }
    }

    /// 返回 nil 表示请求在开始前已过期
    func run<T: Sendable>(generation: Int, _ work: @escaping @Sendable () -> T) async -> T? {
        await withCheckedContinuation { continuation in
            queue.async {
                guard self.lock.withLock({ self.latest == generation }) else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: work())
            }
        }
    }
}
