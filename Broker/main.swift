import AppKit
import os
import PeekCore
import PeekUI

extension Bundle {
    /// 外层主应用 PeekBox.app（后台服务位于其 Contents/Helpers/PeekBoxBroker.app）
    static let mainApp: Bundle = {
        let url = Bundle.main.bundleURL          // …/PeekBox.app/Contents/Helpers/PeekBoxBroker.app
            .deletingLastPathComponent()        // Helpers
            .deletingLastPathComponent()        // Contents
            .deletingLastPathComponent()        // PeekBox.app
        return url.pathExtension == "app" ? Bundle(url: url) ?? .main : .main
    }()

    /// 后台服务与主应用共用主应用的文案表，按界面语言设置选择
    static var app: Bundle { Localization.bundle(.mainApp) }
}

/// 按需启动的 LaunchAgent：launchd 在扩展连接 Mach 服务时拉起，空闲后自行退出。
final class Broker: NSObject, NSXPCListenerDelegate, PeekBrokerProtocol, @unchecked Sendable {
    private static let idleTimeout: TimeInterval = 30

    private let log = Logger.peek("Broker")
    private let queue = DispatchQueue(label: "com.mars.PeekBox.Broker.state")
    private var activeConnections = 0
    /// 进行中的任务数；预览关闭导致连接断开后，任务仍要做完，期间不能空闲退出
    private var activeWork = 0
    private var idleTimer: DispatchSourceTimer?
    /// 读取器与已提取文件的复用（见 MaterializeCache）
    private let materializeCache = MaterializeCache()
    /// 压缩包写入串行执行：同一时间只有一个写事务
    /// 每个压缩包一个串行写队列：同一个包的写事务严格排队；不同的包互不阻塞
    /// （原先全局只有一个队列，某个包等待用户选择冲突处理方式时，其他包的写入也只能干等）
    private var writeQueues: [String: DispatchQueue] = [:]
    private let writeQueuesLock = NSLock()

    private func writeQueue(for archive: URL) -> DispatchQueue {
        let key = archive.standardizedFileURL.resolvingSymlinksInPath().path
        return writeQueuesLock.withLock {
            if let queue = writeQueues[key] { return queue }
            let queue = DispatchQueue(label: "com.mars.PeekBox.Broker.write", qos: .userInitiated)
            writeQueues[key] = queue
            return queue
        }
    }

    /// 启动时自身可执行文件的身份。应用更新会整体替换 PeekBox.app，正在运行的旧后台服务不会因此退出
    /// （连接未断时空闲计时不开始），但此后系统按磁盘上的新程序核对它：访问桌面、文稿等隐私保护位置被拒绝
    /// （tccd "Failed to create Attribution Chain"），客户端也因签名不符拒收它的回复。所以旧进程不再接新连接，
    /// 手头任务做完立即退出，下一次连接由 launchd 拉起新版本
    private let executableIdentity = Bundle.main.executablePath.flatMap(FileIdentity.init(path:))

    private var isOutdated: Bool {
        guard let executableIdentity, let path = Bundle.main.executablePath else { return false }
        return FileIdentity(path: path) != executableIdentity
    }

    /// 监视外层 PeekBox.app：被替换（Sparkle 原子交换）、移走（Finder 覆盖时移到废纸篓）或删除时由内核通知，
    /// 不轮询。旧进程据此立即退出，而不是等到下一个连接进来才发现过期并拒绝它
    /// （否则更新后预览里的第一次操作会丢失，再点一次才由 launchd 拉起新版本）
    private var appBundleWatcher: DispatchSourceFileSystemObject?

