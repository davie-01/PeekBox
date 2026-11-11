import AppKit

/// 外观与交互模仿系统菜单项的行：左侧对勾 / 展开箭头列、悬停整行强调色高亮、右侧灰色数值、点击整行生效。
/// 用于快速设置面板——系统菜单不支持折叠，而子菜单在 Quick Look 中会导致点击失效，故用弹出框承载。
@MainActor
final class MenuLikeRow: NSView {
    enum Kind {
        /// 开关：选中时左侧显示对勾
        case toggle
        /// 分组中的单选项：缩进显示，选中时显示对勾
        case option
        /// 可折叠分组标题：左侧箭头，右侧显示当前值
        case group
        /// 普通命令（检查更新…等）
        case action
    }

    static let height: CGFloat = 24

    private let kind: Kind
    private let marker = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let valueLabel = NSTextField(labelWithString: "")
    private var hovering = false
    private let onClick: () -> Void
    /// 每次 refresh() 时重新求值，面板据此更新而不必重建
    var isOn: () -> Bool = { false }
    var isEnabled: () -> Bool = { true }
    var value: () -> String = { "" }
    var isExpanded: () -> Bool = { false }

    init(kind: Kind, title: String, onClick: @escaping () -> Void) {
        self.kind = kind
        self.onClick = onClick
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 5

        titleLabel.stringValue = title
        titleLabel.font = .menuFont(ofSize: 0)
        valueLabel.font = .menuFont(ofSize: 0)
        valueLabel.alignment = .right
        marker.imageScaling = .scaleProportionallyDown
        for view in [marker, titleLabel, valueLabel] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        let markerLeading: CGFloat = kind == .option ? 24 : 8
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            marker.leadingAnchor.constraint(equalTo: leadingAnchor, constant: markerLeading),
            marker.centerYAnchor.constraint(equalTo: centerYAnchor),
            marker.widthAnchor.constraint(equalToConstant: 12),
            marker.heightAnchor.constraint(equalToConstant: 12),
            titleLabel.leadingAnchor.constraint(equalTo: marker.trailingAnchor, constant: 6),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            valueLabel.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 8),
            valueLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            valueLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func refresh() {
        let enabled = isEnabled()
        switch kind {
        case .toggle, .option:
            marker.image = isOn() ? NSImage(systemSymbolName: "checkmark", accessibilityDescription: String(localized: "已选", bundle: .peekUI)) : nil
        case .group:
            marker.image = NSImage(systemSymbolName: isExpanded() ? "chevron.down" : "chevron.right", accessibilityDescription: nil)
        case .action:
            marker.image = nil
        }
        valueLabel.stringValue = kind == .group ? value() : ""
        let highlighted = hovering && enabled
        layer?.backgroundColor = highlighted ? NSColor.controlAccentColor.cgColor : nil
        let textColor: NSColor = !enabled ? .tertiaryLabelColor : highlighted ? .white : .labelColor
        titleLabel.textColor = textColor
        marker.contentTintColor = textColor
        valueLabel.textColor = highlighted ? .white : enabled ? .secondaryLabelColor : .tertiaryLabelColor
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        refresh()
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        refresh()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard isEnabled(), bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onClick()
    }
}
