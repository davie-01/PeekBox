import AppKit
import QuickLookThumbnailing
import os
import PeekCore

/// 图标视图：只显示当前层级（不展开树），与列表共用选择、操作、右键菜单与拖出。
/// 缩略图只为可见项生成，滚出可见区即取消；压缩包内条目显示类型图标。
extension BrowserViewController: NSCollectionViewDataSource, NSCollectionViewDelegate {
    func configureIconView() {
        // 缩略图缓存设上限（按显示像素计费）：滚动浏览大量图片时内存不随浏览量无限增长
        thumbnailCache.totalCostLimit = 96 * 1024 * 1024
        let layout = NSCollectionViewFlowLayout()
        layout.sectionInset = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        layout.minimumInteritemSpacing = 8
        layout.minimumLineSpacing = 12
        collectionView.collectionViewLayout = layout
        collectionView.register(IconItem.self, forItemWithIdentifier: IconItem.identifier)
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = true
        collectionView.backgroundColors = [.clear]
        collectionView.dataSource = self
        collectionView.delegate = self
        // 拖入、拖出与列表使用同一目标判断。
        collectionView.registerForDraggedTypes([.fileURL])
        collectionView.onDraggingBoundary = { [weak self] in self?.resetDropChecks() }
        collectionView.setDraggingSourceOperationMask(.copy, forLocal: false)
        collectionView.contextMenuProvider = { [weak self] _ in self?.makeContextMenu() }
        collectionView.onDoubleClick = { [weak self] indexPath in self?.iconDoubleClicked(at: indexPath) }
        iconScrollView.documentView = collectionView
        iconScrollView.hasVerticalScroller = true
        iconScrollView.scrollerStyle = .legacy
        iconScrollView.autohidesScrollers = true
        iconScrollView.drawsBackground = false
        applyIconSize()
    }

    /// 切换视图；在图标视图与列表（含分栏）之间切换时，把切换前的选择（当前层级的项）带到新视图
    func switchViewMode(to mode: PeekPreferences.ViewMode) {
        let old = PeekPreferences.viewMode
        guard mode != old else { return }
        let selected = (old == .icons) != (mode == .icons) ? selectedNodes() : nil
        PeekPreferences.viewMode = mode
        applyViewMode(keeping: selected)
    }

    /// nodes 为 nil 时保留当前视图里的选择
    func applyViewMode(keeping nodes: [BrowserNode]? = nil) {
        let mode = PeekPreferences.viewMode
        let icons = mode == .icons
        scrollView.isHidden = icons
        iconScrollView.isHidden = !icons
        iconSizeSlider.isHidden = !icons
        viewSwitch.selectedSegment = PeekPreferences.ViewMode.allCases.firstIndex(of: mode) ?? 0
        setInspectorVisible(mode == .columns)
        // 在图标视图与列表之间切换（nodes 非 nil）时，刚显示出来的视图若已过期先刷新
        if nodes != nil, hiddenViewStale {
            if icons { collectionView.reloadData() } else { outlineView.reloadData() }
            hiddenViewStale = false
        }
        if let nodes {
            reselect(nodes, icons: icons)
        }
        // 焦点留在隐藏的视图上时，选中项会以非活动的灰色显示
        view.window?.makeFirstResponder(icons ? collectionView : outlineView)
        // 隐藏视图（检查器文本、列表）留下的指针区域不会自动失效，切换后指针可能停留为 I 形
        view.window?.invalidateCursorRects(for: view)
        updateStatus()
        updateToolbarState()
        updateInspector()
    }

    /// 两种视图的滚动位置互不对应：有选择时把第一个选中项滚到可见区中部
    private func reselect(_ nodes: [BrowserNode], icons: Bool) {
        let selected = Set(nodes.map { ObjectIdentifier($0) })
        // 刚显示的视图尚未布局，先布局才能算出选中项位置
        view.layoutSubtreeIfNeeded()
        if icons {
            let paths = roots.enumerated().filter { selected.contains(ObjectIdentifier($0.element)) }
                .map { IndexPath(item: $0.offset, section: 0) }
            collectionView.selectItems(at: Set(paths), scrollPosition: [])
            if let first = paths.first {
                collectionView.scrollToItems(at: [first], scrollPosition: .centeredVertically)
            }
        } else {
            let rows = IndexSet(roots.compactMap { selected.contains(ObjectIdentifier($0)) ? outlineView.row(forItem: $0) : nil }
                .filter { $0 >= 0 })
            outlineView.selectRowIndexes(rows, byExtendingSelection: false)
            if let first = rows.first { scrollRowToCenter(first) }
        }
    }

