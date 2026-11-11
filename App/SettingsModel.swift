import AppKit
import Observation
import ServiceManagement
import SwiftUI
import PeekCore

extension Bundle {
    /// 主应用文案所在的资源包，按界面语言设置选择（见 PeekCore.Localization）
    static var app: Bundle { Localization.bundle(.main) }
}

@MainActor
@Observable
final class SettingsModel {
    enum Page: String, CaseIterable, Identifiable {
        case home, appearance, behavior, permissions, maintenance, about

        var id: Self { self }

        var title: String {
            switch self {
            case .home: String(localized: "主页", bundle: .app)
            case .appearance: String(localized: "外观", bundle: .app)
            case .behavior: String(localized: "行为", bundle: .app)
            case .permissions: String(localized: "权限", bundle: .app)
            case .maintenance: String(localized: "维护", bundle: .app)
            case .about: String(localized: "关于", bundle: .app)
            }
        }

        var symbol: String {
            switch self {
            case .home: "house"
            case .appearance: "paintbrush"
            case .behavior: "gearshape"
            case .permissions: "lock.shield"
            case .maintenance: "wrench.and.screwdriver"
            case .about: "info.circle"
            }
        }
    }

    enum ExtensionState {
        case enabled, disabled, missing

        var label: String {
            switch self {
            case .enabled: String(localized: "已启用", bundle: .app)
            case .disabled: String(localized: "已停用", bundle: .app)
            case .missing: String(localized: "未注册", bundle: .app)
            }
        }
    }

    /// 与 PeekBox 声明了相同文件类型、且未被停用的其他快速查看扩展（按所属应用汇总）。
    /// 同一类型有多个扩展时系统任选其一，无法由应用指定，实测 Folder Preview Pro 的压缩包扩展会抢先
    struct PreviewConflict: Identifiable {
        let id: String
        let appName: String
        var folder = false
        var archive = false

        var label: String {
            switch (folder, archive) {
            case (true, true): String(localized: "\(appName) 也会预览文件夹和压缩包", bundle: .app)
            case (true, false): String(localized: "\(appName) 也会预览文件夹", bundle: .app)
            default: String(localized: "\(appName) 也会预览压缩包", bundle: .app)
            }
        }
    }

    /// 后台服务以自己的身份访问的隐私保护位置
    enum AccessState {
        case unknown, granted, denied
    }

    struct ProtectedLocation: Identifiable {
        let id: String
        let title: String
        let url: URL
    }

    var page: Page = .home
    var folderExtension: ExtensionState = .missing
    var archiveExtension: ExtensionState = .missing
    var conflicts: [PreviewConflict] = []
    var brokerStatus: SMAppService.Status = .notRegistered
    var access: [String: AccessState] = [:]
    var cacheSize: Int64?
    var message = ""
    /// 共享设置不可观察：每次写入或回到前台时递增，让读取设置的视图重新求值
    private(set) var revision = 0

    private let agent = SMAppService.agent(plistName: PeekShared.brokerAgentPlist)

    nonisolated static let home = FileManager.default.homeDirectoryForCurrentUser
    static let fullDiskProbe = home.appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db")
    static let protectedLocations = [
        ProtectedLocation(id: "desktop", title: String(localized: "桌面", bundle: .app), url: home.appendingPathComponent("Desktop")),
        ProtectedLocation(id: "documents", title: String(localized: "文稿", bundle: .app), url: home.appendingPathComponent("Documents")),
        ProtectedLocation(id: "downloads", title: String(localized: "下载", bundle: .app), url: home.appendingPathComponent("Downloads")),
    ]

    var isReady: Bool {
        folderExtension == .enabled && archiveExtension == .enabled && brokerStatus == .enabled && conflicts.isEmpty
    }

    /// 扩展状态要启动 pluginkit 子进程并等待退出：放到后台并行执行，结果回主线程更新；
    /// 进行中再次触发（如频繁切回前台）时合并为一次
    private var refreshing = false

