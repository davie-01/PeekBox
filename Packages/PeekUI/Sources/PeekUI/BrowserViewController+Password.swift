import AppKit
import PeekCore

/// 列表中间的提示区与密码输入。
/// 嵌在预览视图里的输入框收不到键盘，弹出框是独立窗口可以输入；
/// 密码只交给 ArchiveSource 保存在内存里，不写日志。
extension BrowserViewController {
    func configureMessageView(in root: NSView) {
        messageLabel.alignment = .center
        messageLabel.textColor = .secondaryLabelColor
        unlockButton.target = self
        unlockButton.action = #selector(unlockClicked(_:))
        messageView.setViews([messageLabel, unlockButton], in: .center)
        messageView.orientation = .vertical
        messageView.spacing = 12
        messageView.isHidden = true
        messageView.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(messageView)
        messageLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 420).isActive = true
    }

    public override func viewDidAppear() {
        super.viewDidAppear()
        disableHostGestures()
        // 解析很快完成时预览窗口可能还没显示，弹出框无处可挂，留到这里再弹
        if let pending = pendingPrompt {
            pendingPrompt = nil
            promptPassword(for: pending.source, message: pending.message, then: pending.then)
        }
    }

    /// 预览关闭：停止检查器尚未完成的工作并删除它的临时文件
    public override func viewDidDisappear() {
        super.viewDidDisappear()
        stopInspector()
    }

    /// Quick Look 在预览容器 QLUIServiceView 上装有点击（双击打开被预览项目）、拖动、长按手势识别器，
    /// 三者都会暂扣鼠标事件：双击识别器使每次单击延迟约 0.5 秒（日志 "Delaying event … needed:2 … too slow!"），
    /// 双击还会被宿主当作"打开被预览项目"。预览内的点击、双击、拖出均由我们的视图处理，故停用这些识别器。
    /// 窗口框架（ViewBridge）上的调整大小识别器不在 QLUIServiceView 上，不受影响
    private func disableHostGestures() {
        var owner: NSView? = view
        while let current = owner {
            if String(describing: type(of: current)).hasPrefix("QLUIServiceView") {
                for recognizer in current.gestureRecognizers where recognizer.delaysPrimaryMouseButtonEvents {
                    recognizer.delaysPrimaryMouseButtonEvents = false
                    recognizer.isEnabled = false
                }
            }
            owner = current.superview
        }
    }

    func showMessage(_ text: String, unlock archive: ArchiveSource?) {
        messageLabel.stringValue = text
        unlockTarget = archive
        messageAction = nil
        unlockButton.title = String(localized: "输入密码…", bundle: .peekUI)
        unlockButton.isHidden = archive == nil
        messageView.isHidden = false
    }

    /// 带一个操作按钮的提示（如超大压缩包的"仍然读取"）
    func showMessage(_ text: String, actionTitle: String, action: @escaping () -> Void) {
        messageLabel.stringValue = text
        unlockTarget = nil
        messageAction = action
        unlockButton.title = actionTitle
        unlockButton.isHidden = false
        messageView.isHidden = false
    }

    func hideMessage() {
        messageView.isHidden = true
        unlockTarget = nil
        messageAction = nil
    }

    @objc private func unlockClicked(_ sender: NSButton) {
        if let action = messageAction {
            action()
            return
        }
        guard let archive = unlockTarget else { return }
        promptPassword(for: archive, message: String(localized: "压缩包内容已加密，输入密码后才能查看。", bundle: .peekUI)) { [weak self] in
            self?.reload()
        }
    }

    /// anchor：由某个按钮触发时挂在该按钮上（如预览栏的"输入密码…"）；否则按选中行定位
    func promptPassword(for archive: ArchiveSource, message: String, anchor: NSView? = nil, then: @escaping () -> Void) {
        guard view.window != nil else {
            pendingPrompt = (archive, message, then)
            return
        }
        passwordPrompt?.popover.close()
        let field = NSSecureTextField()
        DialogField.style(field)
        field.placeholderString = String(localized: "密码", bundle: .peekUI)
        field.target = self
        field.action = #selector(passwordSubmitted(_:))
        let cancel = DialogButton(title: String(localized: "取消", bundle: .peekUI), target: self, action: #selector(passwordCancelled(_:)))
        cancel.keyEquivalent = "\u{1b}"
        let unlock = DialogButton(title: String(localized: "解锁", bundle: .peekUI), role: .primary,
                                  target: self, action: #selector(passwordSubmitted(_:)))
        // 回车由输入框处理，避免重复提交
        unlock.keyEquivalent = ""
        let content = DialogContentView(
            icon: NSWorkspace.shared.icon(forFile: archive.rootURL.path),
            title: String(localized: "“\(archive.rootURL.lastPathComponent)”需要密码", bundle: .peekUI),
            message: message, accessories: [field], trailingButtons: [cancel, unlock], width: 360)

        let popover = makePopover(content)
        // 整个压缩包被锁时挂在中间的"输入密码…"按钮上；由某一行触发（双击、拖出、打开等）时挂在该行上，
        // 与删除确认框一致；行不可见时退回状态栏
        if let anchor, anchor.window != nil {
            popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        } else if !messageView.isHidden, !unlockButton.isHidden {
            popover.show(relativeTo: unlockButton.bounds, of: unlockButton, preferredEdge: .minY)
        } else {
            let (anchor, rect) = anchorForPopover(nodes: selectedNodes(), fallback: statusLabel)
            popover.show(relativeTo: rect, of: anchor, preferredEdge: .maxY)
        }
        content.window?.makeFirstResponder(field)
        passwordPrompt = PasswordPrompt(popover: popover, source: archive, content: content, field: field,
                                        button: unlock, then: then)
    }

    @objc private func passwordCancelled(_ sender: Any?) {
        passwordPrompt?.popover.close()
        passwordPrompt = nil
    }

    /// 当场验证密码；错误时留在弹出框内提示重输，不保留错误密码
    @objc private func passwordSubmitted(_ sender: Any?) {
        guard let prompt = passwordPrompt, prompt.field.isEnabled, !prompt.field.stringValue.isEmpty else { return }
        let password = prompt.field.stringValue
        prompt.field.isEnabled = false
        prompt.button.isEnabled = false
        prompt.content.setNote(String(localized: "正在验证密码…", bundle: .peekUI))
        Task {
            do {
                try await prompt.source.unlock(with: password)
                prompt.popover.close()
                passwordPrompt = nil
                prompt.then()
            } catch {
                prompt.field.isEnabled = true
                prompt.button.isEnabled = true
                prompt.field.stringValue = ""
                prompt.content.setNote(Self.passwordMessage(for: error) ?? error.localizedDescription, isError: true)
                prompt.field.window?.makeFirstResponder(prompt.field)
            }
        }
    }

    func makePopover(_ content: NSView) -> NSPopover {
        let controller = NSViewController()
        controller.view = content
        let popover = NSPopover()
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.delegate = self
        return popover
    }
}

extension BrowserViewController: NSPopoverDelegate {
    /// 弹出框里的控件一律不画焦点环（见 FocusRing.swift）；所有弹出框都经 makePopover 创建，以此为代理
    public func popoverDidShow(_ notification: Notification) {
        guard let window = (notification.object as? NSPopover)?.contentViewController?.view.window else { return }
        FocusRing.suppress(in: window)
    }

    /// 弹出框关闭后把焦点还给显示中的列表 / 图标视图（选中项保持强调色，焦点不落到按钮上）
    public func popoverDidClose(_ notification: Notification) {
        view.window?.makeFirstResponder(PeekPreferences.viewMode == .icons ? collectionView : outlineView)
    }
}
