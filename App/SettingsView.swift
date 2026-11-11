import SwiftUI
import PeekCore

/// 设置窗口：侧边栏 + 分页。首次运行时主页即为引导（列出尚未完成的准备工作）。
struct SettingsView: View {
    @Bindable var model: SettingsModel

    var body: some View {
        NavigationSplitView {
            List(SettingsModel.Page.allCases, selection: $model.page) { page in
                Label(page.title, systemImage: page.symbol).tag(page)
            }
            .navigationSplitViewColumnWidth(160)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            Group {
                switch model.page {
                case .home: HomePage(model: model)
                case .appearance: AppearancePage(model: model)
                case .behavior: BehaviorPage(model: model)
                case .permissions: PermissionsPage(model: model)
                case .maintenance: MaintenancePage(model: model)
                case .about: AboutPage(model: model)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(model.page.title)
        }
        .environment(\.locale, model.locale)
        .id(model.languageID)
        .frame(width: 700, height: 500)
        .onAppear {
            model.registerBrokerIfNeeded()
            model.refresh()
        }
        // 从系统设置回来时刷新扩展与后台服务状态
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refresh()
        }
    }
}

// MARK: - 主页 / 引导

private struct HomePage: View {
    let model: SettingsModel

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 56, height: 56)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("PeekBox").font(.title2.bold())
                        Text(model.isReady
                             ? String(localized: "一切就绪。在 Finder 中选中文件夹或压缩包，按空格即可预览。", bundle: .app)
                             : String(localized: "还差几步：完成下面的准备工作后即可在 Finder 中按空格预览。", bundle: .app))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
            Section(String(localized: "准备工作", bundle: .app)) {
                StatusRow(title: String(localized: "文件夹预览", bundle: .app), detail: model.folderExtension.label,
                          ok: model.folderExtension == .enabled) {
                    if model.folderExtension != .enabled {
                        Button(String(localized: "打开系统设置", bundle: .app)) { model.openExtensionsSettings() }
                    }
                }
                StatusRow(title: String(localized: "压缩包预览", bundle: .app), detail: model.archiveExtension.label,
                          ok: model.archiveExtension == .enabled) {
                    if model.archiveExtension != .enabled {
                        Button(String(localized: "打开系统设置", bundle: .app)) { model.openExtensionsSettings() }
                    }
                }
                StatusRow(title: String(localized: "后台服务", bundle: .app), detail: model.brokerStatus.label, ok: model.brokerStatus == .enabled) {
                    switch model.brokerStatus {
                    case .notRegistered, .notFound: Button(String(localized: "启用", bundle: .app)) { model.registerBroker() }
                    case .requiresApproval: Button(String(localized: "打开系统设置", bundle: .app)) { model.openLoginItemsSettings() }
                    default: EmptyView()
                    }
                }
            }
            if !model.conflicts.isEmpty {
                Section {
                    ForEach(model.conflicts) { conflict in
                        StatusRow(title: conflict.label, detail: "", ok: false) {
                            Button(String(localized: "打开系统设置", bundle: .app)) { model.openExtensionsSettings() }
                        }
                    }
                } header: {
                    Text(String(localized: "其他预览扩展", bundle: .app))
                } footer: {
                    Text(String(localized: "同一类文件有多个预览扩展时，由系统任选其一，PeekBox 可能不会生效。请在“快速查看”中停用这些扩展。", bundle: .app))
                }
            }
            Section {
                Text(String(localized: "扩展在“系统设置 › 通用 › 登录项与扩展 › 快速查看”中启用。后台服务负责打开、拷贝、提取和移到废纸篓，只在需要时运行，空闲约 30 秒后自动退出。", bundle: .app))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            MessageSection(message: model.message)
        }
    }
}

private struct StatusRow<Action: View>: View {
    let title: String
    let detail: String
    let ok: Bool
    @ViewBuilder let action: () -> Action

    var body: some View {
        HStack {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(ok ? .green : .orange)
            Text(title)
            Spacer()
            Text(detail).foregroundStyle(.secondary)
            action()
        }
    }
}

// MARK: - 外观

private struct AppearancePage: View {
    let model: SettingsModel