    func refresh() {
        brokerStatus = agent.status
        // 预览窗口里可能改过设置
        revision += 1
        guard !refreshing else { return }
        refreshing = true
        Task {
            async let folder = Task.detached { Self.extensionState(PeekShared.folderExtensionID) }.value
            async let archive = Task.detached { Self.extensionState(PeekShared.archiveExtensionID) }.value
            async let others = Task.detached { Self.previewConflicts() }.value
            let (folderState, archiveState, conflictList) = await (folder, archive, others)
            folderExtension = folderState
            archiveExtension = archiveState
            conflicts = conflictList
            refreshing = false
        }
    }

    /// 首次运行时注册后台服务；系统会提示"已添加后台项目"
    /// 全新用户里从未注册过的服务，系统报告的是 .notFound 而不是 .notRegistered（新用户账户实测），两者都要注册
    func registerBrokerIfNeeded() {
        guard agent.status == .notRegistered || agent.status == .notFound else { return }
        registerBroker()
    }

    // MARK: - 共享设置

    /// 读写 PeekPreferences 的绑定
    func binding<Value>(_ keyPath: ReferenceWritableKeyPath<PreferencesProxy, Value>) -> Binding<Value> {
        Binding(
            get: { [self] in
                _ = revision
                return PreferencesProxy.shared[keyPath: keyPath]
            },
            set: { [self] in
                PreferencesProxy.shared[keyPath: keyPath] = $0
                revision += 1
            })
    }

    func columnBinding(_ column: PeekPreferences.Column) -> Binding<Bool> {
        Binding(
            get: { [self] in
                _ = revision
                return PeekPreferences.visibleColumns.contains(column)
            },
            set: { [self] visible in
                var columns = PeekPreferences.visibleColumns
                if visible { columns.insert(column) } else { columns.remove(column) }
                PeekPreferences.visibleColumns = columns
                revision += 1
            })
    }

    var expandAllFolders: Bool {
        _ = revision
        return PeekPreferences.expandAllFolders
    }

    /// SwiftUI 的 Text 按环境中的 locale 查文案
    var locale: Locale {
        _ = revision
        return Localization.locale
    }

    /// 语言变化时用作视图标识，整窗重建：用 String(localized:) 生成的文字（侧边栏、状态等）随之更新
    var languageID: String {
        _ = revision
        return PeekPreferences.language ?? "system"
    }

    // MARK: - 后台服务

    func registerBroker() {
        do {
            try agent.register()
            message = String(localized: "后台服务已注册", bundle: .app)
        } catch {
            message = String(localized: "注册失败：\(error.localizedDescription)", bundle: .app)
        }
        refresh()
    }

    func unregisterBroker() {
        Task {
            do {
                try await agent.unregister()
                message = String(localized: "后台服务已注销", bundle: .app)
            } catch {
                message = String(localized: "注销失败：\(error.localizedDescription)", bundle: .app)
            }
            refresh()
        }
    }

    func pingBroker() {
        Task {
            do {
                message = String(localized: "后台服务响应：\(try await BrokerClient.shared.ping())", bundle: .app)
            } catch {
                message = error.localizedDescription
            }
        }
    }

