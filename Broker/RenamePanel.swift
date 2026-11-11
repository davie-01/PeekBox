import AppKit
import UniformTypeIdentifiers
import PeekCore
import PeekUI

/// 重命名 / 新建文件夹的输入面板。Quick Look 预览收不到键盘输入，由后台服务弹出。
/// 不激活应用的浮动面板：Finder 仍是前台应用，预览窗口不会因失去焦点而关闭；面板本身可以接收键盘输入。
@MainActor
final class RenamePanel: NSObject, NSTextFieldDelegate, NSWindowDelegate {
    /// 显示期间保持自身存活
    private static var current: RenamePanel?

    private let panel = DialogPanel.make()
    private let field = NSTextField()
    private let confirmButton: DialogButton
    private var content: DialogContentView!
    private let originalName: String
    private let creating: Bool
    private let validate: (String) -> String?
    private var completion: ((String?) -> Void)?

    /// creating 为新建文件夹（name 为建议名称，location 为所在目录名，根目录为 nil）；
    /// validate 返回错误提示（nil 表示可用）；completion 收到名称，取消时为 nil
    static func present(name: String, isDirectory: Bool, creating: Bool = false, archiveName: String,
                        location: String? = nil, validate: @escaping (String) -> String?,
                        completion: @escaping (String?) -> Void) {
        current?.finish(nil)
        let instance = RenamePanel(name: name, isDirectory: isDirectory, creating: creating, archiveName: archiveName,
                                   location: location, validate: validate, completion: completion)
        current = instance
        instance.show(isDirectory: isDirectory)
    }

    private init(name: String, isDirectory: Bool, creating: Bool, archiveName: String, location: String?,
                 validate: @escaping (String) -> String?, completion: @escaping (String?) -> Void) {
        originalName = name
        self.creating = creating
        self.validate = validate
        self.completion = completion
        confirmButton = DialogButton(title: creating ? String(localized: "新建", bundle: .app) : String(localized: "重命名", bundle: .app),
                                     role: .primary, target: nil, action: nil)
        super.init()

        let title: String
        let message: String
        if creating {
            title = String(localized: "新建文件夹", bundle: .app)
            message = location.map { String(localized: "将在“\(archiveName)”的“\($0)”中新建。", bundle: .app) }
                ?? String(localized: "将在“\(archiveName)”中新建。", bundle: .app)
        } else {
            title = String(localized: "重命名“\(name)”", bundle: .app)
            message = String(localized: "修改会直接保存到“\(archiveName)”中。", bundle: .app)
        }
        let type = isDirectory ? UTType.folder : UTType(filenameExtension: (name as NSString).pathExtension) ?? .data
        DialogField.style(field)
        field.stringValue = name
        field.delegate = self
        confirmButton.target = self
        confirmButton.action = #selector(confirmClicked)
        let cancel = DialogButton(title: String(localized: "取消", bundle: .app), target: self, action: #selector(cancelClicked))
        cancel.keyEquivalent = "\u{1b}"
        content = DialogContentView(icon: NSWorkspace.shared.icon(for: type), title: title, message: message,
                                    accessories: [field], trailingButtons: [cancel, confirmButton])
        panel.contentView = content
        panel.delegate = self
        updateState()
    }

    private func show(isDirectory: Bool) {
        DialogPanel.place(panel)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
        // 与 Finder 一致：文件只选中扩展名之前的部分
        let stem = isDirectory ? originalName : (originalName as NSString).deletingPathExtension
        field.currentEditor()?.selectedRange = NSRange(location: 0, length: (stem as NSString).length)
    }

    func controlTextDidChange(_ notification: Notification) {
        updateState()
    }

    private func updateState() {
        let name = field.stringValue
        let unchanged = !creating && name == originalName
        let error = unchanged ? nil : validate(name)
        content.setNote(error, isError: true)
        confirmButton.isEnabled = error == nil && !unchanged
            && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        panel.setContentSize(content.fittingSize)
    }

    @objc private func confirmClicked() {
        guard confirmButton.isEnabled else { return }
        finish(field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    @objc private func cancelClicked() {
        finish(nil)
    }

    func windowWillClose(_ notification: Notification) {
        finish(nil)
    }

    private func finish(_ name: String?) {
        guard let completion else { return }
        self.completion = nil
        panel.delegate = nil
        panel.orderOut(nil)
        completion(name)
        if Self.current === self { Self.current = nil }
    }
}
