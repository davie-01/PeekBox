import AppKit
import UniformTypeIdentifiers
import PeekCore
import PeekUI

/// 写入进度与同名冲突面板。与重命名面板一样保持 Finder 为前台；进度和冲突均属于 Broker，预览关闭不终止任务。
/// 写入很快完成时（250 ms 内）不显示。
///
/// 进度与冲突分用两个面板：后台服务的面板取得键盘焦点后，预览窗口失去焦点，而点击预览内容区（由预览扩展进程绘制）
/// 不会让它重新取得焦点，只能点标题栏。进度面板永不取得焦点，写入期间可以继续浏览；冲突必须当场处理，
/// 对话框取得焦点（回车替换、Esc 取消），处理完收起，焦点随之交还预览窗口
@MainActor
final class ArchiveWritePanel: NSObject, NSWindowDelegate {
    let control = ZipWriteControl()
    private let progressPanel = DialogPanel.make(canBecomeKey: false)
    private let conflictPanel = DialogPanel.make()
    private let archive: URL
    /// 拷到真实文件夹（见 ArchiveCopier）时为目标文件夹；写入压缩包时为 nil
    private let copyDestination: URL?
    private var completed = false
    private var answer: ((ZipEditor.ConflictDecision) -> Void)?
    /// 等待冲突选择期间进度循环挂起在这里，不再定时唤醒
    private var progressPause: CheckedContinuation<Void, Never>?
    private var showingConflict = false

    // 进度
    private var progressContent: DialogContentView!
    private let progress = NSProgressIndicator()
    private let percent = NSTextField(labelWithString: "")
    private var cancelButton: DialogButton!

    // 冲突
    private let applyAll = PanelButton(checkboxWithTitle: "", target: nil, action: nil)

