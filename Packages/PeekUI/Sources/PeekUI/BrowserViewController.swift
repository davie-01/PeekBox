import AppKit
import UniformTypeIdentifiers
import os
import QuickLookThumbnailing
import PeekCore

/// 文件夹与压缩包共用的浏览视图：标题栏（导航 + 操作）+ 树形列表 + 路径栏 + 底栏（快速设置）。
///
/// Quick Look 环境的两条硬约束（见 DESIGN.md「Quick Look 环境的约束」）：
/// - 预览内收不到键盘事件，所有操作经鼠标完成；
/// - 展开子菜单后点击会失效（macOS 27 Quick Look 的系统问题，Folder Preview Pro 同样复现），
///   因此任何菜单都只用单层，多选项设置放在弹出面板里。
@MainActor
public final class BrowserViewController: NSViewController {
    public enum Mode: Sendable {
        case folder
        case archive
    }

    let mode: Mode
    let log = Logger.peek("Browser")

    var source: EntrySource?
    /// "进入文件夹"后的层级；空表示被预览项目的根
    var navigation: [Entry] = []
    /// 后退 / 前进历史：每项是一个 navigation 快照
    private var backStack: [[Entry]] = []
    private var forwardStack: [[Entry]] = []
    var roots: [BrowserNode] = []
    private var loadGeneration = 0
    /// 已完成加载（成功或失败）的那一代；用于判断是否该显示"正在读取…"
    private var finishedGeneration = 0
    /// 列表与图标视图中隐藏的那个内容已过期
    var hiddenViewStale = false
    /// 下次加载完成后要选中的条目（如重命名后的新名字）
    var pendingSelectionID: String?
    var archiveWriteInProgress = false
    var dropWriteChecks: [URL: DropWriteCheck] = [:]
    /// 监视当前显示的压缩包文件（见 BrowserViewController+ArchiveWatch）
    var archiveWatcher: FileChangeWatcher?
    var archiveChangeCheck: Task<Void, Never>?
    var loadingDropArchives = Set<URL>()

    lazy var promiseDelegate = ArchivePromiseDelegate { [weak self] message in
        Task { @MainActor in self?.flash(message) }
    }

    let outlineView = PreviewOutlineView()
    /// 当前列表实际使用的字号与行高。行高经 heightOfRowByItem 提供，outlineView.rowHeight 保持默认不动
    private var appliedFontSize = CGFloat(PeekPreferences.fontSize)
    private var appliedRowHeight: CGFloat = 22
    let scrollView = NSScrollView()
    // 图标视图（见 BrowserViewController+IconView.swift）
    let iconScrollView = NSScrollView()
    let collectionView = PreviewCollectionView()
    let thumbnailCache = NSCache<NSString, NSImage>()
    var thumbnailRequests: [ObjectIdentifier: QLThumbnailGenerator.Request] = [:]
    /// 当前显示的图标大小。拖动滑块时只改它与布局，停下后才写入设置（见 iconSizeChanged）
    lazy var currentIconSize = CGFloat(PeekPreferences.iconSize)
    /// 缩略图缓存中图片的生成尺寸；图标不超过它时直接复用，放大超过时才重新生成
    lazy var thumbnailSide = CGFloat(PeekPreferences.iconSize)
    var iconSizeSaveTask: Task<Void, Never>?
    // 分栏模式的检查器（见 BrowserViewController+Inspector.swift）
    let splitView = NSSplitView()
    let inspectorView = InspectorView(frame: NSRect(x: 0, y: 0, width: 280, height: 400))
    var inspectorWidth: CGFloat = 280
    var inspectorGeneration = 0
    /// 压缩包条目预览时提取到的临时目录，换项或关闭检查器时删除
    var inspectorTemp: URL?
    var inspectorUnlockTarget: ArchiveSource?
    let inspectorWorker = InspectorWorker()
    var inspectorThumbnailRequest: QLThumbnailGenerator.Request?
    let pathControl = NSPathControl()
    /// 路径栏每一项对应的层级：nil 为被预览项目之上的祖先目录（不可导航），0 为根
    private var pathLevels: [Int?] = []
    let metadata = MetadataCache()

    // 标题栏
    let backButton = PreviewToolbarButton()
    let forwardButton = PreviewToolbarButton()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")
    let openWithButton = PreviewPopUpButton(frame: .zero, pullsDown: true)
    let copyButton = PreviewToolbarButton()
    let copyPathButton = PreviewToolbarButton()
    let infoButton = PreviewToolbarButton()
    let revealButton = PreviewToolbarButton()
    let deleteButton = PreviewToolbarButton()
    let hiddenFilesButton = PreviewToolbarButton()

    // 底栏
    let settingsButton = PreviewToolbarButton()
    let statusLabel = NSTextField(labelWithString: "")
    let viewSwitch = NSSegmentedControl()
    let iconSizeSlider = NSSlider()
    private var flashTimer: Timer?
    private var toolbarViews: [NSView] = []
    private var pathBarViews: [NSView] = []

    /// 当前右键菜单；每次右键新建（见 PreviewOutlineView.menu(for:)）
    var contextMenu: NSMenu?
    let openWithMenu = NSMenu()
    let headerMenu = NSMenu()