    func watchAppBundle() {
        let url = Bundle.mainApp.bundleURL
        guard url.pathExtension == "app" else { return }
        // O_EVTONLY：只为接收事件打开，不妨碍目录被移走、删除或卷被推出
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else {
            log.error("cannot watch app bundle: \(String(cString: strerror(errno)), privacy: .public)")
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.rename, .delete, .revoke],
                                                               queue: queue)
        source.setEventHandler { [weak self] in self?.appBundleChanged() }
        source.setCancelHandler { close(fd) }
        source.resume()
        appBundleWatcher = source
    }

    /// 在 queue 上执行。手头没有任务就立即退出；正在写入等则做完再退出（见 endWork）
    private func appBundleChanged() {
        guard isOutdated else { return }
        appBundleWatcher?.cancel()
        appBundleWatcher = nil
        guard activeWork == 0 else {
            log.notice("app updated, exiting after \(self.activeWork) task(s) finish")
            return
        }
        log.notice("app updated, exiting outdated broker")
        exit(0)
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard !isOutdated else {
            log.notice("app updated, rejecting connection from pid \(connection.processIdentifier)")
            queue.async { if self.activeConnections == 0 { self.scheduleIdleExit() } }
            return false
        }
        // 只接受同一 Team 签名的客户端
        connection.setCodeSigningRequirement(PeekShared.teamRequirement)
        connection.exportedInterface = NSXPCInterface(with: PeekBrokerProtocol.self)
        connection.exportedObject = self
        connection.invalidationHandler = { [weak self] in self?.connectionEnded() }
        queue.sync {
            activeConnections += 1
            idleTimer?.cancel()
            idleTimer = nil
        }
        log.notice("accepted connection from pid \(connection.processIdentifier)")
        connection.resume()
        return true
    }

    private func connectionEnded() {
        queue.async {
            self.activeConnections -= 1
            if self.activeConnections == 0 { self.scheduleIdleExit() }
        }
    }

    /// 须在 queue 上调用。
    func scheduleIdleExit() {
        if activeWork == 0, isOutdated {
            log.notice("app updated, exiting outdated broker")
            exit(0)
        }
        idleTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.idleTimeout)
        timer.setEventHandler { [weak self, log] in
            guard let self, self.activeWork == 0, self.activeConnections == 0 else { return }
            log.notice("idle, exiting")
            exit(0)
        }
        timer.resume()
        idleTimer = timer
    }

    /// 在后台执行耗时任务，完成后若已无连接则重新开始空闲计时
    func performWork(_ body: @escaping @Sendable () -> Void) {
        beginWork()
        DispatchQueue.global(qos: .userInitiated).async {
            body()
            self.endWork()
        }
    }

    /// 跨越多个阶段的任务（如等待用户在面板中输入）用 begin / end 包住，期间不空闲退出
    func beginWork() {
        queue.sync { activeWork += 1 }
    }

    func endWork() {
        queue.async {
            self.activeWork -= 1
            // 已被新版本替换时，任务做完即退出，不等预览端断开连接（scheduleIdleExit 中退出）
            if self.activeWork == 0, self.activeConnections == 0 || self.isOutdated { self.scheduleIdleExit() }
        }
    }

    // MARK: - PeekBrokerProtocol

    func ping(reply: @escaping @Sendable (String) -> Void) {
        reply("pid \(getpid())")
    }

    func openMainApp(command: String, reply: @escaping @Sendable (Bool, String?) -> Void) {
        guard let command = MainAppCommand(rawValue: command) else {
            reply(false, String(localized: "未知命令：\(command)", bundle: .app))
            return
        }
        // 明确交给外层的主应用：只按 peekbox: 链接打开时，LaunchServices 可能选中构建目录
        // 或安装中间产物里的其他副本，拉起后即退出，设置窗口打不开
        let app = Bundle.mainApp.bundleURL
        log.notice("open main app: \(command.rawValue, privacy: .public) via \(app.path, privacy: .public)")
        let completion: @Sendable (NSRunningApplication?, (any Error)?) -> Void = { [log] _, error in
            if let error { log.error("open main app failed: \(error.localizedDescription, privacy: .public)") }
            reply(error == nil, error?.localizedDescription)
        }
        if app.pathExtension == "app" {
            NSWorkspace.shared.open([command.url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration(),
                                    completionHandler: completion)
        } else {
            NSWorkspace.shared.open(command.url, configuration: NSWorkspace.OpenConfiguration(), completionHandler: completion)
        }
    }
}

extension Broker {
    func openFile(path: String, appPath: String?, reply: @escaping @Sendable (Bool, String?) -> Void) {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            reply(false, String(localized: "文件不存在", bundle: .app))
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        log.notice("open \((path as NSString).lastPathComponent, privacy: .public) with \(appPath.map { ($0 as NSString).lastPathComponent } ?? "default", privacy: .public)")
        if let appPath {
            NSWorkspace.shared.open([url], withApplicationAt: URL(fileURLWithPath: appPath),
                                    configuration: configuration) { _, error in
                reply(error == nil, error?.localizedDescription)
            }
        } else {
            NSWorkspace.shared.open(url, configuration: configuration) { _, error in
                reply(error == nil, error?.localizedDescription)
            }
        }
    }

