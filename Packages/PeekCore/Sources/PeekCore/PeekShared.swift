import Foundation
import os

/// 各进程共用的标识与常量。
public enum PeekShared {
    public static let teamID = "32N23TW5BT"
    public static let appGroup = "\(teamID).com.mars.PeekBox"
    public static let mainAppBundleID = "com.mars.PeekBox"
    public static let folderExtensionID = "com.mars.PeekBox.FolderPreview"
    public static let archiveExtensionID = "com.mars.PeekBox.ArchivePreview"
    public static let brokerAgentPlist = "com.mars.PeekBox.Broker.plist"

    /// Broker 的 Mach 服务名以 App Group 为前缀，沙盒扩展才能合法查找。
    public static let brokerMachService = "\(appGroup).broker"

    /// XPC 双方互相校验：必须是同一 Team 签名的进程。
    public static let teamRequirement =
        "anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\""

    public static let urlScheme = "peekbox"
}

public enum MainAppCommand: String, Sendable {
    case settings
    case checkUpdate = "check-update"

    public var url: URL { URL(string: "\(PeekShared.urlScheme)://\(rawValue)")! }
}

extension Logger {
    /// P0 期间统一用这个 category 记录探测结果：`log stream --predicate 'subsystem == "com.mars.PeekBox"'`
    public static func peek(_ category: String) -> Logger {
        Logger(subsystem: "com.mars.PeekBox", category: category)
    }
}