    // 快速设置面板（见 BrowserViewController+QuickSettings.swift）
    var settingsPopover: NSPopover?
    /// 面板中当前展开的分组
    var expandedSettingsGroup: String?
    var settingsStack: NSStackView?
    var settingsRows: [MenuLikeRow] = []

    // 密码与提示（见 BrowserViewController+Password.swift）
    struct PasswordPrompt {
        let popover: NSPopover
        let source: ArchiveSource
        let content: DialogContentView
        let field: NSSecureTextField
        let button: DialogButton
        let then: () -> Void
    }
    var passwordPrompt: PasswordPrompt?
    var pendingPrompt: (source: ArchiveSource, message: String, then: () -> Void)?
    let messageLabel = NSTextField(wrappingLabelWithString: "")
    let unlockButton = DialogButton(title: String(localized: "输入密码…", bundle: .peekUI), target: nil, action: nil)
    let messageView = NSStackView()
    var unlockTarget: ArchiveSource?
    var messageAction: (() -> Void)?
    /// 本次预览中用户已点"仍然读取"的超大压缩包
    private var oversizedAllowed = false
    var confirmPopover: NSPopover?
    /// 删除确认框打开期间待删除的文件
    var pendingDeletion: [URL] = []
    /// 确认框打开期间待从压缩包中删除的条目
    var pendingArchiveDeletion: (archive: ArchiveSource, url: URL, paths: [String])?

    /// 日期格式随界面语言
    static var dateFormat: Date.FormatStyle { Date.FormatStyle(date: .abbreviated, time: .shortened, locale: Localization.locale) }
    /// 沙盒内 NSHomeDirectory() 返回扩展容器路径，路径栏需要真实的用户家目录
    static let userHome: String = {
        guard let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir else { return NSHomeDirectory() }
        return String(cString: dir)
    }()
    /// 自动展开的总条目预算，超出即停止，避免大目录卡顿
    private static let autoExpandBudget = 5_000
    private static let nameColumn = NSUserInterfaceItemIdentifier("name")

    public init(mode: Mode) {
        self.mode = mode
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // MARK: - 视图

    public override func loadView() {
        let root = NSView()
        configureOutline()
        scrollView.documentView = outlineView
        // 参考 Dirscope：传统滚动条、关闭横向滚动条，列宽跟随窗口
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.scrollerStyle = .legacy
        scrollView.autohidesScrollers = true

        pathControl.pathStyle = .standard
        pathControl.controlSize = .small
        pathControl.isEditable = false
        pathControl.target = self
        pathControl.action = #selector(pathClicked(_:))
        // 层级很深时路径栏的固有宽度会超过窗口，把整个预览撑宽：允许压缩，由系统把中间各级缩成省略号
        pathControl.setContentCompressionResistancePriority(.init(1), for: .horizontal)

        configure(settingsButton, symbol: "gearshape", tip: String(localized: "快速设置", bundle: .peekUI), action: #selector(showSettingsPanel(_:)))
        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .center
        statusLabel.lineBreakMode = .byTruncatingMiddle
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        metadata.onUpdate = { [weak self] in self?.refreshVisibleCells() }
        configureIconView()
        configureViewSwitch()
        configureInspector()
        // 列表与图标视图叠放在同一区域，按视图模式显示其一；分栏模式在右侧加检查器
        let browsing = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 400))
        for view in [scrollView, iconScrollView] {
            pin(view, in: browsing)
        }
        splitView.addArrangedSubview(browsing)
        let content = NSView()
        pin(splitView, in: content)

        let header = makeHeader()
        let pathBar = bar(with: [pathControl])
        // 齿轮靠左、提示居中、视图切换固定在右下角
        let statusBar = bar(with: [])
        statusBar.setViews([settingsButton], in: .leading)
        statusBar.setViews([statusLabel], in: .center)
        statusBar.setViews([iconSizeSlider, viewSwitch], in: .trailing)

        let headerSeparator = separator()
        let pathSeparator = separator()
        toolbarViews = [header, headerSeparator]
        pathBarViews = [pathBar, pathSeparator]

        let stack = NSStackView(views: [header, headerSeparator, content, pathSeparator, pathBar, separator(), statusBar])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .leading
        stack.distribution = .fill
        for view in stack.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        content.setContentHuggingPriority(.defaultLow, for: .vertical)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)

