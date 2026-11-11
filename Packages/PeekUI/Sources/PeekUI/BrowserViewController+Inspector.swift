import AppKit
import QuickLookThumbnailing
import os
import UniformTypeIdentifiers
import PeekCore

/// 分栏模式右侧的检查器：显示单个选中项的预览与属性。
/// 选择变化后稍作延迟再加载，快速连续点选时只加载最后一项；晚到的结果按 inspectorGeneration 丢弃。
extension BrowserViewController: NSSplitViewDelegate {
    static let inspectorMinWidth: CGFloat = 200
    static let listMinWidth: CGFloat = 260

    func configureInspector() {
        inspectorView.unlockButton.target = self
        inspectorView.unlockButton.action = #selector(unlockForInspector(_:))
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.delegate = self
        InspectorLoader.purgeStale()
    }

    /// 预览关闭时停止检查器的工作并删除临时文件
    func stopInspector() {
        inspectorGeneration += 1
        inspectorWorker.supersede(with: inspectorGeneration)
        cancelInspectorThumbnail()
        removeInspectorTemp()
    }

    /// 检查器只在分栏模式下加入分栏视图。仅隐藏子视图时 NSSplitView 不会把左侧拉回全宽，分隔线会留在原处
    func setInspectorVisible(_ visible: Bool) {
        let shown = inspectorView.superview === splitView
        guard shown != visible else { return }
        if visible {
            splitView.addArrangedSubview(inspectorView)
            // 窗口变宽变窄时由列表吸收，检查器保持宽度
            splitView.setHoldingPriority(.defaultLow, forSubviewAt: 0)
            splitView.setHoldingPriority(.defaultLow + 10, forSubviewAt: 1)
            splitView.adjustSubviews()
            let width = splitView.bounds.width
            if width > 0 {
                splitView.setPosition(width - inspectorWidth - splitView.dividerThickness, ofDividerAt: 0)
            }
        } else {
            splitView.removeArrangedSubview(inspectorView)
            inspectorView.removeFromSuperview()
            splitView.adjustSubviews()
            stopInspector()
        }
    }

    func updateInspector() {
        guard PeekPreferences.viewMode == .columns else { return }
        inspectorGeneration += 1
        let generation = inspectorGeneration
        let nodes = selectedNodes()
        guard nodes.count == 1, let entry = nodes.first?.entry else {
            removeInspectorTemp()
            showSummary(of: nodes)
            return
        }
        inspectorView.setInfo(name: entry.name, details: details(of: entry, pixelSize: nil))
        inspectorView.show(.loading)
        inspectorWorker.supersede(with: generation)
        cancelInspectorThumbnail()
        Task {
            // 连续点选时只加载停下来的那一项
            try? await Task.sleep(for: .milliseconds(120))
            guard generation == inspectorGeneration else { return }
            await loadInspector(entry, generation: generation)
        }
    }

    private func showSummary(of nodes: [BrowserNode]) {
        if nodes.isEmpty {
            inspectorView.setInfo(name: "", details: [])
            inspectorView.show(.message(String(localized: "未选择项目", bundle: .peekUI), unlock: false))
            return
        }
        let total = nodes.compactMap(\.entry.size).saturatingSum
        inspectorView.setInfo(name: String(localized: "已选 \(nodes.count) 项", bundle: .peekUI),
                              details: [Localization.fileSize(total)])
        inspectorView.show(.image(stackIcon(for: nodes)))
    }

    private func loadInspector(_ entry: Entry, generation: Int) async {
        removeInspectorTemp()
        let kind = entry.isDirectory ? .other : InspectorLoader.kind(ofName: entry.name)
        if entry.isDirectory || entry.isArchive {
            inspectorView.show(.image(largeIcon(for: entry)))
            return
        }
        if let url = entry.fileURL {
            guard let content = await inspectorWorker.run(generation: generation, { InspectorLoader.load(url, kind: kind) }),
                  generation == inspectorGeneration else { return }
            present(content, for: entry, fallbackURL: url, generation: generation)
            return
        }
        await loadArchived(entry, kind: kind, generation: generation)
    }