    var body: some View {
        Form {
            Section {
                Picker(String(localized: "语言", bundle: .app), selection: model.binding(\.language)) {
                    Text(String(localized: "跟随系统", bundle: .app)).tag(String?.none)
                    // 语言名称用各自的语言书写
                    Text(verbatim: "简体中文").tag(String?("zh-Hans"))
                    Text(verbatim: "English").tag(String?("en"))
                }
            } footer: {
                Text(String(localized: "设置窗口立即切换；预览窗口在下次打开时切换。", bundle: .app))
            }
            Section {
                Picker(String(localized: "显示", bundle: .app), selection: model.binding(\.viewMode)) {
                    Text(String(localized: "列表", bundle: .app)).tag(PeekPreferences.ViewMode.list)
                    Text(String(localized: "图标", bundle: .app)).tag(PeekPreferences.ViewMode.icons)
                    Text(String(localized: "分栏", bundle: .app)).tag(PeekPreferences.ViewMode.columns)
                }
                Picker(String(localized: "行高", bundle: .app), selection: model.binding(\.largeRows)) {
                    Text(String(localized: "小", bundle: .app)).tag(false)
                    Text(String(localized: "大", bundle: .app)).tag(true)
                }
                Picker(String(localized: "文字大小", bundle: .app), selection: model.binding(\.fontSize)) {
                    ForEach(Array(PeekPreferences.fontSizes), id: \.self) { Text("\($0)").tag($0) }
                }
                LabeledContent(String(localized: "图标大小", bundle: .app)) {
                    Slider(value: model.binding(\.iconSize), in: PeekPreferences.iconSizes)
                        .frame(width: 200)
                }
                Toggle(String(localized: "显示路径栏", bundle: .app), isOn: model.binding(\.showPathBar))
                Toggle(String(localized: "显示标题栏", bundle: .app), isOn: model.binding(\.showToolbar))
            } footer: {
                Text(String(localized: "这里设置的是全局默认值，与预览窗口左下角的快速设置同步，下次打开预览时生效。", bundle: .app))
            }
            Section(String(localized: "列表中显示的列", bundle: .app)) {
                ForEach(PeekPreferences.Column.allCases, id: \.self) { column in
                    Toggle(column.title, isOn: model.columnBinding(column))
                }
            }
        }
    }
}

// MARK: - 行为

private struct BehaviorPage: View {
    let model: SettingsModel

    var body: some View {
        Form {
            Section {
                Toggle(String(localized: "显示隐藏文件", bundle: .app), isOn: model.binding(\.showHiddenFiles))
                Toggle(String(localized: "文件夹置顶", bundle: .app), isOn: model.binding(\.foldersFirst))
            }
            Section {
                Toggle(String(localized: "展开所有子文件夹", bundle: .app), isOn: model.binding(\.expandAllFolders))
                Picker(String(localized: "文件夹深度", bundle: .app), selection: model.binding(\.expandDepth)) {
                    ForEach(Array(PeekPreferences.expandDepths), id: \.self) { Text("\($0)").tag($0) }
                }
                .disabled(!model.expandAllFolders)
                Toggle(String(localized: "同时展开压缩包", bundle: .app), isOn: model.binding(\.expandArchives))
                    .disabled(!model.expandAllFolders)
            } footer: {
                Text(String(localized: "自动展开最多读取约 5,000 项；加密、分卷压缩包不参与自动展开。", bundle: .app))
            }
            Section {
                Picker(String(localized: "压缩包大小上限", bundle: .app), selection: model.binding(\.archiveSizeLimit)) {
                    ForEach(PeekPreferences.archiveSizeLimits, id: \.self) { limit in
                        Group {
                            if limit == 0 {
                                Text(String(localized: "不限制", bundle: .app))
                            } else {
                                Text(Localization.fileSize(limit))
                            }
                        }
                        .tag(limit)
                    }
                }
            } footer: {
                Text(String(localized: "超过上限的压缩包不会自动读取：单独预览时显示“仍然读取”按钮，在文件夹中也不参与自动展开。", bundle: .app))
            }
            Section {
                Toggle(String(localized: "修改压缩包时将旧版本移到废纸篓", bundle: .app), isOn: model.binding(\.trashOldArchiveVersion))
            } footer: {
                Text(String(localized: "在压缩包内重命名、删除或替换后，修改前的压缩包会放进废纸篓，需要时可以找回。", bundle: .app))
            }
        }
    }
}

// MARK: - 权限

private struct PermissionsPage: View {
    let model: SettingsModel

    var body: some View {
        Form {
            Section {
                Text(String(localized: "预览窗口本身只能读取被预览的项目。打开、拷贝、提取和移到废纸篓由 PeekBox 后台服务完成，访问下面这些受隐私保护的位置需要你的授权。", bundle: .app))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section {
                AccessRow(title: String(localized: "完全磁盘访问权限", bundle: .app), state: model.access["fullDisk"] ?? .unknown)
            } footer: {
                HStack {
                    Text(String(localized: "可选。开启后可访问所有位置，不再逐项询问。", bundle: .app))
                    Spacer()
                    Button(String(localized: "打开设置", bundle: .app)) { model.openPrivacySettings(fullDisk: true) }
                }
            }
            Section {
                ForEach(SettingsModel.protectedLocations) { location in
                    AccessRow(title: location.title, state: model.access[location.id] ?? .unknown)
                }
            } header: {
                Text(String(localized: "文件与文件夹", bundle: .app))
            } footer: {
                HStack {
                    Text(String(localized: "检查时，尚未决定的位置会弹出系统授权提示。", bundle: .app))
                    Spacer()
                    Button(String(localized: "检查访问权限", bundle: .app)) { model.checkProtectedLocations() }
                    Button(String(localized: "打开设置", bundle: .app)) { model.openPrivacySettings(fullDisk: false) }
                }
            }
            MessageSection(message: model.message)
        }
        .onAppear { model.checkFullDiskAccess() }
    }
}

private struct AccessRow: View {
    let title: String
    let state: SettingsModel.AccessState

