import AppKit

// 预览内弹出框与后台服务面板共用的对话框组件：统一排版、按钮悬停反馈、无蓝色焦点环。

/// 对话框按钮：不接收焦点（不画蓝色焦点环，回车 / Esc 等快捷键照常生效），鼠标移入时明显变色，
/// 第一次点击即生效（预览与后台服务的面板都不是前台应用的当前窗口）
public final class DialogButton: NSButton {
    public enum Role {
        case normal, primary, destructive
    }

    public let role: Role
    /// 自绘背景：系统按钮在没有焦点的窗口里一律画成非活动样式，忽略 bezelColor，悬停变色与着色都会消失。
    /// 放在始终不取得焦点的面板（如写入进度）里时使用
    private let drawsBackground: Bool
    private var hovering = false
    private var pressed = false

    public init(title: String, role: Role = .normal, drawsBackground: Bool = false, target: AnyObject?, action: Selector?) {
        self.role = role
        self.drawsBackground = drawsBackground
        super.init(frame: .zero)
        self.title = title
        self.target = target
        self.action = action
        if drawsBackground {
            isBordered = false
            wantsLayer = true
            layer?.cornerCurve = .continuous
            font = .systemFont(ofSize: NSFont.systemFontSize)
            setButtonType(.momentaryChange)
        } else {
            bezelStyle = .push
            controlSize = .large
            setButtonType(.momentaryPushIn)
        }
        focusRingType = .none
        if role == .primary { keyEquivalent = "\r" }
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(greaterThanOrEqualToConstant: 84).isActive = true
        refreshAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    public override var acceptsFirstResponder: Bool { false }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    public override var intrinsicContentSize: NSSize {
        guard drawsBackground else { return super.intrinsicContentSize }
        // 与大号系统按钮同高、留出同样的左右边距
        return NSSize(width: super.intrinsicContentSize.width + 32, height: 28)
    }

    public override func layout() {
        super.layout()
        if drawsBackground { layer?.cornerRadius = bounds.height / 2 }
    }

    /// 自绘时按下期间加深（super.mouseDown 跟踪鼠标直到松开才返回）
    public override func mouseDown(with event: NSEvent) {
        guard drawsBackground, isEnabled else { return super.mouseDown(with: event) }
        pressed = true
        refreshAppearance()
        super.mouseDown(with: event)
        pressed = false
        refreshAppearance()
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        if drawsBackground { refreshAppearance() }
    }

    public override var isEnabled: Bool {
        didSet { refreshAppearance() }
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    public override func mouseEntered(with event: NSEvent) {
        hovering = true
        refreshAppearance()
    }

    public override func mouseExited(with event: NSEvent) {
        hovering = false
        refreshAppearance()
    }

    /// 普通按钮的悬停底色。系统按底色明暗自动选文字颜色：深色模式用中灰（保持白字），浅色模式用浅灰（保持黑字）
    private static let hoverColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 0.40, alpha: 1)
            : NSColor(white: 0.78, alpha: 1)
    }

    /// 自绘时普通按钮的常态与按下底色
    private static let normalColor = NSColor(name: nil) { appearance in
        NSColor(white: appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? 0.24 : 0.89, alpha: 1)
    }
    private static let pressedColor = NSColor(name: nil) { appearance in
        NSColor(white: appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? 0.48 : 0.70, alpha: 1)
    }

    public override var title: String {
        didSet { refreshAppearance() }
    }

    private func refreshAppearance() {
        let highlighted = hovering && isEnabled
        // 主要 / 删除按钮不可用时显示为普通灰色按钮，避免看起来仍可点击
        let tinted = role != .normal && isEnabled
        let tint: NSColor? = switch role {
        case .primary where tinted: highlighted ? NSColor.controlAccentColor.blended(withFraction: 0.22, of: .white) : .controlAccentColor
        case .destructive where tinted: highlighted ? NSColor.systemRed.blended(withFraction: 0.22, of: .white) : .systemRed
        default: highlighted ? Self.hoverColor : nil
        }
        if drawsBackground {
            var background = tint ?? Self.normalColor
            if pressed { background = tinted ? background.blended(withFraction: 0.2, of: .black) ?? background : Self.pressedColor }
            // 动态颜色按本视图的外观取值后再交给图层
            effectiveAppearance.performAsCurrentDrawingAppearance {
                layer?.backgroundColor = background.cgColor
            }
        } else {
            bezelColor = tint
        }
        // macOS 26 的按钮不采用 contentTintColor 作为文字颜色：着色按钮直接指定白色文字
        let font = font ?? .systemFont(ofSize: NSFont.systemFontSize)
        let color: NSColor = tinted ? .white : (isEnabled ? .labelColor : .tertiaryLabelColor)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: color, .font: font, .paragraphStyle: paragraph,
        ])
    }
}