    private func scrollRowToCenter(_ row: Int) {
        let rect = outlineView.rect(ofRow: row)
        let clip = scrollView.contentView
        let visible = clip.bounds.height - (outlineView.headerView?.frame.height ?? 0)
        let maxY = max(outlineView.frame.height - visible, 0)
        let y = min(max(rect.midY - visible / 2, 0), maxY)
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: y - (outlineView.headerView?.frame.height ?? 0)))
        scrollView.reflectScrolledClipView(clip)
    }

    func applyIconSize() {
        guard let layout = collectionView.collectionViewLayout as? NSCollectionViewFlowLayout else { return }
        layout.itemSize = NSSize(width: currentIconSize + 40, height: currentIconSize + 52)
        iconSizeSlider.doubleValue = Double(currentIconSize)
        collectionView.reloadData()
    }

    @objc func viewModeChanged(_ sender: NSSegmentedControl) {
        let modes = PeekPreferences.ViewMode.allCases
        switchViewMode(to: modes[min(max(sender.selectedSegment, 0), modes.count - 1)])
    }

    /// 拖动滑块时每个事件只调整布局与可见图标的大小；停下 0.3 秒后才写入设置。
    /// 此前每个事件都写一次设置文件、清空缩略图缓存并整表重新加载，可见项的缩略图被反复重新生成
    @objc func iconSizeChanged(_ sender: NSSlider) {
        currentIconSize = CGFloat(sender.doubleValue)
        if let layout = collectionView.collectionViewLayout as? NSCollectionViewFlowLayout {
            layout.itemSize = NSSize(width: currentIconSize + 40, height: currentIconSize + 52)
        }
        for item in collectionView.visibleItems() {
            (item as? IconItem)?.setIconSize(currentIconSize)
        }
        iconSizeSaveTask?.cancel()
        iconSizeSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, !Task.isCancelled else { return }
            PeekPreferences.iconSize = Double(currentIconSize)
            // 放大超过已有缩略图的尺寸时才重新生成，缩小时直接复用
            if currentIconSize > thumbnailSide {
                thumbnailSide = currentIconSize
                thumbnailCache.removeAllObjects()
                collectionView.reloadData()
            }
        }
    }

    private func iconDoubleClicked(at indexPath: IndexPath) {
        guard indexPath.item < roots.count else { return }
        let entry = roots[indexPath.item].entry
        if entry.isExpandable {
            enter(entry)
        } else {
            open([entry], with: nil)
        }
    }

    // MARK: - 数据源

    public func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        roots.count
    }

    public func collectionView(_ collectionView: NSCollectionView,
                               itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: IconItem.identifier, for: indexPath)
        guard let icon = item as? IconItem, indexPath.item < roots.count else { return item }
        let entry = roots[indexPath.item].entry
        icon.representedID = entry.id
        let image = thumbnailCache.object(forKey: entry.id as NSString) ?? self.icon(for: entry)
        icon.configure(name: entry.name, icon: image, iconSize: currentIconSize, fontSize: CGFloat(PeekPreferences.fontSize) - 1)
        return icon
    }

    // MARK: - 选择

    public func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        updateStatus()
        updateToolbarState()
    }

    public func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
        updateStatus()
        updateToolbarState()
    }

    // MARK: - 拖出

    public func collectionView(_ collectionView: NSCollectionView, canDragItemsAt indexPaths: Set<IndexPath>,
                               with event: NSEvent) -> Bool {
        true
    }

    public func collectionView(_ collectionView: NSCollectionView,
                               pasteboardWriterForItemAt indexPath: IndexPath) -> (any NSPasteboardWriting)? {
        guard indexPath.item < roots.count else { return nil }
        return pasteboardWriter(for: roots[indexPath.item].entry)
    }

    // MARK: - 缩略图

    public func collectionView(_ collectionView: NSCollectionView, willDisplay item: NSCollectionViewItem,
                               forRepresentedObjectAt indexPath: IndexPath) {
        guard let icon = item as? IconItem, indexPath.item < roots.count else { return }
        let entry = roots[indexPath.item].entry
        // 只有文件夹中的真实文件能生成缩略图；目录与包保持系统图标
        guard let url = entry.fileURL, !entry.isDirectory,
              thumbnailCache.object(forKey: entry.id as NSString) == nil else { return }
        let scale = view.window?.backingScaleFactor ?? 2
        // 缓存中的缩略图统一按 thumbnailSide 生成，图标缩小时可直接复用
        let side = thumbnailSide
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: side, height: side),
                                                   scale: scale, representationTypes: .thumbnail)
        thumbnailRequests[ObjectIdentifier(icon)] = request
        let id = entry.id
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self, weak icon] thumbnail, error in
            guard let image = thumbnail?.nsImage else {
                if let error { Logger.peek("Browser").error("thumbnail failed: \(error.localizedDescription, privacy: .public)") }
                return
            }
            Task { @MainActor in
                let pixels = image.representations.first.map { $0.pixelsWide * $0.pixelsHigh } ?? 0
                self?.thumbnailCache.setObject(image, forKey: id as NSString, cost: pixels * 4)
                // 单元已被复用于其他条目时丢弃结果
                if let icon, icon.representedID == id { icon.setThumbnail(image) }
            }
        }
    }

    public func collectionView(_ collectionView: NSCollectionView, didEndDisplaying item: NSCollectionViewItem,
                               forRepresentedObjectAt indexPath: IndexPath) {
        guard let request = thumbnailRequests.removeValue(forKey: ObjectIdentifier(item)) else { return }
        QLThumbnailGenerator.shared.cancel(request)
    }
}
