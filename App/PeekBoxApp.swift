import AppKit
import SwiftUI
import PeekCore

@main
struct PeekBoxApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = SettingsModel()

    var body: some Scene {
        // 用 WindowGroup 而不是 Window：由预览的 peekbox:// 链接拉起时，若上次退出时没有打开的窗口，
        // Window 场景不会创建默认窗口（Dock 有图标却没有设置窗口）。WindowGroup 处理外部链接时，
        // 有窗口就交给现有窗口，没有就新建一个
        WindowGroup("PeekBox", id: "main") {
            SettingsView(model: model)
                .onOpenURL { model.handle($0) }
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
        }
        .handlesExternalEvents(matching: ["*"])
        .windowResizability(.contentSize)
        .commands {
            // 设置只需要一个窗口
            CommandGroup(replacing: .newItem) {}
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        BrokerRegistration.ensureCurrent()
        // install.sh 安装后以此参数调用一次，只刷新后台服务登记，不显示界面
        if CommandLine.arguments.contains("--refresh-broker") { exit(0) }
    }

    /// 原生形态约束：最后一个窗口关闭即退出，不在 Dock 常驻。
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