    var body: some View {
        LabeledContent(title) {
            switch state {
            case .unknown:
                Text(String(localized: "未检查", bundle: .app)).foregroundStyle(.secondary)
            case .granted:
                Label(String(localized: "已允许", bundle: .app), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .denied:
                Label(String(localized: "未允许", bundle: .app), systemImage: "xmark.circle.fill").foregroundStyle(.orange)
            }
        }
    }
}

// MARK: - 维护

private struct MaintenancePage: View {
    let model: SettingsModel

    var body: some View {
        Form {
            Section {
                LabeledContent(String(localized: "预览缓存", bundle: .app)) {
                    Text(model.cacheSize.map { Localization.fileSize($0) } ?? String(localized: "计算中…", bundle: .app))
                        .foregroundStyle(.secondary)
                    Button(String(localized: "立即清理", bundle: .app)) { model.clearCache() }
                        .disabled((model.cacheSize ?? 0) == 0)
                }
                Picker(String(localized: "自动清理", bundle: .app), selection: model.binding(\.cacheRetention)) {
                    Text(String(localized: "超过 1 小时", bundle: .app)).tag(TimeInterval(3600))
                    Text(String(localized: "超过 24 小时", bundle: .app)).tag(TimeInterval(86400))
                    Text(String(localized: "超过 7 天", bundle: .app)).tag(TimeInterval(7 * 86400))
                }
            } footer: {
                Text(String(localized: "从压缩包中打开或拷贝的文件会先提取到缓存，其他应用打开的、剪贴板里的都是这份文件，所以不在关闭预览时删除，而是在后台服务启动时回收超过时限的部分。立即清理后，仍在其他应用中打开的这类文件可能无法保存。", bundle: .app))
            }
            Section(String(localized: "诊断", bundle: .app)) {
                LabeledContent(String(localized: "后台服务", bundle: .app), value: model.brokerStatus.label)
                HStack {
                    Button(String(localized: "测试连接", bundle: .app)) { model.pingBroker() }
                    Button(String(localized: "测试写入…", bundle: .app)) { model.probeWrite() }
                    Spacer()
                    Button(String(localized: "重新注册", bundle: .app)) { model.registerBroker() }
                    Button(String(localized: "注销", bundle: .app)) { model.unregisterBroker() }
                }
                Button(String(localized: "打开登录项设置", bundle: .app)) { model.openLoginItemsSettings() }
            }
            MessageSection(message: model.message)
        }
        .onAppear { model.measureCache() }
    }
}

// MARK: - 关于

private struct AboutPage: View {
    let model: SettingsModel

    private static let components: [(name: String, license: String, url: String)] = [
        ("libzip", "BSD 3-Clause", "https://libzip.org"),
        ("XADMaster", "LGPL 2.1", "https://github.com/MacPaw/XADMaster"),
        ("UniversalDetector", "LGPL 2.1", "https://github.com/MacPaw/universal-detector"),
        ("Sparkle", "MIT", "https://sparkle-project.org"),
    ]

    /// 构建时拷入应用包的许可原文（见 project.yml 中拷到 Resources/Licenses 的文件）
    private static let licensesFolder: URL? = Bundle.main.resourceURL.map { $0.appendingPathComponent("Licenses") }
        .flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 56, height: 56)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("PeekBox").font(.title2.bold())
                        Text(String(localized: "版本 \(model.version)", bundle: .app)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(String(localized: "检查更新…", bundle: .app)) { model.checkForUpdates() }
                }
                .padding(.vertical, 4)
            } footer: {
                Text(String(localized: "PeekBox 只在你点击“检查更新…”时联网，不自动检查，不收集任何数据。", bundle: .app))
            }
            Section {
                ForEach(Self.components, id: \.name) { component in
                    LabeledContent {
                        Text(component.license).foregroundStyle(.secondary)
                    } label: {
                        Link(component.name, destination: URL(string: component.url)!)
                    }
                }
            } header: {
                Text(String(localized: "第三方组件", bundle: .app))
            } footer: {
                HStack {
                    Text(String(localized: "PeekBox 采用 GPL-3.0 许可。本应用及第三方组件的许可原文随应用附带。", bundle: .app))
                    Spacer()
                    if let licenses = Self.licensesFolder {
                        Button(String(localized: "显示许可文件", bundle: .app)) { NSWorkspace.shared.open(licenses) }
                    }
                }
            }
        }
    }
}

private struct MessageSection: View {
    let message: String

    var body: some View {
        if !message.isEmpty {
            Section {
                Text(message)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }
}