        configureMessageView(in: root)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            // Quick Look 远程视图的安全区域为 0，标题栏位于系统标题栏玻璃之下但可以点击（与 Folder Preview Pro 相同）
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            messageView.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            messageView.centerYAnchor.constraint(equalTo: content.centerYAnchor),
        ])
        // 视图刚创建时尺寸为 0，固定高度若为必须满足会与"贴满父视图"冲突
        for (bar, height) in [(header, 52.0), (pathBar, 26.0), (statusBar, 34.0)] as [(NSView, CGFloat)] {
            let constraint = bar.heightAnchor.constraint(equalToConstant: height)
            constraint.priority = .init(999)
            constraint.isActive = true
        }
        view = root
        applyRowMetrics()
        applyBarsVisibility()
        applyColumns()
        applyViewMode()
        updateNavigationButtons()
    }

    private func pin(_ view: NSView, in container: NSView) {
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }

    /// 底栏右侧：列表 / 图标 / 分栏（列表 + 右侧检查器）
    private func configureViewSwitch() {
        viewSwitch.segmentCount = 3
        for (index, (symbol, tip)) in [("list.bullet", String(localized: "列表", bundle: .peekUI)), ("square.grid.2x2", String(localized: "图标", bundle: .peekUI)),
                                        ("sidebar.right", String(localized: "分栏（列表 + 预览）", bundle: .peekUI))].enumerated() {
            viewSwitch.setImage(NSImage(systemSymbolName: symbol, accessibilityDescription: tip), forSegment: index)
            viewSwitch.setToolTip(tip, forSegment: index)
            viewSwitch.setWidth(30, forSegment: index)
        }
        viewSwitch.trackingMode = .selectOne
        viewSwitch.controlSize = .small
        viewSwitch.target = self
        viewSwitch.action = #selector(viewModeChanged(_:))

        iconSizeSlider.minValue = PeekPreferences.iconSizes.lowerBound
        iconSizeSlider.maxValue = PeekPreferences.iconSizes.upperBound
        iconSizeSlider.controlSize = .small
        iconSizeSlider.toolTip = String(localized: "图标大小", bundle: .peekUI)
        iconSizeSlider.isContinuous = true
        iconSizeSlider.target = self
        iconSizeSlider.action = #selector(iconSizeChanged(_:))
        iconSizeSlider.widthAnchor.constraint(equalToConstant: 90).isActive = true
        // 范围设好后再赋值：configureIconView 先于这里执行，那时赋的值会被默认范围 0…1 截断
        iconSizeSlider.doubleValue = PeekPreferences.iconSize
    }

    private func configureOutline() {
        let name = NSTableColumn(identifier: Self.nameColumn)
        name.title = String(localized: "名称", bundle: .peekUI)
        name.width = 300
        name.minWidth = 120
        outlineView.addTableColumn(name)
        outlineView.outlineTableColumn = name
        for column in PeekPreferences.Column.allCases {
            let tableColumn = NSTableColumn(identifier: .init(column.rawValue))
            tableColumn.title = column.title
            tableColumn.width = Self.width(of: column)
            tableColumn.minWidth = 50
            if column == .size { tableColumn.headerCell.alignment = .right }
            outlineView.addTableColumn(tableColumn)
        }
        outlineView.style = .fullWidth
        outlineView.usesAlternatingRowBackgroundColors = true
        outlineView.allowsMultipleSelection = true
        outlineView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        outlineView.autosaveExpandedItems = false
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.target = self
        outlineView.doubleAction = #selector(doubleClicked(_:))
        // 拖入、拖出均为复制语义。
        outlineView.registerForDraggedTypes([.fileURL])
        outlineView.onDraggingBoundary = { [weak self] in self?.resetDropChecks() }
        outlineView.setDraggingSourceOperationMask(.copy, forLocal: false)
        outlineView.contextMenuProvider = { [weak self] _ in self?.makeContextMenu() }

        // 表头右键：选择显示的列（单层菜单）
        for column in PeekPreferences.Column.allCases {
            if column == .dimensions { headerMenu.addItem(.separator()) }
            let entry = NSMenuItem(title: column.title, action: #selector(toggleColumn(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = column.rawValue
            headerMenu.addItem(entry)
        }
        headerMenu.delegate = self
        outlineView.headerView?.menu = headerMenu
    }

    private static func width(of column: PeekPreferences.Column) -> CGFloat {
        switch column {
        // 英文日期（"Mar 15, 2026 at 11:41 PM"）比中文长
        case .modified, .created, .lastOpened, .added: 180
        case .size: 80
        case .kind: 130
        case .comment: 160
        case .tags: 110
        case .dimensions: 100
        }
    }

    /// 标题栏：后退 / 前进 · 标题与摘要 · 操作按钮（布局参考 Folder Preview Pro）
    private func makeHeader() -> NSView {
        // 后退 / 前进放在同一个玻璃胶囊里（布局参考 Folder Preview Pro）
        configure(backButton, symbol: "chevron.left", tip: String(localized: "后退", bundle: .peekUI), action: #selector(goBack(_:)))
        configure(forwardButton, symbol: "chevron.right", tip: String(localized: "前进", bundle: .peekUI), action: #selector(goForward(_:)))
        for button in [backButton, forwardButton] { button.isBordered = false }
        let navigationButtons = NSStackView(views: [backButton, forwardButton])
        navigationButtons.spacing = 0
        navigationButtons.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 6)
        let navigation = NSGlassEffectView()
        navigation.contentView = navigationButtons
        navigation.cornerRadius = 16
        navigation.heightAnchor.constraint(equalToConstant: 32).isActive = true

        titleLabel.font = .boldSystemFont(ofSize: NSFont.systemFontSize + 1)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        subtitleLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingTail
        let titles = NSStackView(views: [titleLabel, subtitleLabel])
        titles.orientation = .vertical
        titles.alignment = .leading
        titles.spacing = 1
        titles.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        subtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        openWithButton.bezelStyle = .glass
        openWithButton.controlSize = .large
        openWithButton.toolTip = String(localized: "打开方式", bundle: .peekUI)
        openWithButton.usesItemFromMenu = false
        let face = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        face.image = NSImage(systemSymbolName: "macwindow.badge.plus", accessibilityDescription: String(localized: "打开方式", bundle: .peekUI))
        (openWithButton.cell as? NSPopUpButtonCell)?.menuItem = face
        // 下拉按钮含图标与箭头，未设宽度时会被压窄并与相邻按钮重叠
        openWithButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 56).isActive = true
        openWithButton.menu = openWithMenu
        rebuildOpenWithMenu(openWithMenu)
        // 应用列表在"即将弹出"时重建（参考 Folder Preview Pro 的 updatePopUpButtonMenu:）
        NotificationCenter.default.addObserver(self, selector: #selector(openWithWillPopUp(_:)),
                                               name: NSPopUpButton.willPopUpNotification, object: openWithButton)

        configure(hiddenFilesButton, symbol: "eye", tip: String(localized: "显示隐藏文件", bundle: .peekUI), action: #selector(toggleHiddenFiles(_:)))
        updateHiddenFilesButton()
        configure(copyButton, symbol: "doc.on.doc", tip: String(localized: "拷贝", bundle: .peekUI), action: #selector(copyItems(_:)))
        configure(copyPathButton, symbol: "link", tip: String(localized: "拷贝路径", bundle: .peekUI), action: #selector(copyPaths(_:)))
        configure(infoButton, symbol: "info.circle", tip: String(localized: "显示简介", bundle: .peekUI), action: #selector(showInfo(_:)))
        configure(revealButton, symbol: "macwindow.on.rectangle", tip: String(localized: "在 Finder 中显示", bundle: .peekUI), action: #selector(revealItems(_:)))
        configure(deleteButton, symbol: "trash", tip: String(localized: "移到废纸篓", bundle: .peekUI), action: #selector(deleteItems(_:)))
        let actions = NSStackView(views: [hiddenFilesButton, openWithButton, copyButton, copyPathButton, infoButton, revealButton, deleteButton])
        actions.spacing = 8

        // 标题靠左紧挨导航按钮，中间留白把操作按钮推到右侧
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let header = NSStackView(views: [navigation, titles, spacer, actions])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 12
        header.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        header.setHuggingPriority(.defaultLow, for: .horizontal)
        actions.setContentHuggingPriority(.required, for: .horizontal)
        return header
    }

    func configure(_ button: NSButton, symbol: String, tip: String, action: Selector) {
        // macOS 26 起的 Liquid Glass 按钮样式
        button.bezelStyle = .glass
        button.controlSize = .large
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        button.imagePosition = .imageOnly
        button.toolTip = tip
        button.target = self
        button.action = action
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: 34).isActive = true
    }

    @objc private func openWithWillPopUp(_ notification: Notification) {
        rebuildOpenWithMenu(openWithMenu)
    }

    private func bar(with views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        return stack
    }

    private func separator() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        return box
    }

    // MARK: - 外观（按需更新，不整表重新加载）

    /// 行高与字号：行高变化只通知行高，字号变化只刷新可见单元格（屏幕外的单元格创建时自然使用新字号）
    func applyRowMetrics() {
        let fontSize = CGFloat(PeekPreferences.fontSize)
        let baseHeight: CGFloat = PeekPreferences.largeRows ? 28 : 22
        let rowHeight = max(baseHeight, fontSize + 9)
        let rowsChanged = appliedRowHeight != rowHeight
        let fontChanged = appliedFontSize != fontSize
        appliedRowHeight = rowHeight
        appliedFontSize = fontSize
        if rowsChanged, outlineView.numberOfRows > 0 {
            outlineView.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<outlineView.numberOfRows))
        }
        if fontChanged {
            refreshVisibleCells()
            if PeekPreferences.viewMode == .icons { collectionView.reloadData() }
        }
    }

    func applyBarsVisibility() {
        for view in toolbarViews { view.isHidden = !PeekPreferences.showToolbar }
        for view in pathBarViews { view.isHidden = !PeekPreferences.showPathBar }
    }

    private func refreshVisibleCells() {
        let rows = outlineView.rows(in: outlineView.visibleRect)
        guard rows.length > 0 else { return }
        outlineView.reloadData(forRowIndexes: IndexSet(integersIn: rows.location..<NSMaxRange(rows)),
                               columnIndexes: IndexSet(integersIn: 0..<outlineView.numberOfColumns))
    }

    /// "文件夹置顶"切换：在内存中重新排序已加载的节点，并恢复展开状态，不重新读取目录
    func resortPreservingExpansion() {
        let expanded = (0..<outlineView.numberOfRows).compactMap { outlineView.item(atRow: $0) as? BrowserNode }
            .filter { outlineView.isItemExpanded($0) }
        let generation = loadGeneration
        // 比较排序在后台进行，主线程只按结果重排已有节点
        func resort(_ nodes: [BrowserNode]) async -> [BrowserNode] {
            let entries = nodes.map(\.entry)
            let foldersFirst = PeekPreferences.foldersFirst
            let order = await Task.detached(priority: .userInitiated) {
                entries.sortedForDisplay(foldersFirst: foldersFirst).map(\.id)
            }.value
            let byID = Dictionary(nodes.map { ($0.entry.id, $0) }, uniquingKeysWith: { first, _ in first })
            let sorted = order.compactMap { byID[$0] }
            for node in sorted where node.children != nil { node.children = await resort(node.children!) }
            return sorted
        }
        Task {
            let sorted = await resort(roots)
            guard generation == loadGeneration else { return }
            roots = sorted
            reloadViews()
            // 行号顺序保证父节点先于子节点展开
            for node in expanded { outlineView.expandItem(node) }
        }
    }

    /// 自动展开相关设置变化：直接在现有列表上收起或重新展开，不重新读取当前层级
    func applyExpandSettings() {
        outlineView.collapseItem(nil, collapseChildren: true)
        guard PeekPreferences.expandAllFolders else { return }
        let generation = loadGeneration
        Task { await autoExpand(generation: generation) }
    }

    /// 按设置显示 / 隐藏可选列
    func applyColumns() {
        let visible = PeekPreferences.visibleColumns
        for column in PeekPreferences.Column.allCases {
            outlineView.tableColumn(withIdentifier: .init(column.rawValue))?.isHidden = !visible.contains(column)
        }
    }

    @objc private func toggleColumn(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let column = PeekPreferences.Column(rawValue: raw) else { return }
        var visible = PeekPreferences.visibleColumns
        if visible.contains(column) { visible.remove(column) } else { visible.insert(column) }
        PeekPreferences.visibleColumns = visible
        applyColumns()
    }

    // MARK: - 加载与导航

    public func load(source: EntrySource) {
        metadata.reset()
        self.source = source
        oversizedAllowed = false
        navigation = []
        backStack = []
        forwardStack = []
        reload()
    }

    var currentParent: Entry? { navigation.last }

    func reload() {
        guard let source else { return }
        watchDisplayedArchive()
        loadGeneration += 1
        let generation = loadGeneration
        let parent = currentParent
        let started = ContinuousClock.now
        updatePathBar()
        updateNavigationButtons()
        if parent == nil, !oversizedAllowed, let archive = source as? ArchiveSource,
           case let size = Self.fileSize(archive.rootURL), PeekPreferences.exceedsArchiveLimit(size) {
            showOversized(size: size ?? 0)
            return
        }
        // 密码回调会存进 passwordPrompt，必须弱引用，避免预览关闭时密码框未关导致泄漏
        let retry: () -> Void = { [weak self] in self?.reload() }
        // 大目录读取较慢：0.3 秒内没读完就先给出进度提示，不让界面停在上一层的内容上
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard generation == loadGeneration, finishedGeneration != generation else { return }
            roots = []
            reloadViews()
            showMessage(String(localized: "正在读取…", bundle: .peekUI), unlock: nil)
        }
        Task {
            do {
                let entries = try await source.children(of: parent)
                if parent == nil { _ = try await (source as? ArchiveSource)?.reader() }
                // 换文件或切换层级后晚到的结果直接丢弃
                guard generation == loadGeneration else { return }
                let loaded = ContinuousClock.now
                // 排序离开主线程：10 万项按本地化规则比较需要数百毫秒
                let foldersFirst = PeekPreferences.foldersFirst
                let sortedEntries = await Task.detached(priority: .userInitiated) {
                    entries.sortedForDisplay(foldersFirst: foldersFirst)
                }.value
                guard generation == loadGeneration else { return }
                finishedGeneration = generation
                hideMessage()
                roots = sortedEntries.map(BrowserNode.init)
                let sorted = ContinuousClock.now
                reloadViews()
                selectPendingEntry()
                updateStatus()
                updateToolbarState()
                updateInspector()
                view.layoutSubtreeIfNeeded()
                let shown = ContinuousClock.now
                let ms = { (d: Duration) in Int(d / .milliseconds(1)) }
                log.notice("level loaded: \(entries.count) entries, read \(ms(loaded - started)) ms, sort \(ms(sorted - loaded)) ms, display \(ms(shown - sorted)) ms, total \(ms(shown - started)) ms")
                if PeekPreferences.expandAllFolders { await autoExpand(generation: generation) }
            } catch {
                guard generation == loadGeneration else { return }
                finishedGeneration = generation
                roots = []
                reloadViews()
                updateStatus()
                updateToolbarState()
                updateInspector()
                log.error("level load failed: \(error.localizedDescription, privacy: .public)")
                if let message = Self.passwordMessage(for: error), let archive = archiveSource(forLevel: parent) {
                    showMessage(message, unlock: archive)
                    promptPassword(for: archive, message: message, then: retry)
                } else {
                    showMessage(error.localizedDescription, unlock: nil)
                }
            }
        }
    }

    /// 超过设置的大小上限：不自动读取，由用户决定
    private func showOversized(size: Int64) {
        roots = []
        reloadViews()
        updateStatus()
        updateToolbarState()
        let fmt = { Localization.fileSize($0) }
        showMessage(String(localized: "此压缩包有 \(fmt(size))，超过设置的上限 \(fmt(PeekPreferences.archiveSizeLimit))，未自动读取。", bundle: .peekUI),
                    actionTitle: String(localized: "仍然读取", bundle: .peekUI)) { [weak self] in
            self?.oversizedAllowed = true
            self?.hideMessage()
            self?.reload()
        }
    }

    static func fileSize(_ url: URL) -> Int64? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
    }

    /// 当前层级所属的压缩包数据源（单独预览的压缩包，或文件夹中被进入的压缩包）
    private func archiveSource(forLevel parent: Entry?) -> ArchiveSource? {
        if let archive = source as? ArchiveSource { return archive }
        guard let parent, let url = parent.archiveURL ?? parent.fileURL else { return nil }
        return source?.archiveSource(for: url)
    }

    /// 切换到新的层级并记入后退历史
    private func navigate(to path: [Entry]) {
        guard path.map(\.id) != navigation.map(\.id) else { return }
        backStack.append(navigation)
        forwardStack.removeAll()
        navigation = path
        reload()
    }

    func enter(_ entry: Entry) {
        guard entry.isExpandable else { return }
        navigate(to: navigation + [entry])
    }

    func navigateUp() {
        guard !navigation.isEmpty else { return }
        navigate(to: Array(navigation.dropLast()))
    }

    @objc func goBack(_ sender: Any?) {
        guard let previous = backStack.popLast() else { return }
        forwardStack.append(navigation)
        navigation = previous
        reload()
    }

    @objc func goForward(_ sender: Any?) {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(navigation)
        navigation = next
        reload()
    }

    private func updateNavigationButtons() {
        backButton.isEnabled = !backStack.isEmpty
        forwardButton.isEnabled = !forwardStack.isEmpty
        for button in [backButton, forwardButton] {
            button.contentTintColor = button.isEnabled ? .labelColor : .tertiaryLabelColor
        }
    }

    @objc private func pathClicked(_ sender: NSPathControl) {
        guard let item = sender.clickedPathItem,
              let index = sender.pathItems.firstIndex(of: item),
              index < pathLevels.count, let level = pathLevels[index] else { return }
        navigate(to: Array(navigation.prefix(level)))
    }

    /// 路径栏：家目录（或卷根）以下的祖先目录 + 被预览项目 + 已进入的各层
    private func updatePathBar() {
        guard let source else { return }
        var chain: [URL] = []
        var url = source.rootURL.standardizedFileURL
        while true {
            chain.insert(url, at: 0)
            if url.path == Self.userHome || url.path == "/" { break }
            url = url.deletingLastPathComponent()
        }
        var items: [NSPathControlItem] = []
        var levels: [Int?] = []
        for (index, url) in chain.enumerated() {
            items.append(pathItem(title: FileManager.default.displayName(atPath: url.path),
                                  icon: NSWorkspace.shared.icon(forFile: url.path)))
            levels.append(index == chain.count - 1 ? 0 : nil)
        }
        for (depth, entry) in navigation.enumerated() {
            items.append(pathItem(title: entry.name, icon: icon(for: entry)))
            levels.append(depth + 1)
        }
        pathControl.pathItems = items
        pathLevels = levels
        titleLabel.stringValue = currentParent?.name ?? FileManager.default.displayName(atPath: source.rootURL.path)
    }

    private func pathItem(title: String, icon: NSImage) -> NSPathControlItem {
        let item = NSPathControlItem()
        item.title = title
        let image = icon.copy() as? NSImage ?? icon
        image.size = NSSize(width: 16, height: 16)
        item.image = image
        return item
    }

    static func passwordMessage(for error: Error) -> String? {
        switch error as? ArchiveError {
        case .passwordRequired: String(localized: "此压缩包需要密码", bundle: .peekUI)
        case .wrongPassword: String(localized: "密码不正确，请重新输入", bundle: .peekUI)
        default: nil
        }
    }

    private func loadChildren(of node: BrowserNode) {
        guard node.children == nil, let source else { return }
        node.children = []
        let retry: () -> Void = { [weak self, weak node] in
            if let node { self?.outlineView.expandItem(node) }
        }
        Task {
            do {
                node.children = await sortedNodesInBackground(try await source.children(of: node.entry))
                outlineView.reloadItem(node, reloadChildren: true)
            } catch {
                // 文件夹内的压缩包打不开（需要密码、分卷缺失等）：收起并提示，允许重试
                node.children = nil
                outlineView.collapseItem(node)
                flash(String(localized: "\(node.entry.name)：\(error.localizedDescription)", bundle: .peekUI))
                if let message = Self.passwordMessage(for: error),
                   let url = node.entry.archiveURL ?? node.entry.fileURL,
                   let archive = source.archiveSource(for: url) {
                    promptPassword(for: archive, message: message, then: retry)
                }
            }
        }
    }

    /// 按"文件夹深度"逐层展开，受总条目预算约束；压缩包仅在开启"同时展开压缩包"时展开
    func autoExpand(generation: Int) async {
        guard let source else { return }
        var budget = Self.autoExpandBudget
        var level = roots
        for _ in 1..<PeekPreferences.expandDepth {
            var next: [BrowserNode] = []
            for node in level where shouldAutoExpand(node.entry) {
                guard budget > 0 else {
                    flash(String(localized: "条目较多，已停止自动展开", bundle: .peekUI))
                    return
                }
                guard let entries = try? await source.children(of: node.entry),
                      generation == loadGeneration else { continue }
                // 单个子文件夹就超出剩余预算时不展开它（保持折叠，可手动展开），并停止自动展开
                guard entries.count <= budget else {
                    flash(String(localized: "条目较多，已停止自动展开", bundle: .peekUI))
                    return
                }
                if node.children == nil { node.children = await sortedNodesInBackground(entries) }
                guard generation == loadGeneration else { return }
                outlineView.reloadItem(node, reloadChildren: true)
                outlineView.expandItem(node)
                budget -= entries.count
                next.append(contentsOf: node.children ?? [])
            }
            level = next
        }
    }

    private func shouldAutoExpand(_ entry: Entry) -> Bool {
        if entry.isDirectory { return true }
        // 加密与分卷压缩包可能需要交互，不参与自动展开
        return entry.isArchive && PeekPreferences.expandArchives && !PeekPreferences.exceedsArchiveLimit(entry.size)
    }

    func sortedNodes(_ entries: [Entry]) -> [BrowserNode] {
        entries.sortedForDisplay(foldersFirst: PeekPreferences.foldersFirst).map(BrowserNode.init)
    }

    /// 排序离开主线程：10 万项按本地化规则比较约 0.5 秒，在主线程会卡住界面
    func sortedNodesInBackground(_ entries: [Entry]) async -> [BrowserNode] {
        let foldersFirst = PeekPreferences.foldersFirst
        let sorted = await Task.detached(priority: .userInitiated) {
            entries.sortedForDisplay(foldersFirst: foldersFirst)
        }.value
        return sorted.map(BrowserNode.init)
    }

    // MARK: - 摘要与提示

    /// 标题栏副标题：当前层级（或选中项）的文件总大小与项目数；文件夹大小不统计
    func updateStatus() {
        let selected = selectedNodes()
        let nodes = selected.isEmpty ? roots : selected
        let total = nodes.compactMap(\.entry.size).saturatingSum
        let size = Localization.fileSize(total)
        var text = selected.isEmpty ? String(localized: "\(size)，\(roots.count) 个项目", bundle: .peekUI) : String(localized: "已选 \(selected.count) 项，\(size)", bundle: .peekUI)
        if let reader = archiveSource(forLevel: currentParent)?.loadedReader {
            if let xad = reader as? XADArchive { text += " · \(xad.formatName)" }
            if reader.tree.hasEncryptedEntries { text += String(localized: " · 含加密条目", bundle: .peekUI) }
        }
        subtitleLabel.stringValue = text
    }

    /// 在底栏短暂显示操作结果，3 秒后清除
    func flash(_ message: String) {
        log.notice("\(message, privacy: .public)")
        statusLabel.stringValue = message
        flashTimer?.invalidate()
        flashTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.statusLabel.stringValue = "" }
        }
    }

    func selectedNodes() -> [BrowserNode] {
        if PeekPreferences.viewMode == .icons {
            return collectionView.selectionIndexPaths.sorted().compactMap { $0.item < roots.count ? roots[$0.item] : nil }
        }
        return outlineView.selectedRowIndexes.compactMap { outlineView.item(atRow: $0) as? BrowserNode }
    }

    /// 选中并滚动到 pendingSelectionID 对应的当前层级条目
    private func selectPendingEntry() {
        guard let id = pendingSelectionID else { return }
        pendingSelectionID = nil
        guard let index = roots.firstIndex(where: { $0.entry.id == id }) else { return }
        if PeekPreferences.viewMode == .icons {
            let path = IndexPath(item: index, section: 0)
            collectionView.selectItems(at: [path], scrollPosition: .centeredVertically)
        } else {
            let row = outlineView.row(forItem: roots[index])
            guard row >= 0 else { return }
            outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            outlineView.scrollRowToVisible(row)
        }
    }

    /// 当前层级变化后只刷新显示中的视图：隐藏的集合视图刷新时也会为每一项计算布局，10 万项要多占数十 MB。
    /// 隐藏的那个标记为过期，切换过去时再刷新（见 applyViewMode）
    func reloadViews() {
        if PeekPreferences.viewMode == .icons {
            collectionView.reloadData()
        } else {
            outlineView.reloadData()
        }
        hiddenViewStale = true
    }

    func icon(for entry: Entry) -> NSImage {
        if let url = entry.fileURL {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        let type = entry.isDirectory
            ? UTType.folder
            : UTType(filenameExtension: (entry.name as NSString).pathExtension) ?? .data
        return NSWorkspace.shared.icon(for: type)
    }
}