    init(archive: URL, copyDestination: URL? = nil) {
        self.archive = archive
        self.copyDestination = copyDestination
        super.init()
        progressPanel.delegate = self
        conflictPanel.delegate = self

        progress.minValue = 0
        progress.maxValue = 1
        progress.isIndeterminate = false
        progress.style = .bar
        progress.controlSize = .regular
        percent.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize + 1, weight: .regular)
        percent.textColor = .secondaryLabelColor
        percent.alignment = .right
        percent.widthAnchor.constraint(equalToConstant: 40).isActive = true
        let progressRow = NSStackView(views: [progress, percent])
        progressRow.spacing = 10
        cancelButton = DialogButton(title: String(localized: "取消", bundle: .app), drawsBackground: true,
                                    target: self, action: #selector(cancelClicked))
        if let copyDestination {
            let folder = FileManager.default.displayName(atPath: copyDestination.path)
            progressContent = DialogContentView(
                icon: NSWorkspace.shared.icon(forFile: copyDestination.path),
                title: String(localized: "正在拷贝到“\(folder)”", bundle: .app),
                message: String(localized: "从“\(archive.lastPathComponent)”中提取。", bundle: .app),
                accessories: [progressRow], trailingButtons: [cancelButton])
        } else {
            progressContent = DialogContentView(
                icon: NSWorkspace.shared.icon(forFile: archive.path),
                title: String(localized: "正在写入“\(archive.lastPathComponent)”", bundle: .app),
                message: String(localized: "完成前请不要移动或修改这个压缩包。", bundle: .app),
                accessories: [progressRow], trailingButtons: [cancelButton])
        }
        progressPanel.contentView = progressContent
        applyAll.focusRingType = .none

        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self, !self.completed else { return }
            // 期间已弹出冲突时，处理完再显示进度（见 choose）
            if !self.showingConflict { self.present(self.progressPanel, replacing: self.conflictPanel) }
            // 每 0.2 秒检查一次，百分比变化时才更新界面；等待冲突选择时挂起
            var shownPercent = -1
            while !self.completed {
                if self.showingConflict {
                    await withCheckedContinuation { self.progressPause = $0 }
                    continue
                }
                // 各阶段均按实际工作量换算（见 ZipWriteControl）
                let fraction = self.control.fractionCompleted
                let value = Int(fraction * 100)
                if value != shownPercent {
                    shownPercent = value
                    self.progress.doubleValue = fraction
                    self.percent.stringValue = fraction.formatted(.percent.precision(.fractionLength(0)))
                    if fraction >= 0.98, self.cancelButton.isEnabled { self.cancelButton.isEnabled = false }
                }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    /// 只由写入队列调用，不在主线程阻塞等待用户。
    nonisolated func resolve(_ conflict: ZipEditor.ImportConflict) -> ZipEditor.ConflictDecision {
        let response = ConflictResponse()
        Task { @MainActor in
            guard !self.completed, !self.control.isCancelled else { response.finish(.init(.cancel)); return }
            self.answer = { response.finish($0) }
            self.showConflict(conflict)
        }
        return response.wait()
    }

    func finish() {
        completed = true
        resumeProgress()
        answer?(.init(.cancel))
        answer = nil
        progressPanel.delegate = nil
        conflictPanel.delegate = nil
        progressPanel.orderOut(nil)
        conflictPanel.orderOut(nil)
    }

    private func resumeProgress() {
        showingConflict = false
        progressPause?.resume()
        progressPause = nil
    }

    private func showConflict(_ conflict: ZipEditor.ImportConflict) {
        showingConflict = true
        let name = (conflict.path as NSString).lastPathComponent
        let directory = conflict.incomingIsDirectory || conflict.existingIsDirectory
        let message: String
        if let copyDestination {
            let folder = FileManager.default.displayName(atPath: copyDestination.path)
            message = String(localized: "“\(folder)”中已有同名项目。替换会把原有的“\(name)”移到废纸篓。", bundle: .app)
        } else {
            message = directory
                ? String(localized: "压缩包中已有同名项目。替换会移除原有的“\(name)”及其全部内容。", bundle: .app)
                : String(localized: "压缩包中已有同名项目。要用拖入的项目替换它吗？", bundle: .app)
        }
        let ext = (name as NSString).pathExtension
        let type = conflict.incomingIsDirectory
            ? (ArchiveSource.isPackageName(name) ? UTType(filenameExtension: ext, conformingTo: .directory) : nil) ?? .folder
            : UTType(filenameExtension: ext) ?? .data

        // 只有后面还有同名项目时，"同样处理"才有意义
        var accessories: [NSView] = []
        if conflict.remainingConflicts > 0 {
            applyAll.title = String(localized: "后面还有 \(conflict.remainingConflicts) 个同名项目，也这样处理", bundle: .app)
            applyAll.state = .off
            accessories.append(applyAll)
        }
        let cancel = DialogButton(title: String(localized: "取消", bundle: .app), target: self, action: #selector(cancelClicked))
        cancel.keyEquivalent = "\u{1b}"
        let skip = DialogButton(title: String(localized: "跳过", bundle: .app), target: self, action: #selector(choose(_:)))
        let keepBoth = DialogButton(title: String(localized: "保留两者", bundle: .app), target: self, action: #selector(choose(_:)))
        let replace = DialogButton(title: String(localized: "替换", bundle: .app), role: .primary, target: self, action: #selector(choose(_:)))
        replace.tag = 0
        skip.tag = 1
        keepBoth.tag = 2
        conflictPanel.contentView = DialogContentView(
            icon: NSWorkspace.shared.icon(for: type),
            title: String(localized: "“\(name)”已存在", bundle: .app), message: message,
            accessories: accessories, leadingButtons: [cancel], trailingButtons: [skip, keepBoth, replace], width: 460)
        present(conflictPanel, replacing: progressPanel)
    }

    /// 在另一个面板的位置（顶边、水平中线对齐）显示，先显示新的再收起旧的，切换时不闪；另一个面板未显示时放到默认位置
    private func present(_ target: NSPanel, replacing other: NSPanel) {
        if other.isVisible, let content = target.contentView {
            target.setContentSize(content.fittingSize)
            target.setFrameTopLeftPoint(NSPoint(x: other.frame.midX - target.frame.width / 2, y: other.frame.maxY))
        } else if !target.isVisible {
            DialogPanel.place(target)
        }
        if target.canBecomeKey {
            target.makeKeyAndOrderFront(nil)
        } else {
            target.orderFrontRegardless()
        }
        other.orderOut(nil)
    }

    @objc private func choose(_ sender: NSButton) {
        let actions: [ZipEditor.ConflictAction] = [.replace, .skip, .keepBoth]
        let pending = answer
        answer = nil
        let decision = ZipEditor.ConflictDecision(actions[sender.tag], applyToAll: applyAll.state == .on)
        present(progressPanel, replacing: conflictPanel)
        resumeProgress()
        pending?(decision)
    }

    @objc private func cancelClicked() {
        control.cancel()
        answer?(.init(.cancel))
        answer = nil
        cancelButton.isEnabled = false
        progressContent.setNote(String(localized: "正在取消…", bundle: .app))
        if conflictPanel.isVisible { present(progressPanel, replacing: conflictPanel) }
        resumeProgress()
    }

    func windowWillClose(_ notification: Notification) { cancelClicked() }
}

private final class ConflictResponse: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var decision = ZipEditor.ConflictDecision(.cancel)
    func finish(_ decision: ZipEditor.ConflictDecision) {
        lock.withLock { self.decision = decision }
        semaphore.signal()
    }
    func wait() -> ZipEditor.ConflictDecision {
        semaphore.wait()
        return lock.withLock { decision }
    }
}
