import AppKit
import PeekCore

/// 开发用：`PeekBoxBroker --demo-dialog rename|folder|progress|conflict|conflict-folder [压缩包路径]`
/// 直接弹出对应面板，用于检查样式，不需要从预览中触发。
enum DialogDemo {
    @MainActor
    static func runIfRequested() {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--demo-dialog"), index + 1 < arguments.count else { return }
        let kind = arguments[index + 1]
        let archive = URL(fileURLWithPath: index + 2 < arguments.count ? arguments[index + 2] : "/tmp/示例.zip")
        NSApplication.shared.setActivationPolicy(.accessory)
        let validate: (String) -> String? = { $0.contains("/") ? ZipEditor.EditError.invalidName.localizedDescription : nil }
        switch kind {
        case "rename":
            RenamePanel.present(name: "文件 006.txt", isDirectory: false, archiveName: archive.lastPathComponent,
                                validate: validate) { _ in exit(0) }
        case "folder":
            RenamePanel.present(name: String(localized: "未命名文件夹", bundle: .app), isDirectory: true, creating: true,
                                archiveName: archive.lastPathComponent, location: "目录 00", validate: validate) { _ in exit(0) }
        case "progress", "conflict", "conflict-folder":
            let panel = ArchiveWritePanel(archive: archive)
            if kind != "progress" {
                DispatchQueue.global().async {
                    _ = panel.resolve(ZipEditor.ImportConflict(path: kind == "conflict" ? "文件 001.txt" : "资料",
                                                               incomingIsDirectory: kind != "conflict",
                                                               existingIsDirectory: kind != "conflict",
                                                               remainingConflicts: 2))
                    exit(0)
                }
            }
        default:
            return
        }
        NSApplication.shared.run()
    }
}