// MARK: - 表头菜单

extension BrowserViewController: NSMenuDelegate {
    /// 只更新勾选状态，不增删菜单项
    public func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === headerMenu else { return }
        let visible = PeekPreferences.visibleColumns
        for item in menu.items {
            guard let raw = item.representedObject as? String, let column = PeekPreferences.Column(rawValue: raw) else { continue }
            item.state = visible.contains(column) ? .on : .off
        }
    }
}

// MARK: - 数据源与拖出

extension BrowserViewController: NSOutlineViewDataSource {
    public func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? BrowserNode else { return roots.count }
        return node.children?.count ?? 0
    }

    public func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? BrowserNode else { return roots[index] }
        return node.children![index]
    }

    public func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? BrowserNode)?.entry.isExpandable ?? false
    }

    // 文件夹条目直接提供真实 URL；压缩包条目用 File Promise，放下后才提取
    public func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> (any NSPasteboardWriting)? {
        guard let entry = (item as? BrowserNode)?.entry else { return nil }
        return pasteboardWriter(for: entry)
    }

    /// 列表与图标视图共用
    func pasteboardWriter(for entry: Entry) -> (any NSPasteboardWriting)? {
        if let url = entry.fileURL { return url as NSURL }
        guard let archiveURL = entry.archiveURL, let archive = source?.archiveSource(for: archiveURL),
              let reader = archive.loadedReader else { return nil }
        let path = ArchiveSource.archivePath(of: entry)
        // File Promise 在放下后才在后台写入，无法中途询问密码：未解锁时改为弹出密码框，不开始拖动
        if needsPassword([entry], reader: reader), archive.password == nil {
            Task { @MainActor [weak self] in
                self?.promptPassword(for: archive, message: String(localized: "拖出加密的项目前，请先输入密码。", bundle: .peekUI)) { [weak self] in
                    self?.flash(String(localized: "已解锁，可以拖出", bundle: .peekUI))
                }
            }
            return nil
        }
        let promise = ArchivePromise(path: path, name: entry.name, reader: reader, source: archive)
        return ArchivePromiseDelegate.provider(for: promise, isDirectory: entry.isDirectory, delegate: promiseDelegate)
    }

    func needsPassword(_ entries: [Entry], reader: any ArchiveReader) -> Bool {
        entries.contains { entry in
            entry.isEncrypted || entry.isDirectory
                && reader.tree.descendantFiles(of: ArchiveSource.archivePath(of: entry)).contains { $0.isEncrypted }
        }
    }
}

