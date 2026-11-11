import AppKit

/// 右侧检查器：上方预览（图片 / 文本 / 提示），下方名称与属性
@MainActor
final class InspectorView: NSView {
    enum Preview {
        case image(NSImage)
        case text(String, truncated: Bool)
        case message(String, unlock: Bool)
        case loading
    }

    private let imageView = NSImageView()
    private let textScroll = NSTextView.scrollableTextView()
    private var textView: NSTextView { textScroll.documentView as! NSTextView }
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    let unlockButton = DialogButton(title: String(localized: "输入密码…", bundle: .peekUI), target: nil, action: nil)
    private let messageStack = NSStackView()
    private let spinner = NSProgressIndicator()
    private let nameLabel = NSTextField(wrappingLabelWithString: "")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let infoStack = NSStackView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        imageView.imageScaling = .scaleProportionallyDown
        imageView.imageAlignment = .alignCenter
        // NSImageView 的固有尺寸等于图片尺寸：大图会把检查器乃至整个预览撑得比窗口还宽
        for orientation in [NSLayoutConstraint.Orientation.horizontal, .vertical] {
            imageView.setContentCompressionResistancePriority(.init(1), for: orientation)
            imageView.setContentHuggingPriority(.init(1), for: orientation)
        }

        textView.isEditable = false
        textView.isSelectable = true
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.drawsBackground = false
        textScroll.drawsBackground = false
        textScroll.scrollerStyle = .legacy
        textScroll.autohidesScrollers = true

        messageLabel.isSelectable = false
        messageLabel.alignment = .center
        messageLabel.textColor = .secondaryLabelColor
        messageStack.orientation = .vertical
        messageStack.spacing = 8
        messageStack.setViews([messageLabel, unlockButton], in: .center)

        spinner.style = .spinning
        spinner.controlSize = .small

        nameLabel.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        nameLabel.maximumNumberOfLines = 3
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.isSelectable = true
        detailLabel.isSelectable = false
        detailLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detailLabel.textColor = .secondaryLabelColor
        infoStack.orientation = .vertical
        infoStack.alignment = .leading
        infoStack.spacing = 4
        infoStack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 12, right: 12)
        infoStack.setViews([nameLabel, detailLabel], in: .top)

        let separator = NSBox()
        separator.boxType = .separator
        for view in [imageView, textScroll, messageStack, spinner, separator, infoStack] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        let previewBottom = separator.topAnchor
        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            imageView.bottomAnchor.constraint(equalTo: previewBottom, constant: -12),
            textScroll.topAnchor.constraint(equalTo: topAnchor),
            textScroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            textScroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            textScroll.bottomAnchor.constraint(equalTo: previewBottom),
            messageStack.centerXAnchor.constraint(equalTo: imageView.centerXAnchor),
            messageStack.centerYAnchor.constraint(equalTo: imageView.centerYAnchor),
            messageStack.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -32),
            spinner.centerXAnchor.constraint(equalTo: imageView.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: imageView.centerYAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            infoStack.topAnchor.constraint(equalTo: separator.bottomAnchor),
            infoStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            infoStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            infoStack.bottomAnchor.constraint(equalTo: bottomAnchor),
            // 预览区至少占一半高度，属性区按内容收缩
            separator.topAnchor.constraint(greaterThanOrEqualTo: centerYAnchor),
        ])
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        show(.message(String(localized: "未选择项目", bundle: .peekUI), unlock: false))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func layout() {
        super.layout()
        // 换行文本需要明确的最大宽度，否则按单行计算高度
        let width = max(bounds.width - 24, 50)
        nameLabel.preferredMaxLayoutWidth = width
        detailLabel.preferredMaxLayoutWidth = width
        messageLabel.preferredMaxLayoutWidth = max(bounds.width - 32, 50)
    }

    func show(_ preview: Preview) {
        imageView.isHidden = true
        textScroll.isHidden = true
        messageStack.isHidden = true
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        switch preview {
        case .image(let image):
            imageView.image = image
            imageView.isHidden = false
        case .text(let text, let truncated):
            textView.string = truncated ? text + String(localized: "\n\n……（仅显示开头部分）", bundle: .peekUI) : text
            textView.scrollToBeginningOfDocument(nil)
            textScroll.isHidden = false
        case .message(let message, let unlock):
            messageLabel.stringValue = message
            unlockButton.isHidden = !unlock
            messageStack.isHidden = false
        case .loading:
            spinner.isHidden = false
            spinner.startAnimation(nil)
        }
    }

    func setInfo(name: String, details: [String]) {
        nameLabel.stringValue = name
        detailLabel.stringValue = details.joined(separator: "\n")
        infoStack.isHidden = name.isEmpty && details.isEmpty
    }
}
