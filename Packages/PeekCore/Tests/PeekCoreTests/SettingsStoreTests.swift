import Foundation
import Testing
@testable import PeekCore

@Suite struct SettingsStoreTests {
    @Test func valuesAreSharedThroughTheFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SettingsStoreTests-\(UUID().uuidString)/settings.plist")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        // 两个实例模拟两个进程（如扩展与主应用）
        let writer = SettingsStore(url: url)
        let reader = SettingsStore(url: url)
        reader.checkInterval = 0
        #expect(reader.value(forKey: "fontSize") == nil)

        writer.set(15, forKey: "fontSize")
        writer.set(true, forKey: "largeRows")
        #expect(reader.value(forKey: "fontSize") as? Int == 15)
        #expect(reader.value(forKey: "largeRows") as? Bool == true)

        // 后写入方合并而不是覆盖对方已写入的键
        reader.set(false, forKey: "showToolbar")
        writer.checkInterval = 0
        #expect(writer.value(forKey: "fontSize") as? Int == 15)
        #expect(writer.value(forKey: "showToolbar") as? Bool == false)
    }

    /// 两个进程同时写不同的键，整份读改写不能互相覆盖
    @Test func concurrentWritersDoNotLoseKeys() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SettingsStoreTests-\(UUID().uuidString)/settings.plist")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let stores = [SettingsStore(url: url), SettingsStore(url: url)]
        let perWriter = 150
        DispatchQueue.concurrentPerform(iterations: stores.count) { writer in
            for index in 0..<perWriter {
                stores[writer].set(index, forKey: "w\(writer)-k\(index)")
            }
        }
        let data = try Data(contentsOf: url)
        let saved = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(saved.count == stores.count * perWriter)
    }
}
