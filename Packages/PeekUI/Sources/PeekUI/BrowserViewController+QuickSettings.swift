import AppKit
import PeekCore

/// 左下角快速设置：外观与交互模仿系统菜单的弹出面板（见 MenuLikeRow），行高 / 文字大小 / 文件夹深度为可折叠分组。
/// 不用菜单：子菜单在 Quick Look 中会导致点击失效（见 BrowserViewController 的说明），弹出框已验证可用。
/// 改动立即作用于当前预览并成为全局默认值；只在展开 / 折叠时重建面板，其余改动只刷新对勾与数值。
extension BrowserViewController {
    private enum Group: String {
        case rowHeight, fontSize, depth
    }

    private static let panelWidth: CGFloat = 240

    @objc func showSettingsPanel(_ sender: Any?) {
        if let popover = settingsPopover, popover.isShown {
            popover.close()
            return
        }
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)
        settingsStack = stack
        rebuildSettingsRows()

        let popover = makePopover(stack)
        // 尺寸变化不做动画，避免展开 / 折叠时闪烁
        popover.animates = false
        popover.contentSize = stack.fittingSize
        popover.show(relativeTo: settingsButton.bounds, of: settingsButton, preferredEdge: .maxY)
        settingsPopover = popover
    }

    /// 结构变化（展开 / 折叠分组）时重建行，并按新高度调整弹出框
    private func rebuildSettingsRows() {
        guard let stack = settingsStack else { return }
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        settingsRows = []
        for view in makeSettingsRows() {
            stack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalToConstant: Self.panelWidth - 12).isActive = true
            if let row = view as? MenuLikeRow {
                settingsRows.append(row)
                row.refresh()
            }
        }
        if let popover = settingsPopover, popover.isShown {
            popover.contentSize = stack.fittingSize
        }
    }

    /// 只刷新对勾、数值与可用状态
    private func refreshSettingsRows() {
        settingsRows.forEach { $0.refresh() }
    }

    private func makeSettingsRows() -> [NSView] {
        // 外观与行为两组之间只用分隔线区分，不加组标题（与系统菜单的观感一致）
        var rows: [NSView] = group(.rowHeight, title: String(localized: "行高", bundle: .peekUI), value: { PeekPreferences.largeRows ? String(localized: "大", bundle: .peekUI) : String(localized: "小", bundle: .peekUI) },
                      options: [(String(localized: "小", bundle: .peekUI), false), (String(localized: "大", bundle: .peekUI), true)].map { title, large in
                          (title, { PeekPreferences.largeRows == large }, { [weak self] in self?.setRowHeight(large: large) })
                      })
        rows += group(.fontSize, title: String(localized: "文字大小", bundle: .peekUI), value: { "\(PeekPreferences.fontSize)" },
                      options: PeekPreferences.fontSizes.map { size in
                          ("\(size)", { PeekPreferences.fontSize == size }, { [weak self] in self?.setFontSize(size) })
                      })
        rows.append(toggle(String(localized: "显示路径栏", bundle: .peekUI), isOn: { PeekPreferences.showPathBar }) { [weak self] in
            PeekPreferences.showPathBar.toggle()
            self?.applyBarsVisibility()
        })
        rows.append(toggle(String(localized: "显示标题栏", bundle: .peekUI), isOn: { PeekPreferences.showToolbar }) { [weak self] in
            PeekPreferences.showToolbar.toggle()
            self?.applyBarsVisibility()
        })

        rows.append(divider())
        rows.append(toggle(String(localized: "显示隐藏文件", bundle: .peekUI), isOn: { PeekPreferences.showHiddenFiles }) { [weak self] in
            self?.toggleHiddenFiles(nil)
        })
        rows.append(toggle(String(localized: "文件夹置顶", bundle: .peekUI), isOn: { PeekPreferences.foldersFirst }) { [weak self] in
            PeekPreferences.foldersFirst.toggle()
            self?.resortPreservingExpansion()
        })
        rows.append(toggle(String(localized: "展开所有子文件夹", bundle: .peekUI), isOn: { PeekPreferences.expandAllFolders }) { [weak self] in
            PeekPreferences.expandAllFolders.toggle()
            if !PeekPreferences.expandAllFolders, self?.expandedSettingsGroup == Group.depth.rawValue {
                self?.expandedSettingsGroup = nil
                self?.rebuildSettingsRows()
            }
            self?.applyExpandSettings()
        })
        rows += group(.depth, title: String(localized: "文件夹深度", bundle: .peekUI), value: { "\(PeekPreferences.expandDepth)" },
                      options: PeekPreferences.expandDepths.map { depth in
                          ("\(depth)", { PeekPreferences.expandDepth == depth }, { [weak self] in
                              PeekPreferences.expandDepth = depth
                              self?.applyExpandSettings()
                          })
                      }, isEnabled: { PeekPreferences.expandAllFolders })
        let archives = toggle(String(localized: "同时展开压缩包", bundle: .peekUI), isOn: { PeekPreferences.expandArchives }) { [weak self] in
            PeekPreferences.expandArchives.toggle()
            self?.applyExpandSettings()
        }
        archives.isEnabled = { PeekPreferences.expandAllFolders }
        rows.append(archives)

        rows.append(divider())
        rows.append(MenuLikeRow(kind: .action, title: String(localized: "检查更新…", bundle: .peekUI)) { [weak self] in
            self?.settingsPopover?.close()
            self?.sendToMainApp(.checkUpdate)
        })
        rows.append(MenuLikeRow(kind: .action, title: String(localized: "设置…", bundle: .peekUI)) { [weak self] in
            self?.settingsPopover?.close()
            self?.sendToMainApp(.settings)
        })
        return rows
    }

    // MARK: - 面板元素

    private func divider() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        let container = NSStackView(views: [box])
        container.edgeInsets = NSEdgeInsets(top: 5, left: 8, bottom: 5, right: 8)
        return container
    }

    /// 点击后先改设置、再刷新面板；toggle 动作内只负责修改与应用
    private func toggle(_ title: String, isOn: @escaping () -> Bool, action: @escaping () -> Void) -> MenuLikeRow {
        let row = MenuLikeRow(kind: .toggle, title: title) { [weak self] in
            action()
            self?.refreshSettingsRows()
        }
        row.isOn = isOn
        return row
    }

    private func group(_ group: Group, title: String, value: @escaping () -> String,
                       options: [(title: String, selected: () -> Bool, choose: () -> Void)],
                       isEnabled: @escaping () -> Bool = { true }) -> [NSView] {
        let header = MenuLikeRow(kind: .group, title: title) { [weak self] in
            guard let self else { return }
            expandedSettingsGroup = expandedSettingsGroup == group.rawValue ? nil : group.rawValue
            rebuildSettingsRows()
        }
        header.value = value
        header.isEnabled = isEnabled
        header.isExpanded = { [weak self] in self?.expandedSettingsGroup == group.rawValue }
        guard expandedSettingsGroup == group.rawValue, isEnabled() else { return [header] }
        let choices = options.map { option in
            let row = MenuLikeRow(kind: .option, title: option.title) { [weak self] in
                option.choose()
                self?.refreshSettingsRows()
            }
            row.isOn = option.selected
            return row
        }
        return [header] + choices
    }

    // MARK: - 设置动作

    private func setRowHeight(large: Bool) {
        PeekPreferences.largeRows = large
        applyRowMetrics()
    }

    private func setFontSize(_ size: Int) {
        PeekPreferences.fontSize = size
        applyRowMetrics()
    }

    private func sendToMainApp(_ command: MainAppCommand) {
        Task {
            do {
                try await BrokerClient.shared.openMainApp(command)
            } catch {
                flash(error.localizedDescription)
            }
        }
    }

    /// 显示隐藏文件改变了列举结果，需要新的数据源；保留当前层级与已输入的密码
    /// 标题栏眼睛按钮与快速设置共用
    @objc func toggleHiddenFiles(_ sender: Any?) {
        PeekPreferences.showHiddenFiles.toggle()
        updateHiddenFilesButton()
        refreshSettingsRows()
        reloadSourceKeepingPassword()
    }

    /// 睁眼 = 正在显示隐藏文件
    func updateHiddenFilesButton() {
        let shown = PeekPreferences.showHiddenFiles
        hiddenFilesButton.image = NSImage(systemSymbolName: shown ? "eye" : "eye.slash",
                                          accessibilityDescription: shown ? String(localized: "隐藏隐藏文件", bundle: .peekUI) : String(localized: "显示隐藏文件", bundle: .peekUI))
        hiddenFilesButton.toolTip = shown ? String(localized: "隐藏隐藏文件", bundle: .peekUI) : String(localized: "显示隐藏文件", bundle: .peekUI)
    }

    private func reloadSourceKeepingPassword() {
        let path = navigation
        if let folder = source as? FolderSource {
            source = FolderSource(rootURL: folder.rootURL, showHidden: PeekPreferences.showHiddenFiles)
        } else if let archive = source as? ArchiveSource {
            let reloaded = ArchiveSource(rootURL: archive.rootURL, showHidden: PeekPreferences.showHiddenFiles)
            reloaded.setPassword(archive.password)
            source = reloaded
        }
        navigation = path
        reload()
    }

    /// 单层菜单项（右键菜单使用）
    func item(_ title: String, _ action: Selector, checked: Bool = false) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.state = checked ? .on : .off
        return item
    }
}
