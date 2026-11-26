import Foundation

/// 文件夹数据源；其中的压缩包可展开，展开后交给对应的 ArchiveSource（每个文件只打开一次）。
/// 文件夹扩展对被预览目录有递归读权限，分卷包在这里可以读到其他卷。
public struct FolderSource: EntrySource {
    public let rootURL: URL
    public let showHidden: Bool
    /// 文件夹中展开过的压缩包；最近使用的在前（见 trimLoadedReaders）
    private let archives = Locked<(sources: [URL: ArchiveSource], recent: [URL])>(([:], []))
    /// 同时持有读取器的压缩包数与条目总数上限：读取器（XAD 还有解析器与文件句柄）随展开累积，
    /// 超出时释放最久未用的读取器，保留压缩包对象与已输入的密码，下次使用时重新读取
    private static let loadedReaderLimit = 4
    private static let loadedItemLimit = 200_000

    /// 可展开的压缩包扩展名（.tar.gz 按最后的 gz 识别）；JAR/APK 等 ZIP 容器不在此列（V1 不接管）
    private static let archiveExtensions: Set<String> = [
        "zip", "7z", "rar", "tar", "tgz", "gz", "tbz", "tbz2", "bz2", "txz", "xz",
        // 磁盘镜像
        "dmg", "img", "iso", "cdr", "toast",
    ]

    /// 列举时只取廉价属性。种类（localizedTypeDescription）要逐个询问 LaunchServices、标签要读扩展属性，
    /// 10 万项目录分别多花约 2 秒和 1.3 秒（沙盒内更慢）：种类按扩展名缓存，标签在显示时按需读取（见 MetadataCache）
    private static let keys: [URLResourceKey] = [
        .isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .fileSizeKey,
        .contentModificationDateKey, .creationDateKey, .addedToDirectoryDateKey,
    ]

    public init(rootURL: URL, showHidden: Bool) {
        self.rootURL = rootURL
        self.showHidden = showHidden
    }

    public func children(of parent: Entry?) async throws -> [Entry] {
        if let parent, let archive = parent.archiveURL {
            let children = try await archiveSource(forArchive: archive).children(of: parent)
            trimLoadedReaders()
            return children
        }
        if let parent, parent.isArchive, let archive = parent.fileURL {
            // 读取完成（新读取器已加载）后再检查上限
            let children = try await archiveSource(forArchive: archive).children(of: nil)
            trimLoadedReaders()
            return children
        }
        let directory = parent?.fileURL ?? rootURL
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Self.keys,
            options: showHidden ? [] : [.skipsHiddenFiles]
        )
        let keySet = Set(Self.keys)
        var kinds = KindCache()
        return urls.map { url in
            let values = try? url.resourceValues(forKeys: keySet)
            // .app 等包作为单一项目，不展开
            let isDirectory = (values?.isDirectory ?? false) && !(values?.isPackage ?? false)
            // 列举返回的 URL 缓存着预取的整组属性，不保留：条目只存名称与共用的目录 URL（见 Entry.fileURL）
            return Entry(
                directory: directory,
                name: url.lastPathComponent,
                isDirectory: isDirectory,
                size: isDirectory ? nil : values?.fileSize.map(Int64.init),
                modified: values?.contentModificationDate,
                kind: kinds.kind(of: url, isDirectory: isDirectory, isSymbolicLink: values?.isSymbolicLink ?? false),
                isArchive: !isDirectory && Self.isArchiveName(url),
                created: values?.creationDate,
                added: values?.addedToDirectoryDate
            )
        }
    }

    public func archiveSource(for archive: URL) -> ArchiveSource? {
        if let existing = archives.value.sources[archive] { return existing }
        // 悬停在尚未展开的 ZIP 上也要能检查写入；不预先打开整个文件夹里的归档。
        guard archive != rootURL, archive.pathComponents.starts(with: rootURL.pathComponents),
              Self.archiveExtensions.contains(archive.pathExtension.lowercased()) else { return nil }
        return archiveSource(forArchive: archive)
    }

    private func archiveSource(forArchive archive: URL) -> ArchiveSource {
        let source = archives.withLock { cache in
            cache.recent.removeAll { $0 == archive }
            cache.recent.insert(archive, at: 0)
            if let existing = cache.sources[archive] { return existing }
            let source = ArchiveSource(rootURL: archive, showHidden: showHidden)
            cache.sources[archive] = source
            return source
        }
        return source
    }

    /// 释放最久未用的压缩包读取器，使持有读取器的压缩包与条目总数不超过上限（最近使用的那个始终保留）
    private func trimLoadedReaders() {
        let (sources, recent) = archives.withLock { ($0.sources, $0.recent) }
        var loaded = 0
        var items = 0
        for url in recent {
            guard let source = sources[url], let reader = source.loadedReader else { continue }
            loaded += 1
            items += reader.tree.items.count
            if loaded > 1, loaded > Self.loadedReaderLimit || items > Self.loadedItemLimit {
                source.invalidate()
            }
        }
    }

    /// 同一次列举中，同扩展名的文件（以及所有文件夹）只向 LaunchServices 询问一次种类；
    /// 替身与无扩展名文件（可能是可执行文件等）逐个询问
    private struct KindCache {
        private var byKey: [String: String?] = [:]

        mutating func kind(of url: URL, isDirectory: Bool, isSymbolicLink: Bool) -> String? {
            let ext = url.pathExtension.lowercased()
            let key: String? = isSymbolicLink ? nil : isDirectory ? "/" : ext.isEmpty ? nil : ext
            if let key, let cached = byKey[key] { return cached }
            let kind = try? url.resourceValues(forKeys: [.localizedTypeDescriptionKey]).localizedTypeDescription
            if let key { byKey[key] = kind }
            return kind
        }
    }

    /// 列举时只看扩展名，避免为每个文件做一次 I/O；展开时才校验格式。分卷的首卷可展开，其余卷按普通文件显示。
    private static func isArchiveName(_ url: URL) -> Bool {
        switch VolumeInfo.detect(url) {
        case .first: return true
        case .part: return false
        case nil: return archiveExtensions.contains(url.pathExtension.lowercased())
        }
    }
}
