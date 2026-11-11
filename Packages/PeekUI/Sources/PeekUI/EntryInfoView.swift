import AppKit
import PeekCore

/// "显示简介"弹出框内容：顶部图标、名称与"种类 · 大小"，分隔线下为两列详细信息（标签右对齐、内容可换行可选中）。
/// 多选时显示数量与合计大小。
@MainActor
enum EntryInfoView {
    private static let width: CGFloat = 340
    private static let labelWidth: CGFloat = 76
    private static let padding: CGFloat = 20
    private static var valueWidth: CGFloat { width - padding * 2 - labelWidth - 12 }

    static func make(for entries: [Entry], icon: (Entry) -> NSImage, reader: (any ArchiveReader)?) -> NSView {
        guard entries.count == 1, let entry = entries.first else { return summary(entries) }

        let kind = entry.kind ?? (entry.isDirectory ? String(localized: "文件夹", bundle: .peekUI) : String(localized: "未知", bundle: .peekUI))
        let subtitle = entry.size.map { kind + " · " + Localization.fileSize($0) } ?? kind

        var rows: [(String, String)] = [
            (String(localized: "修改日期", bundle: .peekUI), entry.modified?.formatted(BrowserViewController.dateFormat) ?? String(localized: "日期未知", bundle: .peekUI)),
        ]
        if let url = entry.fileURL {
            rows.append((String(localized: "位置", bundle: .peekUI), url.deletingLastPathComponent().path))
        } else if let archive = entry.archiveURL {
            let path = ArchiveSource.archivePath(of: entry)
            rows.append((String(localized: "所在压缩包", bundle: .peekUI), archive.lastPathComponent))
            rows.append((String(localized: "归档内路径", bundle: .peekUI), path))
            if entry.isDirectory, let reader {
                let files = reader.tree.descendantFiles(of: path)
                let total = files.compactMap(\.size).saturatingSum
                rows.append((String(localized: "包含", bundle: .peekUI), String(localized: "\(files.count) 个文件，\(Localization.fileSize(total))", bundle: .peekUI)))
            }
            if entry.isEncrypted { rows.append((String(localized: "加密", bundle: .peekUI), String(localized: "🔒 已加密", bundle: .peekUI))) }
        }
        return layout(icon: icon(entry), title: entry.name, subtitle: subtitle, rows: rows)
    }

    private static func summary(_ entries: [Entry]) -> NSView {
        let total = entries.compactMap(\.size).saturatingSum
        let folders = entries.filter(\.isDirectory).count
        var rows = [(String(localized: "文件合计", bundle: .peekUI), Localization.fileSize(total))]
        if folders > 0 {
            rows.append((String(localized: "文件夹", bundle: .peekUI), String(localized: "\(folders) 个（大小未统计）", bundle: .peekUI)))
        }
        return layout(icon: NSImage(named: NSImage.multipleDocumentsName), title: String(localized: "\(entries.count) 个项目", bundle: .peekUI),
                      subtitle: nil, rows: rows)
    }

    private static func layout(icon: NSImage?, title: String, subtitle: String?, rows: [(String, String)]) -> NSView {
        let image = NSImageView()
        image.image = icon
        image.imageScaling = .scaleProportionallyUpOrDown
        image.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            image.widthAnchor.constraint(equalToConstant: 56),
            image.heightAnchor.constraint(equalToConstant: 56),
        ])
        let titleWidth = width - padding * 2 - 56 - 14
        let name = wrapping(title, width: titleWidth)
        name.font = .systemFont(ofSize: NSFont.systemFontSize + 1, weight: .semibold)
        name.maximumNumberOfLines = 3
        name.lineBreakMode = .byTruncatingMiddle
        var titleViews: [NSView] = [name]
        if let subtitle {
            let detail = wrapping(subtitle, width: titleWidth)
            detail.font = .systemFont(ofSize: NSFont.smallSystemFontSize + 1)
            detail.textColor = .secondaryLabelColor
            titleViews.append(detail)
        }
        let titles = NSStackView(views: titleViews)
        titles.orientation = .vertical
        titles.alignment = .leading
        titles.spacing = 3
        let header = NSStackView(views: [image, titles])
        header.alignment = .centerY
        header.spacing = 14

        let separator = NSBox()
        separator.boxType = .separator

        let grid = NSGridView(views: rows.map { label, value in
            let key = NSTextField(labelWithString: label)
            key.font = .systemFont(ofSize: NSFont.smallSystemFontSize + 1)
            key.textColor = .secondaryLabelColor
            key.alignment = .right
            let text = wrapping(value, width: valueWidth)
            text.font = .systemFont(ofSize: NSFont.smallSystemFontSize + 1)
            text.isSelectable = true
            return [key, text]
        })
        grid.columnSpacing = 12
        grid.rowSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 0).width = labelWidth
        grid.column(at: 1).width = valueWidth
        for row in 0..<grid.numberOfRows { grid.row(at: row).yPlacement = .top }

        let stack = NSStackView(views: [header, separator] + (rows.isEmpty ? [] : [grid]))
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: padding, left: padding, bottom: padding, right: padding)
        separator.widthAnchor.constraint(equalToConstant: width - padding * 2).isActive = true
        stack.widthAnchor.constraint(equalToConstant: width).isActive = true
        return stack
    }

    /// 换行文本必须给出首选宽度，否则在网格 / 栈视图中会被压成零宽
    private static func wrapping(_ text: String, width: CGFloat) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.preferredMaxLayoutWidth = width
        field.isSelectable = false
        field.setContentCompressionResistancePriority(.required, for: .horizontal)
        return field
    }
}