    func copyToPasteboard(paths: [String], text: String?, reply: @escaping @Sendable (Bool, String?) -> Void) {
        DispatchQueue.main.async {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            var objects: [NSPasteboardWriting] = paths.map { URL(fileURLWithPath: $0) as NSURL }
            if let text { objects.append(text as NSString) }
            let ok = pasteboard.writeObjects(objects)
            self.log.notice("pasteboard: \(paths.count) files, text \(text != nil), ok \(ok)")
            reply(ok, ok ? nil : String(localized: "写入剪贴板失败", bundle: .app))
        }
    }

    func setSettings(_ data: Data, reply: @escaping @Sendable (Bool) -> Void) {
        let ok = SettingsStore.mergeSettings(data)
        log.notice("settings merged: \(ok)")
        reply(ok)
    }

    func reveal(paths: [String], reply: @escaping @Sendable (Bool, String?) -> Void) {
        let urls = paths.map { URL(fileURLWithPath: $0) }
        DispatchQueue.main.async {
            NSWorkspace.shared.activateFileViewerSelecting(urls)
            self.log.notice("reveal \(urls.count) items in Finder")
            reply(true, nil)
        }
    }

    func trash(paths: [String], reply: @escaping @Sendable (Bool, String?) -> Void) {
        performWork {
            var failures: [String] = []
            for path in paths {
                do {
                    try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
                } catch {
                    failures.append(String(localized: "\((path as NSString).lastPathComponent)：\(error.localizedDescription)", bundle: .app))
                }
            }
            self.log.notice("trash \(paths.count) items, \(failures.count) failed")
            reply(failures.isEmpty, failures.isEmpty ? nil : failures.joined(separator: "\n"))
        }
    }

    /// 提取到 MaterializedCache 的任务目录；按保留时长在启动时回收，也可在主应用维护页立即清理
    func materialize(archivePath: String, entryPaths: [String], password: String?,
                     reply: @escaping @Sendable ([String]?, String?) -> Void) {
        performWork {
            do {
                let archive = URL(fileURLWithPath: archivePath)
                let identity = MaterializeCache.ArchiveIdentity(archive)
                let reader = try self.materializeCache.reader(for: archive, identity: identity, password: password)
                var results: [String] = []
                var reused = 0
                // 只有需要提取时才建任务目录
                var taskFolder: URL?
                for entryPath in entryPaths {
                    // 加密条目不复用：副本是解密后的内容，复用等于跳过了本次的密码校验
                    if let item = reader.tree.items[entryPath], !item.isDirectory, !item.isEncrypted,
                       let existing = self.materializeCache.reusableFile(archive: identity, entryPath: entryPath) {
                        results.append(existing.path)
                        reused += 1
                        continue
                    }
                    let folder = try taskFolder ?? MaterializedCache.makeTaskDirectory()
                    taskFolder = folder
                    let name = (entryPath as NSString).lastPathComponent
                    var target = folder.appendingPathComponent(name)
                    // 不同目录下的同名条目：后者加序号，避免互相覆盖
                    var index = 2
                    while FileManager.default.fileExists(atPath: target.path) {
                        let base = (name as NSString).deletingPathExtension
                        let ext = (name as NSString).pathExtension
                        target = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)")
                        index += 1
                    }
                    try reader.extract(path: entryPath, to: target, password: password)
                    results.append(target.path)
                    self.materializeCache.recordFile(archive: identity, entryPath: entryPath, url: target)
                }
                // 继承压缩包的隔离属性（打开下载来的 App 仍经过 Gatekeeper）；复用的副本也补上，
                // 旧版本留下的缓存没有这个属性
                Quarantine.inherit(from: archive, to: results.map { URL(fileURLWithPath: $0) })
                self.log.notice("materialized \(results.count) entries (\(reused) reused)")
                reply(results, nil)
            } catch {
                reply(nil, error.localizedDescription)
            }
        }
    }
}

extension Broker {
    func checkAccess(paths: [String], reply: @escaping @Sendable ([Bool]) -> Void) {
        performWork {
            let fm = FileManager.default
            let results = paths.map { path -> Bool in
                var isDirectory: ObjCBool = false
                guard fm.fileExists(atPath: path, isDirectory: &isDirectory) else { return false }
                if isDirectory.boolValue { return (try? fm.contentsOfDirectory(atPath: path)) != nil }
                guard let handle = FileHandle(forReadingAtPath: path) else { return false }
                try? handle.close()
                return true
            }
            self.log.notice("check access: \(results, privacy: .public)")
            reply(results)
        }
    }