/// 输入框统一样式：圆角边框、大号控件、不画蓝色焦点环
@MainActor
public enum DialogField {
    public static func style(_ field: NSTextField) {
        field.bezelStyle = .roundedBezel
        field.isBezeled = true
        field.controlSize = .large
        field.font = .systemFont(ofSize: NSFont.systemFontSize + 1)
        field.focusRingType = .none
        field.lineBreakMode = .byTruncatingMiddle
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.translatesAutoresizingMaskIntoConstraints = false
    }
}

/// 对话框内容：左侧图标，右侧标题、说明、附加内容（输入框 / 进度条等）与提示行；按钮在底部，
/// 次要按钮靠左、主要按钮靠右
public final class DialogContentView: NSView {
    public let titleLabel = NSTextField(wrappingLabelWithString: "")
    public let messageLabel = NSTextField(wrappingLabelWithString: "")
    /// 输入错误、处理中等状态提示，默认隐藏
    public let noteLabel = NSTextField(wrappingLabelWithString: "")
    private let iconView = NSImageView()
    private let textWidth: CGFloat

    public init(icon: NSImage?, title: String, message: String? = nil, accessories: [NSView] = [],
                leadingButtons: [NSView] = [], trailingButtons: [NSView], width: CGFloat = 400) {
        textWidth = width - 20 * 2 - (icon == nil ? 0 : 48 + 16)
        super.init(frame: .zero)

        for label in [titleLabel, messageLabel, noteLabel] {
            label.isSelectable = false
            label.preferredMaxLayoutWidth = textWidth
        }
        titleLabel.stringValue = title
        titleLabel.font = .systemFont(ofSize: NSFont.systemFontSize + 1, weight: .semibold)
        titleLabel.maximumNumberOfLines = 3
        titleLabel.lineBreakMode = .byTruncatingMiddle
        messageLabel.stringValue = message ?? ""
        messageLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize + 1)
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.isHidden = message == nil
        noteLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        noteLabel.isHidden = true

        let texts = NSStackView(views: [titleLabel, messageLabel] + accessories + [noteLabel])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 8
        texts.setCustomSpacing(4, after: titleLabel)
        if let last = accessories.last { texts.setCustomSpacing(6, after: last) }
        for view in accessories {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalToConstant: textWidth).isActive = true
        }

        let body = NSStackView()
        body.orientation = .horizontal
        body.alignment = .top
        body.spacing = 16
        if let icon {
            iconView.image = icon
            iconView.imageScaling = .scaleProportionallyUpOrDown
            iconView.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                iconView.widthAnchor.constraint(equalToConstant: 48),
                iconView.heightAnchor.constraint(equalToConstant: 48),
            ])
            body.addArrangedSubview(iconView)
        }
        body.addArrangedSubview(texts)

        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 10
        buttons.setViews(leadingButtons, in: .leading)
        buttons.setViews(trailingButtons, in: .trailing)

        let stack = NSStackView(views: [body, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 20
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 18, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthAnchor.constraint(equalToConstant: width),
            buttons.widthAnchor.constraint(equalToConstant: width - 40),
            texts.widthAnchor.constraint(equalToConstant: textWidth),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// 显示状态提示；isError 时用红色
    public func setNote(_ text: String?, isError: Bool = false) {
        noteLabel.stringValue = text ?? ""
        noteLabel.textColor = isError ? .systemRed : .secondaryLabelColor
        noteLabel.isHidden = text?.isEmpty ?? true
    }

    public func setIcon(_ image: NSImage?) {
        iconView.image = image
    }
}

/// 永远不取得键盘焦点的面板
private final class NonKeyPanel: FocusRinglessPanel {
    override var canBecomeKey: Bool { false }
}

/// 后台服务的对话框面板：无标题栏与红绿灯，可拖动背景移动；不激活应用（Finder 保持前台，预览不关闭）
@MainActor
public enum DialogPanel {
    /// canBecomeKey 为 false 时面板不取得键盘焦点，预览窗口保持可操作（按钮须自绘，见 DialogButton）
    public static func make(canBecomeKey: Bool = true) -> NSPanel {
        // 两种面板都不画焦点环（见 FocusRing.swift）
        let panelClass: NSPanel.Type = canBecomeKey ? FocusRinglessPanel.self : NonKeyPanel.self
        let panel = panelClass.init(contentRect: NSRect(x: 0, y: 0, width: 400, height: 160),
                                    styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
                                    backing: .buffered, defer: false)
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(kind)?.isHidden = true
        }
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = true
        // 位于 Quick Look 预览窗口之上
        panel.level = .modalPanel
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isReleasedWhenClosed = false
        return panel
    }

    /// 放到鼠标所在屏幕的中上部
    public static func place(_ panel: NSPanel) {
        guard let content = panel.contentView else { return }
        panel.setContentSize(content.fittingSize)
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: visible.midX - panel.frame.width / 2,
                                         y: visible.minY + visible.height * 0.62))
        }
    }
}