// MARK: - 单元格与选择

extension BrowserViewController: NSOutlineViewDelegate {
    public func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let tableColumn, let node = item as? BrowserNode else { return nil }
        let entry = node.entry
        if tableColumn.identifier == Self.nameColumn {
            let cell = makeCell(identifier: Self.nameColumn, withIcon: true, alignment: .left)
            cell.textField?.font = .systemFont(ofSize: appliedFontSize)
            cell.textField?.stringValue = entry.name
            cell.imageView?.image = icon(for: entry)
            return cell
        }
        guard let column = PeekPreferences.Column(rawValue: tableColumn.identifier.rawValue) else { return nil }
        let cell = makeCell(identifier: tableColumn.identifier, withIcon: false,
                            alignment: column == .size ? .right : .left)
        cell.textField?.font = .systemFont(ofSize: appliedFontSize)
        cell.textField?.stringValue = text(for: column, of: entry)
        return cell
    }

    private func text(for column: PeekPreferences.Column, of entry: Entry) -> String {
        func date(_ value: Date?) -> String { value?.formatted(Self.dateFormat) ?? "--" }
        switch column {
        case .modified: return entry.modified?.formatted(Self.dateFormat) ?? String(localized: "日期未知", bundle: .peekUI)
        case .created: return date(entry.created)
        case .added: return date(entry.added)
        // 元数据在后台读取，尚未读完时留空（读完后刷新可见行）
        case .lastOpened:
            guard let url = entry.fileURL else { return "--" }
            guard let values = metadata.values(of: url) else { return "" }
            return date(values.lastOpened)
        case .size:
            return entry.size.map { Localization.fileSize($0) } ?? "--"
        case .kind:
            let kind = entry.kind ?? (entry.isDirectory ? String(localized: "文件夹", bundle: .peekUI) : "")
            return entry.isEncrypted ? "🔒 " + kind : kind
        case .comment: return entry.fileURL.flatMap { metadata.values(of: $0)?.comment } ?? ""
        case .tags:
            return (entry.fileURL.flatMap { metadata.values(of: $0)?.tags } ?? []).joined(separator: String(localized: "，", bundle: .peekUI))
        case .dimensions:
            guard let url = entry.fileURL else { return "--" }
            guard let values = metadata.values(of: url) else { return "" }
            guard let size = values.pixelSize else { return "--" }
            return "\(Int(size.width)) × \(Int(size.height))"
        }
    }

    public func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        appliedRowHeight
    }

    public func outlineViewSelectionDidChange(_ notification: Notification) {
        updateStatus()
        updateToolbarState()
        updateInspector()
    }

    public func outlineViewItemWillExpand(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? BrowserNode else { return }
        loadChildren(of: node)
    }

    private func makeCell(identifier: NSUserInterfaceItemIdentifier, withIcon: Bool,
                          alignment: NSTextAlignment) -> NSTableCellView {
        let reuseID = NSUserInterfaceItemIdentifier("cell.\(identifier.rawValue)")
        if let reused = outlineView.makeView(withIdentifier: reuseID, owner: self) as? NSTableCellView {
            return reused
        }
        let cell = NSTableCellView()
        cell.identifier = reuseID
        let text = NSTextField(labelWithString: "")
        text.lineBreakMode = withIcon ? .byTruncatingMiddle : .byTruncatingTail
        text.alignment = alignment
        text.translatesAutoresizingMaskIntoConstraints = false
        if !withIcon { text.textColor = .secondaryLabelColor }
        cell.addSubview(text)
        cell.textField = text

        if withIcon {
            let image = NSImageView()
            image.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(image)
            cell.imageView = image
            NSLayoutConstraint.activate([
                image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                image.widthAnchor.constraint(equalTo: image.heightAnchor),
                text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
            ])
            // 图标随行高缩放；行高可实时改变，单元格会被复用，故用比例而非常量
            let height = image.heightAnchor.constraint(equalTo: cell.heightAnchor, multiplier: 0.72)
            height.priority = .init(999)
            height.isActive = true
        } else {
            text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2).isActive = true
        }
        // 单元格刚创建时宽度为 0，尾部约束若为必须满足会与文本非负宽度冲突
        let trailing = text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2)
        trailing.priority = .init(999)
        NSLayoutConstraint.activate([trailing, text.centerYAnchor.constraint(equalTo: cell.centerYAnchor)])
        return cell
    }
}
