import AppKit
import UniformTypeIdentifiers
import PeekCore

/// 标题栏按钮与右键菜单共享的操作（菜单一律单层，见 BrowserViewController 的说明）。文件夹条目直接处理真实文件；压缩包条目由 Broker 先提取到缓存再处理。
extension BrowserViewController: NSMenuItemValidation {
    // MARK: - 操作对象

    /// 标题栏按钮与右键菜单都作用于选中项：右键点在未选中的行上时会先选中该行（见 PreviewOutlineView.menu(for:)）
    func targets(for sender: Any?) -> [BrowserNode] {
        selectedNodes()
    }

    private enum Action {
        case enter, open, openWith, copy, copyPath, info, reveal, delete, rename
    }

    private func canPerform(_ action: Action, on nodes: [BrowserNode]) -> Bool {
        let entries = nodes.map(\.entry)
        guard !entries.isEmpty else { return false }
        switch action {
        case .enter: return entries.count == 1 && entries[0].isExpandable
        case .open, .copy, .copyPath, .info, .reveal: return true
        case .openWith: return entries.allSatisfy { !$0.isDirectory }
        // 文件夹中的文件移到废纸篓；压缩包内的条目从同一个 ZIP 中删除
        case .delete: return !archiveWriteInProgress && (entries.allSatisfy { $0.fileURL != nil } || archiveForDeletion(entries) != nil)
        // 只支持 ZIP 内的单个条目（文件夹中的文件不提供重命名）
        case .rename: return !archiveWriteInProgress && entries.count == 1 && writableArchive(of: entries[0]) != nil
        }
    }

    /// 所有条目都在同一个可修改的 ZIP 中时返回该压缩包
    private func archiveForDeletion(_ entries: [Entry]) -> (source: ArchiveSource, url: URL)? {
        guard let first = entries.first, let url = first.archiveURL, let archive = writableArchive(of: first),
              entries.allSatisfy({ $0.archiveURL == url }) else { return nil }
        return (archive, url)
    }

    /// 条目所在的、可以修改的压缩包（libzip 打开的 ZIP）
    private func writableArchive(of entry: Entry) -> ArchiveSource? {
        guard let url = entry.archiveURL, let archive = source?.archiveSource(for: url),
              archive.loadedReader is ZipArchive else { return nil }
        return archive
    }

