import AppKit

/// 图标视图的集合视图：与列表一致地接受首次点击、右键先选中被点项；NSCollectionView 没有 doubleAction，双击在此识别
final class PreviewCollectionView: NSCollectionView {
    /// 拖入 / 离开时通知控制器清空本次拖动的写入检查
    var onDraggingBoundary: (() -> Void)?
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        onDraggingBoundary?()
        return super.draggingEntered(sender)
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        super.draggingExited(sender)
        onDraggingBoundary?()
    }

    var contextMenuProvider: ((NSEvent) -> NSMenu?)?
    var onDoubleClick: ((IndexPath) -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        guard event.clickCount == 2,
              let indexPath = indexPathForItem(at: convert(event.locationInWindow, from: nil)) else { return }
        onDoubleClick?(indexPath)
    }

    /// 右键点在未选中的项上时先选中它，点在空白处清除选择（与列表行为一致）
    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        if let indexPath = indexPathForItem(at: point) {
            if !selectionIndexPaths.contains(indexPath) {
                deselectAll(nil)
                selectItems(at: [indexPath], scrollPosition: [])
                delegate?.collectionView?(self, didSelectItemsAt: [indexPath])
            }
        } else if !selectionIndexPaths.isEmpty {
            let previous = selectionIndexPaths
            deselectAll(nil)
            delegate?.collectionView?(self, didDeselectItemsAt: previous)
        }
        return contextMenuProvider?(event)
    }
}

/// 图标项的根视图：不接受隐藏。NSCollectionView 在拖动开始时会把被拖的条目设为隐藏，直到拖动会话结束
/// （包括放下失败后拖动图像飞回原位的约 0.5 秒）才恢复，看起来像图标闪了一下。Finder 拖动时原位图标始终可见；
/// 诊断日志显示，条目的显示与回收是通过加入 / 移出视图层级完成的，隐藏只出现在拖动期间
final class IconItemView: NSView {
    override var isHidden: Bool {
        get { super.isHidden }
        set { super.isHidden = false }
    }
}

/// 图标项：图标 + 最多两行名称；选中时图标加圆角底色、名称加强调色背景（参考 Finder）
final class IconItem: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("IconItem")

    private let iconView = NSImageView()
    private let iconBackground = NSView()
    private let nameField = NSTextField(wrappingLabelWithString: "")
    private var iconSizeConstraint: NSLayoutConstraint?
    /// 缩略图请求的标识，单元复用时用来丢弃过期结果
    var representedID: String?

    override func loadView() {
        let root = IconItemView()
        iconBackground.wantsLayer = true
        iconBackground.layer?.cornerRadius = 6
        iconView.imageScaling = .scaleProportionallyUpOrDown
        // NSImageView 默认登记了文件与 File Promise 等拖放类型，且不可编辑时一律拒绝：不取消登记，
        // 拖到图标正中时拖放交给它而到不了集合视图（只有图标边缘能放下）
        iconView.unregisterDraggedTypes()
        // 换行标签默认可选中文字，指针在名称上会变成 I 形
        nameField.isSelectable = false
        nameField.alignment = .center
        nameField.maximumNumberOfLines = 2
        nameField.lineBreakMode = .byTruncatingMiddle
        nameField.cell?.truncatesLastVisibleLine = true
        nameField.wantsLayer = true
        nameField.layer?.cornerRadius = 4
        for view in [iconBackground, iconView, nameField] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        let size = iconView.widthAnchor.constraint(equalToConstant: 72)
        iconSizeConstraint = size
        NSLayoutConstraint.activate([
            iconView.topAnchor.constraint(equalTo: root.topAnchor, constant: 6),
            iconView.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            size,
            iconView.heightAnchor.constraint(equalTo: iconView.widthAnchor),
            iconBackground.leadingAnchor.constraint(equalTo: iconView.leadingAnchor, constant: -4),
            iconBackground.trailingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 4),
            iconBackground.topAnchor.constraint(equalTo: iconView.topAnchor, constant: -4),
            iconBackground.bottomAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 4),
            nameField.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 6),
            nameField.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            nameField.widthAnchor.constraint(lessThanOrEqualTo: root.widthAnchor, constant: -4),
        ])
        view = root
        imageView = iconView
        textField = nameField
    }

    func configure(name: String, icon: NSImage, iconSize: CGFloat, fontSize: CGFloat) {
        nameField.stringValue = name
        nameField.font = .systemFont(ofSize: fontSize)
        nameField.preferredMaxLayoutWidth = iconSize + 36
        iconView.image = icon
        iconSizeConstraint?.constant = iconSize
        updateSelection()
    }

    /// 拖动图标大小滑块时直接调整可见项，不重新配置单元
    func setIconSize(_ iconSize: CGFloat) {
        iconSizeConstraint?.constant = iconSize
        nameField.preferredMaxLayoutWidth = iconSize + 36
    }

    func setThumbnail(_ image: NSImage) {
        iconView.image = image
    }

    override var isSelected: Bool {
        didSet { updateSelection() }
    }

    private func updateSelection() {
        iconBackground.layer?.backgroundColor = isSelected ? NSColor.quaternaryLabelColor.cgColor : nil
        nameField.layer?.backgroundColor = isSelected ? NSColor.controlAccentColor.cgColor : nil
        nameField.textColor = isSelected ? .white : .labelColor
    }
}