    /// 压缩包内条目：只为图片和文本提取（限大小）；加密且未解锁时先请求密码
    private func loadArchived(_ entry: Entry, kind: InspectorLoader.Kind, generation: Int) async {
        guard kind != .other else {
            inspectorView.show(.image(largeIcon(for: entry)))
            return
        }
        guard let archiveURL = entry.archiveURL, let archive = source?.archiveSource(for: archiveURL),
              let reader = archive.loadedReader,
              let item = reader.tree.items[ArchiveSource.archivePath(of: entry)] else {
            inspectorView.show(.image(largeIcon(for: entry)))
            return
        }
        if (item.size ?? 0) > InspectorLoader.extractLimit {
            inspectorView.show(.message(String(localized: "文件较大，不在此预览", bundle: .peekUI), unlock: false))
            return
        }
        if item.isEncrypted, archive.password == nil {
            inspectorUnlockTarget = archive
            inspectorView.show(.message(String(localized: "加密条目，输入密码后预览", bundle: .peekUI), unlock: true))
            return
        }
        let password = archive.password
        guard let result = await inspectorWorker.run(generation: generation, { () -> Result<(URL, InspectorLoader.Content), Error> in
            Result {
                let url = try InspectorLoader.extract(item, from: reader, password: password)
                return (url, InspectorLoader.load(url, kind: kind))
            }
        }) else { return }
        guard generation == inspectorGeneration else {
            if case .success(let (url, _)) = result { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            return
        }
        switch result {
        case .success(let (url, content)):
            inspectorTemp = url.deletingLastPathComponent()
            present(content, for: entry, fallbackURL: nil, generation: generation)
        case .failure(let error):
            if Self.passwordMessage(for: error) != nil {
                inspectorUnlockTarget = archive
                inspectorView.show(.message(String(localized: "密码不正确，请重新输入", bundle: .peekUI), unlock: true))
            } else {
                inspectorView.show(.message(String(localized: "无法预览：\(error.localizedDescription)", bundle: .peekUI), unlock: false))
            }
        }
    }

    private func present(_ content: InspectorLoader.Content, for entry: Entry, fallbackURL: URL?, generation: Int) {
        switch content {
        case .image(let image, let pixelSize):
            inspectorView.show(.image(NSImage(cgImage: image, size: .zero)))
            inspectorView.setInfo(name: entry.name, details: details(of: entry, pixelSize: pixelSize))
        case .text(let text, let truncated):
            inspectorView.show(.text(text, truncated: truncated))
        case .none:
            inspectorView.show(.image(largeIcon(for: entry)))
            // 其他类型的真实文件：用系统缩略图（PDF、视频、文稿等）
            if let url = fallbackURL { requestInspectorThumbnail(url, generation: generation) }
        }
    }

    private func requestInspectorThumbnail(_ url: URL, generation: Int) {
        let scale = view.window?.backingScaleFactor ?? 2
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 512, height: 512),
                                                   scale: scale, representationTypes: .thumbnail)
        inspectorThumbnailRequest = request
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] thumbnail, error in
            guard let image = thumbnail?.nsImage else {
                if let error { Logger.peek("Browser").error("inspector thumbnail failed: \(error.localizedDescription, privacy: .public)") }
                return
            }
            Task { @MainActor in
                guard let self, generation == self.inspectorGeneration else { return }
                self.inspectorView.show(.image(image))
            }
        }
    }

    /// 换项或关闭检查器时取消尚未完成的系统缩略图请求
    func cancelInspectorThumbnail() {
        guard let request = inspectorThumbnailRequest else { return }
        inspectorThumbnailRequest = nil
        QLThumbnailGenerator.shared.cancel(request)
    }

    @objc private func unlockForInspector(_ sender: Any?) {
        guard let archive = inspectorUnlockTarget else { return }
        promptPassword(for: archive, message: String(localized: "此项目已加密，输入密码后即可预览。", bundle: .peekUI),
                       anchor: inspectorView.unlockButton) { [weak self] in
            self?.updateStatus()
            self?.updateInspector()
        }
    }

    private func details(of entry: Entry, pixelSize: CGSize?) -> [String] {
        var lines: [String] = []
        let kind = entry.kind ?? (entry.isDirectory ? String(localized: "文件夹", bundle: .peekUI) : "")
        if !kind.isEmpty { lines.append(entry.isEncrypted ? "🔒 " + kind : kind) }
        if let size = entry.size { lines.append(Localization.fileSize(size)) }
        if let pixelSize { lines.append(String(localized: "\(Int(pixelSize.width)) × \(Int(pixelSize.height)) 像素", bundle: .peekUI)) }
        if let modified = entry.modified { lines.append(String(localized: "修改于 \(modified.formatted(Self.dateFormat))", bundle: .peekUI)) }
        return lines
    }

    private func largeIcon(for entry: Entry) -> NSImage {
        let image = icon(for: entry)
        image.size = NSSize(width: 128, height: 128)
        return image
    }

    private func stackIcon(for nodes: [BrowserNode]) -> NSImage {
        let image = NSImage(systemSymbolName: "square.stack.3d.up", accessibilityDescription: nil) ?? NSImage()
        return image.withSymbolConfiguration(.init(pointSize: 64, weight: .light)) ?? image
    }

    func removeInspectorTemp() {
        guard let temp = inspectorTemp else { return }
        inspectorTemp = nil
        try? FileManager.default.removeItem(at: temp)
    }

    // MARK: - NSSplitViewDelegate

    public func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat,
                          ofSubviewAt dividerIndex: Int) -> CGFloat {
        Self.listMinWidth
    }

    public func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat,
                          ofSubviewAt dividerIndex: Int) -> CGFloat {
        splitView.bounds.width - Self.inspectorMinWidth
    }

    public func splitViewDidResizeSubviews(_ notification: Notification) {
        guard inspectorView.superview === splitView, inspectorView.frame.width >= Self.inspectorMinWidth else { return }
        inspectorWidth = inspectorView.frame.width
    }
}
