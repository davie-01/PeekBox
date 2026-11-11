import Foundation
import ServiceManagement
import os
import PeekCore

/// 后台服务的启动配置（LaunchAgent plist）在注册时由系统记下，之后不再读取包内的 plist。
/// 后台服务的位置或配置变化时（layout 递增），已注册的旧配置会指向不存在的程序，必须注销后重新注册。
enum BrokerRegistration {
    /// 2：后台服务移到 Contents/Helpers/PeekBoxBroker.app（此前为 Contents/MacOS/PeekBoxBroker）
    static let layout = 2
    private static let key = "BrokerRegistrationLayout"
    private static let log = Logger.peek("App")

    static func ensureCurrent() {
        let defaults = UserDefaults.standard
        guard defaults.integer(forKey: key) != layout else { return }
        let agent = SMAppService.agent(plistName: PeekShared.brokerAgentPlist)
        // 从未注册过的交给主页的首次引导处理
        guard agent.status != .notRegistered, agent.status != .notFound else {
            defaults.set(layout, forKey: key)
            return
        }
        do {
            try? agent.unregister()
            try agent.register()
            defaults.set(layout, forKey: key)
            log.notice("broker re-registered for layout \(layout)")
        } catch {
            log.error("broker re-register failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