    func renameInArchive(archivePath: String, entryPath: String, reply: @escaping @Sendable (String?, String?) -> Void) {
        let archive = URL(fileURLWithPath: archivePath)
        beginWork()
        let finish: @Sendable (String?, String?) -> Void = { newPath, message in
            reply(newPath, message)
            self.endWork()
        }
        writeQueue(for: archive).async {
            // 先检查可写并读出目录树，不可写时直接回复原因，不弹面板
            let tree: ArchiveTree
            let item: ArchiveTree.Item
            do {
                try ZipEditor.checkWritable(archive)
                tree = try ZipArchive.open(archive).tree
                guard let found = tree.items[entryPath] else { throw ArchiveError.entryNotFound(entryPath) }
                item = found
            } catch {
                finish(nil, error.localizedDescription)
                return
            }
            Task { @MainActor in
                RenamePanel.present(name: item.name, isDirectory: item.isDirectory,
                                    archiveName: archive.lastPathComponent, validate: { name in
                    do {
                        _ = try ZipEditor.renamedPath(in: tree, path: entryPath, newName: name)
                        return nil
                    } catch {
                        return error.localizedDescription
                    }
                }, completion: { newName in
                    guard let newName else {
                        finish(nil, nil)
                        return
                    }
                    let panel = ArchiveWritePanel(archive: archive)
                    let control = panel.control
                    self.writeQueue(for: archive).async {
                        defer { Task { @MainActor in panel.finish() } }
                        do {
                            let newPath = try ZipEditor.rename(archive: archive, path: entryPath, to: newName,
                                                               trashOldVersion: PeekPreferences.trashOldArchiveVersion, control: control)
                            self.log.notice("renamed in archive: \(entryPath, privacy: .public) → \(newPath, privacy: .public)")
                            finish(newPath, nil)
                        } catch {
                            self.log.error("rename failed: \(error.localizedDescription, privacy: .public)")
                            finish(nil, error.localizedDescription)
                        }
                    }
                })
            }
        }
    }

    func deleteInArchive(archivePath: String, entryPaths: [String], reply: @escaping @Sendable (Bool, String?) -> Void) {
        let archive = URL(fileURLWithPath: archivePath)
        beginWork()
        Task { @MainActor in
            let panel = ArchiveWritePanel(archive: archive)
            let control = panel.control
            self.writeQueue(for: archive).async {
                do {
                    let count = try ZipEditor.delete(archive: archive, paths: entryPaths,
                                                     trashOldVersion: PeekPreferences.trashOldArchiveVersion, control: control)
                    self.log.notice("deleted \(count) entries from archive")
                    reply(true, nil)
                } catch {
                    self.log.error("delete in archive failed: \(error.localizedDescription, privacy: .public)")
                    reply(false, error.localizedDescription)
                }
                Task { @MainActor in panel.finish() }
                self.endWork()
            }
        }
    }

    private static func encode(_ error: Error) -> Data? {
        try? JSONEncoder().encode(error as? ArchiveError ?? .failed(error.localizedDescription))
    }

    func archiveTree(archivePath: String, password: String?, reply: @escaping @Sendable (Data?, Data?) -> Void) {
        performWork {
            do {
                let archive = URL(fileURLWithPath: archivePath)
                let reader = try self.materializeCache.reader(for: archive, identity: MaterializeCache.ArchiveIdentity(archive),
                                                              password: password)
                reply(try JSONEncoder().encode(reader.tree), nil)
                self.log.notice("served archive tree: \(reader.tree.items.count) items")
            } catch {
                self.log.error("archive tree failed: \(error.localizedDescription, privacy: .public)")
                reply(nil, Self.encode(error))
            }
        }
    }