    func updateToolbarState() {
        let nodes = selectedNodes()
        openWithButton.isEnabled = canPerform(.openWith, on: nodes)
        copyButton.isEnabled = canPerform(.copy, on: nodes)
        copyPathButton.isEnabled = canPerform(.copyPath, on: nodes)
        infoButton.isEnabled = canPerform(.info, on: nodes)
        revealButton.isEnabled = canPerform(.reveal, on: nodes)
        deleteButton.isEnabled = canPerform(.delete, on: nodes)
        // 玻璃样式下系统默认的禁用效果几乎看不出来：可用时用主文字色（深色模式为白色），不可用时用禁用色
        for button in [openWithButton, copyButton, copyPathButton, infoButton, revealButton, deleteButton] as [NSButton] {
            button.contentTintColor = button.isEnabled ? .labelColor : .tertiaryLabelColor
        }
        if !nodes.contains(where: { $0.entry.archiveURL != nil }) {
            deleteButton.toolTip = String(localized: "移到废纸篓", bundle: .peekUI)
        } else if deleteButton.isEnabled {
            deleteButton.toolTip = String(localized: "从压缩包中删除", bundle: .peekUI)
        } else {
            deleteButton.toolTip = String(localized: "只支持删除 ZIP 压缩包内的项目", bundle: .peekUI)
        }
    }

    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let nodes = targets(for: menuItem)
        switch menuItem.action {
        case #selector(createArchiveFolder(_:)): return !archiveWriteInProgress && directoryCreationTarget != nil
        case #selector(enterFolder(_:)): return canPerform(.enter, on: nodes)
        case #selector(openItems(_:)): return canPerform(.open, on: nodes)
        case #selector(copyItems(_:)): return canPerform(.copy, on: nodes)
        case #selector(copyPaths(_:)): return canPerform(.copyPath, on: nodes)
        case #selector(showInfo(_:)): return canPerform(.info, on: nodes)
        case #selector(revealItems(_:)): return canPerform(.reveal, on: nodes)
        case #selector(deleteItems(_:)): return canPerform(.delete, on: nodes)
        case #selector(renameItem(_:)): return canPerform(.rename, on: nodes)
        case #selector(openWithApplication(_:)): return canPerform(.openWith, on: nodes)
        default: return true
        }
    }

    // MARK: - 菜单

    func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        contextMenu = menu
        rebuildContextMenu(menu)
        return menu
    }

    /// 顺序与命名参考 Finder。不含"打开方式"：它需要应用列表，只能做成子菜单，改由标题栏的下拉按钮提供
    private func rebuildContextMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let nodes = selectedNodes()
        if directoryCreationTarget != nil {
            menu.addItem(item(String(localized: "新建文件夹…", bundle: .peekUI), #selector(createArchiveFolder(_:))))
            menu.addItem(.separator())
        }
        if nodes.isEmpty {
            if !navigation.isEmpty { menu.addItem(item(String(localized: "返回上一级", bundle: .peekUI), #selector(goUp(_:)))) }
            return
        }
        if canPerform(.enter, on: nodes) { menu.addItem(item(String(localized: "进入文件夹", bundle: .peekUI), #selector(enterFolder(_:)))) }
        menu.addItem(item(String(localized: "打开", bundle: .peekUI), #selector(openItems(_:))))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "拷贝", bundle: .peekUI), #selector(copyItems(_:))))
        menu.addItem(item(String(localized: "拷贝路径", bundle: .peekUI), #selector(copyPaths(_:))))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "显示简介", bundle: .peekUI), #selector(showInfo(_:))))
        menu.addItem(item(String(localized: "在 Finder 中显示", bundle: .peekUI), #selector(revealItems(_:))))
        // 重命名只针对压缩包内的条目
        if nodes.allSatisfy({ $0.entry.archiveURL != nil }) {
            let rename = item(String(localized: "重命名…", bundle: .peekUI), #selector(renameItem(_:)))
            if !canPerform(.rename, on: nodes) {
                rename.toolTip = nodes.count > 1
                    ? String(localized: "一次只能重命名一个项目", bundle: .peekUI)
                    : String(localized: "只支持重命名 ZIP 压缩包内的项目", bundle: .peekUI)
            }
            menu.addItem(rename)
        }
        menu.addItem(.separator())
        let inArchive = nodes.allSatisfy { $0.entry.archiveURL != nil }
        menu.addItem(item(inArchive ? String(localized: "从压缩包中删除…", bundle: .peekUI)
                                    : String(localized: "移到废纸篓", bundle: .peekUI), #selector(deleteItems(_:))))
        if !navigation.isEmpty {
            menu.addItem(.separator())
            menu.addItem(item(String(localized: "返回上一级", bundle: .peekUI), #selector(goUp(_:))))
        }
    }

    func rebuildOpenWithMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let titleItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        titleItem.image = NSImage(systemSymbolName: "macwindow.badge.plus", accessibilityDescription: String(localized: "打开方式", bundle: .peekUI))
        menu.addItem(titleItem)
        fillApplications(into: menu, for: selectedNodes().map(\.entry))
    }

    /// 默认应用在前，其余按名称排序；压缩包条目按扩展名查询
    private func fillApplications(into menu: NSMenu, for entries: [Entry]) {
        guard let first = entries.first, !first.isDirectory else { return }
        let workspace = NSWorkspace.shared
        let defaultApp: URL?
        let apps: [URL]
        if let url = first.fileURL {
            defaultApp = workspace.urlForApplication(toOpen: url)
            apps = workspace.urlsForApplications(toOpen: url)
        } else {
            let type = UTType(filenameExtension: (first.name as NSString).pathExtension) ?? .data
            defaultApp = workspace.urlForApplication(toOpen: type)
            apps = workspace.urlsForApplications(toOpen: type)
        }
        func appItem(_ app: URL, suffix: String = "") -> NSMenuItem {
            let name = FileManager.default.displayName(atPath: app.path)
                .replacingOccurrences(of: ".app", with: "")
            let entry = item(name + suffix, #selector(openWithApplication(_:)))
            entry.representedObject = app
            let icon = workspace.icon(forFile: app.path)
            icon.size = NSSize(width: 16, height: 16)
            entry.image = icon
            return entry
        }
        if let defaultApp {
            menu.addItem(appItem(defaultApp, suffix: String(localized: "（默认）", bundle: .peekUI)))
            menu.addItem(.separator())
        }
        let others = apps.filter { $0 != defaultApp }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        others.prefix(30).forEach { menu.addItem(appItem($0)) }
        if defaultApp == nil, others.isEmpty {
            let none = NSMenuItem(title: String(localized: "没有可用的应用", bundle: .peekUI), action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
    }

    // MARK: - 操作

    @objc func doubleClicked(_ sender: Any?) {
        let row = outlineView.clickedRow
        guard row >= 0, let node = outlineView.item(atRow: row) as? BrowserNode else { return }
        if node.entry.isExpandable {
            if outlineView.isItemExpanded(node) {
                outlineView.collapseItem(node)
            } else {
                outlineView.expandItem(node)
            }
        } else {
            open([node.entry], with: nil)
        }
    }

    @objc func enterFolder(_ sender: Any?) {
        guard let node = targets(for: sender).first else { return }
        enter(node.entry)
    }

    @objc func goUp(_ sender: Any?) {
        navigateUp()
    }

    @objc func openItems(_ sender: Any?) {
        let entries = targets(for: sender).map(\.entry)
        // 压缩包内的单个目录：进入；文件夹中的目录与压缩包内的包（.app 等）：提取后交给系统打开
        if entries.count == 1, entries[0].isExpandable, entries[0].fileURL == nil {
            enter(entries[0])
            return
        }
        open(entries, with: nil)
    }

    /// 输入面板由后台服务弹出（预览收不到键盘输入）；改名成功后重新读取压缩包并选中改名后的项目
    @objc func renameItem(_ sender: Any?) {
        guard let entry = targets(for: sender).first?.entry, let archiveURL = entry.archiveURL,
              let archive = writableArchive(of: entry) else { return }
        let path = ArchiveSource.archivePath(of: entry)
        guard !archiveWriteInProgress else { return }
        archiveWriteInProgress = true
        updateToolbarState()
        Task {
            defer { archiveWriteInProgress = false; updateToolbarState() }
            do {
                guard let newPath = try await BrokerClient.shared.renameInArchive(archiveURL, entryPath: path) else { return }
                archive.invalidate()
                pendingSelectionID = ArchiveSource.entryID(for: newPath)
                flash(String(localized: "已重命名", bundle: .peekUI))
                reload()
            } catch {
                flash(error.localizedDescription)
            }
        }
    }

    @objc func openWithApplication(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? URL else { return }
        open(targets(for: sender).map(\.entry), with: app)
    }

    func open(_ entries: [Entry], with app: URL?) {
        let limited = Array(entries.prefix(10))
        if entries.count > limited.count { flash(String(localized: "一次最多打开 10 项", bundle: .peekUI)) }
        resolveURLs(for: limited.filter { $0.fileURL != nil || !$0.isDirectory || $0.isPackage }) { [weak self] urls in
            for url in urls {
                Task {
                    do {
                        try await BrokerClient.shared.openFile(url, with: app)
                    } catch {
                        self?.flash(String(localized: "无法打开 \(url.lastPathComponent)：\(error.localizedDescription)", bundle: .peekUI))
                    }
                }
            }
        }
    }

    @objc func copyItems(_ sender: Any?) {
        let entries = targets(for: sender).map(\.entry)
        resolveURLs(for: entries) { [weak self] urls in
            guard !urls.isEmpty else { return }
            Task {
                do {
                    try await BrokerClient.shared.copy(urls)
                    self?.flash(String(localized: "已拷贝 \(urls.count) 项", bundle: .peekUI))
                } catch {
                    self?.flash(error.localizedDescription)
                }
            }
        }
    }

    @objc func copyPaths(_ sender: Any?) {
        // 压缩包条目给出"归档内路径"，不伪装成 Finder 中存在的路径
        let paths = targets(for: sender).map { $0.entry.fileURL?.path ?? ArchiveSource.archivePath(of: $0.entry) }
        Task {
            do {
                try await BrokerClient.shared.copy(text: paths.joined(separator: "\n"))
                flash(paths.count == 1 ? String(localized: "已拷贝路径", bundle: .peekUI) : String(localized: "已拷贝 \(paths.count) 个路径", bundle: .peekUI))
            } catch {
                flash(error.localizedDescription)
            }
        }
    }

    @objc func revealItems(_ sender: Any?) {
        // 压缩包条目在 Finder 中显示的是压缩包本身
        var urls: [URL] = []
        for entry in targets(for: sender).map(\.entry) {
            guard let url = entry.fileURL ?? entry.archiveURL, !urls.contains(url) else { continue }
            urls.append(url)
        }
        Task {
            do {
                try await BrokerClient.shared.reveal(urls)
            } catch {
                flash(error.localizedDescription)
            }
        }
    }

    @objc func showInfo(_ sender: Any?) {
        let nodes = targets(for: sender)
        guard !nodes.isEmpty else { return }
        let reader = nodes.first?.entry.archiveURL.flatMap { source?.archiveSource(for: $0)?.loadedReader }
        let content = EntryInfoView.make(for: nodes.map(\.entry), icon: icon(for:), reader: reader)
        let popover = makePopover(content)
        let (anchor, rect) = anchorForPopover(nodes: nodes, fallback: infoButton)
        popover.show(relativeTo: rect, of: anchor, preferredEdge: .maxX)
    }

    @objc func deleteItems(_ sender: Any?) {
        let nodes = targets(for: sender)
        let entries = nodes.map(\.entry)
        let urls = entries.compactMap(\.fileURL)
        let archive = archiveForDeletion(entries)
        guard !entries.isEmpty, urls.count == entries.count || archive != nil else { return }

        // 预览扩展中 NSAlert sheet 不可靠，用弹出框确认
        let titleText: String
        let detailText: String
        let confirmText: String
        if let archive {
            let archiveName = archive.url.lastPathComponent
            titleText = entries.count == 1
                ? String(localized: "要从“\(archiveName)”中删除“\(entries[0].name)”吗？", bundle: .peekUI)
                : String(localized: "要从“\(archiveName)”中删除 \(entries.count) 个项目吗？", bundle: .peekUI)
            detailText = PeekPreferences.trashOldArchiveVersion
                ? String(localized: "删除前的压缩包会放进废纸篓，需要时可以找回。", bundle: .peekUI)
                : String(localized: "删除后无法恢复。", bundle: .peekUI)
            confirmText = String(localized: "删除", bundle: .peekUI)
            pendingDeletion = []
            pendingArchiveDeletion = (archive.source, archive.url, entries.map(ArchiveSource.archivePath(of:)))
        } else {
            titleText = urls.count == 1
                ? String(localized: "要将“\(urls[0].lastPathComponent)”移到废纸篓吗？", bundle: .peekUI)
                : String(localized: "要将 \(urls.count) 个项目移到废纸篓吗？", bundle: .peekUI)
            detailText = String(localized: "之后可以在废纸篓中选择“放回原处”恢复。", bundle: .peekUI)
            confirmText = String(localized: "移到废纸篓", bundle: .peekUI)
            pendingDeletion = urls
            pendingArchiveDeletion = nil
        }
        let cancel = DialogButton(title: String(localized: "取消", bundle: .peekUI), target: self, action: #selector(dismissConfirm(_:)))
        cancel.keyEquivalent = "\u{1b}"
        let confirm = DialogButton(title: confirmText, role: .destructive, target: self, action: #selector(confirmDelete(_:)))
        let icon = entries.count == 1 ? self.icon(for: entries[0]) : NSImage(named: NSImage.multipleDocumentsName)
        let content = DialogContentView(icon: icon, title: titleText, message: detailText,
                                        trailingButtons: [cancel, confirm], width: 360)

        confirmPopover?.close()
        let popover = makePopover(content)
        let (anchor, rect) = anchorForPopover(nodes: nodes, fallback: deleteButton)
        popover.show(relativeTo: rect, of: anchor, preferredEdge: .maxY)
        confirmPopover = popover
    }

    @objc private func dismissConfirm(_ sender: Any?) {
        confirmPopover?.close()
        confirmPopover = nil
    }

    @objc private func confirmDelete(_ sender: NSButton) {
        let urls = pendingDeletion
        let archived = pendingArchiveDeletion
        pendingDeletion = []
        pendingArchiveDeletion = nil
        dismissConfirm(nil)
        if let archived {
            guard !archiveWriteInProgress else { return }
            archiveWriteInProgress = true
            updateToolbarState()
            flash(String(localized: "正在删除…", bundle: .peekUI))
            Task {
                defer { archiveWriteInProgress = false; updateToolbarState() }
                do {
                    try await BrokerClient.shared.deleteInArchive(archived.url, entryPaths: archived.paths)
                    archived.archive.invalidate()
                    flash(String(localized: "已从压缩包中删除 \(archived.paths.count) 项", bundle: .peekUI))
                } catch {
                    flash(error.localizedDescription)
                }
                reload()
            }
            return
        }
        guard !urls.isEmpty else { return }
        Task {
            do {
                try await BrokerClient.shared.trash(urls)
                flash(urls.count == 1 ? String(localized: "已移到废纸篓", bundle: .peekUI) : String(localized: "已将 \(urls.count) 项移到废纸篓", bundle: .peekUI))
            } catch {
                flash(error.localizedDescription)
            }
            reload()
        }
    }

    // MARK: - 辅助

    /// 文件夹条目直接返回真实 URL；压缩包条目按所属压缩包分组交给 Broker 提取，需要时先要求密码
    private func resolveURLs(for entries: [Entry], completion: @escaping ([URL]) -> Void) {
        var urls = entries.compactMap(\.fileURL)
        let archived = Dictionary(grouping: entries.filter { $0.fileURL == nil }) { $0.archiveURL }
        guard !archived.isEmpty else {
            completion(urls)
            return
        }
        for (archiveURL, group) in archived {
            guard let archiveURL, let archive = source?.archiveSource(for: archiveURL),
                  let reader = archive.loadedReader else { continue }
            if needsPassword(group, reader: reader), archive.password == nil {
                promptPassword(for: archive, message: String(localized: "所选项目已加密，输入密码后才能继续。", bundle: .peekUI)) { [weak self] in
                    self?.resolveURLs(for: entries, completion: completion)
                }
                return
            }
        }
        flash(String(localized: "正在提取…", bundle: .peekUI))
        Task {
            for (archiveURL, group) in archived {
                guard let archiveURL, let archive = source?.archiveSource(for: archiveURL) else { continue }
                do {
                    urls += try await BrokerClient.shared.materialize(
                        archive: archiveURL, entryPaths: group.map(ArchiveSource.archivePath(of:)), password: archive.password)
                } catch {
                    flash(String(localized: "提取失败：\(error.localizedDescription)", bundle: .peekUI))
                }
            }
            updateStatus()
            completion(urls)
        }
    }

    /// 弹出框挂在第一个目标行上；行不可见或无目标时挂在工具栏按钮（工具栏隐藏时挂状态栏）
    func anchorForPopover(nodes: [BrowserNode], fallback: NSView) -> (NSView, NSRect) {
        if PeekPreferences.viewMode == .icons, let first = nodes.first,
           let index = roots.firstIndex(where: { $0 === first }),
           let item = collectionView.item(at: IndexPath(item: index, section: 0)),
           collectionView.visibleRect.intersects(item.view.frame) {
            return (item.view, item.view.bounds)
        }
        // 分栏模式左侧同样是列表
        if PeekPreferences.viewMode != .icons, let first = nodes.first {
            let row = outlineView.row(forItem: first)
            if row >= 0 {
                let rect = outlineView.rect(ofRow: row)
                if outlineView.visibleRect.intersects(rect) {
                    let column = outlineView.column(withIdentifier: .init("name"))
                    let cell = column >= 0 ? outlineView.frameOfCell(atColumn: column, row: row) : rect
                    return (outlineView, NSRect(x: cell.minX, y: rect.minY, width: min(cell.width, 240), height: rect.height))
                }
            }
        }
        let anchor = PeekPreferences.showToolbar ? fallback : statusLabel
        return (anchor, anchor.bounds)
    }
}

