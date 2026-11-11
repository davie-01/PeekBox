import Foundation
import os

/// 共享设置文件：App Group 容器中的一个 plist，扩展、主应用、Broker 共用。
///
/// 不用 `UserDefaults(suiteName:)`：免费团队、无描述文件时，cfprefsd 拒绝沙盒扩展写入
/// （日志 "Couldn't write values for keys … Domain: <App Group>"），设置只留在进程内存里。
/// 沙盒扩展对容器也只有读权限（实测"没有保存权限"），写入失败时交给 Broker 代写，本进程先以内存值生效。
public final class SettingsStore: @unchecked Sendable {
    static let shared = SettingsStore()

    private let lock = NSLock()
    private let url: URL?
    private let log = Logger.peek("Settings")
    private var values: [String: Any] = [:]
    /// 已在本进程生效、但 Broker 尚未确认写入文件的值；确认后移除，此后以文件为准
    private var pending: [String: Any] = [:]
    /// 已加载文件的修改时间与文件编号（原子写入会换成新文件，编号随之变化）
    private var loadedStamp: [FileAttributeKey: AnyHashable]?
    private var lastCheck = Date.distantPast
    /// 单元格绘制时会频繁读取，限制检查文件变化的频率
    var checkInterval: TimeInterval = 1

    init(url: URL? = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: PeekShared.appGroup)?
            .appendingPathComponent("Library/Application Support/PeekBox/settings.plist")) {
        self.url = url
    }

    func value(forKey key: String) -> Any? {
        lock.withLock {
            reloadIfChanged()
            return values[key]
        }
    }

    func set(_ value: Any, forKey key: String) {
        lock.withLock {
            withFileLock {
                reloadIfChanged(force: true, ignoreStamp: true)
                values[key] = value
                if !write() {
                    pending[key] = value
                    Self.forwardToBroker(key: key, value: value)
                }
            }
        }
    }

    /// 跨进程写入互斥。NSLock 只保护本进程：主应用与 Broker 各自"重读 → 改一个键 → 整份写回"，
    /// 两边的重读与写回交叠时，后写的会覆盖掉对方刚写的键。写入方在同目录的锁文件上 flock，
    /// 锁内重读、修改、原子写回。沙盒扩展对容器只读、写入改由 Broker 代办，拿不到锁时直接执行
    private func withFileLock<T>(_ body: () -> T) -> T {
        guard let url else { return body() }
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let descriptor = open(directory.appendingPathComponent("settings.lock").path, O_RDWR | O_CREAT, 0o644)
        guard descriptor >= 0 else { return body() }
        // 关闭描述符即释放锁
        defer { close(descriptor) }
        flock(descriptor, LOCK_EX)
        return body()
    }

    /// ignoreStamp：写入前在文件锁内无条件重读，不依赖修改时间与文件编号判断
    private func reloadIfChanged(force: Bool = false, ignoreStamp: Bool = false) {
        guard let url else { return }
        let now = Date()
        guard force || now.timeIntervalSince(lastCheck) >= checkInterval else { return }
        lastCheck = now
        let stamp = Self.stamp(of: url)
        guard ignoreStamp || stamp != loadedStamp else { return }
        loadedStamp = stamp
        guard let data = try? Data(contentsOf: url),
              var dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return
        }
        for (key, value) in pending {
            dict[key] = value
        }
        values = dict
    }

    /// 不用 URL.resourceValues：同一 URL 实例会缓存结果，读不到其他进程的新写入
    private static func stamp(of url: URL) -> [FileAttributeKey: AnyHashable]? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        var stamp: [FileAttributeKey: AnyHashable] = [:]
        stamp[.modificationDate] = attributes[.modificationDate] as? Date
        stamp[.systemFileNumber] = attributes[.systemFileNumber] as? Int
        return stamp
    }

    /// 返回是否写入成功
    @discardableResult
    private func write() -> Bool {
        guard let url else {
            log.error("App Group container unavailable")
            return false
        }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0)
            try data.write(to: url, options: .atomic)
            loadedStamp = Self.stamp(of: url)
            return true
        } catch {
            log.notice("write settings locally failed, forwarding to broker: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Broker 收到后调用 merge(_:) 写入文件
    private static func forwardToBroker(key: String, value: Any) {
        guard let data = try? PropertyListSerialization.data(fromPropertyList: [key: value], format: .binary, options: 0) else {
            return
        }
        Task.detached {
            do {
                try await BrokerClient.shared.setSettings(data)
                shared.confirm(key: key, encoded: data)
            } catch {
                Logger.peek("Settings").error("broker write failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Broker 已写入：清除待确认值并立即重读文件。之后其他进程的修改照常生效（最后修改者为准）。
    /// 若在等待期间本进程又改了同一项，保留较新的待确认值
    private func confirm(key: String, encoded: Data) {
        let written = (try? PropertyListSerialization.propertyList(from: encoded, format: nil) as? [String: Any])?[key]
        lock.withLock {
            if let current = pending[key] as AnyObject?, let written, current.isEqual(written) {
                pending[key] = nil
            }
            reloadIfChanged(force: true)
        }
    }

    /// 合并一组设置并写入文件（Broker 端调用）
    func merge(_ data: Data) -> Bool {
        guard let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return false
        }
        return lock.withLock {
            withFileLock {
                reloadIfChanged(force: true, ignoreStamp: true)
                values.merge(dict) { _, new in new }
                return write()
            }
        }
    }

    /// 供 Broker 写入时使用
    public static func mergeSettings(_ data: Data) -> Bool {
        shared.merge(data)
    }
}
