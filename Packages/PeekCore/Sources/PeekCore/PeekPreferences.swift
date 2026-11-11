import Foundation

/// 共享偏好；扩展、主应用、Broker 读写同一份（存储见 SettingsStore）。
public enum PeekPreferences {
    private static let store = SettingsStore.shared

    private enum Key {
        static let showHidden = "showHiddenFiles"
        static let foldersFirst = "foldersFirst"
        static let largeRows = "largeRows"
        static let fontSize = "fontSize"
        static let showPathBar = "showPathBar"
        static let showToolbar = "showToolbar"
        static let expandAll = "expandAllFolders"
        static let expandDepth = "expandDepth"
        static let expandArchives = "expandArchives"
        static let visibleColumns = "visibleColumns"
        static let viewMode = "viewMode"
        static let iconSize = "iconSize"
        static let archiveSizeLimit = "archiveSizeLimit"
        static let cacheRetention = "cacheRetention"
        static let language = "language"
        static let trashOldArchiveVersion = "trashOldArchiveVersion"
    }

    /// columns：列表 + 右侧检查器（预览栏）
    public enum ViewMode: String, CaseIterable, Sendable {
        case list, icons, columns
    }

    public static let iconSizes: ClosedRange<Double> = 48...160

    public static var viewMode: ViewMode {
        get { (store.value(forKey: Key.viewMode) as? String).flatMap(ViewMode.init(rawValue:)) ?? .list }
        set { store.set(newValue.rawValue, forKey: Key.viewMode) }
    }

    /// 图标视图中的图标边长（点）
    public static var iconSize: Double {
        get { min(max(store.value(forKey: Key.iconSize) as? Double ?? 72, iconSizes.lowerBound), iconSizes.upperBound) }
        set { store.set(min(max(newValue, iconSizes.lowerBound), iconSizes.upperBound), forKey: Key.iconSize) }
    }

    /// 列表可选列（名称列始终显示）。顺序即表头顺序
    public enum Column: String, CaseIterable, Sendable {
        case modified, created, lastOpened, added, size, kind, comment, tags, dimensions

        public var title: String {
            switch self {
            case .modified: String(localized: "修改日期", bundle: CoreStrings.bundle)
            case .created: String(localized: "创建日期", bundle: CoreStrings.bundle)
            case .lastOpened: String(localized: "上次打开日期", bundle: CoreStrings.bundle)
            case .added: String(localized: "添加日期", bundle: CoreStrings.bundle)
            case .size: String(localized: "大小", bundle: CoreStrings.bundle)
            case .kind: String(localized: "种类", bundle: CoreStrings.bundle)
            case .comment: String(localized: "注释", bundle: CoreStrings.bundle)
            case .tags: String(localized: "标签", bundle: CoreStrings.bundle)
            case .dimensions: String(localized: "尺寸", bundle: CoreStrings.bundle)
            }
        }
    }

    public static var visibleColumns: Set<Column> {
        get {
            guard let raw = store.value(forKey: Key.visibleColumns) as? [String] else { return [.modified, .size, .kind] }
            return Set(raw.compactMap(Column.init(rawValue:)))
        }
        set { store.set(Column.allCases.filter(newValue.contains).map(\.rawValue), forKey: Key.visibleColumns) }
    }

    public static let fontSizes = 11...16
    public static let expandDepths = 2...7

    public static var showHiddenFiles: Bool {
        get { bool(Key.showHidden) }
        set { store.set(newValue, forKey: Key.showHidden) }
    }

    public static var foldersFirst: Bool {
        get { bool(Key.foldersFirst) }
        set { store.set(newValue, forKey: Key.foldersFirst) }
    }

    /// 行高：小 / 大
    public static var largeRows: Bool {
        get { bool(Key.largeRows) }
        set { store.set(newValue, forKey: Key.largeRows) }
    }

    public static var fontSize: Int {
        get { clamp(store.value(forKey: Key.fontSize) as? Int ?? 13, fontSizes) }
        set { store.set(clamp(newValue, fontSizes), forKey: Key.fontSize) }
    }

    public static var showPathBar: Bool {
        get { store.value(forKey: Key.showPathBar) as? Bool ?? true }
        set { store.set(newValue, forKey: Key.showPathBar) }
    }

    public static var showToolbar: Bool {
        get { store.value(forKey: Key.showToolbar) as? Bool ?? true }
        set { store.set(newValue, forKey: Key.showToolbar) }
    }

    /// 打开时自动展开子文件夹（默认关闭，性能优先）
    public static var expandAllFolders: Bool {
        get { bool(Key.expandAll) }
        set { store.set(newValue, forKey: Key.expandAll) }
    }

    public static var expandDepth: Int {
        get { clamp(store.value(forKey: Key.expandDepth) as? Int ?? 4, expandDepths) }
        set { store.set(clamp(newValue, expandDepths), forKey: Key.expandDepth) }
    }

    /// 自动展开时是否也展开文件夹中的压缩包（默认关闭）
    public static var expandArchives: Bool {
        get { bool(Key.expandArchives) }
        set { store.set(newValue, forKey: Key.expandArchives) }
    }

    /// 压缩包大小上限（字节，0 为不限制）：超过时不自动读取，单独预览时需点"仍然读取"，也不参与自动展开
    public static let archiveSizeLimits: [Int64] = [100, 500, 1024, 2048, 5120].map { $0 * 1024 * 1024 } + [0]

    public static var archiveSizeLimit: Int64 {
        get {
            let value = store.value(forKey: Key.archiveSizeLimit) as? Int64 ?? 1024 * 1024 * 1024
            return archiveSizeLimits.contains(value) ? value : 1024 * 1024 * 1024
        }
        set { store.set(newValue, forKey: Key.archiveSizeLimit) }
    }

    /// 界面语言：nil 跟随系统。预览扩展只跟随系统语言，不受"按应用设置语言"影响，所以由 Localization 自己选资源
    public static let languages = ["zh-Hans", "en"]

    public static var language: String? {
        get { (store.value(forKey: Key.language) as? String).flatMap { languages.contains($0) ? $0 : nil } }
        set { store.set(newValue ?? "", forKey: Key.language) }
    }

    /// 修改压缩包（重命名、删除、替换）时把旧版本移到废纸篓，默认开启
    public static var trashOldArchiveVersion: Bool {
        get { store.value(forKey: Key.trashOldArchiveVersion) as? Bool ?? true }
        set { store.set(newValue, forKey: Key.trashOldArchiveVersion) }
    }

    /// 从压缩包提取的文件（打开 / 拷贝用）保留多久，后台服务启动时回收过期的
    public static let cacheRetentions: [TimeInterval] = [3600, 86400, 7 * 86400]

    public static var cacheRetention: TimeInterval {
        get {
            let value = store.value(forKey: Key.cacheRetention) as? TimeInterval ?? 86400
            return cacheRetentions.contains(value) ? value : 86400
        }
        set { store.set(newValue, forKey: Key.cacheRetention) }
    }

    /// 文件大小是否超过上限；读不到大小时视为未超过
    public static func exceedsArchiveLimit(_ size: Int64?) -> Bool {
        let limit = archiveSizeLimit
        guard limit > 0, let size else { return false }
        return size > limit
    }

    private static func bool(_ key: String) -> Bool {
        store.value(forKey: key) as? Bool ?? false
    }

    private static func clamp(_ value: Int, _ range: ClosedRange<Int>) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }
}