    func extractEntries(archivePath: String, entryPaths: [String], targets: [String], password: String?,
                        reply: @escaping @Sendable (Data?) -> Void) {
        performWork {
            do {
                let archive = URL(fileURLWithPath: archivePath)
                let reader = try self.materializeCache.reader(for: archive, identity: MaterializeCache.ArchiveIdentity(archive),
                                                              password: password)
                guard entryPaths.count == targets.count else { throw ArchiveError.failed("entry / target count mismatch") }
                let jobs = try zip(entryPaths, targets).map { path, target in
                    guard let item = reader.tree.items[path], !item.isDirectory else { throw ArchiveError.entryNotFound(path) }
                    let url = URL(fileURLWithPath: target)
                    guard !FileManager.default.fileExists(atPath: url.path) else {
                        throw ArchiveError.destinationExists(url.lastPathComponent)
                    }
                    return (item: item, target: url)
                }
                try reader.extractFiles(jobs, password: password)
                Quarantine.inherit(from: archive, to: jobs.map(\.target))
                self.log.notice("extracted \(jobs.count) entries for client")
                reply(nil)
            } catch {
                self.log.error("extract entries failed: \(error.localizedDescription, privacy: .public)")
                reply(Self.encode(error))
            }
        }
    }

    func archiveWriteStatus(archivePath: String, reply: @escaping @Sendable (String?) -> Void) {
        performWork {
            do {
                try ZipEditor.checkAdditions(URL(fileURLWithPath: archivePath))
                reply(nil)
            } catch { reply(error.localizedDescription) }
        }
    }

    func createArchiveDirectory(archivePath: String, parent: String,
                                reply: @escaping @Sendable (String?, String?) -> Void) {
        let archive = URL(fileURLWithPath: archivePath)
        beginWork()
        let finish: @Sendable (String?, String?) -> Void = { path, message in
            reply(path, message)
            self.endWork()
        }
        writeQueue(for: archive).async {
            do {
                try ZipEditor.checkAdditions(archive)
                // 同层名称集合只建立一次，默认名称递增与输入校验都查它（父目录不存在时这里就抛错）
                let siblings = try ZipEditor.SiblingNames(tree: ZipArchive.open(archive).tree, parent: parent)
                let base = String(localized: "未命名文件夹", bundle: .app)
                var name = base
                var suffix = 2
                while (try? siblings.folderPath(for: name)) == nil {
                    name = "\(base) \(suffix)"
                    suffix += 1
                }
                let suggested = name
                Task { @MainActor in
                    RenamePanel.present(name: suggested, isDirectory: true, creating: true,
                                        archiveName: archive.lastPathComponent,
                                        location: parent.isEmpty ? nil : (parent as NSString).lastPathComponent,
                                        validate: { name in
                        do { _ = try siblings.folderPath(for: name); return nil }
                        catch { return error.localizedDescription }
                    }, completion: { name in
                        guard let name else { finish(nil, nil); return }
                        let panel = ArchiveWritePanel(archive: archive)
                        let control = panel.control
                        self.writeQueue(for: archive).async {
                            defer { Task { @MainActor in panel.finish() } }
                            do { finish(try ZipEditor.createDirectory(archive: archive, parent: parent, name: name, control: control), nil) }
                            catch ZipEditor.EditError.cancelled { finish(nil, nil) }
                            catch { finish(nil, error.localizedDescription) }
                        }
                    })
                }
            } catch { finish(nil, error.localizedDescription) }
        }
    }

    func addToArchive(archivePath: String, sourcePaths: [String], parent: String,
                      reply: @escaping @Sendable (Int, Int, Int, Bool, String?) -> Void) {
        let archive = URL(fileURLWithPath: archivePath)
        beginWork()
        Task { @MainActor in
            let panel = ArchiveWritePanel(archive: archive)
            let control = panel.control
            self.writeQueue(for: archive).async {
                do {
                    let summary = try ZipEditor.addFiles(archive: archive, sources: sourcePaths.map { URL(fileURLWithPath: $0) },
                                                         parent: parent, trashOldVersion: PeekPreferences.trashOldArchiveVersion,
                                                         control: control, resolve: { panel.resolve($0) })
                    self.log.notice("added to archive: \(summary.added) added, \(summary.replaced) replaced, \(summary.skipped) skipped")
                    reply(summary.added, summary.replaced, summary.skipped, false, nil)
                } catch ZipEditor.EditError.cancelled {
                    self.log.notice("add to archive cancelled")
                    reply(0, 0, 0, true, nil)
                } catch {
                    self.log.error("add to archive failed: \(error.localizedDescription, privacy: .public)")
                    reply(0, 0, 0, false, error.localizedDescription)
                }
                Task { @MainActor in panel.finish() }
                self.endWork()
            }
        }
    }