    /// 选一个文件夹，让后台服务在其中做 创建 → 替换 → 移到废纸篓
    func probeWrite() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = String(localized: "测试写入", bundle: .app)
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        Task {
            do {
                message = String(localized: "写入测试通过 · \(try await BrokerClient.shared.probeWrite(directory: folder))", bundle: .app)
            } catch {
                message = String(localized: "写入测试：\(error.localizedDescription)", bundle: .app)
            }
        }
    }

    // MARK: - 权限

    /// 完全磁盘访问权限：读取 TCC 数据库不会触发授权提示，打开权限页时自动检查
    func checkFullDiskAccess() {
        Task {
            let result = try? await BrokerClient.shared.checkAccess([Self.fullDiskProbe])
            access["fullDisk"] = result?.first.map { $0 ? .granted : .denied } ?? .unknown
        }
    }

    /// 桌面 / 文稿 / 下载：尚未决定时会弹出系统授权提示，所以只在用户点按钮时检查
    func checkProtectedLocations() {
        Task {
            do {
                let results = try await BrokerClient.shared.checkAccess(Self.protectedLocations.map(\.url))
                for (location, granted) in zip(Self.protectedLocations, results) {
                    access[location.id] = granted ? .granted : .denied
                }
                message = ""
            } catch {
                message = error.localizedDescription
            }
        }
        checkFullDiskAccess()
    }

    func openPrivacySettings(fullDisk: Bool) {
        let anchor = fullDisk ? "Privacy_AllFiles" : "Privacy_FilesAndFolders"
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    func openExtensionsSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.ExtensionsPreferences") {
            NSWorkspace.shared.open(url)
        }
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    // MARK: - 维护

    func measureCache() {
        Task.detached {
            let size = Self.directorySize(MaterializedCache.directory)
            await MainActor.run { self.cacheSize = size }
        }
    }

    func clearCache() {
        Task {
            // 递归删除可能较慢，不在主线程进行
            let failed = await Task.detached { MaterializedCache.removeAll() }.value
            message = failed == 0 ? String(localized: "预览缓存已清理", bundle: .app) : String(localized: "有 \(failed) 项未能删除（可能正被其他应用使用）", bundle: .app)
            measureCache()
        }
    }

    nonisolated private static func directorySize(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) else {
            return 0
        }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            total += Int64((try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
        }
        return total
    }

    // MARK: - 关于与链接

    func checkForUpdates() {
        Updater.shared.checkForUpdates()
    }

    var version: String {
        let info = Bundle.main.infoDictionary
        return String(localized: "\(info?["CFBundleShortVersionString"] as? String ?? "?")（\(info?["CFBundleVersion"] as? String ?? "?")）", bundle: .app)
    }

    func handle(_ url: URL) {
        switch url.host.flatMap(MainAppCommand.init(rawValue:)) {
        case .checkUpdate:
            page = .about
            checkForUpdates()
        case .settings:
            page = .home
        case nil:
            message = String(localized: "未知链接：\(url.absoluteString)", bundle: .app)
        }
        refresh()
    }

    /// pluginkit 输出首字符：+ 已启用，- 已停用；无输出表示未注册。
    nonisolated private static func extensionState(_ identifier: String) -> ExtensionState {
        let line = (pluginkit(["-m", "-i", identifier]) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if line.isEmpty { return .missing }
        return line.hasPrefix("-") ? .disabled : .enabled
    }

    /// 逐个比对其他快速查看扩展声明的类型。只算完全相同的类型：声明上层类型（如 public.archive）的扩展，
    /// 系统会优先选更具体的 PeekBox
    nonisolated private static func previewConflicts() -> [PreviewConflict] {
        guard let plugIns = Bundle.main.builtInPlugInsURL,
              let output = pluginkit(["-m", "-v", "-p", "com.apple.quicklook.preview"]) else { return [] }
        let folderTypes = supportedTypes(of: plugIns.appendingPathComponent("FolderPreview.appex"))
        let archiveTypes = supportedTypes(of: plugIns.appendingPathComponent("ArchivePreview.appex"))
        var conflicts: [String: PreviewConflict] = [:]
        // 每行：选择标记（+ 启用，- 停用，空白为未选择即默认启用）、标识符(版本)、UUID、注册时间、路径，以制表符分隔
        for line in output.split(separator: "\n") where !line.hasPrefix("-") {
            let fields = line.split(separator: "\t")
            guard fields.count >= 2, let path = fields.last else { continue }
            let identifier = fields[0].dropFirst().trimmingCharacters(in: .whitespaces)
            guard !identifier.hasPrefix(PeekShared.mainAppBundleID + ".") else { continue }
            let types = supportedTypes(of: URL(fileURLWithPath: String(path)))
            let folder = !types.isDisjoint(with: folderTypes)
            let archive = !types.isDisjoint(with: archiveTypes)
            guard folder || archive else { continue }
            var app = URL(fileURLWithPath: String(path))
            while app.pathExtension != "app", app.pathComponents.count > 1 { app = app.deletingLastPathComponent() }
            let owner = app.pathExtension == "app" ? app : URL(fileURLWithPath: String(path))
            var conflict = conflicts[owner.path]
                ?? PreviewConflict(id: owner.path, appName: owner.deletingPathExtension().lastPathComponent)
            conflict.folder = conflict.folder || folder
            conflict.archive = conflict.archive || archive
            conflicts[owner.path] = conflict
        }
        return conflicts.values.sorted { $0.appName.localizedStandardCompare($1.appName) == .orderedAscending }
    }

    nonisolated private static func supportedTypes(of appex: URL) -> Set<String> {
        let info = NSDictionary(contentsOf: appex.appendingPathComponent("Contents/Info.plist"))
        let attributes = (info?["NSExtension"] as? [String: Any])?["NSExtensionAttributes"] as? [String: Any]
        return Set((attributes?["QLSupportedContentTypes"] as? [String] ?? []).map { $0.lowercased() })
    }

    nonisolated private static func pluginkit(_ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pluginkit")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return output
    }
}