    func copyFromArchive(archivePath: String, entryPaths: [String], destination: String, password: String?,
                         reply: @escaping @Sendable (Int, Int, Int, Bool, String?) -> Void) {
        let archive = URL(fileURLWithPath: archivePath)
        let target = URL(fileURLWithPath: destination, isDirectory: true)
        beginWork()
        Task { @MainActor in
            let panel = ArchiveWritePanel(archive: archive, copyDestination: target)
            let control = panel.control
            // 按目标文件夹串行：同时往"应用程序"拷两次时冲突判断不会互相干扰
            self.writeQueue(for: target).async {
                do {
                    let reader = try self.materializeCache.reader(for: archive, identity: MaterializeCache.ArchiveIdentity(archive),
                                                                  password: password)
                    let summary = try ArchiveCopier.copy(reader: reader, archive: archive, paths: entryPaths, to: target,
                                                         password: password, control: control, resolve: { panel.resolve($0) })
                    self.log.notice("copied from archive: \(summary.added) added, \(summary.replaced) replaced, \(summary.skipped) skipped")
                    reply(summary.added, summary.replaced, summary.skipped, false, nil)
                } catch ZipEditor.EditError.cancelled {
                    self.log.notice("copy from archive cancelled")
                    reply(0, 0, 0, true, nil)
                } catch {
                    self.log.error("copy from archive failed: \(error.localizedDescription, privacy: .public)")
                    reply(0, 0, 0, false, error.localizedDescription)
                }
                Task { @MainActor in panel.finish() }
                self.endWork()
            }
        }
    }

    func probeWrite(directory: String, reply: @escaping @Sendable (Bool, String) -> Void) {
        let fm = FileManager.default
        let folder = URL(fileURLWithPath: directory, isDirectory: true)
        let name = ".peekbox-probe-\(UUID().uuidString.prefix(8))"
        let target = folder.appendingPathComponent(name)
        let replacement = folder.appendingPathComponent(name + ".new")
        var steps: [String] = []
        do {
            try Data("v1".utf8).write(to: target)
            steps.append(String(localized: "创建", bundle: .app))
            try Data("v2".utf8).write(to: replacement)
            _ = try fm.replaceItemAt(target, withItemAt: replacement)
            steps.append(String(localized: "替换", bundle: .app))
            var trashed: NSURL?
            try fm.trashItem(at: target, resultingItemURL: &trashed)
            steps.append(String(localized: "移到废纸篓", bundle: .app))
            // 探测文件不留在废纸篓里
            if let trashed = trashed as URL? { try? fm.removeItem(at: trashed) }
            reply(true, String(localized: "\(folder.lastPathComponent)：", bundle: .app) + steps.joined(separator: " → "))
        } catch {
            try? fm.removeItem(at: target)
            try? fm.removeItem(at: replacement)
            let done = steps.isEmpty ? "" : steps.joined(separator: " → ") + String(localized: " 后", bundle: .app)
            reply(false, String(localized: "\(folder.lastPathComponent)：\(done)失败：\(error.localizedDescription)", bundle: .app))
        }
        log.notice("probe write \(directory, privacy: .public): \(steps.joined(separator: ","), privacy: .public)")
    }
}

// 开发用：直接弹出面板检查样式（见 DialogDemo）
MainActor.assumeIsolated { DialogDemo.runIfRequested() }

let broker = Broker()
let listener = NSXPCListener(machServiceName: PeekShared.brokerMachService)
listener.delegate = broker
// 串行清扫上次崩溃留下的未提交包后，再接收新写任务。
ZipEditor.cleanupAbandonedTransactions()
listener.resume()
broker.watchAppBundle()
// 被拉起后若始终没有连接，同样按空闲退出
broker.scheduleIdleExitOnStart()
// 回收超过保留时长的提取文件（后台服务按需启动，启动频率足够）
broker.performWork {
    let removed = MaterializedCache.purgeExpired()
    if removed > 0 { Logger.peek("Broker").notice("purged \(removed) expired cache folders") }
}
// 以附属应用运行 NSApplication：改名面板需要处理窗口事件；附属应用不出现在 Dock，也不抢前台。
// 不用 dispatchMain()：activateFileViewerSelecting 等 AppKit 调用依赖主 RunLoop，
// 只有 dispatchMain() 时这些请求会被丢弃（日志 "Attempting to use the main runloop, but the main thread has exited"）
NSApplication.shared.setActivationPolicy(.accessory)
NSApplication.shared.run()

extension Broker {
    func scheduleIdleExitOnStart() {
        queue.async { if self.activeConnections == 0 { self.scheduleIdleExit() } }
    }
}