/// 把 PeekPreferences 的静态属性包装成实例属性，供 KeyPath 绑定使用
@MainActor
final class PreferencesProxy {
    static let shared = PreferencesProxy()

    var language: String? {
        get { PeekPreferences.language }
        set { PeekPreferences.language = newValue }
    }
    var viewMode: PeekPreferences.ViewMode {
        get { PeekPreferences.viewMode }
        set { PeekPreferences.viewMode = newValue }
    }
    var largeRows: Bool {
        get { PeekPreferences.largeRows }
        set { PeekPreferences.largeRows = newValue }
    }
    var fontSize: Int {
        get { PeekPreferences.fontSize }
        set { PeekPreferences.fontSize = newValue }
    }
    var iconSize: Double {
        get { PeekPreferences.iconSize }
        set { PeekPreferences.iconSize = newValue }
    }
    var showPathBar: Bool {
        get { PeekPreferences.showPathBar }
        set { PeekPreferences.showPathBar = newValue }
    }
    var showToolbar: Bool {
        get { PeekPreferences.showToolbar }
        set { PeekPreferences.showToolbar = newValue }
    }
    var showHiddenFiles: Bool {
        get { PeekPreferences.showHiddenFiles }
        set { PeekPreferences.showHiddenFiles = newValue }
    }
    var foldersFirst: Bool {
        get { PeekPreferences.foldersFirst }
        set { PeekPreferences.foldersFirst = newValue }
    }
    var expandAllFolders: Bool {
        get { PeekPreferences.expandAllFolders }
        set { PeekPreferences.expandAllFolders = newValue }
    }
    var expandDepth: Int {
        get { PeekPreferences.expandDepth }
        set { PeekPreferences.expandDepth = newValue }
    }
    var expandArchives: Bool {
        get { PeekPreferences.expandArchives }
        set { PeekPreferences.expandArchives = newValue }
    }
    var cacheRetention: TimeInterval {
        get { PeekPreferences.cacheRetention }
        set { PeekPreferences.cacheRetention = newValue }
    }
    var trashOldArchiveVersion: Bool {
        get { PeekPreferences.trashOldArchiveVersion }
        set { PeekPreferences.trashOldArchiveVersion = newValue }
    }
    var archiveSizeLimit: Int64 {
        get { PeekPreferences.archiveSizeLimit }
        set { PeekPreferences.archiveSizeLimit = newValue }
    }
}

extension SMAppService.Status {
    var label: String {
        switch self {
        case .notRegistered: String(localized: "未注册", bundle: .app)
        case .enabled: String(localized: "已启用", bundle: .app)
        case .requiresApproval: String(localized: "需要在系统设置中允许", bundle: .app)
        case .notFound: String(localized: "未找到", bundle: .app)
        @unknown default: String(localized: "未知", bundle: .app)
        }
    }
}
